# expects limetster user and group to be present on a test sytem
# build with
# $ rpmbuild -bb -D 'destdir /some/destination/dir' rpm-ima-sign-test.spec

Summary: This is the rpm-ima-sign-test package
Name: rpm-ima-sign-test
Version: 1
Release: 1
Group: System Environment/Base
License: GPL
BuildArch: noarch
BuildRoot:  %(mktemp -ud %{_tmppath}/%{name}-%{version}-%{release}-XXXXXX)
%description

This is a rpm-ima-sign-test test package

%build
echo -e '#!/bin/bash\necho' > rpm-ima-sign-test-echo

%install
mkdir -p %{buildroot}/%{destdir}
mv rpm-ima-sign-test-echo %{buildroot}/%{destdir}

%files
%attr(755, limetester, limetester) %{destdir}/rpm-ima-sign-test-echo
