# omarchy-on-cachyos

- UPDATE 9-October-2026: The installer now installs Omarchy 4.x directly from its pacman packages. The old route (clone Omarchy 3.8.4, patch its `install.sh`, then upgrade to 4.x) is gone: its package list no longer installs cleanly on current CachyOS.
- UPDATE 20-May-2026: The install script now includes interactive version selection for choosing between Stable releases and Bleeding Edge.
- UPDATE 1-October-2025: The install script has been updated to support Omarchy 3.0+ out of the box.

## 1. Introduction

This project installs DHH's Omarchy on top of CachyOS, so you get Omarchy's desktop with CachyOS's kernel, optimized repositories, and hardware detection. Omarchy is an 'opinionated' desktop setup, based on Hyprland, that emphasizes simplicity and productivity, while CachyOS offers a performance-optimized Arch Linux distribution.

## 2. How It Works

Since 4.x, Omarchy ships as two pacman packages, `omarchy` and `omarchy-settings`, from its own repository. The Omarchy ISO installs those packages and then runs two setup commands that come with them: `omarchy-apply-system` (root-side setup: services, hardware quirks, SDDM) and `omarchy-provision-user` (per-user setup: theme, git, mise, keyring).

This script does the same on CachyOS:

  1) Adds the Omarchy repository and signing key next to the CachyOS repositories
  2) Installs `omarchy`, `omarchy-settings` and Omarchy's default package set
  3) Runs `omarchy-apply-system`, with the steps that would undo CachyOS taken out
  4) Copies Omarchy's default configs into your home directory (backing up anything it replaces) and runs `omarchy-provision-user`
  5) Keeps `linux-cachyos` as the default boot entry and rebuilds the boot images

It shows every package it is about to replace before replacing it, prints all output to the screen, and keeps a full copy in `~/omarchy-on-cachyos-install.log`.

This script does not:

 1) Install CachyOS or any other Linux operating system
 2) Partition, format, or encrypt hard disks
 3) Install a boot loader (it requires the Limine boot loader CachyOS installs by default)

## 3. What Is Kept From CachyOS

The philosophy is to change as little as possible of either system. Where CachyOS and Omarchy conflict, the script chooses:

1. Repositories: CachyOS's `pacman.conf` and mirrorlist are kept. Omarchy's installer normally copies its own over them, which would remove the CachyOS repositories; that step is skipped. Only an `[omarchy]` section is added.

2. Kernel: `linux-cachyos` stays the first boot entry. Omarchy prefers its own `linux-omarchy` kernel, and one of its migrations installs it and moves it to the top of the boot menu. The script pins `BOOT_ORDER` in `/etc/default/limine` to `linux-cachyos` and marks that migration as done.

3. NVIDIA: Omarchy's `nvidia.sh` is replaced by `bin/nvidia.sh`, which keeps whatever driver CachyOS's `chwd` installed (and runs `chwd -a` only if there is none). Omarchy's own script installs a DKMS driver that conflicts with the CachyOS prebuilt modules.

4. TLDR: CachyOS's Tealdeer is kept and Omarchy's `tldr` is not installed. They conflict, and `cachyos-fish-config` depends on Tealdeer.

5. Conflicting packages: Any other installed package that conflicts with Omarchy's defaults (for example `jack2` → `pipewire-jack`, `tuned-cachy-ppd` → `power-profiles-daemon`) is listed first and replaced only after you confirm. The old 3.x installer stopped here with an unexplained error, because `pacman --noconfirm` answers "no" to every conflict question.

6. Shell: CachyOS uses Fish by default, Omarchy uses Bash. The script switches your login shell to Bash so Omarchy's shell config is actually loaded. Fish stays installed; run `fish` to use it.

7. Login: SDDM is set up the way the Omarchy ISO does it. On an encrypted disk you log in automatically after entering the LUKS passphrase; on an unencrypted disk SDDM asks for your password. CachyOS's `/etc/sddm.conf` is removed so it does not override Omarchy's settings.

8. Encrypted disks: Omarchy replaces the initramfs hooks with a busybox-based set (`encrypt`). If your CachyOS disk is unlocked with the systemd `sd-encrypt` hook, the script keeps the CachyOS hooks, because Omarchy's would leave the system unable to unlock the disk.

9. Boot splash: The CachyOS Plymouth theme is kept. Run `omarchy-refresh-plymouth` to switch to Omarchy's.

10. Qt 6.12: CachyOS ships Qt 6.12 before Omarchy's stable channel does. Qt 6.12 adds its own `Color` type, which hides the palette the Omarchy shell uses, so the shell runs but shows no bar and no launcher (the journal shows `Cannot read property 'background' of undefined`). `bin/fix-omarchy-shell-qt612.sh` applies Omarchy's upstream fix (commit b83d3df0) to the installed shell, and a pacman hook re-applies it after each `omarchy` upgrade until a release includes it. Once one does, the script finds nothing to change.

