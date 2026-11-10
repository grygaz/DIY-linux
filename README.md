# DIY Linux

**Language:** English | [Lietuvių](README.lt.md)

Build a small Linux system from source with a single Bash script: [`diy-linux.sh`](diy-linux.sh). The script downloads pinned sources, verifies SHA-256 checksums, builds a cross toolchain and root filesystem, and creates boot images. It does not use Buildroot.

Builder version: **1.1.210** (`bash diy-linux.sh --version`). The version is shown at startup and is incremented with every script update.

All build recipes are embedded in `diy-linux.sh`. You can copy that file elsewhere and run it on its own. No previous build files or development fixtures are required. Downloads, build directories, and toolchains are created when needed.

## Project principles

This project takes inspiration from the GNU free-software idea that people should be able to run, study, change, and share the software they use. In practice, the build choices and recipes are visible in the script, source archives are pinned and checked, and the menu and `--plan` explain constraints before a long build starts. The aim is to make the system understandable and modifiable, not to hide its construction behind a black box. See the [GNU explanation of free software](https://www.gnu.org/philosophy/free-sw.en.html).

Documentation is part of that work: the English and Lithuanian guides should describe the same commands, risks, and known limitations. This follows GNU's view that documentation is essential to users' freedom to understand and adapt a system ([why free software needs free documentation](https://www.gnu.org/philosophy/free-doc.html)). Source pins and SHA-256 checks make downloads match this script's recorded inputs; they do not by themselves prove upstream authorship, make builds bit-for-bit reproducible, or certify every component's license. Review upstream notices before redistributing an image. The [GNU Coding Standards](https://www.gnu.org/prep/standards/standards.html) also offer useful general guidance on clear, robust software; this project adopts no claim of GNU package status or full compliance. It is independent and is not an official GNU or FSF project.

The builder script and project documentation are licensed under the GNU General Public License, version 3 or (at your option) any later version (`GPL-3.0-or-later`). See [LICENSE](LICENSE). Downloaded components retain their own upstream licenses.

## Quick start

Run the script as your normal user on an x86_64 Linux host. Use a working directory without spaces.

```bash
bash diy-linux.sh --help
bash diy-linux.sh --plan
bash diy-linux.sh
```

The terminal menu lets you create a new system, resume an interrupted build, or maintain an existing system. Use arrow keys to navigate, Enter to open an item, and Space to toggle checkboxes. Help entries describe the choices and their limitations. Missing host dependencies, including `dialog`, can be installed through `sudo`.

Choose the username and enter a password in the menu before building. The default username is `user`; the user belongs to the `sudo` group. Root is locked unless you configure a root password. After booting, use `sudo -i` for administration.

## Interface language

The builder uses English by default, regardless of the host locale. Add `--LT` for Lithuanian; the flag can appear before or after another command:

```bash
./diy-linux.sh
./diy-linux.sh --LT
./diy-linux.sh --LT --help
./diy-linux.sh --plan --LT
```

Run these examples from the repository root. The language selection covers menus, descriptions, help, progress, and script error messages. Compiler and external program output retains its own language. Generated system helpers use the language chosen during configuration.

## Requirements

- An x86_64 Linux build host with Bash 4.4 or newer and internet access.
- Considerable free disk space and several hours for the first source build; requirements depend on selected packages.
- Enough RAM and swap for GCC. The script checks for at least 6 GiB of available RAM plus free swap before its GCC stages; this is a minimum check, not a guarantee.
- `sudo` for host dependency installation, chroot, and selected image operations. Do not run the entire build as root.

Automatic host dependency installation supports `apt-get`, `pacman`, and `dnf`. Install dependencies separately with:

```bash
bash diy-linux.sh --install-deps
```

Disable automatic installation when managing host dependencies yourself:

```bash
AUTO_INSTALL_DEPS=no bash diy-linux.sh --build
```

The script's `--help` lists manual Debian/Ubuntu dependencies and extra requirements for image formats, Fish, and desktop profiles. Check `--help` for host build dependencies required by the selected profile. The host package manager used to install build dependencies is independent of the package manager selected for the new system.

If GCC is killed with `Error 137`, inspect available memory and the host kernel log. The script can prepare temporary swap:

```bash
bash diy-linux.sh --prepare-swap 8
```

This creates an 8 GiB swap file in the working directory and enables it with `sudo`. It does not modify `/etc/fstab`. Existing non-swap files are not overwritten; Btrfs requires a separately prepared swap file. The command prints how to disable the swap afterwards.

## Build choices

| Setting | Choices | Notes |
| --- | --- | --- |
| `TARGET_ARCH` | `x86_64`, `i686`, `aarch64` | AMD64 and Intel64 both use `x86_64`. ARM64 targets QEMU virt/UEFI, not every ARM board. |
| `SHELL_CHOICE` | `bash`, `dash`, `zsh`, `fish`, `busybox` | The BusyBox choice uses ash. Zsh/Fish use dash for `/bin/sh`. |
| `TOOLS_CHOICE` | `gnu`, `busybox` | Selects base utilities independently of the interactive shell. |
| `INIT_CHOICE` | `openrc`, `busybox`, `sysvinit`, `runit`, `dinit`, `s6`, `systemd` | OpenRC works with GNU or BusyBox utilities; BusyBox profiles use BusyBox `getty` and `login` on local and serial consoles. Automatic login still requires GNU utilities. SysVinit, runit, Dinit, s6, and systemd require GNU utilities. Dinit 0.22.1 is a beta release; it also needs host m4 and the target C++ runtime. |
| `PACKAGE_MANAGER` | `none`, `apt`, `pacman` | APT includes dpkg. Both package manager recipes require GNU utilities. |
| `BOOT_CHOICE` | `bios`, `uefi`, `syslinux`, `lilo`, `refind`, `efistub`, `limine`, `systemd-boot`, `none` | `bios` and `uefi` select GRUB. LILO is legacy x86 BIOS and creates a raw IMG only; creating it uses sudo for a temporary loop device. |
| `DESKTOP_CHOICE` | `none`, `mate`, `lxde`, `fluxbox` | MATE, LXDE, and Fluxbox Xorg profiles are built from pinned source archives; supported combinations depend on architecture and userland. |
| `WITH_GCC` | `yes`, `no` | Include a native compiler in the final system. A cross compiler is built in either case. |
| `NETWORK` | `yes`, `no` | Enable DHCP networking. |
| `AUTOLOGIN` | `yes`, `no` | `no` by default. When enabled, automatically opens the configured `USER_NAME` account on local `tty1` without a password prompt. Requires GNU utilities; the serial console still requires login. Anyone with physical access can use the account, and `sudo` continues to ask for its password. |
| `DESKTOP_AUTOSTART` | `yes`, `no` | `no` by default; supports the selected desktop profile. Starts the desktop on local `tty1` after the selected user logs in. Combine with `AUTOLOGIN=yes` to skip the console password prompt too. Closing the desktop returns to the shell; it will not relaunch until the next reboot. |
| `PKG_NANO`, `PKG_WGET`, `PKG_PING`, `PKG_VIM`, `PKG_FDISK`, `PKG_GEANY`, `PKG_FIREFOX`, `PKG_PLUMA`, `PKG_CAJA`, `PKG_ENGRAMPA`, `PKG_MATE_CONTROL_CENTER`, `PKG_MATE_POWER_MANAGER` | `yes`, `no` | Xterm is the single terminal emulator included in MATE/Xorg profiles. The checklist filters other desktop apps by profile. MATE Control Center and Power Manager are available with systemd or another supported init. Non-systemd profiles build elogind; all profiles build Linux-PAM and enable PAM session tracking so Polkit can recognize the logged-in user. These options require GNU utilities (not BusyBox login) and add substantial compile time and ISO data. Control Center also needs Rust and Cargo for librsvg. |
| `PKG_NGINX`, `PKG_PHP` | `yes`, `no` | Optional for console and MATE profiles, independent of the desktop. Nginx serves `/srv/www/html` on port 80. PHP builds PHP-FPM with OpenSSL, zlib, XML, and SQLite support and uses a local Unix FastCGI socket; selecting PHP also enables Nginx. Services are enabled for the selected init. The sample `index.php` is a plain-text health check. Configure TLS certificates, firewall rules, and application-specific PHP extensions yourself. |

Neofetch and the welcome message are always included in new builds. Bash is also included to run Neofetch even when another login shell is selected. `PKG_NEOFETCH=no` does not disable this required component.

Other useful settings are `SYSTEM_NAME`, `USER_NAME`, `WORK_DIR`, `JOBS`, `AUTO_INSTALL_DEPS`, and `COLOR`. `JOBS` defaults to 1; the bootstrap GCC stages explicitly use one compilation job to reduce memory pressure. Use `COLOR=never` or `NO_COLOR=1` to disable colors.

See exact pinned package versions with:

```bash
bash diy-linux.sh --versions
```

Versions do not silently track upstream releases. Updating a package requires updating its source URL and checksum and checking the build recipe.

### Noninteractive build

Preview a configuration before building:

```bash
SHELL_CHOICE=bash TOOLS_CHOICE=gnu INIT_CHOICE=openrc \
  PACKAGE_MANAGER=none bash diy-linux.sh --plan
```

For `--build`, supply a SHA-512 crypt password hash so the regular user can log in. This example prompts locally for the password:

```bash
USER_PASSWORD_HASH="$(openssl passwd -6)" \
  USER_NAME=grygas SYSTEM_NAME=linmini \
  SHELL_CHOICE=bash TOOLS_CHOICE=gnu INIT_CHOICE=openrc \
  bash diy-linux.sh --build
```

Without a password hash the account remains locked. Password hashes are stored in saved build settings and the target `/etc/shadow`; do not publish those files or commit them to version control.

A small BusyBox configuration:

```bash
SHELL_CHOICE=busybox TOOLS_CHOICE=busybox INIT_CHOICE=busybox \
  bash diy-linux.sh --plan
```

Change `--plan` to `--build` and configure a user password when ready.

## Resume or create another system

```bash
bash diy-linux.sh --resume   # Continue saved work
bash diy-linux.sh --new      # Configure a separate new system
bash diy-linux.sh --edit     # Choose an existing system to maintain
bash diy-linux.sh --fresh    # Start over, including a new toolchain build
```

Completed stages are recorded in stamp files. Interrupted compilation can reuse existing objects when resumed. Compatible completed toolchains are reused automatically, except when explicitly starting fresh.

Successfully built package stages are also cached in `WORK_DIR/artifacts/`. A new compatible profile can install those compiled files without rebuilding them; changing init or bootloader does not by itself invalidate ordinary userland binaries. Cache keys include target architecture, the selected toolchain, pinned source checksums, the relevant build recipes, and stage-specific options. Unrelated script or documentation edits do not invalidate package artifacts. Remove this directory only when you intentionally want to rebuild cached stages.

The working directory deliberately keeps sources, build objects, logs, and reusable toolchains so a retry does not repeat completed work. The final ISO contains the live system, not the compiler's build tree, which is why it can be much smaller than the profile directory. Put `WORK_DIR` on a filesystem with ample free space, use `--resume` after failures, and use `--repack` after rootfs-only changes. Keep a profile until you no longer need to resume it or reuse its toolchain.

The live image keeps the base system in read-only `rootfs.squashfs`. At boot, the initramfs looks for a writable ext4 volume labelled `DIYDATA` and uses it for the overlay, so file changes and installed packages survive reboots. If no such volume is connected, it falls back to a RAM overlay and changes are temporary. The separate sparse `persistence.ext4` file (4 GiB by default) is created alongside each image set for QEMU and attached by the generated QEMU command; it is writable guest data and is not included in `SHA256SUMS`. For USB boot, add an ext4 partition labelled `DIYDATA` to the USB drive. This partition is unencrypted. The initramfs contains only early-boot tools; the desktop and ordinary applications stay in SquashFS.

Do not run two builds against the same profile or toolchain simultaneously. If a lock is occupied, inspect the reported process and stop the earlier build cleanly. Deleting the lock file does not safely release a lock held by a running process.

At startup, the progress table lists every planned build stage, including optional packages for the selected desktop. Waiting stages show `0%`; completed stages show `100%` and their own elapsed time in minutes and seconds. Only the active row changes during a stage. If the list exceeds the terminal height, the live view follows the page containing the active stage; the complete final table remains in terminal scrollback. Terminal resizing redraws the table without changing stage states. Use Up/Down to scroll by one stage, Page Up/Page Down or Left/Right to change pages, Home/End to jump, and F to follow the active stage again. Keyboard echo is disabled while the table is open; terminal settings are restored when it closes, including on errors and Ctrl+C. While a stage runs, its row shows a moving activity marker and `--%`: make does not provide a reliable percentage for the complete stage. Full compiler output is written to the profile's `build.log`; only errors are shown on failure. The header also shows total elapsed time for the current run and an approximate remaining time (ETA). Successful stage durations are saved to `stage-times.tsv` in the working directory and reused for matching architecture, package/init/shell choices and parallelism. `ETA: learning` means no usable history yet; `~20m + ?` estimates known stages while some durations remain unknown. An overrun is marked unknown rather than reporting zero before completion. Cached/skipped, failed and interrupted stages do not train the estimate. Hours are shown when needed; `--resume` starts a new elapsed timer and retains the history.

## Build only the toolchain

```bash
bash diy-linux.sh --toolchain
TARGET_ARCH=aarch64 bash diy-linux.sh --toolchain
```

This builds binutils, initial GCC, glibc, and final GCC without creating a system or ISO. Repeating the command resumes completed toolchain stages. Toolchains are stored under `WORK_DIR/toolchains/` and have their own `build.log` and `sdk-env.sh`.

After building a system, use its profile-specific SDK environment to compile additional software for that rootfs:

```bash
source /absolute/path/to/profile/sdk-env.sh
./configure --host=x86_64-diy-linux-gnu --prefix=/usr
make
make DESTDIR="$DIY_ROOT" install
```

Use the target triplet appropriate to your architecture. The standalone toolchain's environment points at its SDK sysroot; the system profile's environment points at that system's rootfs. Do not move toolchain directories: their compiler configuration references the original paths.

## Enter and modify an existing system

```bash
bash diy-linux.sh --chroot
# Equivalent:
bash diy-linux.sh --enter
```

If several systems exist, select one from the menu. You can also pass an explicit profile directory:

```bash
bash diy-linux.sh --chroot /absolute/path/to/profile
```

Changes made inside chroot remain in that profile's `rootfs`. Use `exit` to return to the host. Chroot shares the host kernel, CPU information, and uptime; a newly created rootfs does not have its own running kernel. Running another architecture requires working `qemu-user` binfmt registration.

APT and pacman are optional tools, not a connection to an automatically compatible distribution repository. Supply your own compatible packages and repositories. The source-built base files are not registered in their package databases.

If native GCC was included, you can also compile inside the system. Additional packages may still need headers and build dependencies that are not included in the minimal image.

## Create or refresh images

After leaving chroot, package the changed system separately:

```bash
bash diy-linux.sh --iso
bash diy-linux.sh --img
bash diy-linux.sh --repack
```

These commands select an existing system when no directory is provided. Specify a profile to avoid the picker:

```bash
bash diy-linux.sh --iso /absolute/path/to/profile
```

`--iso` requests an ISO, `--img` requests a raw image, and `--repack` uses the profile's configured boot format. The bootloader determines which formats are available. IMG may contain a hybrid ISO or an EFI FAT image; it is not necessarily an installed persistent system. LILO is the exception: it creates a bootable DOS-partitioned ext2 disk image only (no ISO) and asks for sudo to attach a loop device backed by that image file.

The generated QEMU command attaches `persistence.ext4` automatically and writes serial boot output to `images/qemu-boot.log` (overwritten each launch). The log includes bootloader output where serial output is enabled and the Linux kernel/initramfs messages; it does not capture the graphical display or necessarily the firmware's own messages. Keep `persistence.ext4` next to the image set and use the generated command on every launch. For a USB stick, create an empty ext4 partition on the stick with the label `DIYDATA` using a partition editor. Formatting a partition erases it; select only an empty partition you created for this purpose. The live system finds it at startup and reuses its `upper`/`work` directories. If the volume is missing or cannot be mounted, the system boots with temporary RAM changes instead.
