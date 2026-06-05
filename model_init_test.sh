# Build it
cd model-init
sudo podman build -t quay.io/YOUR_ORG/drone-edge-model-init:v1 .

# Run it with the host models dir mounted
sudo podman run --rm \
  --device nvidia.com/gpu=all \
  -v /var/lib/drone-edge/models:/models:z \
  quay.io/YOUR_ORG/drone-edge-model-init:v1

# Expect output ending with "[model-init] done."
ls -la /var/lib/drone-edge/models/
# Should show yolov8n.engine and one sentinel file

# Run it AGAIN — should no-op immediately
sudo podman run --rm \
  --device nvidia.com/gpu=all \
  -v /var/lib/drone-edge/models:/models:z \
  quay.io/YOUR_ORG/drone-edge-model-init:v1
# Expect: "engine already exists and matches signature, nothing to do"