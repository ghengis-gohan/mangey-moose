lang en_US.UTF-8
keyboard us
timezone UTC
text

# --- Pre-install sanity check -------------------------------------------------
# Fail loud if the NVMe isn't enumerated. Better than silently installing onto
# the wrong disk (e.g. the USB stick itself, which is what happened last time).
%pre --erroronfail
if [ ! -b /dev/nvme0n1 ]; then
    echo "FATAL: /dev/nvme0n1 not detected. Aborting install." >&2
    exit 1
fi
%end

# --- Disk layout --------------------------------------------------------------
# Pin install to the NVMe ONLY. Anaconda will not touch the USB stick, SD card,
# or anything else that enumerates. The JetPack BSP partitions (A_kernel,
# B_kernel, recovery, esp_alt, UDA, etc.) get wiped along with everything else
# on the NVMe — that's intentional. UEFI firmware lives in the Jetson's QSPI,
# not on the NVMe, so this is safe.
ignoredisk --only-use=nvme0n1
zerombr
clearpart --all --initlabel --drives=nvme0n1

# Platform-required partitions (ESP + boot on aarch64), then LVM for everything
# else. ESP lands at p1 where UEFI looks first.
reqpart --add-boot
part pv.01 --grow --ondisk=nvme0n1
volgroup rhel pv.01
logvol / --vgname=rhel --fstype=xfs --size=51200 --name=root

# --- Accounts -----------------------------------------------------------------
rootpw redhat

# --- Networking ---------------------------------------------------------------
# Wired interface gets DHCP and activates on boot. WiFi is configured in
# %post below.
network --bootproto=dhcp --device=link --activate --onboot=on

# --- Boot from the embedded bootc container ----------------------------------
# bootc-image-builder embeds the OCI image in the ISO at /run/install/repo/container
ostreecontainer --transport oci --url /run/install/repo/container

# Eject the install media before rebooting so the firmware doesn't try to boot
# it again on the next cycle.
reboot --eject

# --- Post-install -------------------------------------------------------------
%post --log=/dev/console --erroronfail
set -euxo pipefail

# Make sure the video group exists in /etc/group (it's in /usr/lib/group on
# image-mode systems and needs to be replicated for rootless GPU access).
grep -E '^video' /usr/lib/group >> /etc/group

# Regenerate kernel module dependency tables for the installed kernel.
depmod -a

# Re-point the bootc image reference at the registry so future `bootc upgrade`
# pulls from the right place. Replace ${IMAGE_NAME} with your real image
# reference at build time, or hard-code it here.
bootc switch --mutate-in-place --transport registry \
    quay.io/rh-ee-soanders/mangey-moose-base-image:latest

# --- WiFi setup ---------------------------------------------------------------
# Create the NetworkManager connection for 'Bivouac-Den'. PSK is a
# kickstart-time substitution; the rendered file in /tmp/moose.rendered.ks
# has the real value before mkksiso embedded it.
cat >/etc/NetworkManager/system-connections/Bivouac-Den.nmconnection <<'EOF'
[connection]
id=Bivouac-Den
type=wifi
autoconnect=true
[wifi]
mode=infrastructure
ssid=###SSID###
[wifi-security]
key-mgmt=wpa-psk
psk=###WIFI_PASSWD###
[ipv4]
method=auto
[ipv6]
method=auto
EOF
chmod 600 /etc/NetworkManager/system-connections/Bivouac-Den.nmconnection
chown root:root /etc/NetworkManager/system-connections/Bivouac-Den.nmconnection

# --- SSH access for the redhat user -------------------------------------------
useradd -m -d /var/home/redhat       -G wheel,video redhat       2>/dev/null || true
useradd -m -d /var/home/ghengisgohan -G wheel,video ghengisgohan 2>/dev/null || true

echo 'root:redhat'         | chpasswd
echo 'redhat:redhat'       | chpasswd
echo 'ghengisgohan:redhat' | chpasswd

mkdir -p /var/home/redhat/.ssh
cat >/var/home/redhat/.ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFArFqiUcEC0Uk9y+BwjaAkL6OVb6/ka48oQlcdE7bEp ghengisgohan@mangey-moose
EOF
chmod 700 /var/home/redhat/.ssh
chmod 600 /var/home/redhat/.ssh/authorized_keys
chown -R redhat:redhat /var/home/redhat/.ssh

# --- Hostname -----------------------------------------------------------------
hostnamectl set-hostname jetson-drone-01

%end