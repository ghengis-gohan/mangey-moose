#!/usr/bin/env bash
# export_engine.sh
#
# Idempotent TensorRT engine export for Ultralytics YOLO.
# Writes $OUT_DIR/$OUT_NAME and a sentinel $OUT_DIR/.engine_built_<sig>.
# Exits 0 on success or on no-op (already built with matching signature).

set -euo pipefail

SRC_WEIGHTS="${SRC_WEIGHTS:-/app/yolov8n.pt}"
OUT_DIR="${OUT_DIR:-/models}"
OUT_NAME="${OUT_NAME:-yolov8n.engine}"
IMG_SIZE="${IMG_SIZE:-640}"
HALF="${HALF:-true}"
WORKSPACE_GB="${WORKSPACE_GB:-2}"

OUT_PATH="${OUT_DIR}/${OUT_NAME}"

log() { printf '[model-init] %s\n' "$*"; }
die() { printf '[model-init][FATAL] %s\n' "$*" >&2; exit 1; }

[[ -f "$SRC_WEIGHTS" ]] || die "source weights not found: $SRC_WEIGHTS"
[[ -d "$OUT_DIR"     ]] || die "output dir not mounted: $OUT_DIR"

# Build a signature from things that, if they change, invalidate the engine.
# We include: source weights SHA256, TRT version, torch CUDA version, image size, half flag.
TRT_VER="$(python3 -c 'import tensorrt as t; print(t.__version__)' 2>/dev/null || echo 'unknown')"
TORCH_CUDA="$(python3 -c 'import torch; print(torch.version.cuda)' 2>/dev/null || echo 'unknown')"
WEIGHTS_SHA="$(sha256sum "$SRC_WEIGHTS" | awk '{print $1}' | cut -c1-12)"
SIG="${WEIGHTS_SHA}_trt${TRT_VER}_cuda${TORCH_CUDA}_img${IMG_SIZE}_half${HALF}"
# Sanitize (no slashes etc. in filenames)
SIG="${SIG//\//_}"
SENTINEL="${OUT_DIR}/.engine_built_${SIG}"

log "source weights: $SRC_WEIGHTS (sha256[:12]=$WEIGHTS_SHA)"
log "TRT version:    $TRT_VER"
log "Torch CUDA:     $TORCH_CUDA"
log "output:         $OUT_PATH"
log "signature:      $SIG"

# Fast path: already built for this exact stack.
if [[ -f "$OUT_PATH" && -f "$SENTINEL" ]]; then
    log "engine already exists and matches signature, nothing to do"
    exit 0
fi

# If an old engine exists from a prior signature, remove it and any old sentinels.
if [[ -f "$OUT_PATH" ]]; then
    log "stale engine found (no matching sentinel), removing"
    rm -f "$OUT_PATH"
fi
# Clean old sentinels so we don't accumulate.
find "$OUT_DIR" -maxdepth 1 -type f -name '.engine_built_*' -delete || true

log "exporting TensorRT engine (this can take several minutes on Orin Nano)..."

# Ultralytics CLI export. Writes alongside the .pt by default, so we copy after.
# format=engine -> .engine file. half=True -> FP16 (big speedup on Jetson, same accuracy for YOLOv8n).
cd /app
python3 - <<PY
from ultralytics import YOLO
import os, shutil

src = os.environ["SRC_WEIGHTS"]
imgsz = int(os.environ["IMG_SIZE"])
half = os.environ["HALF"].lower() in ("1","true","yes")
workspace = int(os.environ["WORKSPACE_GB"])

m = YOLO(src, task="detect")
# Ultralytics writes the engine next to the .pt by default.
out = m.export(format="engine", imgsz=imgsz, half=half, workspace=workspace, verbose=True)
print(f"[model-init] ultralytics wrote: {out}")

dst = os.path.join(os.environ["OUT_DIR"], os.environ["OUT_NAME"])
if os.path.abspath(out) != os.path.abspath(dst):
    shutil.copy2(out, dst)
    print(f"[model-init] copied to: {dst}")
PY

[[ -f "$OUT_PATH" ]] || die "export completed but engine not at expected path: $OUT_PATH"

# Write sentinel last so a partial failure doesn't leave a false-positive.
touch "$SENTINEL"

# Permissions: readable by anyone (inference container may run as non-root).
chmod 0644 "$OUT_PATH" "$SENTINEL"

log "done."