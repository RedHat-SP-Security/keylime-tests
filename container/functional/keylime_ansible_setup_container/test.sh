#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

#How to run it
#tmt -c distro=rhel-9.1 -c agent=rust run plan --default discover -h fmf -t /setup/configure_kernel_ima_module/ima_policy_simple -t /functional/keylime_agent_container-basic-attestation -vv provision --how=connect --guest=testvm --user root prepare execute --how tmt --interactive login finish
#Machine should have /dev/tpm0 or /dev/tpmrm0 device
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # update /etc/keylime.conf
        limeBackupConfig
        CONT_NETWORK_NAME="container_network"
        IP="172.18.0.12"
        #create network for containers
        rlRun "limeconCreateNetwork ${CONT_NETWORK_NAME} 172.18.0.0/16"
        rlRun "limeconSetupSSH --file ${limeLibraryDir}/Dockerfile.ansible"
        rlRun "podman build -t ssh_container_image --file ${limeLibraryDir}/Dockerfile.ansible ."
        rlRun "podman run -d --cap-add CAP_AUDIT_WRITE --name ssh_access_container --net $CONT_NETWORK_NAME --ip $IP localhost/ssh_container_image"
        #rlRun "ssh -o \"StrictHostKeyChecking=no\" $IP"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "rm -f /root/.ssh/id_rsa*"
        rlRun "> /root/.ssh/known_hosts"
        rlRun "limeconStop 'ssh_access_container'"
        rlRun "limeconDeleteNetwork $CONT_NETWORK_NAME"
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd

