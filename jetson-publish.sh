#!/usr/bin/env sh
# Publish a Jetson camera to a MediaMTX path over SRT.
#
# Defaults to a V4L2 camera, which is common for USB/HDMI/SDI/coax capture
# adapters exposed as /dev/video*. Set SOURCE=argus for Jetson CSI cameras.
#
# Requires GStreamer for capture/encoding.
# SRT publish uses GStreamer's srtsink when available, or ffmpeg with SRT support.
#
# Override defaults with env vars:
#   SERVER, CAM, API_PORT, SRT_PORT, RTSP_PORT, SOURCE, DEVICE, SENSOR_ID
#   WIDTH, HEIGHT, FPS, BITRATE, RETRY_SLEEP, SRT_LATENCY_US, NVCONV
#   INPUT_FORMAT=raw|mjpeg|h264
#   V4L2_CAPS='image/jpeg,width=720,height=576,framerate=25/1'
#   TRANSPORT=srt|rtsp
#   SRT_SENDER=auto|gst|ffmpeg, FFMPEG_BIN=/path/to/ffmpeg

set -u

SERVER="${SERVER:-10.8.0.1}"
CAM="${CAM:-cam1}"
API_PORT="${API_PORT:-9997}"
SRT_PORT="${SRT_PORT:-8890}"
RTSP_PORT="${RTSP_PORT:-8554}"
TRANSPORT="${TRANSPORT:-srt}"
SRT_SENDER="${SRT_SENDER:-auto}"
FFMPEG_BIN="${FFMPEG_BIN:-ffmpeg}"
SOURCE="${SOURCE:-argus}"
DEVICE="${DEVICE:-/dev/video0}"
SENSOR_ID="${SENSOR_ID:-0}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"
BITRATE="${BITRATE:-2500000}"
RETRY_SLEEP="${RETRY_SLEEP:-5}"
# FFmpeg/libsrt expects SRT latency values in microseconds.
# Keep SRT_LATENCY_MS as a legacy alias because older copies of this script used it.
SRT_LATENCY_US="${SRT_LATENCY_US:-${SRT_LATENCY_MS:-60000}}"
NVCONV="${NVCONV:-nvvidconv}"
INPUT_FORMAT="${INPUT_FORMAT:-raw}"
V4L2_CAPS="${V4L2_CAPS:-}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

check_dependencies() {
  if [ "$TRANSPORT" = "srt" ]; then
    if [ "$SRT_SENDER" = "gst" ] || { [ "$SRT_SENDER" = "auto" ] && gst-inspect-1.0 srtsink >/dev/null 2>&1; }; then
      SRT_SENDER="gst"
      return 0
    fi
    if [ "$SRT_SENDER" = "ffmpeg" ] || [ "$SRT_SENDER" = "auto" ]; then
      if "$FFMPEG_BIN" -hide_banner -protocols 2>/dev/null | awk '$1 == "srt" { found = 1 } END { exit !found }'; then
        SRT_SENDER="ffmpeg"
        return 0
      fi
    fi
    log "no SRT sender available: missing GStreamer srtsink and ffmpeg srt:// support"
    log "install gstreamer1.0-plugins-bad/libsrt or an SRT-enabled ffmpeg"
    return 1
  fi
}

wait_for_path() {
  while :; do
    status=$(curl -s -o /dev/null -w "%{http_code}" \
      --connect-timeout 3 --max-time 5 \
      "http://${SERVER}:${API_PORT}/v3/config/paths/get/${CAM}" 2>/dev/null || echo "000")
    if [ "$status" = "200" ]; then
      log "path '${CAM}' ready on ${SERVER} - starting publish"
      return 0
    fi
    log "waiting for path '${CAM}' on ${SERVER}:${API_PORT} (api status: ${status})"
    sleep "$RETRY_SLEEP"
  done
}

send_stream() {
  input="$1"
  case "$TRANSPORT" in
    srt)
      output="srt://${SERVER}:${SRT_PORT}?mode=caller&streamid=publish:${CAM}&pkt_size=1316&latency=${SRT_LATENCY_US}&transtype=live&tlpktdrop=1"
      format="mpegts"
      ;;
    rtsp)
      output="rtsp://${SERVER}:${RTSP_PORT}/${CAM}"
      format="rtsp"
      ;;
    *)
      log "unknown TRANSPORT='${TRANSPORT}' (use srt or rtsp)"
      return 1
      ;;
  esac

  "$FFMPEG_BIN" \
    -hide_banner -loglevel warning \
    -fflags nobuffer -flags low_delay \
    -probesize 32 -analyzeduration 0 \
    -f mpegts -i "$input" \
    -c copy -an \
    -flush_packets 1 -muxdelay 0 -muxpreload 0 \
    -f "$format" \
    "$output"
}

