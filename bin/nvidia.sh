#!/bin/bash
set -e

# --- NVIDIA Configuration for Omarchy on CachyOS ---
# Replaces Omarchy's install/hardware/nvidia.sh. Runs as root, inside
# omarchy-apply-system.
#
# Philosophy: use whatever NVIDIA driver CachyOS's chwd installed. Upstream
# installs nvidia-open-dkms or nvidia-580xx-dkms itself, but on CachyOS chwd
# has already installed the prebuilt module matching linux-cachyos, and a
# second, DKMS-built driver conflicts with it. Only install a driver when none
# is present, and then through chwd so it still matches the CachyOS kernel.
#
# Session environment variables (LIBVA_DRIVER_NAME, NVD_BACKEND, ...) are not
# set here: Omarchy 4.x sets them per GPU generation in default/hypr/nvidia.lua.

if ! lspci -nn -d 10de: | grep -qE "VGA|3D"; then
    echo "[*] No NVIDIA GPU found. Skipping."
    exit 0
fi

GPU_NAME=$(lspci -d 10de: | grep -E "VGA|3D" | head -n1 | sed 's/.*: //')
echo "[*] NVIDIA GPU detected: $GPU_NAME"

# nvidia-utils ships with every driver branch chwd picks (open, proprietary,
# or a legacy series such as 580xx), so it is the reliable "a driver is
# installed" signal.
NVIDIA_UTILS=$(pacman -Qq | grep -E '^nvidia(-[0-9]+xx)?-utils$' | head -n1 || true)

if [[ -n "$NVIDIA_UTILS" ]]; then
    echo "[*] Active NVIDIA driver found: $(pacman -Q "$NVIDIA_UTILS")"
    echo "[*] Respecting existing CachyOS driver installation."
else
    echo "[!] No NVIDIA driver detected - installing via chwd..."
    chwd -a
    echo "[*] Driver installed via CachyOS hardware detection."
fi

# VA-API tools for checking hardware video decode (vainfo).
pacman -S --needed --noconfirm libva-utils

# Early KMS, as upstream's nvidia.sh configures it. Omarchy's own mkinitcpio
# drop-in (omarchy_hooks.conf) keys off nvidia_drm in MODULES to decide whether
# the kms hook can be dropped.
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia_drm modeset=1
EOF

mkdir -p /etc/mkinitcpio.conf.d
cat > /etc/mkinitcpio.conf.d/nvidia.conf <<'EOF'
MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
EOF

echo "[*] NVIDIA configuration complete."
