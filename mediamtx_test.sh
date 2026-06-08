# From the drone-edge/ repo root
cd mediamtx

# Build for the Jetson (aarch64). If you're building ON the Jetson, skip --platform.
podman build --platform=linux/arm64 -t quay.io/rh-ee-soanders/mangey-moose-mediamtx:v1.17.1 .

# Smoke test on the Jetson before wiring to Edge Manager
sudo podman run --rm --network=host \
  --name mediamtx-test \
  quay.io/rh-ee-soanders/mangey-moose-mediamtx:v1.17.1

# In another terminal, verify:
curl -s http://127.0.0.1:9997/v3/paths/list | jq
# Should return {"items":[],...}

# Push a test stream (on the Jetson)
ffmpeg -re -f lavfi -i testsrc=size=640x360:rate=15 \
       -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
       -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/test

# On ground station
ffplay -rtsp_transport tcp rtsp://$JETSON_IP:8554/test
# or open http://$JETSON_IP:8889/test in a browser for WHEP