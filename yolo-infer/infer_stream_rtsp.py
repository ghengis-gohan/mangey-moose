#!/usr/bin/env python3
"""
infer_stream_rtsp.py

Reads frames from a V4L2 camera, runs YOLOv8 inference (TensorRT engine),
annotates, and publishes H.264-over-RTSP to a MediaMTX sidecar.

Designed to run under tini in a container managed by Red Hat Edge Manager.
Exits non-zero on unrecoverable errors so podman/flightctl can restart it.
"""

import os
import sys
import time
import signal
import shutil
import subprocess
from typing import List

import cv2
from ultralytics import YOLO


# -------------------------- config from env ----------------------------------
RTSP_URL       = os.environ.get("RTSP_URL", "rtsp://127.0.0.1:8554/infer")
SRC            = os.environ.get("SRC", "/dev/video0")
MODEL          = os.environ.get("MODEL", "/models/yolov8n.engine")
FALLBACK_MODEL = os.environ.get("FALLBACK_MODEL", "/models/yolov8n.pt")
W              = int(os.environ.get("W", "1280"))
H              = int(os.environ.get("H", "720"))
FPS            = int(os.environ.get("FPS", "10"))
CAP_FOURCC     = os.environ.get("CAP_FOURCC", "YUYV")   # "YUYV" or "MJPG"
BITRATE        = os.environ.get("BITRATE", "2500k")
ENCODER        = os.environ.get("ENCODER", "auto")      # "auto" | "nvmpi" | "nvenc" | "x264"
CAM_FAIL_MAX   = int(os.environ.get("CAM_FAIL_THRESHOLD", "30"))


# -------------------------- logging -----------------------------------------
def log(msg: str) -> None:
    print(f"[yolo-infer] {msg}", flush=True)

def die(msg: str, code: int = 1) -> None:
    print(f"[yolo-infer][FATAL] {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


# -------------------------- signal handling ---------------------------------
# podman sends SIGTERM on stop; default Python behavior is to ignore it (it
# raises only KeyboardInterrupt on SIGINT). Convert SIGTERM -> SystemExit so
# our finally: block runs and ffmpeg gets cleaned up.
def _graceful(signum, _frame):
    log(f"received signal {signum}, shutting down")
    raise SystemExit(0)

signal.signal(signal.SIGTERM, _graceful)
signal.signal(signal.SIGINT,  _graceful)


# -------------------------- encoder selection -------------------------------
def ffmpeg_has_encoder(name: str) -> bool:
    try:
        out = subprocess.run(
            ["ffmpeg", "-hide_banner", "-encoders"],
            capture_output=True, text=True, check=True
        ).stdout
        return f" {name} " in out or out.endswith(f" {name}\n")
    except Exception:
        return False

def pick_encoder_args() -> List[str]:
    """
    Return ffmpeg output-side encoder args. Prefers Jetson-native NVENC paths,
    falls back to libx264 ultrafast. Honors ENCODER env if set to a specific
    value.
    """
    choice = ENCODER.lower()
    if choice == "auto":
        for cand in ("h264_nvmpi", "h264_nvenc"):
            if ffmpeg_has_encoder(cand):
                choice = cand
                break
        else:
            choice = "x264"

    log(f"selected encoder: {choice}")

    if choice == "h264_nvmpi":
        # Jetson-specific NVENC wrapper; lowest CPU.
        return ["-c:v", "h264_nvmpi",
                "-b:v", BITRATE, "-maxrate", BITRATE, "-bufsize", "1250k",
                "-profile:v", "baseline"]
    if choice == "h264_nvenc":
        # Standard NVIDIA NVENC.
        return ["-c:v", "h264_nvenc",
                "-preset", "p1", "-tune", "ll",
                "-rc", "cbr", "-b:v", BITRATE, "-maxrate", BITRATE, "-bufsize", "1250k",
                "-pix_fmt", "yuv420p", "-g", "20", "-bf", "0",
                "-profile:v", "baseline"]
    # Fallback: libx264. Works anywhere, eats CPU.
    return ["-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
            "-pix_fmt", "yuv420p", "-g", "20", "-keyint_min", "20", "-bf", "0",
            "-profile:v", "baseline",
            "-b:v", BITRATE, "-maxrate", BITRATE, "-bufsize", "1250k"]


# -------------------------- model loading -----------------------------------
def load_model() -> YOLO:
    if os.path.exists(MODEL):
        log(f"loading TensorRT engine: {MODEL}")
        return YOLO(MODEL, task="detect")
    if os.path.exists(FALLBACK_MODEL):
        log(f"[warn] engine not found, falling back to .pt: {FALLBACK_MODEL}")
        log("[warn] this will be noticeably slower; model-init may not have run")
        return YOLO(FALLBACK_MODEL, task="detect")
    die(f"no model found. tried: {MODEL} and {FALLBACK_MODEL}", code=2)


# -------------------------- camera open -------------------------------------
def open_camera() -> cv2.VideoCapture:
    cap = cv2.VideoCapture(SRC, cv2.CAP_V4L2)
    if not cap.isOpened():
        die(f"cannot open camera at {SRC}", code=3)

    fourcc_code = cv2.VideoWriter_fourcc(*CAP_FOURCC)
    cap.set(cv2.CAP_PROP_FOURCC, fourcc_code)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH,  W)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, H)
    cap.set(cv2.CAP_PROP_FPS, FPS)

    actual_fourcc = int(cap.get(cv2.CAP_PROP_FOURCC))
    actual_str    = "".join(chr((actual_fourcc >> 8*i) & 0xFF) for i in range(4))
    log(f"camera FOURCC={actual_str} "
        f"FPS={cap.get(cv2.CAP_PROP_FPS)} "
        f"size={int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))}x"
        f"{int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))}")
    return cap


