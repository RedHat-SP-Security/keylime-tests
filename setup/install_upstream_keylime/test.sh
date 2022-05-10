#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

[ "$INSTALL_SERVICE_FILES" == "0" -o "$INSTALL_SERVICE_FILES" == "false" ] && INSTALL_SERVICE_FILES=false || INSTALL_SERVICE_FILES=true

rlJournalStart

    rlPhaseStartSetup "Install keylime and its dependencies"
        # remove all install keylime packages
        rlRun "yum remove -y python3-keylime\* keylime\*"
        # build and install keylime-99 dummy RPM
        rlRun -s "rpmbuild -bb keylime.spec"
        RPMPKG=$( awk '/Wrote:/ { print $2 }' $rlRun_LOG )
        # replace installed keylime with our newly built dummy package
        rlRun "rpm -Uvh $RPMPKG"
        # for RHEL and CentOS Stream configure Sergio's copr repo providing necessary dependencies
        if rlIsFedora; then
            FEDORA_EXTRA_PKGS="python3-lark-parser python3-packaging"
        else
            # on C9S we need to enable LEGACY crypto policy to enable SHA1 RPM signatures
            if rlIsRHEL 9 || rlIsCentOS 9; then
                rlRun "dnf upgrade -y https://kojihub.stream.centos.org/kojifiles/packages/crypto-policies/20220223/1.git5203b41.el9/noarch/crypto-policies-20220223-1.git5203b41.el9.noarch.rpm https://kojihub.stream.centos.org/kojifiles/packages/crypto-policies/20220223/1.git5203b41.el9/noarch/crypto-policies-scripts-20220223-1.git5203b41.el9.noarch.rpm"
                rlRun "update-crypto-policies --set LEGACY"
            fi

            rlRun 'cat > /etc/yum.repos.d/keylime.repo <<_EOF
[copr:copr.fedorainfracloud.org:scorreia:keylime]
name=Copr repo for keylime owned by scorreia
baseurl=https://download.copr.fedorainfracloud.org/results/scorreia/keylime/centos-stream-\$releasever-\$basearch/
type=rpm-md
skip_if_unavailable=True
gpgcheck=1
gpgkey=https://download.copr.fedorainfracloud.org/results/scorreia/keylime/pubkey.gpg
repo_gpgcheck=0
enabled=1
enabled_metadata=1
_EOF'
            RHEL_EXTRA_PKGS="cfssl python3-pip"
            if rlIsRHEL 8 || rlIsCentOS 8; then
                RHEL_EXTRA_PIP_PKGS="packaging"
            else
                RHEL_EXTRA_PKGS="$RHEL_EXTRA_PKGS python3-packaging"
            fi
        fi
        rlRun "yum -y install $FEDORA_EXTRA_PKGS $RHEL_EXTRA_PKGS git-core python3-pip python3-pyyaml python3-tornado python3-requests python3-sqlalchemy python3-alembic python3-psutil python3-gnupg python3-cryptography libselinux-python3 procps-ng tpm2-abrmd tpm2-tss tpm2-tools patch"
	# enable the following condition once https://github.com/keylime/keylime/pull/987 is merged
	# if test ${KEYLIME_TEST_DISABLE_REVOCATION-unset} = unset; then
            rlRun "yum -y install python3-zmq"
	# fi
        # need to install few more pgs from pip on RHEL
        if ! rlIsFedora; then
            rlRun "pip3 install lark-parser $RHEL_EXTRA_PIP_PKGS"
        fi
        if [ -d /var/tmp/keylime_sources ]; then
            rlLogInfo "Installing keylime from /var/tmp/keylime_sources"
        else
            rlLogInfo "Installing keylime from cloned upstream repo"
            rlRun "git clone https://github.com/keylime/keylime.git /var/tmp/keylime_sources"
        fi
        rlRun "pushd /var/tmp/keylime_sources"
        # print more details about the code we are going to use
        rlLogInfo "Getting more details about the Packit environment"
        env | grep "PACKIT_"
        rlLogInfo "Getting more details about the code we are going to use"
        if [ -d .git ]; then
            git config --get remote.origin.url
            git status
            git log -n 10 --oneline
        fi
        # clear files that could be present from previous installation and be disruptive
        # in particular db migration files
        rlRun "rm -rf build/lib/keylime/migrations"
        [ -d /usr/local/lib/python*/site-packages/keylime-*/keylime/migrations ] && rlRun "rm -rf /usr/local/lib/python*/site-packages/keylime-*/keylime/migrations"
        rlRun "python3 setup.py install"
        # copy keylime.conf to /etc
        rlRun "cp keylime.conf /etc"
        if $INSTALL_SERVICE_FILES; then
            rlRun "cd services; bash installer.sh"
            rlRun "systemctl daemon-reload"
        fi
        rlRun "popd"
    rlPhaseEnd

    rlPhaseStartTest "Test installed binaries"
        rlRun "keylime_tenant --help"
    rlPhaseEnd

rlJournalEnd
