# ViniCapture: A GPU-accelerated, streamable Chrome session in a single Docker container.
# Base image with NVIDIA CUDA support for GPU access
FROM nvidia/cuda:12.1.1-base-ubuntu22.04

# Set environment variables for non-interactive installation and configuration
ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
# Default values, can be overridden by docker-compose.yml or `docker run`
ENV SCREEN_RESOLUTION=1280x720
ENV VNC_PASSWORD="password"
ENV STREAM_URL="http://localhost:8080/stream/index.m3u8"

# Install dependencies: system tools, desktop environment, Chrome, FFmpeg, Nginx, and Supervisor
RUN apt-get update && apt-get install -y --no-install-recommends \
    # System tools & Supervisor
    wget gnupg software-properties-common supervisor curl procps \
    # Virtual Desktop (X server, window manager, VNC)
    xvfb fluxbox tigervnc-standalone-server tigervnc-common x11vnc xterm x11-utils \
    # Nginx web server
    nginx \
    # FFmpeg for screen capture and encoding
    ffmpeg \
    # Fonts for proper website rendering
    fonts-liberation && \
    # Add Google Chrome repository
    wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | apt-key add - && \
    sh -c 'echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" >> /etc/apt/sources.list.d/google-chrome.list' && \
    # Install Google Chrome
    apt-get update && apt-get install -y google-chrome-stable && \
    # Clean up APT cache
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy configuration files into the image from the config directory
COPY config/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY config/nginx.conf /etc/nginx/sites-available/default
COPY config/stream.sh /usr/local/bin/stream.sh
COPY config/start-vnc.sh /usr/local/bin/start-vnc.sh

# Make the scripts executable
RUN chmod +x /usr/local/bin/stream.sh && \
    chmod +x /usr/local/bin/start-vnc.sh

# Create directory for HLS stream files and set permissions
RUN mkdir -p /var/www/html/stream && \
    chown -R www-data:www-data /var/www/html

# Expose ports: 8080 for HLS stream (Nginx) and 5900 for VNC
EXPOSE 8080
EXPOSE 5900

# The main command to start Supervisor, which manages all other services
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