# -------------------------- ffmpeg spawn ------------------------------------
def spawn_ffmpeg(width: int, height: int) -> subprocess.Popen:
    if not shutil.which("ffmpeg"):
        die("ffmpeg not found in PATH", code=4)

    enc_args = pick_encoder_args()
    cmd = [
        "ffmpeg",
        "-hide_banner", "-loglevel", "warning",
        # INPUT
        "-f", "rawvideo",
        "-pix_fmt", "bgr24",
        "-s", f"{width}x{height}",
        "-r", str(FPS),
        "-i", "-",
        # OUTPUT
        *enc_args,
        "-f", "rtsp",
        "-rtsp_transport", "tcp",
        RTSP_URL,
    ]
    log(f"publishing to: {RTSP_URL}")
    log(f"ffmpeg: {' '.join(cmd)}")
    return subprocess.Popen(cmd, stdin=subprocess.PIPE)


# -------------------------- main --------------------------------------------
def main() -> int:
    model = load_model()
    cap   = open_camera()

    # Warm-up read to fix the frame size we'll tell ffmpeg about.
    ok, frame = cap.read()
    if not ok or frame is None:
        die("initial camera read failed", code=3)
    h, w = frame.shape[:2]

    proc = spawn_ffmpeg(w, h)

    fail_count = 0
    frames = 0
    last = time.time()

    try:
        while True:
            ok, frame = cap.read()
            if not ok or frame is None:
                fail_count += 1
                if fail_count >= CAM_FAIL_MAX:
                    raise RuntimeError(
                        f"camera read failed {fail_count} times in a row; exiting "
                        f"for container restart"
                    )
                time.sleep(0.05)
                continue
            fail_count = 0

            # Inference (model already on GPU via engine).
            results   = model.predict(frame, verbose=False)
            annotated = results[0].plot()

            # Hand off to ffmpeg.
            if proc.poll() is not None:
                raise RuntimeError(
                    f"ffmpeg exited early (rc={proc.returncode}); "
                    f"likely RTSP server unreachable or encoder failed"
                )
            try:
                proc.stdin.write(annotated.tobytes())
            except BrokenPipeError:
                raise RuntimeError("ffmpeg pipe broke; encoder/publisher died")

            # Periodic heartbeat.
            frames += 1
            now = time.time()
            if now - last >= 5:
                log(f"running ~{frames / (now - last):.1f} fps")
                frames = 0
                last = now

    except SystemExit:
        log("exit requested")
        return 0
    except Exception as e:
        log(f"error: {e}")
        return 1
    finally:
        try: cap.release()
        except Exception: pass
        try:
            if proc.stdin:
                proc.stdin.close()
        except Exception:
            pass
        try:
            proc.terminate()
            proc.wait(timeout=3)
        except Exception:
            try: proc.kill()
            except Exception: pass

    return 0


if __name__ == "__main__":
    sys.exit(main())