#!/usr/bin/env bash
# view-stream.sh — open the Jetson's live stream from the ground station.
#
#   JETSON_IP=192.168.1.42 ./view-stream.sh          # rtsp via ffplay (default)
#   JETSON_IP=192.168.1.42 ./view-stream.sh whep     # browser, sub-second (http://IP:8889/infer)
#   JETSON_IP=192.168.1.42 ./view-stream.sh hls      # browser, ~2-5s, works on phones (http://IP:8888/infer)
#   JETSON_IP=192.168.1.42 ./view-stream.sh imu      # AltIMU dashboard (http://IP:8080/)
#   ./view-stream.sh rtsp -loglevel debug            # extra args pass through to ffplay
#
# Env: JETSON_IP (required) STREAM_PATH=infer RTSP_PORT=8554 HLS_PORT=8888 WHEP_PORT=8889 IMU_PORT=8080

set -euo pipefail
JETSON_IP="${JETSON_IP:-}"; STREAM_PATH="${STREAM_PATH:-infer}"
RTSP_PORT="${RTSP_PORT:-8554}"; HLS_PORT="${HLS_PORT:-8888}"; WHEP_PORT="${WHEP_PORT:-8889}"; IMU_PORT="${IMU_PORT:-8080}"
MODE="${1:-rtsp}"

log() { printf '[view-stream] %s\n' "$*"; }
die() { printf '[view-stream][FATAL] %s\n' "$*" >&2; exit 1; }
open_url() { command -v xdg-open >/dev/null && xdg-open "$1" >/dev/null 2>&1 & command -v open >/dev/null && open "$1"; log "URL: $1"; }
probe_port() { if command -v nc >/dev/null; then nc -z -w 2 "$JETSON_IP" "$1" >/dev/null 2>&1; else (exec 3<>"/dev/tcp/$JETSON_IP/$1") 2>/dev/null; fi; }

[[ -n "$JETSON_IP" ]] || die "JETSON_IP not set. Try: JETSON_IP=192.168.x.y $0 $MODE"
log "target $JETSON_IP  path /$STREAM_PATH  mode $MODE"
ping -c1 -W2 "$JETSON_IP" >/dev/null 2>&1 && log "host reachable" || log "warn: no ping reply (ICMP may be blocked; continuing)"

case "$MODE" in
  rtsp)
    command -v ffplay >/dev/null || die "ffplay not installed (dnf install ffmpeg / brew install ffmpeg)"
    probe_port "$RTSP_PORT" || die "RTSP :$RTSP_PORT unreachable — is mediamtx running on the Jetson?"
    shift || true
    exec ffplay -loglevel warning -fflags nobuffer -flags low_delay -analyzeduration 0 -probesize 32 \
         -rtsp_transport tcp "$@" "rtsp://${JETSON_IP}:${RTSP_PORT}/${STREAM_PATH}" ;;
  whep) probe_port "$WHEP_PORT" || die "WHEP :$WHEP_PORT unreachable — is mediamtx running?"; open_url "http://${JETSON_IP}:${WHEP_PORT}/${STREAM_PATH}" ;;
  hls)  probe_port "$HLS_PORT"  || die "HLS :$HLS_PORT unreachable — is mediamtx running?";  open_url "http://${JETSON_IP}:${HLS_PORT}/${STREAM_PATH}" ;;
  imu)  probe_port "$IMU_PORT"  || die "IMU :$IMU_PORT unreachable — is the device labeled inference=imu?"; open_url "http://${JETSON_IP}:${IMU_PORT}/" ;;
  -h|--help|help) sed -n '2,10p' "$0" ;;
  *) die "unknown mode: $MODE (rtsp | whep | hls | imu)" ;;
esac
