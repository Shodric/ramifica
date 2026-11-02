#!/usr/bin/env bash
# Browser-compatible re-encode only: H.264 + AAC + faststart.
# Source dimensions, frame rate, and duration pass through untouched;
# what the provider returns is what gets stored.
set -eo pipefail
in="$1"; out="$2"
if [ -n "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$in")" ]; then
  audio=(-map 0:a:0 -c:a aac -b:a 96k -ar 48000)
else
  audio=(-an)
fi
ffmpeg -y -nostdin -hide_banner -loglevel error -i "$in" \
  -map 0:v:0 "${audio[@]}" \
  -c:v libx264 -profile:v high -level:v 4.0 -pix_fmt yuv420p -preset fast \
  -b:v 900k -maxrate 1M -bufsize 1.6M \
  -g 60 -keyint_min 60 -sc_threshold 0 -movflags +faststart "$out"
