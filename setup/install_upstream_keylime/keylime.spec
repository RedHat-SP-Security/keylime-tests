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

%preun
rm -f /etc/systemd/system/{keylime_*.service,keylime_agent_secure.mount}
rm -f /usr/local/bin/keylime_*
rm -rf /usr/local/lib/python*/site-packages/keylime-*.egg
rm -rf /usr/share/keylime
systemctl daemon-reload

%files

%changelog
* Fri Jan 28 2022 Karel Srot <ksrot@redhat.com> 99-1
- Initial version
