#!/usr/bin/env bash
# Uso: encode.sh entrada.(mp4|mov) salida.mp4
set -euo pipefail
in="$1"; out="$2"

# ¿El archivo trae pista de audio? Si sí, AAC 96 kbps. Si no, sin pista.
if [ -n "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$in")" ]; then
  audio=(-map 0:a:0 -c:a aac -b:a 96k -ar 48000)
else
  audio=(-an)
fi

ffmpeg -y -hide_banner -loglevel error -i "$in" \
  -map 0:v:0 "${audio[@]}" \
  -vf "scale=480:854:force_original_aspect_ratio=increase,crop=480:854,setsar=1,fps=30" \
  -c:v libx264 -profile:v high -level:v 3.1 -pix_fmt yuv420p -preset slow \
  -b:v 900k -maxrate 1M -bufsize 1.6M \
  -g 60 -keyint_min 60 -sc_threshold 0 \
  -movflags +faststart "$out"

ffprobe -v error -show_entries format=duration -of csv=p=0 "$out"   # durationSeconds
