#!/bin/bash

set -euo pipefail

# Installs Omarchy 4.x on top of an existing CachyOS system.
#
# Omarchy 4.x (quattro) is no longer a git checkout driven by install.sh. It
# ships as two pacman packages - `omarchy` and `omarchy-settings` - plus a
# package list and two setup entry points the Omarchy ISO calls after
# pacstrap:
#
#   omarchy-apply-system --install-user USER   (root: services, hardware, sddm)
#   omarchy-provision-user                     (user: theme, git, mise, keyring)
#
# This script does what the ISO does, minus the parts that would undo CachyOS:
# it keeps CachyOS's pacman.conf and mirrorlist, its kernel, its NVIDIA driver
# selection (chwd), and tealdeer. Everything else is Omarchy's own code.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARCHY_SHARE="/usr/share/omarchy"
LOGIN_USER="$(id -un)"

# Everything is shown on screen and kept in one file. The 3.x installer sent
# each step's output only to /var/log/omarchy-install.log, so a failure showed
# up as a bare script name with the actual pacman error buried elsewhere.
INSTALL_LOG="$HOME/omarchy-on-cachyos-install.log"
exec > >(tee -a "$INSTALL_LOG") 2>&1
echo "=== omarchy-on-cachyos install started $(date '+%Y-%m-%d %H:%M:%S') ==="

# Every pacman call goes through this. The guard hook Omarchy installs rejects
# direct `pacman -Syu`; it is right to for a finished system, but this script
# is the installer, and a re-run happens after the hook already exists.
pacman_root() {
    sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman "$@"
}

fail() {
    echo "" >&2
    echo "Error: $1" >&2
    shift
    for line in "$@"; do
        echo "       $line" >&2
    done
    exit 1
}

confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer || return 1
    [[ "${answer,,}" =~ ^(y|yes)$ ]]
}

