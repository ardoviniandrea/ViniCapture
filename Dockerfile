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

# Set KasmVNC version (Upgraded to v1.6.0)
ENV KASM_VNC_VERSION=1.6.0
# Set capabilities for NVIDIA GPU
ENV NVIDIA_DRIVER_CAPABILITIES=all
ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    gnupg \
    ffmpeg \
    nginx \
    supervisor \
    ca-certificates \
    wget \
    gpg-agent \
    software-properties-common \
    # KasmVNC dependencies
    libjpeg-turbo8 \
    libwebp7 \
    libxfont2 \
    x11-utils \
    xauth \
    libxkbcommon-x11-0 \
    libxcb-xinerama0 \
    libxcb-shape0 \
    libxcb-icccm4 \
    libxcb-keysyms1 \
    libxcb-render-util0 \
    libpulse0 \
    libgbm1 \
    && \
    # Add Google Chrome repository (to avoid snap)
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    # Install Google Chrome
    apt-get install -y --no-install-recommends google-chrome-stable && \
    # Re-install Node.js runtime
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    #
    # === FIX ===
    # The filename was wrong. It's 'ubuntu22.04' not 'ubuntu-22.04'.
    # This corrected wget command will fix the 404 error.
    #
    wget "https://github.com/kasmtech/KasmVNC/releases/download/v${KASM_VNC_VERSION}/kasmvncserver_ubuntu22.04_${KASM_VNC_VERSION}_amd64.deb" -O kasmvnc.deb && \
    dpkg -i kasmvnc.deb && \
    rm kasmvnc.deb && \
    # Clean up
    apt-get remove -y --purge software-properties-common gpg-agent && \
    apt-get autoremove -y && \
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
# /data will be mounted as a volume
RUN mkdir -p /var/www/hls && \
    mkdir -p /data && \
    mkdir -p /var/log/nginx && \
    chown -R 1000:1000 /var/www/hls /data
    
# KasmVNC setup: Create a non-root user 'kasm'
RUN useradd -m -s /bin/bash -G audio,video,pulse,pulse-access,input kasm && \
    echo "kasm:kasm" | chpasswd && \
    mkdir -p /home/kasm/.vnc && \
    echo "kasm" | vncpasswd -f > /home/kasm/.vnc/passwd && \
    chown -R kasm:kasm /home/kasm && \
    chmod 600 /home/kasm/.vnc/passwd

# KasmVNC config (run as user kasm)
ENV HOME=/home/kasm
ENV USER=kasm
# Set display for all services
ENV DISPLAY=:1

# Expose ports
# All-in-One UI (proxied by Nginx)
EXPOSE 80
# HLS Stream (served by Nginx)
EXPOSE 8994
# KasmVNC port (proxied by Nginx)
EXPOSE 6901

# Start supervisord as the main command (as root)
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
