#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

#How to run it
#tmt -c distro=rhel-9.1 -c agent=rust run plan --default discover -h fmf -t /setup/configure_kernel_ima_module/ima_policy_simple -t /functional/keylime_agent_container-basic-attestation -vv provision --how=connect --guest=testvm --user root prepare execute --how tmt --interactive login finish
#Machine should have /dev/tpm0 or /dev/tpmrm0 device
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

# If VERIFIER_IMAGE env var is set, the test will try to pull the image from the
# registry set in REGISTRY (default quay.io). Otherwise the test will build the
# verifier image from the Dockerfile set in VERIFIER_DOCKERFILE.
#
# The same applies for REGISTRAR_IMAGE and respective REGISTRAR_DOCKERFILE.

[ -n "$VERIFIER_DOCKERFILE" ] || VERIFIER_DOCKERFILE=Dockerfile.upstream.c9s
[ -n "$REGISTRAR_DOCKERFILE" ] || REGISTRAR_DOCKERFILE=Dockerfile.upstream.c9s
[ -n "$AGENT_DOCKERFILE" ] || AGENT_DOCKERFILE=Dockerfile.upstream.c9s

[ -n "$REGISTRY" ] || REGISTRY=quay.io

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # update /etc/keylime.conf
        limeBackupConfig
        CONT_NETWORK_NAME="container_network"
        IP_VERIFIER="172.18.0.4"
        IP_REGISTRAR="172.18.0.8"
        IP_AGENT="172.18.0.12"
        #create network for containers
        rlRun "limeconCreateNetwork ${CONT_NETWORK_NAME} 172.18.0.0/16"

        #prepare verifier container
        rlRun "limeUpdateConf verifier ip $IP_VERIFIER"
        rlRun "limeUpdateConf verifier registrar_ip $IP_REGISTRAR"
        #for log purposes, when agent fail, we need see verifier log, that attestation failed
        rlRun "limeUpdateConf verifier log_destination stream"

        # prepare registrar container
        rlRun "limeUpdateConf registrar ip $IP_REGISTRAR"

        # Pull or build verifier container
        TAG_VERIFIER="verifier_image"
        if [ -n "$VERIFIER_IMAGE" ]; then
            rlRun "limeconPullImage $REGISTRY $VERIFIER_IMAGE $TAG_VERIFIER"
        else
            rlRun "limeconPrepareImage ${VERIFIER_DOCKERFILE} ${TAG_VERIFIER}"
        fi

        # Pull or build registrar container
        TAG_REGISTRAR="registrar_image"
        if [ -n "$REGISTRAR_IMAGE" ]; then
            rlRun "limeconPullImage $REGISTRY $REGISTRAR_IMAGE $TAG_REGISTRAR"
        else
            rlRun "limeconPrepareImage ${REGISTRAR_DOCKERFILE} ${TAG_REGISTRAR}"
        fi

        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            # start ima emulator
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi
        sleep 5

        #run verifier container
        CONT_VERIFIER="verifier_container"
        rlRun "limeconRunVerifier $CONT_VERIFIER $TAG_VERIFIER $IP_VERIFIER $CONT_NETWORK_NAME keylime_verifier /etc/keylime"
        rlRun "limeWaitForVerifier 8881 $IP_VERIFIER"
        #wait for generating of certs
        sleep 5
        rlRun "podman cp $CONT_VERIFIER:/var/lib/keylime/cv_ca/ ."

        #tenant need certs
        rlRun "cp -r cv_ca/ /var/lib/keylime/"

        #run registrar container
        CONT_REGISTRAR="registrar_container"
        rlRun "limeconRunRegistrar $CONT_REGISTRAR $TAG_REGISTRAR $IP_REGISTRAR $CONT_NETWORK_NAME keylime_registrar /etc/keylime $(realpath ./cv_ca)"
        rlRun "limeWaitForRegistrar 8891 $IP_REGISTRAR"

        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant verifier_ip $IP_VERIFIER"
        rlRun "limeUpdateConf tenant registrar_ip $IP_REGISTRAR"

        #setup of agent
        TAG_AGENT="agent_image"
        CONT_AGENT="agent_container"
        rlRun "limeconPrepareImage ${AGENT_DOCKERFILE} ${TAG_AGENT}"
        rlRun "limeUpdateConf agent registrar_ip '\"$IP_REGISTRAR\"'"
        rlRun "limeconPrepareAgentConfdir $AGENT_ID $IP_AGENT confdir_$CONT_AGENT"

        # create some scripts
        TESTDIR=`limeCreateTestDir`
        rlRun "echo -e '#!/bin/bash\necho This is good-script1' > $TESTDIR/good-script1.sh && chmod a+x $TESTDIR/good-script1.sh"
        rlRun "echo -e '#!/bin/bash\necho This is good-script2' > $TESTDIR/good-script2.sh && chmod a+x $TESTDIR/good-script2.sh"
        # create allowlist and excludelist
        rlRun "limeCreateTestPolicy ${TESTDIR}/*"

        rlRun "limeconRunAgent $CONT_AGENT $TAG_AGENT $IP_AGENT $CONT_NETWORK_NAME $TESTDIR keylime_agent $PWD/confdir_$CONT_AGENT $(realpath ./cv_ca)"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        rlRun -s "keylime_tenant -v $IP_VERIFIER  -t $IP_AGENT -u $AGENT_ID --runtime-policy policy.json -f /etc/hosts -c add"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Running allowed scripts should not affect attestation"
        rlRun "${TESTDIR}/good-script1.sh"
        rlRun "${TESTDIR}/good-script2.sh"
        rlRun "tail /sys/kernel/security/ima/ascii_runtime_measurements | grep good-script1.sh"
        rlRun "tail /sys/kernel/security/ima/ascii_runtime_measurements | grep good-script2.sh"
        rlRun "sleep 5"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/bad-script.sh && chmod a+x $TESTDIR/bad-script.sh"
        rlRun "$TESTDIR/bad-script.sh"
        rlRun "sleep 5"
        rlRun "podman logs verifier_container | grep \"keylime.verifier - WARNING - Agent d432fbb3-d2f1-4a97-9ef7-75bd81c00000 failed, stopping polling\""
        rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        limeconSubmitLogs
        rlRun "limeconStop registrar_container verifier_container agent_container"
        rlRun "limeconDeleteNetwork $CONT_NETWORK_NAME"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeExtendNextExcludelist $TESTDIR
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd

