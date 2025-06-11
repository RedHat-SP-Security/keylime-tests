#!/bin/bash

pushd /root
ARCH=$(arch)
curl -kLo yumrepogen "https://gitlab.cee.redhat.com/api/v4/projects/72924/jobs/artifacts/main/raw/yumrepogen-$ARCH?job=compile"
curl -kLo rhel.repo.tmpl 'https://gitlab.cee.redhat.com/testing-farm/yumrepogen/-/raw/main/rhel.repo.tmpl?inline=false'
chmod a+x yumrepogen
./yumrepogen -insecure -arch=$ARCH -compose-id=$(curl -kLs 'http://storage.tft.osci.redhat.com/composes-production.json' | grep -E -o "RHEL-9.6.0-[^\"]+" | head -1) -outfile /etc/yum.repos.d/yumrepogen.repo
yum config-manager --set-enabled rhel-BaseOS --set-enabled rhel-AppStream
