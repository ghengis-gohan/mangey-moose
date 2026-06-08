# base-image/kickstart.ks
#
# Used with bootc-image-builder (or Anaconda) to produce the installer ISO.
# Handles: disk layout, first-boot WiFi, SSH key, hostname.

text
lang en_US.UTF-8
keyboard us
timezone America/Denver --utc

# Disk layout - wipe and auto-partition the eMMC/NVMe
zerombr
clearpart --all --initlabel
autopart --type=plain --noswap

# Pull the bootc image from your registry.
# Replace with your actual registry path once you push the built image.
ostreecontainer --url quay.io/rh-ee-soanders/marvelous-moose:latest

# No default user here; the redhat user is created in the Containerfile.
# If you want an install-time user instead, add:
#   user --name=redhat --groups=wheel,video --password=... --iscrypted

# Network + SSH come from %post below.
reboot

%post --erroronfail
# --- WiFi connection ----------------------------------------------------------
# Replace SSID and PSK. For WPA-Enterprise or hidden networks, adjust accordingly.
cat >/etc/NetworkManager/system-connections/drone-wifi.nmconnection <<'EOF'
[connection]
id=drone-wifi
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid="###SSID_NAME###"

[wifi-security]
key-mgmt=wpa-psk
psk="###SSID_PASSWD###"

[ipv4]
method=auto

[ipv6]
method=auto
EOF
chmod 600 /etc/NetworkManager/system-connections/drone-wifi.nmconnection

# --- SSH authorized_keys for the redhat user ----------------------------------
mkdir -p /var/home/redhat/.ssh
cat >/var/home/redhat/.ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOk4uX5r2gvfPn7MmgT0A/3NWJKEZU6wkw5WewfR84sv ghengisgohan@mangey-moose
EOF
chmod 700 /var/home/redhat/.ssh
chmod 600 /var/home/redhat/.ssh/authorized_keys
chown -R redhat:redhat /var/home/redhat/.ssh

# --- Hostname -----------------------------------------------------------------
# Each Jetson should have a unique hostname; override per-device if building
# multiple ISOs, or set via flightctl-agent device enrollment.
echo "jetson-drone-01" > /etc/hostname

%end