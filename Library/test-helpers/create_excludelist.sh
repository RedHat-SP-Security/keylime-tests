#!/bin/bash

if [ -n "$1" ]; then
  OUT="$1"
else
  OUT="excludelist.txt"
fi
rm -f $OUT
for DIR in /*; do 
    if [ "$DIR" != "/keylime-tests" ]; then
      echo "$DIR(/.*)?" >> $OUT
    fi
done
# explicitly add items that may not be present on FS
echo -e "memfd:kernel\n/sysroot/etc/fstab\n/dracut-state.sh" >> $OUT
