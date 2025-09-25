# Stage 1: The Builder (For Node.js dependencies)
# Use the NVIDIA devel image as a base to match the runtime
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
    # Install Node.js 20.x
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set working directory and copy package files
WORKDIR /app
COPY app/package*.json ./

# Install all dependencies for the app
RUN npm install

# Copy all app source code so it's included in the builder stage
COPY app/ .

# ---
# Stage 2: The Final Runtime Image
# Use the NVIDIA base image for the runtime
FROM nvidia/cuda:12.2.2-base-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV NVIDIA_DRIVER_CAPABILITIES all
# Set path for KasmVNC
ENV KASM_VNC_PATH /usr/bin

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    gnupg \
    ffmpeg \
    nginx \
    supervisor \
    ca-certificates \
    pulseaudio \
    chromium-browser \
    # KasmVNC Dependencies
    libjpeg-turbo8 \
    libxtst6 \
    libxrandr2 \
    libxi6 \
    libdbus-glib-1-2 \
    libxfixes3 \
    libnss3 \
    && \
    # Install Node.js 20.x runtime
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Download and install KasmVNC
# Using v1.5.0 for Ubuntu 22.04 (jammy)
RUN KASM_VNC_VERSION=1.5.0 && \
    KASM_VNC_URL="https://github.com/kasmtech/KasmVNC/releases/download/v${KASM_VNC_VERSION}/kasmvnc_${KASM_VNC_VERSION}_jammy_amd64.deb" && \
    curl -Lo kasmvnc.deb $KASM_VNC_URL && \
    apt-get install -y ./kasmvnc.deb && \
    rm -f kasmvnc.deb

# Set working directory
WORKDIR /app

# Copy the application files and node_modules from the 'builder' stage
COPY --from=builder /app .

# Copy Nginx and Supervisor configs
COPY nginx.conf /etc/nginx/nginx.conf
COPY supervisord.conf /etc/supervisor/supervisord.conf

# Create directories
RUN mkdir -p /var/www/hls /var/log/supervisor /run/pulseaudio
RUN chmod 777 /run/pulseaudio

# Expose ports
EXPOSE 80   # All-in-One UI
EXPOSE 8994 # HLS Stream

# Start supervisor
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]

