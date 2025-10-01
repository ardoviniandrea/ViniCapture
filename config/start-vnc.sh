#!/bin/bash
# This script sets up the VNC password and starts the VNC server.

# Check if VNC_PASSWORD is set
if [ -z "${VNC_PASSWORD}" ]; then
  echo "FATAL: VNC_PASSWORD environment variable is not set."
  exit 1
fi

# Create the directory for the password file
mkdir -p /root/.vnc

# Use x11vnc's own utility to create the password file in the correct format.
# This is more reliable than using vncpasswd from another package.
echo "Creating VNC password file..."
x11vnc -storepasswd "${VNC_PASSWORD}" /root/.vnc/passwd
chmod 600 /root/.vnc/passwd
echo "VNC password file created."

# Wait for the Xvfb virtual screen to be ready before starting the VNC server.
# This prevents a race condition where x11vnc tries to connect too early.
echo "Waiting for X server on display ${DISPLAY}..."
for i in {1..10}; do
  if xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
    echo "X server is ready."
    break
  fi
  echo "Waiting for X server... (attempt $i of 10)"
  sleep 1
done

if ! xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
  echo "FATAL: X server did not become ready after 10 seconds."
  exit 1
fi

# Start the VNC server.
# -rfbauth is the recommended flag for using a password file.
# -forever keeps the server running.
# -create helps manage the display geometry.
echo "Starting X11VNC server."
exec /usr/bin/x11vnc -display "${DISPLAY}" -forever -rfbauth /root/.vnc/passwd -create

