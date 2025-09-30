#!/bin/bash
# This script sets up the VNC password and starts the VNC server.

# Add a check to ensure the VNC_PASSWORD variable is set
if [ -z "${VNC_PASSWORD}" ]; then
  echo "FATAL: VNC_PASSWORD environment variable is not set."
  exit 1
fi

# Create the .vnc directory if it doesn't exist
mkdir -p /root/.vnc

# Create the password file
echo "${VNC_PASSWORD}" | vncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd

echo "VNC password file has been created successfully."

# Start the VNC server using exec to replace the shell process.
# We use -passwdfile to be explicit about the password location instead of -usepw.
echo "Starting X11VNC server..."
exec /usr/bin/x11vnc -display "$DISPLAY" -forever -passwdfile /root/.vnc/passwd -create
