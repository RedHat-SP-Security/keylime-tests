#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

[ "$INSTALL_SERVICE_FILES" == "0" -o "$INSTALL_SERVICE_FILES" == "false" ] && INSTALL_SERVICE_FILES=false || INSTALL_SERVICE_FILES=true

[ -n "${KEYLIME_UPSTREAM_URL}" ] || KEYLIME_UPSTREAM_URL="https://github.com/keylime/keylime.git"
[ -n "${KEYLIME_UPSTREAM_BRANCH}" ] || KEYLIME_UPSTREAM_BRANCH="master"

rlJournalStart

    rlPhaseStartTest "Install keylime and its dependencies"
        EXTRA_PKGS="git-core libselinux-python3 patch procps-ng tpm2-abrmd tpm2-tss tpm2-tools rpm-build"
        PYTHON_PKGS="python3-alembic python3-cryptography python3-gpg python3-jinja2 python3-jsonschema python3-pip python3-psutil python3-pyasn1 python3-pyasn1-modules python3-pyyaml python3-requests python3-sqlalchemy python3-tornado python3-lark-parser python3-packaging"
        if rlIsRHELLike 9; then
            EXTRA_PKGS+=" gpgme gcc python3.12-devel libpq-devel"
            PYTHON_PKGS="python3.12 python3.12-setuptools python3.12-pip python3.12-requests python3.12-pyyaml python3.12-wheel python3-gpg"
            EXTRA_PIP_PKGS="typing-extensions cryptography packaging pyasn1 pyasn1-modules jinja2 lark jsonschema tornado sqlalchemy psutil alembic pymysql psycopg2"
        elif rlIsFedora 36; then
            EXTRA_PKGS+=" python3-pip"
            EXTRA_PIP_PKGS="typing_extensions"
        fi
        rlRun "yum -y install ${EXTRA_PKGS} ${PYTHON_PKGS} ${EXTRA_DNF_ARGS}"
        if [ -z "$KEYLIME_TEST_DISABLE_REVOCATION" ] && rlIsFedora; then
            rlRun "yum -y install python3-zmq"
        fi
        # need to install few more pgs from pip
        if [ -n "$EXTRA_PIP_PKGS" ]; then
	    if rlIsRHELLike 9; then
                rlRun "pip3.12 install $EXTRA_PIP_PKGS"
	    else
                rlRun "pip3 install $EXTRA_PIP_PKGS"
	    fi
        fi
	# need to fake python3.12-gpg since it cannot be installed
	if rlIsRHELLike 9; then
            rlRun "cp -r /usr/lib64/python3.9/site-packages/gpg /usr/lib64/python3.12/site-packages/"
	    rlRun "find /usr/lib64/python3.12/site-packages/gpg -name __pycache__ -exec rm -rf {} \\;" 0,1
	    rlRun "mv /usr/lib64/python3.12/site-packages/gpg/_gpgme.cpython-39-x86_64-linux-gnu.so /usr/lib64/python3.12/site-packages/gpg/_gpgme.cpython-312-x86_64-linux-gnu.so"
	fi
        # remove all install keylime packages
        rlRun "yum remove -y --noautoremove python3-keylime\* keylime\*"
        # build and install keylime-99 dummy RPM
        rlRun -s "rpmbuild -bb keylime.spec"
        RPMPKG=$( awk '/Wrote:/ { print $2 }' $rlRun_LOG )
        # replace installed keylime with our newly built dummy package
        rlRun "rpm -Uvh $RPMPKG"
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
        # remove previously created build directory if exists
        rlRun "rm -rf build"
        [ -d /usr/local/lib/python*/site-packages/keylime-*/keylime/migrations ] && rlRun "rm -rf /usr/local/lib/python*/site-packages/keylime-*/keylime/migrations"
        [ -d /etc/keylime ] && rlRun "mv /etc/keylime /etc/keylime.backup$$" && "rm -rf /etc/keylime"
        rlRun "mkdir -p /etc/keylime && chmod 700 /etc/keylime"
        if rlIsRHELLike 9; then
            rlRun "python3.12 setup.py install"
        else
            rlRun "python3 setup.py install"
        fi

        # create directory structure in /etc/keylime and copy config files there
        for comp in "verifier" "tenant" "registrar" "ca" "logging"; do
            rlRun "mkdir -p /etc/keylime/$comp.conf.d"
            rlRun "cp -n config/$comp.conf /etc/keylime/"
        done

        # install scripts to /usr/share/keylime
        rlRun "mkdir -p /usr/share/keylime"
        rlRun "cp -r scripts /usr/share/keylime/"
        # update Python version for Python scripts
        if rlIsRHELLike 9; then
            find /usr/share/keylime/scripts -type f | while read F; do
                file "$F" | grep -qi 'python' && rlRun "sed -i '1 s/python3/python3.12/' $F"
	    done
        fi

        if $INSTALL_SERVICE_FILES; then
            rlRun "cd services; bash installer.sh"
            rlRun "systemctl daemon-reload"
        fi

        rlRun "usermod -a -G tss keylime"
        # fix conf file ownership
        rlRun "chown -R keylime:keylime /etc/keylime"
        rlRun "find /etc/keylime -type f -exec chmod 400 {} \;"
        rlRun "find /etc/keylime -type d -exec chmod 500 {} \;"
        ls -lR /etc/keylime

        rlRun "popd"
    rlPhaseEnd

    rlPhaseStartTest "Test installed binaries"
        rlRun "keylime_tenant --help"
    rlPhaseEnd

rlJournalEnd
