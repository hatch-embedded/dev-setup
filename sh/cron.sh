#!/bin/bash
set -e

# Validate number of arguments

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <job-name> <command> <frequency>"
    exit 1
fi

JOB_NAME=$1
COMMAND=$2
FREQUENCY=$3
LOG_DIR="$HOME/.logs"
LOG_FILE="$LOG_DIR/$JOB_NAME.log"

# Ensure crontab for current user
if ! crontab -l &>/dev/null; then
    echo "# Empty crontab created on $(date)" > /tmp/crontab$$
    crontab /tmp/crontab$$
    rm -f /tmp/crontab$$
    echo "Crontab created"
fi

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Escape the special characters in command and frequency for use in sed expressions
ESCAPED_COMMAND=$(echo "$COMMAND" | sed 's/[&/\]/\\&/g')
ESCAPED_FREQUENCY=$(echo "$FREQUENCY" | sed 's/[&/\]/\\&/g')

# Prepare cron job line with log redirection
CRON_JOB="$FREQUENCY CRON=1 $COMMAND >> $LOG_FILE 2>&1"

# Check if there's an existing job with the same name
if crontab -l 2>/dev/null | grep -q "# $JOB_NAME$"; then
    # Job exists, update it
    (crontab -l 2>/dev/null | grep -v "# $JOB_NAME$"; echo "$FREQUENCY $COMMAND >> $LOG_FILE 2>&1 # $JOB_NAME") | crontab -
    echo "Updated cron job: $JOB_NAME"
else
    # No job found, adding it
    (crontab -l 2>/dev/null; echo "$FREQUENCY $COMMAND >> $LOG_FILE 2>&1 # $JOB_NAME") | crontab -
    echo "Added new cron job: $JOB_NAME"
fi