root_filesystem_encrypted() {
    local source
    source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    [[ $source == /dev/mapper/* ]] && return 0
    [[ -n $source ]] && [[ "$(lsblk -no TYPE "$source" 2>/dev/null | head -n1)" == "crypt" ]]
}

# --- preflight ----------------------------------------------------------------
# Each check here guards a failure that would otherwise surface halfway through,
# after packages are already installed.

if (( EUID == 0 )); then
    fail "run this script as your normal user, not as root." \
        "It uses sudo where root is needed, and sets Omarchy up for the user running it."
fi

for cmd in pacman sudo git findmnt lsblk lspci; do
    command -v "$cmd" &>/dev/null || fail "required command '$cmd' is not installed."
done

if ! grep -q '^\[cachyos' /etc/pacman.conf; then
    fail "no CachyOS repositories found in /etc/pacman.conf." \
        "This script installs Omarchy on top of CachyOS. On plain Arch, use the Omarchy ISO."
fi

# Snapper's root config, limine-snapper-sync and Omarchy's snapshot boot
# entries all assume btrfs; config/snapper.sh aborts the system setup without it.
if [ "$(findmnt -n -o FSTYPE /)" != "btrfs" ]; then
    fail "the root filesystem is not btrfs." \
        "Omarchy's snapshot setup requires btrfs. Reinstall CachyOS with btrfs (its default)."
fi

# The omarchy package hard-depends on limine, limine-mkinitcpio-hook and
# limine-snapper-sync, and its settings package writes limine-entry-tool
# drop-ins. On GRUB or systemd-boot that pulls in a second bootloader's tooling
# that nothing boots from.
if ! pacman -Q limine &>/dev/null || [ ! -f /etc/default/limine ]; then
    fail "CachyOS is not using the Limine bootloader." \
        "Omarchy 4.x depends on Limine. Reinstall CachyOS and pick Limine (its default)."
fi

# A real directory here is an Omarchy 3.x git checkout, from the previous
# version of this script or a manual install. 4.x lives in /usr/share/omarchy
# and the upgrade path for a 3.x tree is Omarchy's own converter, not this.
if [ -e "$HOME/.local/share/omarchy" ] && [ ! -L "$HOME/.local/share/omarchy" ]; then
    fail "$HOME/.local/share/omarchy is an existing Omarchy 3.x install." \
        "Upgrade it in place with Omarchy's own tools instead:" \
        "  omarchy-branch-set master && omarchy-update && omarchy-upgrade-to-quattro" \
        "or move it aside (mv ~/.local/share/omarchy ~/.local/share/omarchy.bak) and re-run."
fi

# Omarchy's mkinitcpio drop-in replaces HOOKS with a busybox (udev + encrypt)
# set. CachyOS defaults to the systemd hooks. Unencrypted that swap is fine; on
# a disk unlocked by sd-encrypt (rd.luks.* on the cmdline) the busybox
# `encrypt` hook never finds the volume and the system cannot boot.
KEEP_CACHYOS_HOOKS=false
CACHYOS_HOOKS_LINE="$(grep -E '^[[:space:]]*HOOKS=' /etc/mkinitcpio.conf | tail -n1 || true)"
if root_filesystem_encrypted && [[ $CACHYOS_HOOKS_LINE == *sd-encrypt* ]]; then
    KEEP_CACHYOS_HOOKS=true
fi

# --- prerequisites --------------------------------------------------------------

if ! command -v yay &> /dev/null; then
    echo "yay is not installed. Installing yay..."
    pacman_root -S --needed --noconfirm git base-devel
    YAY_BUILD="$(mktemp -d)"
    git clone https://aur.archlinux.org/yay.git "$YAY_BUILD"
    (cd "$YAY_BUILD" && makepkg -si --noconfirm)
    rm -rf "$YAY_BUILD"
    command -v yay &> /dev/null || fail "failed to install yay."
    echo "yay has been successfully installed."
else
    echo "yay is already installed."
fi

# Receive the Omarchy signing key. Keyserver fetches fail transiently often
# enough to be worth retrying, but never worth continuing without: a missing
# key surfaces much later as signature failures on every omarchy package.
OMARCHY_KEY="40DFB630FF42BCFFB047046CF0134EE680CAC571"
OMARCHY_KEYSERVER="keys.openpgp.org"
for attempt in 1 2 3; do
    if sudo pacman-key --recv-keys "$OMARCHY_KEY" --keyserver "$OMARCHY_KEYSERVER"; then
        break
    fi
    if [ "$attempt" -eq 3 ]; then
        fail "could not receive the Omarchy signing key $OMARCHY_KEY after 3 attempts." \
            "Check network and keyserver access, then re-run."
    fi
    echo "Keyserver fetch failed (attempt $attempt/3). Retrying in $((attempt * 5))s..."
    sleep "$((attempt * 5))"
done
sudo pacman-key --lsign-key "$OMARCHY_KEY"

# Add the omarchy repository next to the CachyOS ones. Only this section is
# ever touched: Omarchy's own installer copies its pacman.conf and mirrorlist
# over the system's, which would remove the CachyOS repositories outright.
if ! grep -q '^\[omarchy\]' /etc/pacman.conf; then
    echo -e "\n[omarchy]\nSigLevel = Optional TrustedOnly\nServer = https://pkgs.omarchy.org/stable/\$arch" | sudo tee -a /etc/pacman.conf > /dev/null
else
    echo "Omarchy repository already present in pacman.conf, skipping."
fi

# Upgrade first. Installing new packages against a partially upgraded system
# is unsupported on Arch and is the usual source of unresolvable dependencies.
pacman_root -Syu --noconfirm
pacman_root -S --needed --noconfirm omarchy-keyring

# --- user details ---------------------------------------------------------------

echo ""
echo "Your name and email are used for git's user.name and user.email."
read -r -p "Full name (leave empty to skip): " OMARCHY_USER_NAME
read -r -p "Email address (leave empty to skip): " OMARCHY_USER_EMAIL
export OMARCHY_USER_NAME OMARCHY_USER_EMAIL

# --- packages -------------------------------------------------------------------

# The meta packages first: the default package list ships inside `omarchy`, so
# it does not exist on disk until this transaction finishes.
#
# --ask 4 answers "yes" to pacman's "X and Y are in conflict. Remove Y?"
# question. With plain --noconfirm pacman answers "no" and aborts the entire
# transaction - which is exactly how the old 3.x install died inside
# packaging/base.sh. --overwrite='*' lets omarchy-settings replace files
# CachyOS put in /etc/skel and /etc/sddm.conf.d. Both flags are what Omarchy's
# own omarchy-upgrade-to-quattro uses for the same transaction.
CORE_PACKAGES=(omarchy-keyring omarchy-settings omarchy-nvim omarchy fakeroot pacman-contrib)

echo ""
echo "Installing the Omarchy packages..."
pacman_root -S --needed --noconfirm --ask 4 --overwrite='*' "${CORE_PACKAGES[@]}"

[ -f "$OMARCHY_SHARE/install/omarchy-base.packages" ] ||
    fail "$OMARCHY_SHARE/install/omarchy-base.packages is missing after installing omarchy."

mapfile -t BASE_PACKAGES < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$OMARCHY_SHARE/install/omarchy-base.packages")

# tldr conflicts with CachyOS's tealdeer, and --ask 4 cannot resolve that one:
# cachyos-fish-config depends on tealdeer, so removing it breaks a dependency
# and pacman aborts anyway. Both provide the same `tldr` command; keep tealdeer.
if pacman -Q tealdeer &>/dev/null; then
    FILTERED=()
    for pkg in "${BASE_PACKAGES[@]}"; do
        [ "$pkg" = "tldr" ] || FILTERED+=("$pkg")
    done
    BASE_PACKAGES=("${FILTERED[@]}")
fi

# The PipeWire stack the ISO's archinstall step provides. CachyOS ships jack2,
# which --ask 4 swaps for pipewire-jack.
AUDIO_PACKAGES=(pipewire pipewire-alsa pipewire-jack pipewire-pulse gst-plugin-pipewire libpulse wireplumber)

# Say up front which installed packages are about to be replaced, instead of
# letting --ask 4 do it silently. Conflicts are declared on either side (e.g.
# CachyOS's tuned-cachy-ppd declares the conflict with power-profiles-daemon),
# so both directions are checked.
report_conflicts() {
    local targets name conflicts c installed
    if ! targets="$(pacman -Sp --print-format '%n' "$@" 2>/dev/null)"; then
        return 0
    fi
    declare -A target_set=()
    for name in $targets; do
        target_set[$name]=1
    done

    # New package declares a conflict with something installed.
    # shellcheck disable=SC2086 # $targets is a whitespace-separated name list
    while IFS=$'\t' read -r name conflicts; do
        for c in $conflicts; do
            c="${c%%[<>=]*}"
            [ "$c" = "$name" ] && continue
            installed="$(pacman -Qq "$c" 2>/dev/null | head -n1 || true)"
            if [ -n "$installed" ] && [ "$installed" != "$name" ] && [ -z "${target_set[$installed]:-}" ]; then
                echo "  - $installed (conflicts with $name)"
            fi
        done
    done < <(pacman -Si $targets 2>/dev/null | awk -F': ' '
        /^Name/ { n = $2 }
        /^Conflicts With/ && $2 != "None" { print n "\t" $2 }')

    # Installed package declares a conflict with something new.
    while IFS=$'\t' read -r name conflicts; do
        [ -n "${target_set[$name]:-}" ] && continue
        for c in $conflicts; do
            c="${c%%[<>=]*}"
            if [ -n "${target_set[$c]:-}" ] && [ "$c" != "$name" ]; then
                echo "  - $name (conflicts with $c)"
            fi
        done
    done < <(pacman -Qi 2>/dev/null | awk -F': ' '
        /^Name/ { n = $2 }
        /^Conflicts With/ && $2 != "None" { print n "\t" $2 }')

    return 0
}

CONFLICTS="$(report_conflicts "${BASE_PACKAGES[@]}" "${AUDIO_PACKAGES[@]}" | sort -u)" || CONFLICTS=""
if [ -n "$CONFLICTS" ]; then
    echo ""
    echo "These installed packages conflict with Omarchy's defaults and will be replaced:"
    echo "$CONFLICTS"
    confirm "Continue?" || fail "aborted by user. Nothing past the Omarchy core packages was installed."
fi

echo ""
echo "Installing the Omarchy default package set..."
pacman_root -S --needed --noconfirm --ask 4 --overwrite='*' "${BASE_PACKAGES[@]}"
pacman_root -S --needed --noconfirm --ask 4 --overwrite='*' "${AUDIO_PACKAGES[@]}"

# Mark them explicit, as Omarchy's own installer does, so orphan cleanup in
# `omarchy update` never treats the defaults as removable. `pacman -Qq` resolves
# providers (nvim -> neovim), which -D needs.
EXPLICIT=()
for pkg in "${CORE_PACKAGES[@]}" "${BASE_PACKAGES[@]}" "${AUDIO_PACKAGES[@]}"; do
    installed="$(pacman -Qq "$pkg" 2>/dev/null | head -n1 || true)"
    [ -n "$installed" ] && EXPLICIT+=("$installed")
done
sudo pacman -D --asexplicit "${EXPLICIT[@]}" > /dev/null

# CachyOS ships Qt 6.12 ahead of Omarchy's stable channel, and Qt 6.12's own
# `Color` type shadows the shell's palette singleton: the shell runs but draws
# no bar and no launcher. Apply upstream's fix to the installed shell, and
# re-apply it from a pacman hook until an Omarchy release includes it.
"$SCRIPT_DIR/fix-omarchy-shell-qt612.sh" --install-hook

# --- system setup ---------------------------------------------------------------
# omarchy-apply-system reads its step scripts from $OMARCHY_INSTALL, which
# defaults to the packaged /usr/share/omarchy/install. Point it at a patched
# copy instead of editing package-owned files, which the next omarchy update
# would silently restore. $OMARCHY_PATH stays on the package, so every path a
# step writes into the system still points at /usr/share/omarchy.

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
cp -a "$OMARCHY_SHARE/install/." "$STAGE_DIR/"

# Each patch asserts its target before and after. sed exits 0 having changed
# nothing when upstream moves a line, and the run would then go on to replace
# the CachyOS pacman.conf.
patch_fail() {
    fail "patch '$1' failed on $2: $3" \
        "Omarchy has most likely changed this file upstream. Aborting before system setup."
}

# Remove post-install/pacman.sh: it copies Omarchy's own pacman.conf and
# mirrorlist over the system's, which deletes every CachyOS repository.
POST_ALL="$STAGE_DIR/post-install/all.sh"
POST_LINE='run_logged "$OMARCHY_INSTALL/post-install/pacman.sh"'
[ -f "$POST_ALL" ] || patch_fail "keep CachyOS pacman.conf" "$POST_ALL" "file does not exist"
grep -qxF -- "$POST_LINE" "$POST_ALL" || patch_fail "keep CachyOS pacman.conf" "$POST_ALL" "expected line not found"
grep -vxF -- "$POST_LINE" "$POST_ALL" > "$POST_ALL.new" || true
mv "$POST_ALL.new" "$POST_ALL"
! grep -qF -- 'post-install/pacman.sh' "$POST_ALL" || patch_fail "keep CachyOS pacman.conf" "$POST_ALL" "line still present"
echo "  - keep CachyOS pacman.conf: applied"

# Replace hardware/nvidia.sh. Upstream installs nvidia-open-dkms or
# nvidia-580xx-dkms itself; on CachyOS chwd has already installed the matching
# prebuilt module for linux-cachyos, and a second, DKMS-built driver conflicts.
NVIDIA_TARGET="$STAGE_DIR/hardware/nvidia.sh"
NVIDIA_MARKER="--- NVIDIA Configuration for Omarchy on CachyOS ---"
[ -f "$NVIDIA_TARGET" ] || patch_fail "replace nvidia.sh" "$NVIDIA_TARGET" "file does not exist"
grep -qF -- "$NVIDIA_MARKER" "$SCRIPT_DIR/nvidia.sh" || patch_fail "replace nvidia.sh" "$SCRIPT_DIR/nvidia.sh" "not the CachyOS version"
cp "$SCRIPT_DIR/nvidia.sh" "$NVIDIA_TARGET"
echo "  - replace nvidia.sh: applied"

# CachyOS's SDDM config sets its own session and theme, overriding the
# drop-ins in /etc/sddm.conf.d that omarchy-settings installs.
if [ -f /etc/sddm.conf ]; then
    echo "Removing CachyOS /etc/sddm.conf"
    sudo rm /etc/sddm.conf
fi

echo ""
echo "Running Omarchy system setup..."
sudo env OMARCHY_PATH="$OMARCHY_SHARE" OMARCHY_INSTALL="$STAGE_DIR" OMARCHY_LOG_TO_STDOUT=1 \
    omarchy-apply-system --install-user "$LOGIN_USER" --first-install

# --- login ----------------------------------------------------------------------
# The ISO owns the autologin decision because it knows whether the disk is
# encrypted, and so does this script. Same rule as Omarchy's: with LUKS the
# passphrase prompt is the login, so SDDM logs straight in; without it, SDDM
# asks for the password.
sudo install -d -m 0755 /etc/sddm.conf.d
printf '[Users]\nRememberLastUser=true\nRememberLastSession=true\n' |
    sudo tee /etc/sddm.conf.d/99-omarchy-login.conf > /dev/null
if root_filesystem_encrypted; then
    printf '[Autologin]\nUser=%s\nSession=omarchy.desktop\n' "$LOGIN_USER" |
        sudo tee /etc/sddm.conf.d/autologin.conf > /dev/null
    AUTOLOGIN_NOTE="Encrypted disk detected: SDDM logs you in automatically after the LUKS prompt."
else
    sudo rm -f /etc/sddm.conf.d/autologin.conf
    AUTOLOGIN_NOTE="Unencrypted disk: SDDM asks for your password (Omarchy's default)."
fi
sudo install -d -m 0755 /var/lib/sddm
printf '[Last]\nSession=omarchy.desktop\nUser=%s\n' "$LOGIN_USER" | sudo tee /var/lib/sddm/state.conf > /dev/null
sudo chown sddm:sddm /var/lib/sddm /var/lib/sddm/state.conf 2>/dev/null || true

# Omarchy's configs, aliases and prompt are written for bash. CachyOS logs in
# to fish, where none of it is ever loaded.
CURRENT_SHELL="$(getent passwd "$LOGIN_USER" | cut -d: -f7)"
if [ "$CURRENT_SHELL" != "/bin/bash" ] && [ "$CURRENT_SHELL" != "/usr/bin/bash" ]; then
    echo "Changing login shell for $LOGIN_USER from $CURRENT_SHELL to /bin/bash..."
    sudo chsh -s /bin/bash "$LOGIN_USER" ||
        echo "Warning: could not change the login shell. Run 'chsh -s /bin/bash' yourself."
fi

# --- kernel and boot ------------------------------------------------------------

# Keep linux-cachyos as the default boot entry. Omarchy's limine drop-in
# prefers linux-omarchy, and one of its migrations installs that kernel and
# writes its own BOOT_ORDER into /etc/default/limine - which takes priority
# over every drop-in, so that is the file to pin.
#
# The migration is marked complete for this user below (the /etc/skel copy
# carries the markers), and its machine-wide marker is set here too, so a
# later `omarchy-migrate` from another account does not reinstall it.
sudo sed -i -E '/^[[:space:]]*BOOT_ORDER[[:space:]]*=/d' /etc/default/limine
printf '\n%s\n' 'BOOT_ORDER="linux-cachyos, linux-cachyos-*, *, *fallback, Snapshots"' |
    sudo tee -a /etc/default/limine > /dev/null
sudo install -d -m 0755 /var/lib/omarchy/migrations
sudo touch /var/lib/omarchy/migrations/1789325478

# Encrypted with sd-encrypt: restore the CachyOS HOOKS after Omarchy's drop-in
# so the initramfs can still unlock the disk (see the preflight check above).
if [ "$KEEP_CACHYOS_HOOKS" = true ]; then
    echo "# Restores CachyOS's systemd/sd-encrypt hooks over omarchy_hooks.conf." |
        sudo tee /etc/mkinitcpio.conf.d/zz-omarchy-on-cachyos-hooks.conf > /dev/null
    echo "$CACHYOS_HOOKS_LINE" | sudo tee -a /etc/mkinitcpio.conf.d/zz-omarchy-on-cachyos-hooks.conf > /dev/null
    echo "Kept the CachyOS sd-encrypt initramfs hooks."
fi

# omarchy-settings changed the mkinitcpio hooks, the kernel command line and
# the UKI settings after the kernel's own build hook last ran. Rebuild every
# kernel's image and limine entry so the next boot uses them.
echo ""
echo "Rebuilding boot images..."
sudo limine-mkinitcpio

# --- user setup -----------------------------------------------------------------
# A user created by `useradd -m` after omarchy-settings is installed gets
# Omarchy's configs from /etc/skel. The CachyOS user predates it, so replay
# /etc/skel the same way (this is what omarchy-reinstall-configs does) after
# backing up anything it would overwrite.

if [ -f "$HOME/.local/state/omarchy/done/finalize-user" ]; then
    echo "Omarchy user setup already done for $LOGIN_USER, skipping."
    echo "To reset your configs to Omarchy's defaults later, run: omarchy-reinstall-configs"
else
    BACKUP_DIR="$HOME/.omarchy-on-cachyos-backup-$(date +%Y%m%d-%H%M%S)"
    (
        cd /etc/skel
        find . -mindepth 1 \( -type f -o -type l \) -print0 |
            while IFS= read -r -d '' file; do
                if [ -e "$HOME/$file" ] || [ -L "$HOME/$file" ]; then
                    mkdir -p "$BACKUP_DIR/$(dirname "$file")"
                    cp -a "$HOME/$file" "$BACKUP_DIR/$file"
                fi
            done
    )
    [ -d "$BACKUP_DIR" ] && echo "Backed up existing dotfiles to $BACKUP_DIR"
    cp -af /etc/skel/. "$HOME/"

    # A context other than "runtime" makes the theme step run headless (there
    # is no Hyprland session yet), and other than "iso-chroot" makes mise
    # fetch Node over the network instead of from the ISO's bundled tarball.
    # --first-install marks every shipped migration as applied for this user.
    echo ""
    echo "Running Omarchy user setup..."
    env OMARCHY_SETUP_CONTEXT=cachyos omarchy-provision-user --first-install
fi

# --- done -----------------------------------------------------------------------

echo ""
echo "Omarchy is installed on CachyOS."
echo ""
echo " - Kept: CachyOS repositories, mirrorlist, kernel (linux-cachyos boots first), chwd NVIDIA driver, tealdeer."
echo " - $AUTOLOGIN_NOTE"
echo " - Login shell is bash. Fish stays installed - run 'fish' to use it."
echo " - The CachyOS boot splash is kept. For Omarchy's, run: omarchy-refresh-plymouth"
echo " - Full log of this run: $INSTALL_LOG"
echo ""
echo "Keep Omarchy updated with:  omarchy update"
echo ""
echo "Do NOT run 'omarchy-channel-set' or 'omarchy-reinstall-pkgs'. Both run"
echo "omarchy-refresh-pacman, which overwrites /etc/pacman.conf and removes the"
echo "CachyOS repositories (a backup is left at /etc/pacman.conf.bak)."
echo ""
if confirm "Reboot now?"; then
    sudo systemctl reboot
fi
