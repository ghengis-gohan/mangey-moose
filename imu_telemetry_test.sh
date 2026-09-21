# --- Build (on the Jetson, or --platform=linux/arm64 elsewhere) ---
cd imu-telemetry
sudo podman build -t quay.io/rh-ee-soanders/mangey-moose-imu-telemetry:v1 .

# --- 1. Prove the wiring before involving the container -------------------
# Expect 6b (LSM6DS33), 1e (LIS3MDL), 5d (LPS25H) on the bus you wired.
# Header pins 3/5 -> /dev/i2c-7 ; pins 27/28 -> /dev/i2c-1 (Orin Nano devkit)
ls -l /dev/i2c-*
sudo podman run --rm --device /dev/i2c-7 --device /dev/i2c-1 \
  --security-opt label=disable registry.access.redhat.com/ubi9/ubi:latest \
  bash -c 'dnf -q install -y i2c-tools >/dev/null && i2cdetect -y 7; i2cdetect -y 1'

# --- 2. UI only, no hardware (SIM=1) ---------------------------------------
sudo podman run --rm --network=host -e SIM=1 \
  quay.io/rh-ee-soanders/mangey-moose-imu-telemetry:v1
# open http://<jetson-ip>:8080/

# --- 3. Real sensor ---------------------------------------------------------
sudo podman run --rm --network=host \
  --device /dev/i2c-7 \
  --security-opt label=disable \
  -e I2C_BUS=7 \
  quay.io/rh-ee-soanders/mangey-moose-imu-telemetry:v1
# Expected:
#   [imu-telemetry] AltIMU-10 v5 on /dev/i2c-7
#   [imu-telemetry] dashboard on http://0.0.0.0:8080/  (window=10, 20.0 Hz)
curl -s http://127.0.0.1:8080/latest | jq
