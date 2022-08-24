#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

[ "$INSTALL_SERVICE_FILES" == "0" -o "$INSTALL_SERVICE_FILES" == "false" ] && INSTALL_SERVICE_FILES=false || INSTALL_SERVICE_FILES=true

[ -n "${KEYLIME_UPSTREAM_URL}" ] || KEYLIME_UPSTREAM_URL="https://github.com/keylime/keylime.git"
[ -n "${KEYLIME_UPSTREAM_BRANCH}" ] || KEYLIME_UPSTREAM_BRANCH="master"

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
        rlRun "yum -y install $FEDORA_EXTRA_PKGS $RHEL_EXTRA_PKGS git-core python3-pip python3-pyyaml python3-tornado python3-requests python3-sqlalchemy python3-alembic python3-psutil python3-gnupg python3-cryptography libselinux-python3 python3-pyasn1 python3-pyasn1-modules python3-jinja2 procps-ng tpm2-abrmd tpm2-tss tpm2-tools patch"
        if [ -z "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "yum -y install python3-zmq"
        fi
        # need to install few more pgs from pip on RHEL
        if ! rlIsFedora; then
            rlRun "pip3 install lark-parser $RHEL_EXTRA_PIP_PKGS"
        fi
        if [ -d /var/tmp/keylime_sources ]; then
            rlLogInfo "Installing keylime from /var/tmp/keylime_sources"
        else
            rlLogInfo "Installing keylime from cloned upstream repo"
            rlRun "git clone -b ${KEYLIME_UPSTREAM_BRANCH} ${KEYLIME_UPSTREAM_URL} /var/tmp/keylime_sources"
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
        [ -d /etc/keylime ] && rlRun "mv /etc/keylime /etc/keylime.backup$$" && "rm -rf /etc/keylime"
        rlRun "mkdir -p /etc/keylime && chmod 700 /etc/keylime"
        rlRun "python3 setup.py install"

        # create directory structure in /etc/keylime and copy config files there
        for comp in "agent" "verifier" "tenant" "registrar" "ca" "logging"; do
            rlRun "mkdir -p /etc/keylime/$comp.conf.d"
            rlRun "cp -n config/$comp.conf /etc/keylime/"
        done

        # configure TPM to use sha256
        rlRun 'cat > /etc/keylime/agent.conf.d/tpm_hash_alg.conf <<_EOF
[agent]
tpm_hash_alg = sha256
_EOF'

        if $INSTALL_SERVICE_FILES; then
            rlRun "cd services; bash installer.sh"
            rlRun "systemctl daemon-reload"
        fi

        # fix conf file ownership
        rlRun "chown -R keylime.keylime /etc/keylime"
        rlRun "find /etc/keylime -type f -exec chmod 400 {} \;"
        rlRun "find /etc/keylime -type d -exec chmod 500 {} \;"
        ls -lR /etc/keylime

        rlRun "popd"
    rlPhaseEnd

    rlPhaseStartTest "Test installed binaries"
        rlRun "keylime_tenant --help"
    rlPhaseEnd

rlJournalEnd
