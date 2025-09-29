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

# 1. Install core dependencies and VNC dependencies
# --- RECONCILED FIX 1: ---
# Add 'ssl-cert' (for the missing key) and 'lxde' (the desktop environment)
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
    libgbm1 \
    x11vnc \
    ssl-cert \
    lxde

# 2. Install Google Chrome
RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-chrome-stable

# 3. Install Node.js runtime
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs

# 4. Download and install KasmVNC, and fix any missing dependencies
RUN curl -fL "https://github.com/kasmtech/KasmVNC/releases/download/v${KASM_VNC_VERSION}/kasmvncserver_jammy_${KASM_VNC_VERSION}_amd64.deb" -o kasmvnc.deb && \
    dpkg -i kasmvnc.deb || apt-get -f install -y && \
    rm kasmvnc.deb

# 5. Final cleanup
RUN apt-get remove -y --purge software-properties-common gpg-agent && \
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
RUN mkdir -p /var/www/hls && \
    mkdir -p /data && \
    mkdir -p /var/log/nginx && \
    chown -R 1000:1000 /var/www/hls /data
    
# KasmVNC setup, Step 1: Create required user groups
# These groups may not exist in the minimal base image.
RUN for group in audio video pulse pulse-access input; do \
        if ! getent group $group >/dev/null; then \
            groupadd --system $group; \
        fi; \
    done

# KasmVNC setup, Step 2: Ensure user 'kasm' exists and has the correct groups 
# This is in its own layer to guarantee the user is created before the next step.
# --- RECONCILED FIX 2: Add 'ssl-cert' group to 'kasm' user ---
RUN if id -u kasm >/dev/null 2>&1; then \
        echo "User kasm already exists, modifying."; \
        usermod -a -G audio,video,pulse,pulse-access,input,ssl-cert kasm; \
    else \
        echo "User kasm does not exist, creating."; \
        useradd -m -s /bin/bash -G audio,video,pulse,pulse-access,input,ssl-cert kasm; \
    fi

# KasmVNC setup, Step 3: Set password and create VNC directory for the 'kasm' user
# --- RECONCILED FIX 3: Pre-create config files to skip the setup wizard ---
RUN echo "kasm:kasm" | chpasswd && \
    mkdir -p /home/kasm/.vnc && \
    x11vnc -storepasswd kasm /home/kasm/.vnc/passwd && \
    echo -e "#!/bin/sh\nset -x\nexec lxsession" > /home/kasm/.vnc/xstartup && \
    touch /home/kasm/.vnc/.de-was-selected && \
    chown -R kasm:kasm /home/kasm && \
    chmod +x /home/kasm/.vnc/xstartup && \
    chmod 600 /home/kasm/.vnc/passwd

# --- FIX: Set permissions for /tmp and create .Xauthority ---
RUN chmod 1777 /tmp && \
    touch /home/kasm/.Xauthority && \
    chown kasm:kasm /home/kasm/.Xauthority

# KasmVNC config (run as user kasm)
ENV HOME=/home/kasm
ENV USER=kasm
# Removed global ENV DISPLAY=:1

# Expose ports
EXPOSE 80
EXPOSE 8994
EXPOSE 6901

# Start supervisord as the main command (as root)
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]

