Name:		keylime
Version:	99
Release:	1
Summary:	Dummy package preventing keylime RPM installation
License:	GPLv2+	
BuildArch:  noarch
Provides: keylime-base
Provides: keylime-verifier
Provides: keylime-registrar
Provides: keylime-tenant
Provides: python3-keylime
Provides: python3-keylime-agent

%description
Dummy package that prevents replacing installed keylime bits with keylime RPM

%prep

%build

%install

%preun
rm -f /etc/systemd/system/{keylime_*.service,keylime_agent_secure.mount}
rm -f /usr/local/bin/keylime_*
rm -rf /usr/local/lib/python*/site-packages/keylime-*.egg
systemctl daemon-reload

%files

%changelog
* Fri Jan 28 2022 Karel Srot <ksrot@redhat.com> 99-1
- Initial version
