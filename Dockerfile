# Stage 1: The Builder (For Node.js dependencies)
# Use the NVIDIA devel image to get build tools
FROM nvidia/cuda:12.2.2-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install Node.js and build essentials
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    gnupg \
    python3 \
    && \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set working directory and copy package files
WORKDIR /usr/src/app
COPY app/package*.json ./

# Install all dependencies for the app
RUN npm install

# Copy all app source code so it's included in the builder stage
COPY app/ .

# ---
# Stage 2: The Final Runtime Image
# Use the smaller NVIDIA 'base' image for runtime
FROM nvidia/cuda:12.2.2-base-ubuntu22.04

# Set environment variables
ENV NVIDIA_DRIVER_CAPABILITIES=all
ENV DEBIAN_FRONTEND=noninteractive
# NEW: Set noVNC version to use
ENV NOVNC_VERSION=1.4.0

# 1. Install core dependencies and VNC dependencies
# NEW: Replaced KasmVNC dependencies with TigerVNC, websockify, and supporting tools.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    gnupg \
    ffmpeg \
    nginx \
    supervisor \
    ca-certificates \
    wget \
    tar \
    lxde \
    tigervnc-standalone-server \
    tigervnc-common \
    websockify \
    libpulse0 \
    libgbm1

# 2. Install Google Chrome
RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable

# 3. Install Node.js runtime
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs

# 4. Download and install noVNC (the web client)
RUN mkdir -p /usr/share/novnc && \
    curl -fL "https://github.com/novnc/noVNC/archive/refs/tags/v${NOVNC_VERSION}.tar.gz" -o novnc.tar.gz && \
    tar -xzf novnc.tar.gz --strip-components=1 -C /usr/share/novnc && \
    rm novnc.tar.gz && \
    # NEW: Create a default index.html for easier proxying
    ln -s /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# 5. Final cleanup
RUN apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /etc/apt/sources.list.d/google-chrome.list

# Create and set the working directory for the Node.js app
WORKDIR /usr/src/app

# Copy the application files and node_modules from the 'builder' stage
COPY --from=builder /usr/src/app .

# Copy configs
COPY nginx.conf /etc/nginx/nginx.conf
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Create directories for HLS, logs, and persistent data
RUN mkdir -p /var/www/hls && \
    mkdir -p /data && \
    mkdir -p /var/log/nginx && \
    chown -R 1000:1000 /var/www/hls /data
    
# NEW: Simplified user setup for TigerVNC
# Create user 'kasm' with necessary groups
RUN groupadd --system --gid 1000 kasm && \
    useradd --system --uid 1000 --gid 1000 -m -s /bin/bash -G audio,video,pulse,pulse-access,input kasm

# NEW: Set password and VNC configuration for the 'kasm' user
RUN echo "kasm:kasm" | chpasswd && \
    mkdir -p /home/kasm/.vnc && \
    # NEW: Use vncpasswd to set the VNC-specific password
    echo "kasm" | vncpasswd -f > /home/kasm/.vnc/passwd && \
    # NEW: Create the xstartup script for the LXDE desktop environment
    echo -e '#!/bin/sh\n[ -x /etc/vnc/xstartup ] && exec /etc/vnc/xstartup\n[ -r $HOME/.Xresources ] && xrdb $HOME/.Xresources\n/usr/bin/lxsession -s LXDE &' > /home/kasm/.vnc/xstartup && \
    chown -R kasm:kasm /home/kasm && \
    chmod 0600 /home/kasm/.vnc/passwd && \
    chmod 755 /home/kasm/.vnc/xstartup

# Fix permissions for /tmp
RUN chmod 1777 /tmp

# Environment variables for VNC
ENV HOME=/home/kasm
ENV USER=kasm
ENV DISPLAY=:1

# Expose ports
EXPOSE 80
EXPOSE 8994
EXPOSE 6901

# Start supervisord as the main command (as root)
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
