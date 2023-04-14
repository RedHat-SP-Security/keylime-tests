#!/bin/bash
# runs sshd on a background and then runs program passed as an argument
/usr/sbin/sshd &> /var/log/sshd &
# copy cv_ca if mounted
mkdir -p /mnt/cv_ca
cp -r /mnt/cv_ca /var/lib/keylime/
chown -R keylime:keylime /var/lib/keylime/cv_ca
# run requested program
RUST_LOG=keylime_agent=trace $( which $1 )
