#!/usr/bin/env bash
# pipeline.sh
#
# Launches a DeepStream GStreamer pipeline:
#   V4L2 camera -> resnet10_4class inference -> OSD bounding boxes
#   -> NVENC H.264 -> RTSP publish to MediaMTX.
#
# On first run, copies shipped Primary_Detector sample to the persistent
# /models cache so nvinfer's generated TRT engine survives container
# recreation. Subsequent runs reuse the cached engine (fast start).

set -euo pipefail

# -------------------------- config from env ---------------------------------
RTSP_URL="${RTSP_URL:-rtsp://127.0.0.1:8554/infer}"
SRC="${SRC:-/dev/video0}"
W="${W:-1280}"
H="${H:-720}"
FPS="${FPS:-10}"
CAP_FOURCC="${CAP_FOURCC:-YUYV}"
BITRATE_BPS="${BITRATE_BPS:-2500000}"
MODEL_CACHE_DIR="${MODEL_CACHE_DIR:-/models/traffic}"
DS_SAMPLES_DIR="${DS_SAMPLES_DIR:-/opt/nvidia/deepstream/deepstream/samples}"

log() { printf '[traffic-infer] %s\n' "$*"; }
die() { printf '[traffic-infer][FATAL] %s\n' "$*" >&2; exit 1; }

# -------------------------- preflight ---------------------------------------
[[ -e "$SRC" ]] || die "camera not found at $SRC (did you pass --device $SRC?)"
[[ -d /models ]] || die "/models not mounted (bind-mount /var/lib/drone-edge/models here)"
command -v gst-launch-1.0 >/dev/null || die "gst-launch-1.0 missing"

# Sanity: does the DeepStream sample we rely on exist?
SHIPPED_MODEL_DIR="${DS_SAMPLES_DIR}/models/Primary_Detector"
SHIPPED_CONFIG="${DS_SAMPLES_DIR}/configs/deepstream-app/config_infer_primary.txt"
[[ -d "$SHIPPED_MODEL_DIR" ]] || die "shipped model dir missing: $SHIPPED_MODEL_DIR"
[[ -f "$SHIPPED_CONFIG"    ]] || die "shipped config missing:    $SHIPPED_CONFIG"

# -------------------------- seed model cache --------------------------------
# On first run, populate /models/traffic/Primary_Detector from the image.
# On subsequent runs, skip. This is what makes engine caching work — nvinfer
# will write its auto-generated .engine next to the .caffemodel on first run,
# and the mount persists it across container lifecycles.
mkdir -p "${MODEL_CACHE_DIR}"
if [[ ! -d "${MODEL_CACHE_DIR}/Primary_Detector" ]]; then
    log "seeding model cache at ${MODEL_CACHE_DIR}/Primary_Detector"
    cp -a "${SHIPPED_MODEL_DIR}" "${MODEL_CACHE_DIR}/Primary_Detector"
else
    log "model cache already present at ${MODEL_CACHE_DIR}/Primary_Detector"
fi

# -------------------------- build runtime config ----------------------------
# The shipped config references paths inside /opt/nvidia/deepstream/... .
# Rewrite the handful of path keys to point at the cache so the auto-built
# .engine lands in /models/traffic/Primary_Detector (persisted).
RUNTIME_CONFIG="/tmp/config_infer_primary.txt"
cp "$SHIPPED_CONFIG" "$RUNTIME_CONFIG"

# Redirect model-file, proto-file, labelfile, model-engine-file, int8-calib-file
# to the cache dir. Not every key is present in every DeepStream version; sed
# is a no-op when a key is absent.
sed -i -E "s|(model-file=).*Primary_Detector/([^/]+)$|\1${MODEL_CACHE_DIR}/Primary_Detector/\2|"       "$RUNTIME_CONFIG"
sed -i -E "s|(proto-file=).*Primary_Detector/([^/]+)$|\1${MODEL_CACHE_DIR}/Primary_Detector/\2|"       "$RUNTIME_CONFIG"
sed -i -E "s|(labelfile-path=).*Primary_Detector/([^/]+)$|\1${MODEL_CACHE_DIR}/Primary_Detector/\2|"   "$RUNTIME_CONFIG"
sed -i -E "s|(model-engine-file=).*Primary_Detector/([^/]+)$|\1${MODEL_CACHE_DIR}/Primary_Detector/\2|" "$RUNTIME_CONFIG"
sed -i -E "s|(int8-calib-file=).*Primary_Detector/([^/]+)$|\1${MODEL_CACHE_DIR}/Primary_Detector/\2|"  "$RUNTIME_CONFIG"

log "runtime infer config written to $RUNTIME_CONFIG with these paths:"
grep -E '^(model-file|proto-file|labelfile-path|model-engine-file|int8-calib-file)=' "$RUNTIME_CONFIG" | sed 's/^/  /' || true

# -------------------------- source caps -------------------------------------
# GStreamer uses FourCC "YUY2" for V4L2 "YUYV" (same 4:2:2 format).
# MJPG needs a decoder in the pipeline. YUYV goes straight in.
case "${CAP_FOURCC^^}" in
    YUYV|YUY2)
        SRC_CAPS="video/x-raw,format=YUY2,width=${W},height=${H},framerate=${FPS}/1"
        SRC_DECODE="videoconvert"
        ;;
    MJPG|MJPEG)
        SRC_CAPS="image/jpeg,width=${W},height=${H},framerate=${FPS}/1"
        SRC_DECODE="jpegdec ! videoconvert"
        ;;
    *)
        die "unsupported CAP_FOURCC=${CAP_FOURCC} (use YUYV or MJPG)"
        ;;
esac

log "source: $SRC @ ${W}x${H}@${FPS} ${CAP_FOURCC}"
log "publishing to: $RTSP_URL"

# -------------------------- pipeline ----------------------------------------
# v4l2src                            : capture from USB cam
# $SRC_DECODE                        : decode (MJPG) or passthrough convert
# nvvideoconvert -> NVMM NV12        : move into GPU memory
# nvstreammux                        : required wrapper for nvinfer; live-source=1 disables buffering
# nvinfer config-file-path=...       : the resnet10_4class primary detector
# nvvideoconvert -> nvdsosd          : draw boxes/labels
# nvvideoconvert -> NVMM NV12        : prepare for hw encoder
# nvv4l2h264enc                      : Jetson hardware H.264 encoder
# h264parse                          : parse for RTSP payloader
# rtspclientsink protocols=tcp       : publish to MediaMTX

PIPELINE=(
    gst-launch-1.0 -e
    v4l2src device="${SRC}" do-timestamp=true
        ! "${SRC_CAPS}"
        ! ${SRC_DECODE}
        ! nvvideoconvert
        ! "video/x-raw(memory:NVMM),format=NV12"
        ! mux.sink_0
    nvstreammux name=mux batch-size=1 width="${W}" height="${H}" live-source=1 batched-push-timeout=40000
        ! nvinfer config-file-path="${RUNTIME_CONFIG}"
        ! nvvideoconvert
        ! nvdsosd
        ! nvvideoconvert
        ! "video/x-raw(memory:NVMM),format=NV12"
        ! nvv4l2h264enc insert-sps-pps=true iframeinterval=20 bitrate="${BITRATE_BPS}" preset-level=1
        ! h264parse
        ! rtspclientsink location="${RTSP_URL}" protocols=tcp
)

log "launching pipeline (first run builds TRT engine — may take ~60s)..."
exec "${PIPELINE[@]}"