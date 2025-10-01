#!/bin/bash
# This script sets up the VNC password and starts the VNC server.
# This version includes extensive logging for debugging purposes.

# All output from this script will be logged by supervisord, but we add echo for clarity.
echo "--- VNC Startup Script Initialized ---"
date
echo "INFO: DISPLAY is set to: ${DISPLAY}"

# Check if VNC_PASSWORD is set
if [ -z "${VNC_PASSWORD}" ]; then
  echo "FATAL: VNC_PASSWORD environment variable is not set."
  exit 1
fi

# Create the directory for the password file
mkdir -p /root/.vnc

# Use x11vnc's own utility to create the password file.
echo "INFO: Creating VNC password file..."
x11vnc -storepasswd "${VNC_PASSWORD}" /root/.vnc/passwd
chmod 600 /root/.vnc/passwd
echo "INFO: VNC password file created successfully."

# --- X Server Readiness Check ---
# This loop waits for the Xvfb virtual screen to be ready.
echo "INFO: Waiting for X server on display ${DISPLAY}..."
for i in {1..15}; do
  if xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
    echo "SUCCESS: X server is ready on attempt $i."
    # Log detailed info about the display for debugging
    echo "--- X Display Info ---"
    xdpyinfo -display "${DISPLAY}"
    echo "----------------------"
    break
  fi
  echo "INFO: Waiting for X server... (attempt $i of 15)"
  # Check if the Xvfb process is running
  pgrep Xvfb >/dev/null || echo "WARNING: Xvfb process not found!"
  sleep 1
done

# Final check to ensure the X server is really there
if ! xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
  echo "FATAL: X server on display ${DISPLAY} did not become ready after 15 seconds."
  echo "FATAL: Check the xvfb logs in /var/log/supervisor/xvfb.err"
  exit 1
fi

# --- Start the VNC Server ---
# The '-create' flag has been REMOVED to prevent it from creating its own session.
# If this command fails, it's because it couldn't attach to the existing Xvfb display.
echo "INFO: Starting X11VNC server. It will now attach to the existing display."
exec /usr/bin/x11vnc -display "${DISPLAY}" -forever -rfbauth /root/.vnc/passwd
