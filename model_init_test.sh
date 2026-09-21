# Build it
cd model-init
sudo podman build -t quay.io/rh-ee-soanders/mangey-moose-model-init:v2 .

# Run it with the host models dir mounted
sudo podman run --rm \
  --device nvidia.com/gpu=all \
  -v /var/lib/mangey-moose/models:/models:z \
  quay.io/rh-ee-soanders/mangey-moose-model-init:v2

# Expect output ending with "[model-init] done."
ls -la /var/lib/mangey-moose/models/
# Should show yolo26n.engine and one sentinel file

# Run it AGAIN — should no-op immediately
sudo podman run --rm \
  --device nvidia.com/gpu=all \
  -v /var/lib/mangey-moose/models:/models:z \
  quay.io/rh-ee-soanders/mangey-moose-model-init:v2
# Expect: "engine already exists and matches signature, nothing to do"