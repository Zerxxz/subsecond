#!/usr/bin/env bash
set -euo pipefail
S=/home/ubuntu/.hermes/cache/scratch
N=$S/mn
RAW=/tmp/subsecond-motion-v2-raw.mp4
MUS=/tmp/subsecond-music.wav
OUT=/home/ubuntu/subsecond/assets/subsecond-motion.mp4

# Trim the completed v2 take to the 71-second v2 timeline, then reuse the existing
# ElevenLabs narration placement and add original music underneath it.
ffmpeg -y -v error -t 71 -i "$RAW" -c copy /tmp/subsecond-motion-v2-trimmed.mp4
ffmpeg -y -v error -stream_loop -1 -i "$MUS" -i /tmp/subsecond-motion-v2-trimmed.mp4 -i "$N/n0.mp3" -i "$N/n1.mp3" -i "$N/n2.mp3" -i "$N/n3.mp3" -i "$N/n4.mp3" -i "$N/n5.mp3" -i "$N/n6.mp3" \
-filter_complex "[1:v]crop=1600:856:0:44,format=yuv420p[v];\
[0:a]atrim=0:71,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=2,afade=t=out:st=65:d=5,volume=0.20[music];\
[2:a]adelay=3400|3400,volume=1.7[a0];[3:a]adelay=16500|16500,volume=1.7[a1];[4:a]adelay=23500|23500,volume=1.7[a2];[5:a]adelay=31000|31000,volume=1.7[a3];[6:a]adelay=45500|45500,volume=1.7[a4];[7:a]adelay=55500|55500,volume=1.7[a5];[8:a]adelay=63500|63500,volume=1.7[a6];\
[a0][a1][a2][a3][a4][a5][a6][music]amix=inputs=8:duration=longest:normalize=0,apad,atrim=0:71[a]" \
-map "[v]" -map "[a]" -c:v libx264 -preset medium -crf 19 -c:a aac -b:a 160k -movflags +faststart "$OUT"

echo "OUT=$OUT"
ffprobe -v error -show_entries format=duration,size -show_entries stream=index,codec_type,codec_name,width,height,r_frame_rate,sample_rate -of default=noprint_wrappers=1 "$OUT"
