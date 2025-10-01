#!/bin/bash

# Set a simple black background
xsetroot -solid black &

# Start Google Chrome in the foreground.
# Fluxbox will manage this window.
# The flags are important for running inside Docker.
exec google-chrome-stable \
  --no-sandbox \
  --start-maximized \
  --user-data-dir=/root/chrome-data \
  --no-first-run \
  --disable-dev-shm-usage
