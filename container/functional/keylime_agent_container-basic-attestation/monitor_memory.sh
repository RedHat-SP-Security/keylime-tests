#!/bin/bash
# Memory monitoring script for keylime processes
# Usage: monitor_memory.sh <verifier_logfile> <registrar_logfile> <interval_seconds>

VERIFIER_LOGFILE="${1:-verifier_memory.log}"
REGISTRAR_LOGFILE="${2:-registrar_memory.log}"
INTERVAL="${3:-5}"

# Initialize log files
echo "# Memory monitoring started at $(date)" > "$VERIFIER_LOGFILE"
echo "# Timestamp,Total_RSS_KB,Total_VSZ_KB,Process_Count" >> "$VERIFIER_LOGFILE"

echo "# Memory monitoring started at $(date)" > "$REGISTRAR_LOGFILE"
echo "# Timestamp,Total_RSS_KB,Total_VSZ_KB,Process_Count" >> "$REGISTRAR_LOGFILE"

# Export variables so they can be used by test.sh
export VERIFIER_LOGFILE
export REGISTRAR_LOGFILE

# Monitor loop
while true; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Monitor keylime_verifier - sum all processes
    VERIFIER_PIDS=$(pgrep -f keylime_verifier)
    if [ -n "$VERIFIER_PIDS" ]; then
        TOTAL_RSS=0
        TOTAL_VSZ=0
        COUNT=0
        for PID in $VERIFIER_PIDS; do
            read RSS VSZ <<< $(ps -p $PID -o rss=,vsz= 2>/dev/null | tr -s ' ')
            if [ -n "$RSS" ]; then
                TOTAL_RSS=$((TOTAL_RSS + RSS))
                TOTAL_VSZ=$((TOTAL_VSZ + VSZ))
                COUNT=$((COUNT + 1))
            fi
        done
        if [ $COUNT -gt 0 ]; then
            echo "$TIMESTAMP,$TOTAL_RSS,$TOTAL_VSZ,$COUNT" >> "$VERIFIER_LOGFILE"
        fi
    fi

    # Monitor keylime_registrar - sum all processes
    REGISTRAR_PIDS=$(pgrep -f keylime_registrar)
    if [ -n "$REGISTRAR_PIDS" ]; then
        TOTAL_RSS=0
        TOTAL_VSZ=0
        COUNT=0
        for PID in $REGISTRAR_PIDS; do
            read RSS VSZ <<< $(ps -p $PID -o rss=,vsz= 2>/dev/null | tr -s ' ')
            if [ -n "$RSS" ]; then
                TOTAL_RSS=$((TOTAL_RSS + RSS))
                TOTAL_VSZ=$((TOTAL_VSZ + VSZ))
                COUNT=$((COUNT + 1))
            fi
        done
        if [ $COUNT -gt 0 ]; then
            echo "$TIMESTAMP,$TOTAL_RSS,$TOTAL_VSZ,$COUNT" >> "$REGISTRAR_LOGFILE"
        fi
    fi

    sleep "$INTERVAL"
done
