cd yolo-infer
sudo podman build --platform=linux/arm64 \
  -t quay.io/rh-ee-soanders/mangey-moose-yolo-infer:v1 .

# Manual test: assumes mediamtx is already running host-network,
# and /var/lib/mangey-moose/models has yolov8n.engine
sudo podman run --rm \
  --network=host \
  --device /dev/video0 \
  --device nvidia.com/gpu=all \
  --group-add video \
  -v /var/lib/mangey-moose/models:/models:ro,z \
  -e RTSP_URL=rtsp://127.0.0.1:8554/infer \
  quay.io/rh-ee-soanders/mangey-moose-yolo-infer:v1

# Expected log sequence:
#   [yolo-infer] loading TensorRT engine: /models/yolov8n.engine
#   [yolo-infer] camera FOURCC=YUYV FPS=10.0 size=1280x720
#   [yolo-infer] selected encoder: h264_nvmpi     (or nvenc / x264)
#   [yolo-infer] publishing to: rtsp://127.0.0.1:8554/infer
#   [yolo-infer] ffmpeg: ffmpeg -hide_banner ...
#   [yolo-infer] running ~9.4 fps
#   [yolo-infer] running ~9.6 fps

# On ground station
ffplay -rtsp_transport tcp rtsp://$JETSON_IP:8554/infer