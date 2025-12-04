#!/bin/bash

# enable epel repo
#yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

# install build requires for C9S
yum -y install \
    git \
    libselinux-python3 \
    openssh \
    openssh-server \
    python3-alembic \
    python3-cryptography \
    python-gpg \
    python3-jinja2 \
    python3-jsonschema \
    python3-lark-parser \
    python3-packaging \
    python3-pip \
    python3-psutil \
    python3-pyasn1 \
    python3-pyasn1-modules \
    python3-pyyaml \
    python3-requests \
    python3-setuptools \
    python3-sqlalchemy \
    python3-tornado \
    python3-typing-extensions \
    tpm2-tools \
    which \
    rpm-build \
    gawk

# if keylime_sources are not present, clone the repo
if [ ! -f /var/tmp/keylime_sources/setup.py ]; then
    rm -rf /var/tmp/keylime_sources
    git clone https://github.com/keylime/keylime.git /var/tmp/keylime_sources
fi

# add keylime user
useradd keylime
usermod -a -G tss keylime

# install upstream keylime
pushd /var/tmp/keylime_sources
mkdir -p /etc/keylime && chmod 700 /etc/keylime
python3 setup.py install

# create directory structure in /etc/keylime and copy config files there
for comp in "verifier" "tenant" "registrar" "ca" "logging"; do
    mkdir -p /etc/keylime/$comp.conf.d
    cp -n config/$comp.conf /etc/keylime/
done

# install scripts to /usr/share/keylime
mkdir -p /usr/share/keylime
cp -r scripts /usr/share/keylime/

# prepare fake keylime package
cat > keylime.spec <<_EOF
Name:		keylime
Version:	99
Release:	1
Summary:	Dummy package preventing keylime RPM installation
License:	GPLv2+
BuildArch:  noarch
Provides: keylime-base = 99
Provides: keylime-verifier = 99
Provides: keylime-registrar = 99
Provides: keylime-tenant = 99
Provides: python3-keylime = 99
Obsoletes: keylime-base < 99

%description
Dummy package that prevents replacing installed keylime bits with keylime RPM

%prep

%build

%install

%files

%changelog
* Fri Jan 28 2022 Karel Srot <ksrot@redhat.com> 99-1
- Initial version
_EOF

rpmbuild -bb keylime.spec 2>&1 | tee build.log
RPMPKG=$( awk '/Wrote:/ { print $2 }' build.log )
rpm -ivh $RPMPKG

# enable rust agent COPR repo and install agent
if [ -f /etc/fedora-release ]; then
    dnf -y copr enable packit/keylime-rust-keylime-master-fedora
else
    _MAJOR=$( rpm -q --qf '%{VERSION}' centos-stream-release | cut -d '.' -f 1 )
    _ARCH=$( arch )
    dnf -y copr enable packit/keylime-rust-keylime-master-centos centos-stream-${_MAJOR}-${_ARCH}
fi
yum -y install keylime-agent-rust keylime-agent-rust-push
curl -o /etc/keylime/keylime-agent.conf https://raw.githubusercontent.com/keylime/rust-keylime/master/keylime-agent.conf
mkdir -p /etc/systemd/system/keylime_agent.service.d /etc/systemd/system/keylime_push_model_agent.service.d
mkdir -p /etc/keylime/agent.conf.d

# fix conf file ownership
chown -Rv keylime:keylime /etc/keylime /var/lib/keylime
find /etc/keylime -type f -exec chmod 400 {} \;
find /etc/keylime -type d -exec chmod 500 {} \;
ls -lR /etc/keylime
popd

# clean yum cache
yum clean all
