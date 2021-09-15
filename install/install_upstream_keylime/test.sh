#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup "Install keylime and its dependencies"
        # configure Sergio's copr repo providing necessary dependencies
        if rlIsRHEL 9; then
            rlRun 'cat > /etc/yum.repos.d/keylime.repo <<_EOF
[copr:copr.devel.redhat.com:scorreia:keylime]
name=Copr repo for keylime owned by scorreia
baseurl=http://coprbe.devel.redhat.com/results/scorreia/keylime/rhel-9.dev-\$basearch/
type=rpm-md
skip_if_unavailable=True
gpgcheck=0
gpgkey=http://coprbe.devel.redhat.com/results/scorreia/keylime/pubkey.gpg
repo_gpgcheck=0
enabled=1
enabled_metadata=1
_EOF'
        fi
        rlRun "yum -y install git-core python3-pip python3-pyyaml python3-tornado python3-simplejson python3-requests python3-sqlalchemy python3-alembic python3-packaging python3-psutil python3-gnupg python3-cryptography libselinux-python3 procps-ng tpm2-abrmd tpm2-tss tpm2-tools python3-zmq cfssl patch"
        rlRun "rm -rf keylime && git clone https://github.com/keylime/keylime.git"
        pushd keylime
        rlRun "python3 setup.py install"
        popd
    rlPhaseEnd

    rlPhaseStartTest "Test installed binaries"
        rlRun "keylime_tenant --help"
    rlPhaseEnd

rlJournalEnd
