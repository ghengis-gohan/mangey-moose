# On the Jetson (or a dev box cross-compiling to arm64)
cd traffic-infer
sudo podman build --platform=linux/arm64 \
  -t quay.io/rh-ee-soanders/mangey-moose-traffic-infer:v1 .

# Run it alongside mediamtx (which should already be running host-network)
sudo podman run --rm \
  --network=host \
  --device /dev/video0 \
  --device nvidia.com/gpu=all \
  --group-add video \
  --security-opt label=disable \
  -v /var/lib/mangey-moose/models:/models:z \
  -e RTSP_URL=rtsp://127.0.0.1:8554/infer \
  quay.io/rh-ee-soanders/mangey-moose-traffic-infer:v1

# Expected log sequence on first run:
#   [traffic-infer] seeding model cache at /models/traffic/Primary_Detector
#   [traffic-infer] runtime infer config written to /tmp/config_infer_primary.txt with these paths: ...
#   [traffic-infer] source: /dev/video0 @ 1280x720@10 YUYV
#   [traffic-infer] publishing to: rtsp://127.0.0.1:8554/infer
#   [traffic-infer] launching pipeline (first run builds TRT engine — may take ~60s)...
#   Setting pipeline to PAUSED ...
#   [INFO] nvinfer: Trying to create engine from model files
#   [INFO] ... (30-60s of TRT build logs)
#   Pipeline is live and does not need PREROLL ...
#   Setting pipeline to PLAYING ...
#   New clock: GstSystemClock

# On ground station
ffplay -rtsp_transport tcp rtsp://$JETSON_IP:8554/infer
# Expect: your camera feed with Vehicle/Bicycle/Person/RoadSign boxes wherever
# the model hallucinates them.