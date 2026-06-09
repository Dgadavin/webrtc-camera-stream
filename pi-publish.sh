#!/usr/bin/env sh
# Publish a Raspberry Pi camera to a MediaMTX path over SRT.
#
# Polls the MediaMTX API until the target path is configured, then runs
# rpicam-vid | ffmpeg. If the pipeline exits (server reboot, network drop,
# camera unplug, anything) waits and starts over.
#
# Override any default with an env var:
#   SERVER, CAM, API_PORT, SRT_PORT, WIDTH, HEIGHT, FPS, BITRATE, RETRY_SLEEP

set -u

SERVER="${SERVER:-10.8.0.1}"
CAM="${CAM:-cam1}"
API_PORT="${API_PORT:-9997}"
SRT_PORT="${SRT_PORT:-8890}"
WIDTH="${WIDTH:-480}"
HEIGHT="${HEIGHT:-270}"
FPS="${FPS:-60}"
BITRATE="${BITRATE:-500000}"
RETRY_SLEEP="${RETRY_SLEEP:-5}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

wait_for_path() {
  while :; do
    status=$(curl -s -o /dev/null -w "%{http_code}" \
      --connect-timeout 3 --max-time 5 \
      "http://${SERVER}:${API_PORT}/v3/config/paths/get/${CAM}" 2>/dev/null || echo "000")
    if [ "$status" = "200" ]; then
      log "path '${CAM}' ready on ${SERVER} — starting publish"
      return 0
    fi
    log "waiting for path '${CAM}' on ${SERVER}:${API_PORT} (api status: ${status})"
    sleep "$RETRY_SLEEP"
  done
}

publish() {
  rpicam-vid -t 0 \
      --width "$WIDTH" --height "$HEIGHT" --framerate "$FPS" \
      --codec h264 --profile baseline --level 4.2 \
      --bitrate "$BITRATE" \
      --inline --intra 6 --flush 1 \
      --libav-format mpegts \
      --nopreview -o - \
    | ffmpeg \
      -fflags nobuffer -flags low_delay \
      -probesize 32 -analyzeduration 0 \
      -f mpegts -i - \
      -c:v copy -an \
      -f mpegts \
      "srt://${SERVER}:${SRT_PORT}?streamid=publish:${CAM}&pkt_size=1316&latency=60000&mode=caller"
}

trap 'log "stopping"; exit 0' INT TERM

while :; do
  wait_for_path
  publish || true
  log "pipeline exited, retrying in ${RETRY_SLEEP}s"
  sleep "$RETRY_SLEEP"
done
