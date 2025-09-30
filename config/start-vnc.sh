#!/bin/bash
# This script sets up the VNC password and starts the VNC server.

# Set VNC password
mkdir -p /root/.vnc
echo "$VNC_PASSWORD" | vncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd

# Start the VNC server using exec to replace the shell process
echo "Starting X11VNC server..."
exec /usr/bin/x11vnc -display "$DISPLAY" -forever -usepw -create