## 4. Pre-Requisites

IMPORTANT: This script does not install CachyOS. You must do that separately (and first). For information on installing CachyOS, please refer to https://www.cachyos.org. Use these choices:

1. File System: BTRFS (the CachyOS default). Omarchy's snapshots and snapshot boot entries require it; the script stops if `/` is not BTRFS.

2. Boot Loader: Limine (the CachyOS default). The `omarchy` package depends on Limine; the script stops if CachyOS uses GRUB or systemd-boot.

3. Shell: Either Fish (the CachyOS default) or Bash works.

4. Desktop Environment: Install a minimal system with no desktop environment, or the CachyOS Hyprland desktop. Do not install GNOME or KDE.

5. Graphics Drivers for NVIDIA users: Let CachyOS install its recommended driver. The script keeps it.

   For NVIDIA hardware video acceleration in browsers:

   **Important:** 

   To enable hardware video decode via NVDEC in chromium, you must:
   
   1. Add the following to `~/.config/chromium-flags.conf`:       ```       --enable-features=VaapiOnNvidiaGPUs       ```
   2. Install the [enhanced-h264ify extension](https://chromewebstore.google.com/detail/enhanced-h264ify/omkfmpieigblcllmkgbflkikinpkodlk) and disable **VP8** and **AV1** codecs.
   
   
   
   To fully enable hardware acceleration in Firefox, you must 
   
   1. Install the [enhanced-h264ify add-on](https://addons.mozilla.org/en-US/firefox/addon/enhanced-h264ify/) and disable **VP8** and **AV1** codecs and manually add the following overrides to your `user.js`:
   
   ```js
   // FORCE NVIDIA HARDWARE ACCELERATION
   user_pref("media.hardware-video-decoding.force-enabled", true);
   user_pref("media.hardware-video-encoding.force-enabled", true);
   user_pref("layers.acceleration.force-enabled", true);
   user_pref("webgl.force-enabled", true);
   user_pref("media.ffmpeg.vaapi.enabled", true);
   user_pref("media.rdd-ffmpeg.enabled", true);
   user_pref("media.av1.enabled", true);
   user_pref("widget.dmabuf.force-enabled", true);
   user_pref("gfx.x11-egl.force-enabled", true);
   ```


Other configuration changes are up to you. Note, however, that this script has not been extensively tested on CachyOS installations other than the author's own machine.

## 5. Installation Instructions

```bash
# Clone the repository
git clone https://github.com/Sothcheat/omarchy-on-cachyos.git

# Navigate to the project directory
cd omarchy-on-cachyos/bin

# Run the installation script as your normal user (not root)
./install-omarchy-on-cachyos.sh
```

**Note:** Please review the script contents before running to understand what changes will be made to your system.

### After installing

- Update with `omarchy update`. It updates CachyOS and Omarchy packages together and runs Omarchy's migrations.
- Do NOT run `omarchy-channel-set` or `omarchy-reinstall-pkgs`. Both run `omarchy-refresh-pacman`, which overwrites `/etc/pacman.conf` with Omarchy's and removes the CachyOS repositories (it leaves a backup at `/etc/pacman.conf.bak`).
- If something fails, the full output is in `~/omarchy-on-cachyos-install.log`. The script is safe to re-run.
- Installed with an earlier version of this script and the bar and launcher are missing? Pull this repo and run `bin/fix-omarchy-shell-qt612.sh --install-hook`, then `omarchy-restart-shell`.

### Already on Omarchy 3.x from the old version of this script?

You do not need this script. Upgrade in place with Omarchy's own tools: run `omarchy-branch-set master` and `omarchy-update` (this brings you to 3.8.5), then `omarchy-upgrade-to-quattro` if the update did not already move you to 4.x. Note that the converter replaces `/etc/pacman.d/mirrorlist` (the Arch mirrors) with Omarchy's own mirror and saves a backup next to it; the CachyOS repositories, which use their own mirrorlists, are not touched.

## 6. Statement of Lack of Warranty

THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Use this script at your own risk. Always backup your system and important data before running installation scripts.

## 7. How to Contribute

We welcome contributions to improve this project! Here's how you can help:

1. **Fork the Repository**: Click the "Fork" button on GitHub to create your own copy
2. **Create a Feature Branch**: `git checkout -b feature/your-feature-name`
3. **Make Your Changes**: Implement your improvements or fixes
4. **Commit Your Changes**: `git commit -m "Add descriptive commit message"`
5. **Push to Your Fork**: `git push origin feature/your-feature-name`
6. **Open a Pull Request**: Submit a PR with a clear description of your changes

### Contribution Guidelines
- Test your changes thoroughly on CachyOS before submitting
- Follow existing code style and conventions
- Update documentation if adding new features
- Report bugs using GitHub Issues 
