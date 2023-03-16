#!/bin/bash
# runs sshd on a background and then runs program passed as an argument
/usr/sbin/sshd &> /var/log/sshd &
$1
