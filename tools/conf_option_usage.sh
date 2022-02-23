#!/bin/bash

# This is a simple script that presents the usage of individual keylime.conf
# options in keylime-tests
#
# Usage: cd keylime-tests
#        tools/conf_option_usage.sh

TESTDIR=$1
[ -z "$TESTDIR" ] && TESTDIR=$( pwd | sed 's/keylime-tests.*/keylime-tests/' )

pushd $TESTDIR

CONF=$( mktemp )
SECTION="empty"
OPTION=""
DEFAULT=""

curl -sk 'https://raw.githubusercontent.com/keylime/keylime/master/keylime.conf' > $CONF

function used_option_values() {
  local SECTION=$1
  local OPTION=$2
  local VALUE
  local VALUES

  grep -R "limeUpdateConf $SECTION $OPTION " . | while read LINE; do
      FILE=$( echo "$LINE" | cut -d ':' -f 1 )
      VALUE=$( echo "$LINE" | sed "s/.*limeUpdateConf $SECTION $OPTION[ ]*\(.*\)\".*/\1/" )
      echo "  $VALUE  $FILE"
  done

}

cat $CONF | while read LINE; do

  # get the first character
  CHAR=${LINE::1}

  case $CHAR in

    "#"|"")  # comment
    ;;

    "[")  # section
      SECTION=$( echo "$LINE" | tr -d '\[\]' )
      echo -e "\n$LINE"
    ;;

    *) # anything else
      OPTION=$( echo "$LINE" | sed 's/[ ]*=.*//')
      DEFAULT=$( echo "$LINE" | sed 's/.*=[ ]*//')
      echo -e "\n$OPTION"
      echo "  $DEFAULT (default)"
      used_option_values $SECTION $OPTION
    ;;

  esac

done

rm $CONF