run_gst_to_media() {
  if [ "$TRANSPORT" = "srt" ] && [ "$SRT_SENDER" = "gst" ]; then
    "$@" ! srtsink uri="srt://${SERVER}:${SRT_PORT}?mode=caller&streamid=publish:${CAM}&pkt_size=1316&latency=${SRT_LATENCY_US}&transtype=live&tlpktdrop=1"
    return $?
  fi

  fifo="${TMPDIR:-/tmp}/jetson-publish-${CAM}-$$.ts"
  rm -f "$fifo"
  mkfifo "$fifo" || return 1

  "$@" ! filesink location="$fifo" sync=false &
  gst_pid=$!

  send_stream "$fifo"
  rc=$?

  kill "$gst_pid" 2>/dev/null || true
  wait "$gst_pid" 2>/dev/null || true
  rm -f "$fifo"
  return "$rc"
}

publish_v4l2_raw() {
  caps="${V4L2_CAPS:-video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1}"
  run_gst_to_media gst-launch-1.0 -e -q \
    v4l2src device="$DEVICE" do-timestamp=true \
    ! "$caps" \
    ! queue leaky=downstream max-size-buffers=1 max-size-bytes=0 max-size-time=0 \
    ! videoconvert \
    ! "$NVCONV" \
    ! "video/x-raw(memory:NVMM),format=NV12" \
    ! nvv4l2h264enc bitrate="$BITRATE" insert-sps-pps=true iframeinterval="$FPS" \
    ! h264parse config-interval=1 \
    ! "video/x-h264,stream-format=byte-stream,alignment=au" \
    ! mpegtsmux alignment=7
}

publish_v4l2_mjpeg() {
  caps="${V4L2_CAPS:-image/jpeg,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1}"
  run_gst_to_media gst-launch-1.0 -e -q \
    v4l2src device="$DEVICE" do-timestamp=true \
    ! "$caps" \
    ! queue leaky=downstream max-size-buffers=1 max-size-bytes=0 max-size-time=0 \
    ! jpegdec \
    ! videoconvert \
    ! "$NVCONV" \
    ! "video/x-raw(memory:NVMM),format=NV12" \
    ! nvv4l2h264enc bitrate="$BITRATE" insert-sps-pps=true iframeinterval="$FPS" \
    ! h264parse config-interval=1 \
    ! "video/x-h264,stream-format=byte-stream,alignment=au" \
    ! mpegtsmux alignment=7
}

publish_v4l2_h264() {
  caps="${V4L2_CAPS:-video/x-h264,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1}"
  run_gst_to_media gst-launch-1.0 -e -q \
    v4l2src device="$DEVICE" do-timestamp=true \
    ! "$caps" \
    ! h264parse config-interval=1 \
    ! "video/x-h264,stream-format=byte-stream,alignment=au" \
    ! mpegtsmux alignment=7
}

publish_v4l2() {
  case "$INPUT_FORMAT" in
    raw) publish_v4l2_raw ;;
    mjpeg) publish_v4l2_mjpeg ;;
    h264) publish_v4l2_h264 ;;
    *)
      log "unknown INPUT_FORMAT='${INPUT_FORMAT}' (use raw, mjpeg, or h264)"
      return 1
      ;;
  esac
}

publish_argus() {
  run_gst_to_media gst-launch-1.0 -e -q \
    nvarguscamerasrc sensor-id="$SENSOR_ID" \
    ! "video/x-raw(memory:NVMM),width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1,format=NV12" \
    ! queue leaky=downstream max-size-buffers=1 max-size-bytes=0 max-size-time=0 \
    ! nvv4l2h264enc bitrate="$BITRATE" insert-sps-pps=true iframeinterval="$FPS" \
    ! h264parse config-interval=1 \
    ! "video/x-h264,stream-format=byte-stream,alignment=au" \
    ! mpegtsmux alignment=7
}

publish() {
  case "$SOURCE" in
    v4l2) publish_v4l2 ;;
    argus) publish_argus ;;
    *)
      log "unknown SOURCE='${SOURCE}' (use SOURCE=v4l2 or SOURCE=argus)"
      return 1
      ;;
  esac
}

trap 'log "stopping"; exit 0' INT TERM

check_dependencies || exit 1

while :; do
  wait_for_path
  publish || true
  log "pipeline exited, retrying in ${RETRY_SLEEP}s"
  sleep "$RETRY_SLEEP"
done
