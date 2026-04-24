#!/usr/bin/env bash
# Print the current date every 5 seconds for one minute. Each line
# appears live — no buffering.
#
# Runs unmodified on both interpreters:
#
#   /bin/bash Examples/date-loop.sh
#   swift-bash exec Examples/date-loop.sh
#
# In `swift-bash exec` the `sleep` is cooperative (`Task.sleep`),
# so Ctrl-C / task cancellation unblocks it immediately.

for i in $(seq 12); do
  date
  sleep 5
done
