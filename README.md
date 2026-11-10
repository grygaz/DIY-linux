# DIY Linux Builder

**DIY Linux Builder** is a single Bash script for experimenting with a small Linux system assembled from source. It is intended for Linux enthusiasts who want to learn how a toolchain, libc, userland, init system, kernel, bootloader, and desktop fit together.

> **Beta software.** This is an educational and experimental project, not a production distribution or a dependable installer. Build profiles and hardware support are not all tested. Expect failures, long build times, missing features, and manual troubleshooting.

## What it can configure

The interactive terminal menu and command-line settings can select:

- **CPU architecture:** x86_64, i686, and AArch64.
- **Shell:** BusyBox ash, Bash, dash, zsh, or fish, subject to profile validation.
- **System tools:** BusyBox or GNU userland.
- **Init:** BusyBox init, OpenRC, runit, dinit, SysVinit, s6, or systemd.
- **Desktop:** MATE, LXDE, Fluxbox, or a console-only system. Current graphical profiles target x86_64 with GNU tools; individual combinations still need validation.
- **Boot and output:** GRUB-based BIOS/UEFI choices and other bootloader profiles where supported by the selected architecture; ISO, disk image, or root filesystem output depending on the profile.
- **Optional components:** APT/dpkg or pacman integration, native GCC, OpenSSH, Firefox, text editors, networking utilities, and an optional Nginx/PHP-FPM web stack.

The script builds a cross-toolchain and target system from pinned source archives. It keeps build logs, can resume an interrupted build, reuses cached downloads and build artifacts when their keys match, and offers a source-update command. These features do not mean every resulting combination has been boot-tested.

## Why try it

- Learn the stages involved in building a Linux system from source.
- Choose and compare core components instead of accepting one fixed distribution profile.
- Inspect build stages and logs, resume interrupted work, and experiment in QEMU.
- Keep the build recipe in one script without relying on Buildroot.

## Trade-offs and limitations

- A full build can take hours and requires substantial free disk space, RAM, swap, and a reliable network connection.
- The many possible combinations exceed the project's practical test coverage. A configuration passing validation is not proof that it boots or that every device works.
- Desktop, Wi-Fi, audio, power-management, and bootloader behavior can vary with the machine and firmware. Verify the exact profile in a VM before using it on hardware.
- APT and pacman need a compatible package repository; this project does not provide a maintained binary repository or a complete distro-style update service.
- Downloaded upstream sources and build dependencies can change. Review source pins, checksums/signatures, and build logs before relying on an image.
- Disk installation can erase or repartition storage. Back up important data and carefully verify the target disk before confirming any installer action.

## Requirements

Use a recent Linux host with Bash 4.4 or newer, internet access, a C/C++ build toolchain, and the utilities listed by `--help`. The script can install missing host packages on supported systems when automatic dependency installation is enabled. A desktop build needs much more time and disk space than a console-only build. QEMU is recommended for first-boot checks.

## Quick start

```bash
chmod +x diy-linux.sh
./diy-linux.sh --help
./diy-linux.sh --plan
./diy-linux.sh
```

The interactive menu is the recommended way to choose a profile. For a non-interactive preview:

```bash
TARGET_ARCH=x86_64 \
SHELL_CHOICE=bash \
TOOLS_CHOICE=gnu \
INIT_CHOICE=openrc \
DESKTOP_CHOICE=none \
PACKAGE_MANAGER=none \
BOOT_CHOICE=uefi \
JOBS=4 \
./diy-linux.sh --plan
```

Then start a build from the same settings by using the menu or `--build`. Use `--resume` to continue the saved unfinished build with its original settings. See `--help` for swap preparation, chroot, image repacking, QEMU, and source-update commands.

## Project status and contributions

The builder is for experimentation and learning. Bug reports are most useful when they include the exact script version, selected settings, host details, the failing stage, and the relevant part of `build.log` or `qemu-boot.log`. Do not attach passwords, private keys, personal files, or unrelated desktop screenshots.

**Version in this snapshot:** `1.1.210`.

**License:** GNU General Public License v3.0 or later (`GPL-3.0-or-later`); see [LICENSE](LICENSE).
