#!/bin/bash

# --- Debugging Startup Script ---
# This script will log its execution steps and capture Chrome's output.

# Log that the script has started
echo "Fluxbox startup script initiated at $(date)" > /tmp/startup.log

# Launch a simple X application (xterm) as a visual confirmation
# that this script is running. If you see a terminal window in VNC,
# we know this script was executed.
echo "Launching xterm for visual confirmation..." >> /tmp/startup.log
xterm &

# Set a simple background color to confirm settings are being applied
# bsetroot -solid SteelBlue

# Now, launch Google Chrome and redirect ALL of its output (stdout and stderr)
# to a dedicated log file. This is the most critical step.
echo "Launching Google Chrome..." >> /tmp/startup.log
google-chrome-stable \
  --no-sandbox \
  --start-maximized \
  --user-data-dir=/root/chrome-data \
  --no-first-run \
  --disable-dev-shm-usage > /tmp/chrome.log 2>&1 &

echo "Fluxbox startup script finished." >> /tmp/startup.log
