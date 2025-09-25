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
ENV KASM_VNC_VERSION=1.3.4
ENV NVIDIA_DRIVER_CAPABILITIES=all
ENV DEBIAN_FRONTEND=noninteractive

#
# === SOLUTION: Break RUN command into logical, cachable layers ===
#

# [cite_start]1. Install core dependencies and VNC dependencies [cite: 3, 4]
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
    libgbm1

# [cite_start]2. Install Google Chrome [cite: 4, 5]
RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable

# [cite_start]3. Install Node.js runtime [cite: 5, 6]
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs

# [cite_start]4. Download and install KasmVNC, and fix any missing dependencies [cite: 6]
RUN curl -fL "https://github.com/kasmtech/KasmVNC/releases/download/v${KASM_VNC_VERSION}/kasmvncserver_jammy_${KASM_VNC_VERSION}_amd64.deb" -o kasmvnc.deb && \
    dpkg -i kasmvnc.deb || apt-get -f install -y && \
    rm kasmvnc.deb

# [cite_start]5. Final cleanup [cite: 6, 7]
RUN apt-get remove -y --purge software-properties-common gpg-agent && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /etc/apt/sources.list.d/google-chrome.list

# Create and set the working directory for the Node.js app
WORKDIR /usr/src/app

# Copy the application files and node_modules from the 'builder' stage
COPY --from=builder /usr/src/app .

# [cite_start]Copy configs [cite: 8]
COPY nginx.conf /etc/nginx/nginx.conf
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Create directories for HLS, logs, and persistent data
# /data will be mounted as a volume
RUN mkdir -p /var/www/hls && \
    mkdir -p /data && \
    mkdir -p /var/log/nginx && \
    chown -R 1000:1000 /var/www/hls /data
    
# [cite_start]KasmVNC setup: Create a non-root user 'kasm' [cite: 8, 9]
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
