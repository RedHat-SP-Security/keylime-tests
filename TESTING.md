Currently, scenario can be successfully manually executed on 1minutetip system.

## 1minutetip

On your workstation
```
$ cd /tmp
$ git@github.com:RedHat-SP-Security/keylime-tests.git^C
$ git clone -b ksrot_install_tpm git@github.com:RedHat-SP-Security/keylime-tests.git
$ 1minutetip -n rhel9
```

On 1minutetip system
```
# ## you may want to allow root login
# sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
# systemctl restart sshd
# ip a l
# ## note down 1minutetip system IP
```

On your workstation
```
$ scp -r keylime-tests root@10.0.X.Y:~
```
On 1minutetip system
```
# ## configure TPM emulator
# cd keylime-tests/install/configure_tpm_emulator/
# bash test.sh
# ## install keylime from upstream
# cd ../install_upstream_keylime/
# bash test.sh
# ## run the test scenario
# cd ../../functional/basic-attestation-on-localhost/
# bash test.sh
```
## Beaker system with TPM

ATM we can use 3 systems used for NBDE testing that have TPM virtualized by QEMU.
Such system can be reserved e.g. using:

```
$ bkr workflow-tomorrow --reserve --distro RHEL-9.0.0-20210914.0 --hostrequire 'TPM=2' --hostrequire 'system_type=Resource' --arch x86_64
```

Test scenario can be executed in a similar fashion with one change. Instead of /keylime/install/configure_tpm_emulator/ you should run /keylime/install/configure_kernel_ima_module/ test. This test reboots the system so once it comes up again you should run the test once more to complete the setup.

Also, be aware that there is a bug in keylime when generating TLS certificates. NBDE test systems are configured to CET/CEST timezone which manifests the issue. A fix (?) is being applied in install_upstream_keylime/test.sh but even with this change test scenario doesn't work. This problem is currently being investigated.
