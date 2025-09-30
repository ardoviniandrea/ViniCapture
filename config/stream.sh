#!/bin/bash

# Wait for the X server to be ready
sleep 5

# Set the output directory for HLS files
OUTPUT_DIR="/var/www/html/stream"
PLAYLIST_NAME="index.m3u8"
PLAYLIST_PATH="$OUTPUT_DIR/$PLAYLIST_NAME"

# Ensure the output directory exists
mkdir -p $OUTPUT_DIR
chown www-data:www-data $OUTPUT_DIR

# Loop to ensure FFmpeg restarts if it fails
while true; do
    echo "Starting FFmpeg stream..."
    ffmpeg \
        -f x11grab \
        -s "$SCREEN_RESOLUTION" \
        -draw_mouse 0 \
        -i "$DISPLAY" \
        -f lavfi -i anullsrc \
        -c:v h264_nvenc -preset p3 -tune hq -b:v 4M -maxrate:v 5M -bufsize:v 6M \
        -c:a aac -b:a 128k \
        -f hls \
        -hls_time 2 \
        -hls_list_size 5 \
        -hls_flags delete_segments \
        -hls_segment_filename "$OUTPUT_DIR/segment%03d.ts" \
        "$PLAYLIST_PATH"

    echo "FFmpeg process exited. Restarting in 5 seconds..."
    sleep 5
done
