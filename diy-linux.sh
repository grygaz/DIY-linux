#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# DIY GNU/Linux from source - one standalone script, x86_64 / i686 / ARM64.
#
# Usage: English by default; add --LT for Lithuanian.
#   bash diy-linux.sh                 # interaktyvus meniu
#   bash diy-linux.sh --plan          # parodyti numatytą planą, nieko nekurti
#   bash diy-linux.sh --build         # kurti pagal aplinkos kintamuosius
#   bash diy-linux.sh --self-test     # vidinės patikros, be atsisiuntimų
#   bash diy-linux.sh --help          # priklausomybės ir pavyzdžiai
#
# Iš originalaus pavyzdžio išlaikyta eiga: kompiliatorius → glibc → programos
# → init → branduolys → GRUB → archyvas. Visi receptai pateikti šiame faile.
# Pavyzdys: https://github.com/adityatelange/diy-build-custom-minimal-linux-distribution-source
# Kūrimas nevykdomas chroot; kryžminis kompiliatorius naudoja atskirą sysroot.
# Niekada nekeičiamas šeimininko /bin/sh ir niekada neįdiegiama į jo /usr.
# Visas kompiliavimas ir paleidimas dar nepatvirtinti. --self-test nėra boot testas.

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf '%s\n' 'Bash 4.4 or newer is required.' >&2
    exit 2
fi
set -Eeuo pipefail
DIY_VERSION=1.1.210
# Inline translation: English first, Lithuanian second. No external catalog required.
tr_text() {
    if [ "${DIY_LANG:-en}" = lt ]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}
# --LT may appear before or after any command. Parse it before validation.
DIY_LANG=en
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    language_args=()
    for language_arg in "$@"; do
        case "$language_arg" in
            --LT) DIY_LANG=lt ;;
            *) language_args+=("$language_arg") ;;
        esac
    done
    set -- "${language_args[@]}"
    unset language_args language_arg
fi
export DIY_LANG
shopt -s inherit_errexit
umask 022
# Spalvos automatinės TTY terminale; NO_COLOR=1 arba COLOR=never jas išjungia.
C_RESET='' C_INFO='' C_OK='' C_ERROR=''
if [[ ${COLOR:-auto} == always || ( ${COLOR:-auto} != never && -z ${NO_COLOR:-} && -t 1 && ${TERM:-dumb} != dumb ) ]]; then
    C_RESET=$'\033[0m'; C_INFO=$'\033[1;36m'; C_OK=$'\033[1;32m'; C_ERROR=$'\033[1;31m'
fi
error_report() {
    local status=$1 line=$2 command=$3 log oom=no
    trap - ERR
    # Restore the normal terminal before printing; otherwise the diagnostic is
    # erased when the alternate progress screen is closed. Never stop the UI
    # from an inherited ERR trap in a run_quiet child shell.
    if [[ ${UI_ACTIVE:-no} == yes && $BASHPID == $$ ]]; then progress_stop; fi
    printf "$(tr_text "\\nError at line %s: %s\\n" "\\nKlaida ties %s eilute: %s\\n")" "$line" "$command" >&2
    printf "$(tr_text "Resume with the same script and settings. JOBS=1 reduces memory use.\\n" "Tęsk tuo pačiu scenarijumi ir pasirinkimais. JOBS=1 mažina RAM apkrovą.\\n")" >&2
    local -a candidate_logs=()
    [[ -z ${BASE:-} ]] || candidate_logs+=("$BASE/build.log")
    [[ -z ${SDK:-} || ${SDK:-} == "${BASE:-}" ]] || candidate_logs+=("$SDK/build.log")
    for log in "${candidate_logs[@]}"; do
        [[ -f "$log" ]] || continue
        if memory_failure_in_log "$log"; then oom=yes; break; fi
    done
    if [[ "$oom" == yes || "$status" == 137 ]]; then
        suggest_swap_command >&2
    fi
    return "$status"
}
trap 'error_report "$?" "$LINENO" "$BASH_COMMAND"' ERR

memory_failure_in_log() {
    [[ -f "$1" ]] && tail -n 300 "$1" | grep -Eiq 'error 137|(^|[[:space:]])killed([[:space:]]|$)|out of memory|cannot allocate memory|virtual memory exhausted|cc1[^[:space:]]*: fatal error: Killed'
}

suggest_swap_command() {
    printf "$(tr_text "\\nThe compiler appears to have run out of memory. Add 8 GiB swap with this command, then resume the same build:\\n" "\\nPanašu, kad kompiliatoriui pritrūko atminties. Pridėk 8 GiB swap šia komanda, tada tęsk tą patį kūrimą:\\n")"
    printf 'WORK_DIR=%q bash %q --prepare-swap 8\n' "${WORK_DIR:-$PWD/diy-linux-work}" "${BASH_SOURCE[0]}"
}

# 1. Pasirinkimai. Juos galima nustatyti meniu arba aplinkos kintamaisiais.
TARGET_ARCH=${TARGET_ARCH:-x86_64}        # x86_64 (AMD64 / Intel64) | i686 (x86) | aarch64 (ARM64)
# Keep the configuration value inside this shell.  GNU make's built-in LINK.o
# appends the environment variable TARGET_ARCH as an input filename; glibc's
# relocatable link then tries to open e.g. "x86_64" and fails.
export -n TARGET_ARCH
SHELL_CHOICE=${SHELL_CHOICE:-bash}       # busybox | bash | dash | zsh | fish
TOOLS_CHOICE=${TOOLS_CHOICE:-gnu}        # busybox | gnu
INIT_CHOICE=${INIT_CHOICE:-openrc}       # busybox | openrc | runit | dinit | sysvinit | s6 | systemd
DESKTOP_CHOICE=${DESKTOP_CHOICE:-none}    # none | mate | lxde | fluxbox (Xorg)
PACKAGE_MANAGER=${PACKAGE_MANAGER:-none} # none | apt (su dpkg) | pacman
WITH_GCC=${WITH_GCC:-no}                 # GCC galutinėje sistemoje: yes | no
BOOT_CHOICE=${BOOT_CHOICE:-bios}         # bios | uefi | none (tik archyvai)
NETWORK=${NETWORK:-yes}                 # DHCP: yes | no
AUTOLOGIN=${AUTOLOGIN:-no}               # Skip tty1 password prompt: yes | no
DESKTOP_AUTOSTART_WAS_SET=${DESKTOP_AUTOSTART+x}
if [[ -n "$DESKTOP_AUTOSTART_WAS_SET" ]]; then
    DESKTOP_AUTOSTART=${DESKTOP_AUTOSTART:-no}
else
    DESKTOP_AUTOSTART=no
fi # Start selected Xorg desktop after tty1 login only when explicitly enabled.
KEEP_ROOTFS_TAR=${KEEP_ROOTFS_TAR:-no}   # Optional exportable rootfs.tar.gz artifact.
AUTO_INSTALL_DEPS=${AUTO_INSTALL_DEPS:-yes} # Trūkstami šeimininko paketai: yes | no
JOBS_WAS_EXPLICIT=${JOBS+x}
maximum_build_jobs() {
    local cpus
    cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')
    [[ "$cpus" =~ ^[1-9][0-9]*$ ]] || cpus=1
    printf '%s' "$cpus"
}
recommended_memory_jobs() {
    local cpus mem_kib jobs memory_field=${1:-MemTotal}
    cpus=$(maximum_build_jobs)
    mem_kib=$(awk -v field="$memory_field" '$1 == field ":" { print $2; exit }' /proc/meminfo 2>/dev/null)
    [[ "$mem_kib" =~ ^[0-9]+$ ]] || mem_kib=0
    jobs=$((mem_kib / 2097152))
    (( jobs < 1 )) && jobs=1
    (( jobs > cpus )) && jobs=$cpus
    printf '%s' "$jobs"
}
default_build_jobs() {
    local cpus jobs
    cpus=$(maximum_build_jobs)
    # Default to 80% of online CPU parallelism, rounded to the nearest job.
    # The GCC bootstrap stages are still explicitly pinned to one job below.
    jobs=$(((cpus * 80 + 50) / 100))
    (( jobs < 1 )) && jobs=1
    (( jobs > cpus )) && jobs=$cpus
    printf '%s' "$jobs"
}
JOBS=${JOBS:-$(default_build_jobs)}
SQUASH_JOBS=${SQUASH_JOBS:-}           # Atskirai galima paspartinti SquashFS pakavimą.
SYSTEM_NAME=${SYSTEM_NAME:-diy-linux}
OS_NAME=${OS_NAME:-DIY Linux}
WORK_DIR_FROM_ENV=${WORK_DIR+x}
WORK_DIR=${WORK_DIR:-"$PWD/diy-linux-work"}
DEFAULT_WORK_DIR=$WORK_DIR
ROOT_PASSWORD_HASH=${ROOT_PASSWORD_HASH:-!}  # ! = užrakinta root paskyra
USER_NAME=${USER_NAME:-user}              # Paprastas vartotojas su sudo teisėmis
USER_PASSWORD_HASH=${USER_PASSWORD_HASH:-$ROOT_PASSWORD_HASH}


# Papildomos programos: yes įtraukia, no praleidžia.
PKG_NANO=${PKG_NANO:-yes}
PKG_WGET=${PKG_WGET:-yes}
PKG_PING=${PKG_PING:-yes}
PKG_NEOFETCH=yes # Welcome ir Neofetch visada įtraukiami į naujus kūrimus.
PKG_VIM=${PKG_VIM:-no}
PKG_FDISK=${PKG_FDISK:-yes}
PKG_GEANY=${PKG_GEANY:-no}       # Native Linux editor; Notepad++ alternative.
PKG_FIREFOX=${PKG_FIREFOX:-no}   # Official Mozilla x86_64 binary archive.
PKG_PLUMA=${PKG_PLUMA:-no}       # MATE text editor.
PKG_ENGRAMPA=${PKG_ENGRAMPA:-no} # MATE archive manager.
PKG_CAJA=${PKG_CAJA:-no}
PKG_EOM=${PKG_EOM:-no}             # Eye of MATE image viewer.
PKG_MATE_CONTROL_CENTER=${PKG_MATE_CONTROL_CENTER:-no} # MATE settings panel; Polkit / UDisks2.
PKG_MATE_POWER_MANAGER=${PKG_MATE_POWER_MANAGER:-no}   # MATE power policy daemon; UPower.
PKG_NGINX=${PKG_NGINX:-no}             # Nginx HTTP server.
PKG_PHP=${PKG_PHP:-no}                 # PHP-FPM FastCGI runtime; requires Nginx.
PKG_OPENSSH=${PKG_OPENSSH:-no}         # OpenSSH client and sshd server, enabled at boot.

# 2. Pinned source versions and SHA-256 checksums; fetch verifies every archive.
# Atsisiunčiami tik pasirinkimui reikalingi paketai. Versijos nekeičiasi tyliai.
# Atnaujinant paketą reikia atnaujinti ir URL, ir SHA-256, ir patikrinti receptą.
declare -A VERSION URL SHA
VERSION[sysvinit]='3.18'; URL[sysvinit]='https://codeberg.org/thejessesmith/sysvinit/releases/download/3.18/sysvinit-3.18.tar.xz'; SHA[sysvinit]='793d7427e219f1ccf122e7c55655cef5f3419adc620ec2ee0ed557e8c94b438f'
VERSION[runit]='2.3.1'; URL[runit]='https://www.smarden.org/runit/runit-2.3.1.tar.gz'; SHA[runit]='634f23c8c4d1d440043be0fe928ddf904626289e97bfe7c5826e93aaf2cc6fe9'
VERSION[dinit]='0.22.1'; URL[dinit]='https://codeload.github.com/davmac314/dinit/tar.gz/refs/tags/v0.22.1'; SHA[dinit]='8907d4f668259c4f66d9d2c7cbbb55d455c28dc433596ab29005d589cb572e1e'
VERSION[skalibs]='2.16.0.0'; URL[skalibs]='https://skarnet.org/software/skalibs/skalibs-2.16.0.0.tar.gz'; SHA[skalibs]='90a3deda94a40d7d6a4495fe6feaf91c0185e0428d59cbd150a1a468741269aa'
VERSION[execline]='2.10.0.0'; URL[execline]='https://skarnet.org/software/execline/execline-2.10.0.0.tar.gz'; SHA[execline]='561be2ce578604644e2263a889bbdf4736e7980401ee88556a7f9017c166dbab'
VERSION[s6]='2.15.1.1'; URL[s6]='https://skarnet.org/software/s6/s6-2.15.1.1.tar.gz'; SHA[s6]='62080839eb5b04d51efd4ef6e7b43e29b5d0576efce9eb319ace32ea90c05931'
VERSION[s6-rc]='0.8.0.2'; URL[s6-rc]='https://skarnet.org/software/s6-rc/s6-rc-0.8.0.2.tar.gz'; SHA[s6-rc]='2fc0fcfe1e74b404b132a978eb316668c8bcdbc1104b3b0fe702a3d2d76caef5'
VERSION[s6-linux-init]='1.2.0.2'; URL[s6-linux-init]='https://skarnet.org/software/s6-linux-init/s6-linux-init-1.2.0.2.tar.gz'; SHA[s6-linux-init]='6fad014da162c0c81924197c57d16e1a75c133b34a20e423431a1b741e907b1d'
VERSION[syslinux]='6.03'; URL[syslinux]='https://www.kernel.org/pub/linux/utils/boot/syslinux/syslinux-6.03.tar.xz'; SHA[syslinux]='26d3986d2bea109d5dc0e4f8c4822a459276cf021125e8c9f23c3cca5d8c850e'
VERSION[lilo]='24.2'; URL[lilo]='https://archive.debian.org/debian/pool/main/l/lilo/lilo_24.2.orig.tar.gz'; SHA[lilo]='e158f19de4560c935ebe0507c21b79bff17618b9230d8076fe8c5fff9fdbd5b1'
VERSION[linux86]='0.16.21'; URL[linux86]='https://deb.debian.org/debian/pool/main/l/linux86/linux86_0.16.21.orig.tar.gz'; SHA[linux86]='49c7ee9102d45c2eef072bfb8a49ba3821c9fe3ef31ccd3290f658b667b579a8'
VERSION[limine]='12.9.6'; URL[limine]='https://github.com/Limine-Bootloader/Limine/releases/download/v12.9.6/limine-binary.tar.gz'; SHA[limine]='b38aabb042b0c0f9f562b7741be3c1204838d7bbacfa78bb411c674bd5b984ee'
VERSION[refind]='0.14.2'; URL[refind]='https://downloads.sourceforge.net/project/refind/0.14.2/refind-bin-0.14.2.zip'; SHA[refind]='410c7828c4fec2f2179bd956073522415831d27c00416381b8f71153c190a311'
# systemd-boot nepriklauso nuo pasirinkto init. EFI failas iš užfiksuoto Debian paketo.
VERSION[sdboot-arm64]='262-1'; URL[sdboot-arm64]='https://snapshot.debian.org/file/2883e8b91443f3a45da0c3236755b1aff0a0ee66'; SHA[sdboot-arm64]='9360e840139837b16eb3912e61896a611b3913087286f8e4dad673976392a73e'
VERSION[sdboot]='262-1'; URL[sdboot]='https://snapshot.debian.org/file/c9b33ba00301e962144089ebcf7cb30dc610ff63'; SHA[sdboot]='315ae06945f96544d07e5a68cfd5827f6ab452edf80e81cce2309c6e3452c1af'
VERSION[e2fsprogs]='1.47.4'; URL[e2fsprogs]='https://www.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v1.47.4/e2fsprogs-1.47.4.tar.xz'; SHA[e2fsprogs]='fd5bf388cbdbe006a3d3b318d983b2948382440acc85a87f1e7d108653e8db0b'
VERSION[btrfs-progs]='7.1'; URL[btrfs-progs]='https://www.kernel.org/pub/linux/kernel/people/kdave/btrfs-progs/btrfs-progs-v7.1.tar.xz'; SHA[btrfs-progs]='d1f55cc2971398c9142eaa79d203e63d586a3b4b867f956664a1d68322cd4e34'
VERSION[dosfstools]='4.2'; URL[dosfstools]='https://github.com/dosfstools/dosfstools/releases/download/v4.2/dosfstools-4.2.tar.gz'; SHA[dosfstools]='64926eebf90092dca21b14259a5301b7b98e7b1943e8a201c7d726084809b527'
VERSION[exfatprogs]='1.4.4'; URL[exfatprogs]='https://github.com/exfatprogs/exfatprogs/releases/download/1.4.4/exfatprogs-1.4.4.tar.xz'; SHA[exfatprogs]='102bbdfd934776c12c6d83743a31ec648f8c2f1ddfa1832b6e13b6efd09412cb'
VERSION[ntfs-3g]='2026.9.28'; URL[ntfs-3g]='https://codeload.github.com/tuxera/ntfs-3g/tar.gz/refs/tags/2026.9.28'; SHA[ntfs-3g]='8a75293f07bf40df5701d296de32a4cb0e46d6ae135abb4f41b438df9868a390'
VERSION[dialog]='1.3-20260721'; URL[dialog]='https://invisible-mirror.net/archives/dialog/dialog-1.3-20260721.tgz'; SHA[dialog]='62bdf59057d4f760a1cc2217827f07887b4a3eebf694c25eacd4803d2171cdc6'
VERSION[neofetch]='7.1.0'; URL[neofetch]='https://codeload.github.com/dylanaraps/neofetch/tar.gz/refs/tags/7.1.0'; SHA[neofetch]='58a95e6b714e41efc804eca389a223309169b2def35e57fa934482a6b47c27e7'
VERSION[zsh]='5.9.2'; URL[zsh]='https://www.zsh.org/pub/zsh-5.9.2.tar.xz'; SHA[zsh]='36fa734374b44783582cec09bcd67822e2f992c779ec1624ab5596df078d2f81'
VERSION[fish]='4.9.3'; URL[fish]='https://github.com/fish-shell/fish-shell/releases/download/4.9.3/fish-4.9.3.tar.xz'; SHA[fish]='20998a25f73217ddcc19f499055fd587e9912d1ad6e7109120fbcf2871f0b98c'
VERSION[bubblewrap]='0.13.1'; URL[bubblewrap]='https://github.com/containers/bubblewrap/releases/download/v0.13.1/bubblewrap-0.13.1.tar.xz'; SHA[bubblewrap]='0e85c8702248b8dd64144f594147553650cdd0e4c951690345faace79c217c4d'
VERSION[vim]='9.2.1172'; URL[vim]='https://codeload.github.com/vim/vim/tar.gz/refs/tags/v9.2.1172'; SHA[vim]='d4f7a793d2cf80ad6bb09085746515979d049e79e5839d8b68325688b47af297'
VERSION[nano]='9.2'; URL[nano]='https://www.nano-editor.org/dist/v9/nano-9.2.tar.xz'; SHA[nano]='05ecb99247b782e8a5b3a25ed4101dd034b0236902f7449bc9795b717642f7e9'
VERSION[inetutils]='2.8'; URL[inetutils]='https://ftp.gnu.org/gnu/inetutils/inetutils-2.8.tar.gz'; SHA[inetutils]='57b3cf4f77555992881e5ba2a09a63b05aa2c56342a60ed4305b5f45938390b5'
VERSION[linux]='7.2.12'; URL[linux]='https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.12.tar.xz'; SHA[linux]='bb18468a8dc8978aa00caa6446e753f7b6da3fee56b6b7f38b16f9430ba02d4f'
VERSION[binutils]='2.47'; URL[binutils]='https://ftp.gnu.org/gnu/binutils/binutils-2.47.tar.xz'; SHA[binutils]='154ab23b60070e8f27013c22977f1129425d67d1e8acd6e13010e617811e4cff'
VERSION[gcc]='16.2.0'; URL[gcc]='https://ftp.gnu.org/gnu/gcc/gcc-16.2.0/gcc-16.2.0.tar.xz'; SHA[gcc]='e6738e29597f733270731aa90600f37ffdc045079dfc27ec7e8192cc81085c3e'
VERSION[glibc]='2.44'; URL[glibc]='https://ftp.gnu.org/gnu/glibc/glibc-2.44.tar.xz'; SHA[glibc]='37f600f2bef3c5e8300147059568b2a2e40a7ad6ccc65ce942556d49429cc667'
VERSION[gmp]='6.3.0'; URL[gmp]='https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz'; SHA[gmp]='a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898'
VERSION[mpfr]='4.2.2'; URL[mpfr]='https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.2.tar.xz'; SHA[mpfr]='b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01'
VERSION[mpc]='1.4.1'; URL[mpc]='https://ftp.gnu.org/gnu/mpc/mpc-1.4.1.tar.xz'; SHA[mpc]='91204cd32f164bd3b7c992d4a6a8ce6519511aadab30f78b6982d0bf8d73e931'
VERSION[bash]='5.3'; URL[bash]='https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz'; SHA[bash]='0d5cd86965f869a26cf64f4b71be7b96f90a3ba8b3d74e27e8e9d9d5550f31ba'
VERSION[dash]='0.5.13.5'; URL[dash]='https://snapshot.debian.org/file/f7bf38cb203bac7b7592fc25a32cd01cf04277a8'; SHA[dash]='40090101a2a491f13e901d3d48e90414f26634628b9bfff35ff540363c227a7d'
VERSION[busybox]='1.38.0'; URL[busybox]='https://busybox.net/downloads/busybox-1.38.0.tar.bz2'; SHA[busybox]='34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2'
VERSION[openrc]='0.64.1'; URL[openrc]='https://codeload.github.com/OpenRC/openrc/tar.gz/0.64.1'; SHA[openrc]='56d6d24c7fd2ca15d1abd1fb82ce5430629a71acb2c3fa12760300243dbd0baa'
VERSION[systemd]='262'; URL[systemd]='https://codeload.github.com/systemd/systemd/tar.gz/v262'; SHA[systemd]='6aa77506c0644aa67f940a48e3d3a7368601f787e4f249139516d353f107bcab'
VERSION[grub]='2.14'; URL[grub]='https://ftp.gnu.org/gnu/grub/grub-2.14.tar.xz'; SHA[grub]='bc8d3c73535b8838d8c8e2654d73edc4e6ae8c8acdb45d5df5dc9a1547446d43'
VERSION[sudo]='1.9.17p2'; URL[sudo]='https://github.com/sudo-project/sudo/releases/download/v1.9.17p2/sudo-1.9.17p2.tar.gz'; SHA[sudo]='4a38a1ab3adb1199257edc2a7c4a2bd714665eb605b04368843b06dada2cfcfb'
VERSION[shadow]='4.20.3'; URL[shadow]='https://github.com/shadow-maint/shadow/releases/download/4.20.3/shadow-4.20.3.tar.xz'; SHA[shadow]='623be9429f64fa2165bfc5957c6a642ec309c5cf23c0d53855c99f7591922297'
VERSION[linux-pam]='1.7.3'; URL[linux-pam]='https://github.com/linux-pam/linux-pam/releases/download/v1.7.3/Linux-PAM-1.7.3.tar.xz'; SHA[linux-pam]='2ce4765fd49df6693771ef2941f81e33d8ee14b94a81a5c7b369aa3b137b85a5'
VERSION[elogind]='257.16'; URL[elogind]='https://github.com/elogind/elogind/archive/refs/tags/v257.16.tar.gz'; SHA[elogind]='3c8146409bfb9daa77f272212c2b0bf0ae727c782ec87ece0d2d25e0e5bf5f4c'
VERSION[ncurses]='6.6'; URL[ncurses]='https://ftp.gnu.org/gnu/ncurses/ncurses-6.6.tar.gz'; SHA[ncurses]='355b4cbbed880b0381a04c46617b7656e362585d52e9cf84a67e2009b749ff11'
VERSION[libcap]='2.78'; URL[libcap]='https://www.kernel.org/pub/linux/libs/security/linux-privs/libcap2/libcap-2.78.tar.xz'; SHA[libcap]='0d621e562fd932ccf67b9660fb018e468a683d7b827541df27813228c996bb11'
VERSION[libxcrypt]='4.5.2'; URL[libxcrypt]='https://github.com/besser82/libxcrypt/releases/download/v4.5.2/libxcrypt-4.5.2.tar.xz'; SHA[libxcrypt]='71513a31c01a428bccd5367a32fd95f115d6dac50fb5b60c779d5c7942aec071'
VERSION[util-linux]='2.42.4'; URL[util-linux]='https://www.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-2.42.4.tar.xz'; SHA[util-linux]='fbd62a100ab7bb8746ba0661255c3c48185b1e9021507c624da01fbc696330ec'
VERSION[coreutils]='9.12'; URL[coreutils]='https://ftp.gnu.org/gnu/coreutils/coreutils-9.12.tar.xz'; SHA[coreutils]='a480198559733e9b3da999e90543ac6f888a2caa544d8d664c5a1f17e528e210'
VERSION[grep]='3.12'; URL[grep]='https://ftp.gnu.org/gnu/grep/grep-3.12.tar.xz'; SHA[grep]='2649b27c0e90e632eadcd757be06c6e9a4f48d941de51e7c0f83ff76408a07b9'
VERSION[sed]='4.10'; URL[sed]='https://ftp.gnu.org/gnu/sed/sed-4.10.tar.xz'; SHA[sed]='b8e72182b2ec96a3574e2998c47b7aaa64cc20ce000d8e9ac313cc07cecf28c7'
VERSION[findutils]='4.11.0'; URL[findutils]='https://ftp.gnu.org/gnu/findutils/findutils-4.11.0.tar.xz'; SHA[findutils]='bfd19cb06cc71f3352d567e90284d8cdac02ac89774bbeadf0b533b0c11432fd'
VERSION[gawk]='5.4.1'; URL[gawk]='https://ftp.gnu.org/gnu/gawk/gawk-5.4.1.tar.xz'; SHA[gawk]='07f6f7342b7febe4313fc2c2542ad93d64fe20ad8717200109f105a826f5fd37'
VERSION[tar]='1.35'; URL[tar]='https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz'; SHA[tar]='4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16'
VERSION[gzip]='1.15'; URL[gzip]='https://ftp.gnu.org/gnu/gzip/gzip-1.15.tar.xz'; SHA[gzip]='9aa0cc780dec156b8282844833b342ab7cb08c25d2cd9a1869cdd0df31deff48'
VERSION[procps]='4.0.6'; URL[procps]='https://sourceforge.net/projects/procps-ng/files/Production/procps-ng-4.0.6.tar.xz/download'; SHA[procps]='67bea6fbc3a42a535a0230c9e891e5ddfb4d9d39422d46565a2990d1ace15216'
VERSION[kmod]='34.2'; URL[kmod]='https://www.kernel.org/pub/linux/utils/kernel/kmod/kmod-34.2.tar.xz'; SHA[kmod]='5a5d5073070cc7e0c7a7a3c6ec2a0e1780850c8b47b3e3892226b93ffcb9cb54'
VERSION[kbd]='2.10.0'; URL[kbd]='https://www.kernel.org/pub/linux/utils/kbd/kbd-2.10.0.tar.xz'; SHA[kbd]='6e5ca4f8d76ee9e3a8db700b667f13e12aac9933828a64e1aaad93d26be9b479'
VERSION[iproute2]='7.2.0'; URL[iproute2]='https://www.kernel.org/pub/linux/utils/net/iproute2/iproute2-7.2.0.tar.xz'; SHA[iproute2]='4c2fa124c2cf0afd7ca34d1eeacba6ba048a56f6374e2aab93dafbdbd4eea9c0'
VERSION[dhcpcd]='10.5.2'; URL[dhcpcd]='https://github.com/NetworkConfiguration/dhcpcd/releases/download/v10.5.2/dhcpcd-10.5.2.tar.xz'; SHA[dhcpcd]='3e476657fdb6eeb38b277da3a48d0ac0113ecce5858ebdcddff2b629faed52b4'
VERSION[make]='4.4.1'; URL[make]='https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz'; SHA[make]='dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3'
VERSION[glibc-fixes]='3'; URL[glibc-fixes]='https://www.linuxfromscratch.org/patches/downloads/glibc/glibc-2.44-upstream_fixes-3.patch'; SHA[glibc-fixes]='cd3245887c9c2564ef18b8e9ed4046093a575fc91bce00fd82eb931102e4a30e'

VERSION[zlib]='1.4'; URL[zlib]='https://github.com/madler/zlib/releases/download/v1.4/zlib-1.4.tar.gz'; SHA[zlib]='02dd159783677a749c04adbdd02b55b8a2bcc7e054f51b76b549199a916ad584'
VERSION[bzip2]='1.0.8'; URL[bzip2]='https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz'; SHA[bzip2]='ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269'
VERSION[xz]='5.8.4'; URL[xz]='https://snapshot.debian.org/file/b1345221051ef5ac65297926418b56d2b941fe64'; SHA[xz]='4ce24038fd4221e0d13bc1a2de7a4db56e90b92b3bf75321f6c14be73f65de4b'
VERSION[lz4]='1.10.0'; URL[lz4]='https://snapshot.debian.org/file/e6a01c6d457365f9e26bc440394daab80ab0aff0'; SHA[lz4]='537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b'
VERSION[xxhash]='0.8.3'; URL[xxhash]='https://snapshot.debian.org/file/6caf7421bbcb2be76006f31ab514d484a8d8b628'; SHA[xxhash]='aae608dfe8213dfd05d909a57718ef82f30722c392344583d3f39050c7f29a80'
VERSION[openssl]='4.0.3'; URL[openssl]='https://snapshot.debian.org/file/7035f60f356f8c80b76eebfdeb81a499f19028fa'; SHA[openssl]='325b5c806167c13b40b1ffeadfe0248197c00eccc4cf123ec1e28d2d2fd216d9'
VERSION[wget]='1.25.0'; URL[wget]='https://ftp.gnu.org/gnu/wget/wget-1.25.0.tar.gz'; SHA[wget]='766e48423e79359ea31e41db9e5c289675947a7fcf2efdcedb726ac9d0da3784'
VERSION[openssh]='10.6p2'; URL[openssh]='https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.6p2.tar.gz'; SHA[openssh]='9ae44872090cf2f06b3cf9ff147e7f16f309671340763ed2f99248398ae29d5b'
VERSION[curl]='8.22.0'; URL[curl]='https://curl.se/download/curl-8.22.0.tar.xz'; SHA[curl]='f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7'
VERSION[libarchive]='3.8.9'; URL[libarchive]='https://libarchive.org/downloads/libarchive-3.8.9.tar.xz'; SHA[libarchive]='888c934f9d95648ecb9163dc8e23ab80a476ecb81a8f1154704a227b5b676dde'
VERSION[libgpg-error]='1.61'; URL[libgpg-error]='https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.61.tar.bz2'; SHA[libgpg-error]='7a85413f2bc354f4f8aa832b718af122e48965e9e0eb9012ee659c13c6385c93'
VERSION[libgcrypt]='1.12.4'; URL[libgcrypt]='https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.12.4.tar.bz2'; SHA[libgcrypt]='d77f68f48879510e79a2f65977ccc68981781ea0923e5bdffac2a193ea3d660e'
VERSION[libassuan]='3.0.2'; URL[libassuan]='https://gnupg.org/ftp/gcrypt/libassuan/libassuan-3.0.2.tar.bz2'; SHA[libassuan]='d2931cdad266e633510f9970e1a2f346055e351bb19f9b78912475b8074c36f6'
VERSION[libksba]='1.8.1'; URL[libksba]='https://gnupg.org/ftp/gcrypt/libksba/libksba-1.8.1.tar.bz2'; SHA[libksba]='c2f84393011827219ae117131dba8e7684c2bed0961eed11b0642c2acba440b5'
VERSION[npth]='1.8'; URL[npth]='https://gnupg.org/ftp/gcrypt/npth/npth-1.8.tar.bz2'; SHA[npth]='8bd24b4f23a3065d6e5b26e98aba9ce783ea4fd781069c1b35d149694e90ca3e'
VERSION[gnupg]='2.4.9'; URL[gnupg]='https://gnupg.org/ftp/gcrypt/gnupg/gnupg-2.4.9.tar.bz2'; SHA[gnupg]='dd17ab2e9a04fd79d39d853f599cbc852062ddb9ab52a4ddeb4176fd8b302964'
VERSION[gpgme]='2.2.0'; URL[gpgme]='https://gnupg.org/ftp/gcrypt/gpgme/gpgme-2.2.0.tar.bz2'; SHA[gpgme]='7160e80e84dafd00d956c84891c533bb7ab16a6a54fbe1574b2f3acf0496977b'
VERSION[db]='5.3.28+dfsg2'; URL[db]='https://snapshot.debian.org/file/c2e52e52021c4df2ebff57f1fb68e2879d65376a'; SHA[db]='ad41b507415dec8316e828b2230242af2251d2c86eefa3c7aa9ef47c5239ef33'
VERSION[ca-bundle]='2026-09-25'; URL[ca-bundle]='https://curl.se/ca/cacert-2026-09-25.pem'; SHA[ca-bundle]='a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505'
VERSION[triehash]='0.3'; URL[triehash]='https://codeload.github.com/julian-klode/triehash/tar.gz/refs/tags/v0.3'; SHA[triehash]='289a0966c02c2008cd263d3913a8e3c84c97b8ded3e08373d63a382c71d2199c'
VERSION[zstd]='1.5.7'; URL[zstd]='https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz'; SHA[zstd]='eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3'
VERSION[libmd]='1.1.0'; URL[libmd]='https://libbsd.freedesktop.org/releases/libmd-1.1.0.tar.xz'; SHA[libmd]='1bd6aa42275313af3141c7cf2e5b964e8b1fd488025caf2f971f43b00776b332'
VERSION[apt]='3.3.3'; URL[apt]='https://snapshot.debian.org/file/f4f5406a434df5f18c885871d77197e682b20447'; SHA[apt]='1c06b4a145d6117917c390c79fe7d27d9d92ee922101134ad6446717b0a1c28f'
VERSION[dpkg]='1.23.11'; URL[dpkg]='https://snapshot.debian.org/file/0f8d21b4ba5fe575f624cf2efbe37600ce1ae418'; SHA[dpkg]='4baf0632157bfac430b7dc1fe8800ea0787dac91f8bb272404ae19d98e569dd3'
VERSION[pacman]='7.1.0'; URL[pacman]='https://gitlab.archlinux.org/pacman/pacman/-/archive/v7.1.0/pacman-v7.1.0.tar.gz'; SHA[pacman]='1090f680958a73dc1f443a1eb919bd2ad77b3caff38e92e9737dec100c647bc9'
VERSION[nginx]='1.30.6'; URL[nginx]='https://nginx.org/download/nginx-1.30.6.tar.gz'; SHA[nginx]='3cf46f5ed7504d460125866b7bea99fb357f31d887e2e63b35503310e9b8b6c8'
VERSION[php]='8.5.12'; URL[php]='https://www.php.net/distributions/php-8.5.12.tar.xz'; SHA[php]='08bc2eba2a588654ade1357174aa646b761556c862dda0678345ee29ed481209'

# BEGIN SHARED DESKTOP SOURCES
VERSION[glib]='2.84.4'; URL[glib]='https://download.gnome.org/sources/glib/2.84/glib-2.84.4.tar.xz'; SHA[glib]='8a9ea10943c36fc117e253f80c91e477b673525ae45762942858aef57631bb90'
VERSION[pango]='1.56.4'; URL[pango]='https://download.gnome.org/sources/pango/1.56/pango-1.56.4.tar.xz'; SHA[pango]='17065e2fcc5f5a5bdbffc884c956bfc7c451a96e8c4fb2f8ad837c6413cb5a01'
VERSION[gdk-pixbuf]='2.42.12'; URL[gdk-pixbuf]='https://download.gnome.org/sources/gdk-pixbuf/2.42/gdk-pixbuf-2.42.12.tar.xz'; SHA[gdk-pixbuf]='b9505b3445b9a7e48ced34760c3bcb73e966df3ac94c95a148cb669ab748e3c7'
VERSION[at-spi2-core]='2.56.4'; URL[at-spi2-core]='https://download.gnome.org/sources/at-spi2-core/2.56/at-spi2-core-2.56.4.tar.xz'; SHA[at-spi2-core]='dbe35b951499e1d6f1fb552c2e0a09cea7cba2adf6c2eba0b2c85b6c094a3a02'
VERSION[gtk]='3.24.50'; URL[gtk]='https://download.gnome.org/sources/gtk/3.24/gtk-3.24.50.tar.xz'; SHA[gtk]='399118a5699314622165a11b769ea9b6ed68e037b6d46d57cfcf4851dec07529'
VERSION[libwnck]='43.2'; URL[libwnck]='https://download.gnome.org/sources/libwnck/43/libwnck-43.2.tar.xz'; SHA[libwnck]='55a7444ec1fbb95c086d40967388f231b5c0bbc8cffaa086bf9290ae449e51d5'
VERSION[adwaita-icon-theme]='43'; URL[adwaita-icon-theme]='https://download.gnome.org/sources/adwaita-icon-theme/43/adwaita-icon-theme-43.tar.xz'; SHA[adwaita-icon-theme]='2e3ac77d32a6aa5554155df37e8f0a0dd54fc5a65fd721e88d505f970da32ec6'
VERSION[libffi]='3.8.0'; URL[libffi]='https://github.com/libffi/libffi/releases/download/v3.8.0/libffi-3.8.0.tar.gz'; SHA[libffi]='7da3e2d9a171eb0a038f592ecad3ff2bb2550f3496d87b3b29ad0cf4430c0db4'
VERSION[pcre2]='10.49'; URL[pcre2]='https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49/pcre2-10.49.tar.bz2'; SHA[pcre2]='53c156e1ba416a20da8e65395daa132da0d80e76910424caca3fcdae7831d384'
VERSION[expat]='2.10.0'; URL[expat]='https://github.com/libexpat/libexpat/releases/download/R_2_10_0/expat-2.10.0.tar.xz'; SHA[expat]='c624ba2998fc65df1163a49641ff3f9ab73138b11641d92c86bee0fb01b1bc7f'
VERSION[dbus]='1.16.2'; URL[dbus]='https://ftp.osuosl.org/pub/blfs/conglomeration/dbus/dbus-1.16.2.tar.xz'; SHA[dbus]='0ba2a1a4b16afe7bceb2c07e9ce99a8c2c3508e5dec290dbb643384bd6beb7e2'
VERSION[libpng]='1.6.50'; URL[libpng]='https://downloads.sourceforge.net/libpng/libpng-1.6.50.tar.xz'; SHA[libpng]='4df396518620a7aa3651443e87d1b2862e4e88cad135a8b93423e01706232307'
VERSION[freetype]='2.13.3'; URL[freetype]='https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz'; SHA[freetype]='0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289'
VERSION[fontconfig]='2.17.1'; URL[fontconfig]='https://ftp.osuosl.org/pub/blfs/conglomeration/fontconfig/fontconfig-2.17.1.tar.xz'; SHA[fontconfig]='9f5cae93f4fffc1fbc05ae99cdfc708cd60dfd6612ffc0512827025c026fa541'
VERSION[pixman]='0.46.4'; URL[pixman]='https://ftp.osuosl.org/pub/blfs/conglomeration/pixman/pixman-0.46.4.tar.gz'; SHA[pixman]='d09c44ebc3bd5bee7021c79f922fe8fb2fb57f7320f55e97ff9914d2346a591c'
VERSION[cairo]='1.18.4'; URL[cairo]='https://ftp.osuosl.org/pub/blfs/conglomeration/cairo/cairo-1.18.4.tar.xz'; SHA[cairo]='445ed8208a6e4823de1226a74ca319d3600e83f6369f99b14265006599c32ccb'
VERSION[harfbuzz]='15.1.0'; URL[harfbuzz]='https://github.com/harfbuzz/harfbuzz/releases/download/15.1.0/harfbuzz-15.1.0.tar.xz'; SHA[harfbuzz]='0fc7c565443a5f4be7da65ac5ee5bd737d9b158dc908708b7689a0a5796b0c8d'
VERSION[fribidi]='1.0.18'; URL[fribidi]='https://github.com/fribidi/fribidi/releases/download/v1.0.18/fribidi-1.0.18.tar.xz'; SHA[fribidi]='1de5e8073d035388b71d0b2d452b1da1f8caeea8a7702997b401fe1b6250727f'
VERSION[libepoxy]='1.5.10'; URL[libepoxy]='https://download.gnome.org/sources/libepoxy/1.5/libepoxy-1.5.10.tar.xz'; SHA[libepoxy]='072cda4b59dd098bba8c2363a6247299db1fa89411dc221c8b81b8ee8192e623'
VERSION[libxml2]='2.14.6'; URL[libxml2]='https://download.gnome.org/sources/libxml2/2.14/libxml2-2.14.6.tar.xz'; SHA[libxml2]='7ce458a0affeb83f0b55f1f4f9e0e55735dbfc1a9de124ee86fb4a66b597203a'
VERSION[shared-mime-info]='2.4'; URL[shared-mime-info]='https://ftp.osuosl.org/pub/blfs/conglomeration/shared-mime-info/shared-mime-info-2.4.tar.gz'; SHA[shared-mime-info]='531291d0387eb94e16e775d7e73788d06d2b2fdd8cd2ac6b6b15287593b6a2de'
VERSION[desktop-file-utils]='0.28'; URL[desktop-file-utils]='https://ftp.osuosl.org/pub/blfs/conglomeration/desktop-file-utils/desktop-file-utils-0.28.tar.xz'; SHA[desktop-file-utils]='4401d4e231d842c2de8242395a74a395ca468cd96f5f610d822df33594898a70'
VERSION[hicolor-icon-theme]='0.18'; URL[hicolor-icon-theme]='https://ftp.osuosl.org/pub/blfs/conglomeration/hicolor-icon-theme/hicolor-icon-theme-0.18.tar.xz'; SHA[hicolor-icon-theme]='db0e50a80aa3bf64bb45cbca5cf9f75efd9348cf2ac690b907435238c3cf81d7'
VERSION[dejavu-fonts]='2.37'; URL[dejavu-fonts]='https://downloads.sourceforge.net/dejavu/dejavu-fonts-ttf-2.37.tar.bz2'; SHA[dejavu-fonts]='fa9ca4d13871dd122f61258a80d01751d603b4d3ee14095d65453b4e846e17d7'
VERSION[eudev]='3.3.0'; URL[eudev]='https://github.com/eudev-project/eudev/releases/download/v3.3.0/eudev-3.3.0.tar.gz'; SHA[eudev]='8fba6e4f49ea4b1938828a3c2e7cc48874816c68621386e527076b6477f5d6ef'
VERSION[libdrm]='2.4.133'; URL[libdrm]='https://dri.freedesktop.org/libdrm/libdrm-2.4.133.tar.xz'; SHA[libdrm]='fc68f9d0ba2ea63c9432a299e14fea09fad7a8a66e8039fcd7802ca59f77b4f5'
VERSION[libxshmfence]='1.3.3'; URL[libxshmfence]='https://xorg.freedesktop.org/releases/individual/lib/libxshmfence-1.3.3.tar.xz'; SHA[libxshmfence]='d4a4df096aba96fea02c029ee3a44e11a47eb7f7213c1a729be83e85ec3fde10'
VERSION[elfutils]='0.193'; URL[elfutils]='https://sourceware.org/elfutils/ftp/0.193/elfutils-0.193.tar.bz2'; SHA[elfutils]='7857f44b624f4d8d421df851aaae7b1402cfe6bcdd2d8049f15fc07d3dde7635'
VERSION[mesa]='26.2.5'; URL[mesa]='https://archive.mesa3d.org/mesa-26.2.5.tar.xz'; SHA[mesa]='794b3d1729075dae7ebd47c7283b7ca0cdb5dec668f7f11cc0a5d82f6138a0a5'
VERSION[libevdev]='1.14.0'; URL[libevdev]='https://ftp.osuosl.org/pub/blfs/conglomeration/Xorg/libevdev-1.14.0.tar.xz'; SHA[libevdev]='5a0966c7110648665983848bad696c7acba614a2160d2865d535397101007332'
VERSION[util-macros]='1.20.2'; URL[util-macros]='https://ftp.osuosl.org/pub/blfs/conglomeration/Xorg/util-macros-1.20.2.tar.xz'; SHA[util-macros]='9ac269eba24f672d7d7b3574e4be5f333d13f04a7712303b1821b2a51ac82e8e'
VERSION[xorgproto]='2024.1'; URL[xorgproto]='https://ftp.osuosl.org/pub/blfs/conglomeration/Xorg/xorgproto-2024.1.tar.xz'; SHA[xorgproto]='372225fd40815b8423547f5d890c5debc72e88b91088fbfb13158c20495ccb59'
VERSION[libXau]='1.0.12'; URL[libXau]='https://ftp.osuosl.org/pub/blfs/conglomeration/Xorg/libXau-1.0.12.tar.xz'; SHA[libXau]='74d0e4dfa3d39ad8939e99bda37f5967aba528211076828464d2777d477fc0fb'
VERSION[libXdmcp]='1.1.5'; URL[libXdmcp]='https://ftp.osuosl.org/pub/blfs/conglomeration/Xorg/libXdmcp-1.1.5.tar.xz'; SHA[libXdmcp]='d8a5222828c3adab70adf69a5583f1d32eb5ece04304f7f8392b6a353aa2228c'
VERSION[libxcb]='1.17.0'; URL[libxcb]='https://ftp.osuosl.org/pub/blfs/conglomeration/Xorg/libxcb-1.17.0.tar.xz'; SHA[libxcb]='599ebf9996710fea71622e6e184f3a8ad5b43d0e5fa8c4e407123c88a59a6d55'
VERSION[xcb-proto]='1.17.0'; URL[xcb-proto]='https://ftp.osuosl.org/pub/blfs/conglomeration/Xorg/xcb-proto-1.17.0.tar.xz'; SHA[xcb-proto]='2c1bacd2110f4799f74de6ebb714b94cf6f80fb112316b1219480fd22562148c'
VERSION[libX11]='1.8.12'; URL[libX11]='https://distfiles.macports.org/xorg-libX11/libX11-1.8.12.tar.xz'; SHA[libX11]='fa026f9bb0124f4d6c808f9aef4057aad65e7b35d8ff43951cef0abe06bb9a9a'
VERSION[libXext]='1.3.6'; URL[libXext]='https://artfiles.org/x.org/pub/individual/lib/libXext-1.3.6.tar.xz'; SHA[libXext]='edb59fa23994e405fdc5b400afdf5820ae6160b94f35e3dc3da4457a16e89753'
VERSION[libXrender]='0.9.12'; URL[libXrender]='https://artfiles.org/x.org/pub/individual/lib/libXrender-0.9.12.tar.xz'; SHA[libXrender]='b832128da48b39c8d608224481743403ad1691bf4e554e4be9c174df171d1b97'
VERSION[libXft]='2.3.9'; URL[libXft]='https://xorg.freedesktop.org/archive/individual/lib/libXft-2.3.9.tar.xz'; SHA[libXft]='60a25b78945ed6932635b3bb1899a517d31df7456e69867ffba27f89ff3976f5'
VERSION[libXfixes]='6.0.1'; URL[libXfixes]='https://artfiles.org/x.org/pub/individual/lib/libXfixes-6.0.1.tar.xz'; SHA[libXfixes]='b695f93cd2499421ab02d22744458e650ccc88c1d4c8130d60200213abc02d58'
VERSION[libXi]='1.8.2'; URL[libXi]='https://artfiles.org/x.org/pub/individual/lib/libXi-1.8.2.tar.xz'; SHA[libXi]='d0e0555e53d6e2114eabfa44226ba162d2708501a25e18d99cfb35c094c6c104'
VERSION[libXrandr]='1.5.4'; URL[libXrandr]='https://artfiles.org/x.org/pub/individual/lib/libXrandr-1.5.4.tar.xz'; SHA[libXrandr]='1ad5b065375f4a85915aa60611cc6407c060492a214d7f9daf214be752c3b4d3'
VERSION[libXcursor]='1.2.3'; URL[libXcursor]='https://artfiles.org/x.org/pub/individual/lib/libXcursor-1.2.3.tar.xz'; SHA[libXcursor]='fde9402dd4cfe79da71e2d96bb980afc5e6ff4f8a7d74c159e1966afb2b2c2c0'
VERSION[libXinerama]='1.1.5'; URL[libXinerama]='https://artfiles.org/x.org/pub/individual/lib/libXinerama-1.1.5.tar.xz'; SHA[libXinerama]='5094d1f0fcc1828cb1696d0d39d9e866ae32520c54d01f618f1a3c1e30c2085c'
VERSION[libXcomposite]='0.4.6'; URL[libXcomposite]='https://artfiles.org/x.org/pub/individual/lib/libXcomposite-0.4.6.tar.xz'; SHA[libXcomposite]='fe40bcf0ae1a09070eba24088a5eb9810efe57453779ec1e20a55080c6dc2c87'
VERSION[libXdamage]='1.1.6'; URL[libXdamage]='https://artfiles.org/x.org/pub/individual/lib/libXdamage-1.1.6.tar.xz'; SHA[libXdamage]='52733c1f5262fca35f64e7d5060c6fcd81a880ba8e1e65c9621cf0727afb5d11'
VERSION[libXtst]='1.2.5'; URL[libXtst]='https://artfiles.org/x.org/pub/individual/lib/libXtst-1.2.5.tar.xz'; SHA[libXtst]='b50d4c25b97009a744706c1039c598f4d8e64910c9fde381994e1cae235d9242'
VERSION[libXres]='1.2.2'; URL[libXres]='https://artfiles.org/x.org/pub/individual/lib/libXres-1.2.2.tar.xz'; SHA[libXres]='9a7446f3484b9b7538ac5ee30d2c1ce9e5b7fbbaf1440e02f6cca186a1fa745f'
VERSION[libXpresent]='1.0.1'; URL[libXpresent]='https://artfiles.org/x.org/pub/individual/lib/libXpresent-1.0.1.tar.xz'; SHA[libXpresent]='b964df9e5a066daa5e08d2dc82692c57ca27d00b8cc257e8e960c9f1cf26231b'
VERSION[libXxf86vm]='1.1.5'; URL[libXxf86vm]='https://xorg.freedesktop.org/releases/individual/lib/libXxf86vm-1.1.5.tar.xz'; SHA[libXxf86vm]='247fef48b3e0e7e67129e41f1e789e8d006ba47dba1c0cdce684b9b703f888e7'
VERSION[libICE]='1.1.2'; URL[libICE]='https://artfiles.org/x.org/pub/individual/lib/libICE-1.1.2.tar.xz'; SHA[libICE]='974e4ed414225eb3c716985df9709f4da8d22a67a2890066bc6dfc89ad298625'
VERSION[libSM]='1.2.5'; URL[libSM]='https://artfiles.org/x.org/pub/individual/lib/libSM-1.2.5.tar.xz'; SHA[libSM]='2af9e12da5ef670dc3a7bce1895c9c0f1bfb0cb9e64e8db40fcc33f883bd20bc'
VERSION[xtrans]='1.5.2'; URL[xtrans]='https://artfiles.org/x.org/pub/individual/lib/xtrans-1.5.2.tar.xz'; SHA[xtrans]='5c5cbfe34764a9131d048f03c31c19e57fb4c682d67713eab6a65541b4dff86c'
VERSION[libfontenc]='1.1.8'; URL[libfontenc]='https://artfiles.org/x.org/pub/individual/lib/libfontenc-1.1.8.tar.xz'; SHA[libfontenc]='7b02c3d405236e0d86806b1de9d6868fe60c313628b38350b032914aa4fd14c6'
VERSION[libXfont2]='2.0.7'; URL[libXfont2]='https://artfiles.org/x.org/pub/individual/lib/libXfont2-2.0.7.tar.xz'; SHA[libXfont2]='8b7b82fdeba48769b69433e8e3fbb984a5f6bf368b0d5f47abeec49de3e58efb'
VERSION[libxkbfile]='1.1.3'; URL[libxkbfile]='https://artfiles.org/x.org/pub/individual/lib/libxkbfile-1.1.3.tar.xz'; SHA[libxkbfile]='a9b63eea997abb9ee6a8b4fbb515831c841f471af845a09de443b28003874bec'
VERSION[libxcvt]='0.1.3'; URL[libxcvt]='https://ftp.osuosl.org/pub/blfs/conglomeration/Xorg/libxcvt-0.1.3.tar.xz'; SHA[libxcvt]='a929998a8767de7dfa36d6da4751cdbeef34ed630714f2f4a767b351f2442e01'
VERSION[font-util]='1.4.1'; URL[font-util]='https://artfiles.org/x.org/pub/individual/font/font-util-1.4.1.tar.xz'; SHA[font-util]='5c9f64123c194b150fee89049991687386e6ff36ef2af7b80ba53efaf368cc95'
VERSION[font-misc-misc]='1.1.3'; URL[font-misc-misc]='https://xorg.freedesktop.org/releases/individual/font/font-misc-misc-1.1.3.tar.xz'; SHA[font-misc-misc]='79abe361f58bb21ade9f565898e486300ce1cc621d5285bec26e14b6a8618fed'
VERSION[xkbcomp]='1.4.7'; URL[xkbcomp]='https://artfiles.org/x.org/pub/individual/app/xkbcomp-1.4.7.tar.xz'; SHA[xkbcomp]='0a288114e5f44e31987042c79aecff1ffad53a8154b8ec971c24a69a80f81f77'
VERSION[xkeyboard-config]='2.45'; URL[xkeyboard-config]='https://ftp.osuosl.org/pub/blfs/conglomeration/Xorg/xkeyboard-config-2.45.tar.xz'; SHA[xkeyboard-config]='169e075a92d957a57787c199e84e359df2931b7196c1c5b4a3d576ee6235a87c'
VERSION[xorg-server]='21.1.18'; URL[xorg-server]='https://ftp.osuosl.org/pub/blfs/conglomeration/Xorg/xorg-server-21.1.18.tar.xz'; SHA[xorg-server]='c878d1930d87725d4a5bf498c24f4be8130d5b2646a9fd0f2994deff90116352'
VERSION[xf86-input-evdev]='2.11.0'; URL[xf86-input-evdev]='https://ftp.osuosl.org/pub/blfs/conglomeration/Xorg/xf86-input-evdev-2.11.0.tar.xz'; SHA[xf86-input-evdev]='730022de934cc366bb12439daf202a7bfff52a028cf4573e457642e25a071315'
VERSION[xinit]='1.4.4'; URL[xinit]='https://ftp.osuosl.org/pub/blfs/conglomeration/Xorg/xinit-1.4.4.tar.xz'; SHA[xinit]='40a47c7a164c7f981ce3787b4b37f7e411fb43231dcde543d70094075dacfef9'
VERSION[xauth]='1.1.3'; URL[xauth]='https://artfiles.org/x.org/pub/individual/app/xauth-1.1.3.tar.xz'; SHA[xauth]='e7075498bae332f917f01d660f9b940c0752b2556a8da61ccb62a44d0ffe9d33'
VERSION[bdftopcf]='1.1.2'; URL[bdftopcf]='https://xorg.freedesktop.org/releases/individual/util/bdftopcf-1.1.2.tar.xz'; SHA[bdftopcf]='bc60be5904330faaa3ddd2aed7874bee2f29e4387c245d6787552f067eb0523a'
VERSION[libXt]='1.3.1'; URL[libXt]='https://artfiles.org/x.org/pub/individual/lib/libXt-1.3.1.tar.xz'; SHA[libXt]='e0a774b33324f4d4c05b199ea45050f87206586d81655f8bef4dba434d931288'
VERSION[libXmu]='1.2.1'; URL[libXmu]='https://artfiles.org/x.org/pub/individual/lib/libXmu-1.2.1.tar.xz'; SHA[libXmu]='fcb27793248a39e5fcc5b9c4aec40cc0734b3ca76aac3d7d1c264e7f7e14e8b2'
VERSION[libXpm]='3.5.17'; URL[libXpm]='https://artfiles.org/x.org/pub/individual/lib/libXpm-3.5.17.tar.xz'; SHA[libXpm]='64b31f81019e7d388c822b0b28af8d51c4622b83f1f0cb6fa3fc95e271226e43'
VERSION[libXaw]='1.0.16'; URL[libXaw]='https://artfiles.org/x.org/pub/individual/lib/libXaw-1.0.16.tar.xz'; SHA[libXaw]='731d572b54c708f81e197a6afa8016918e2e06dfd3025e066ca642a5b8c39c8f'
VERSION[libpciaccess]='0.18.1'; URL[libpciaccess]='https://artfiles.org/x.org/pub/individual/lib/libpciaccess-0.18.1.tar.xz'; SHA[libpciaccess]='4af43444b38adb5545d0ed1c2ce46d9608cc47b31c2387fc5181656765a6fa76'
VERSION[mtdev]='1.1.7'; URL[mtdev]='https://bitmath.org/code/mtdev/mtdev-1.1.7.tar.bz2'; SHA[mtdev]='a107adad2101fecac54ac7f9f0e0a0dd155d954193da55c2340c97f2ff1d814e'
VERSION[libdisplay-info]='0.2.0'; URL[libdisplay-info]='https://gitlab.freedesktop.org/emersion/libdisplay-info/-/releases/0.2.0/downloads/libdisplay-info-0.2.0.tar.xz'; SHA[libdisplay-info]='5a2f002a16f42dd3540c8846f80a90b8f4bdcd067a94b9d2087bc2feae974176'
VERSION[xterm]='401'; URL[xterm]='https://invisible-mirror.net/archives/xterm/xterm-401.tgz'; SHA[xterm]='3da2b5e64cb49b03aa13057d85e62e1f2e64f7c744719c00d338d11cd3e6ca1a'
VERSION[fluxbox]='1.3.7'; URL[fluxbox]='https://downloads.sourceforge.net/project/fluxbox/fluxbox/1.3.7/fluxbox-1.3.7.tar.gz'; SHA[fluxbox]='c99e2baa06fff1e96342b20415059d12ff1fa2917ade0173c75b2fa570295b9f'
# LXDE consists of separately released GTK/X11 components. Pin the official
# upstream release archives so the desktop profile is reproducible.
VERSION[menu-cache]='1.1.1'; URL[menu-cache]='https://github.com/lxde/releases/raw/master/releases/menu-cache-1.1.1.tar.xz'; SHA[menu-cache]='8232399b45b0b99bd480ec6df8fb9a5b8e034cc31c90b375916b372631f4531a'
VERSION[libfm]='1.4.1'; URL[libfm]='https://github.com/lxde/releases/raw/master/releases/libfm-1.4.1.tar.xz'; SHA[libfm]='5caa820443d558974648583e37b4d956ae67a6e3df23493f99c2d0e26a11c665'
VERSION[keybinder]='0.3.2'; URL[keybinder]='https://github.com/kupferlauncher/keybinder/releases/download/keybinder-3.0-v0.3.2/keybinder-3.0-0.3.2.tar.gz'; SHA[keybinder]='e6e3de4e1f3b201814a956ab8f16dfc8a262db1937ff1eee4d855365398c6020'
VERSION[lxmenu-data]='0.1.7'; URL[lxmenu-data]='https://github.com/lxde/releases/raw/master/releases/lxmenu-data-0.1.7.tar.xz'; SHA[lxmenu-data]='60ec0b2ea07637557e040ce8aeec14c596aa0c916922b34d7aa7e01b2a1f7ca5'
VERSION[lxde-icon-theme]='0.5.2'; URL[lxde-icon-theme]='https://github.com/lxde/releases/raw/master/releases/lxde-icon-theme-0.5.2.tar.xz'; SHA[lxde-icon-theme]='88f4b2b0dbb454483be631b605184c9bc26b46653ff749e8e6b90ec24146f52d'
VERSION[lxpanel]='0.11.1'; URL[lxpanel]='https://github.com/lxde/releases/raw/master/releases/lxpanel-0.11.1.tar.xz'; SHA[lxpanel]='251f32cdcc3722ed942bdf33d50d9f0a6bd3ffe07983047b023e02e6c9561d92'
VERSION[lxsession]='0.5.7'; URL[lxsession]='https://github.com/lxde/releases/raw/master/releases/lxsession-0.5.7.tar.xz'; SHA[lxsession]='f10ff300f664169837fd3c26eda35000c18f510178a30d1ac064327dad3dc9ed'
VERSION[pcmanfm]='1.4.0'; URL[pcmanfm]='https://github.com/lxde/releases/raw/master/releases/pcmanfm-1.4.0.tar.xz'; SHA[pcmanfm]='55066ccd32039ab2d3f5a9054c34b292451663b0de8d9ef766430ac483624ade'
VERSION[lxappearance]='0.6.4'; URL[lxappearance]='https://github.com/lxde/releases/raw/master/releases/lxappearance-0.6.4.tar.xz'; SHA[lxappearance]='9fdc4deb841d8cf11b532ffff38634fd7e474fe1639b5f76079ea550b6ea838d'
VERSION[lxrandr]='0.3.3'; URL[lxrandr]='https://github.com/lxde/releases/raw/master/releases/lxrandr-0.3.3.tar.xz'; SHA[lxrandr]='3f08ce48ec5bb10539b64d89ede14d802b0957bbaa68d3f36d62056263715d8a'
VERSION[lxde-common]='0.99.4'; URL[lxde-common]='https://github.com/lxde/releases/raw/master/releases/lxde-common-0.99.4.tar.xz'; SHA[lxde-common]='f9cdbec993a676fe9aa1cc84f4732b1cc9bd30a7f616567c901904d77fcd0d0f'
VERSION[geany]='2.1'; URL[geany]='https://download.geany.org/geany-2.1.tar.gz'; SHA[geany]='8da944e82f78f3c4c6e6b054b7c562ab64ea37d4a3e7dc8576bed8a8160d3c2a'
VERSION[firefox]='158.0'; URL[firefox]='https://archive.mozilla.org/pub/firefox/releases/158.0/linux-x86_64/en-US/firefox-158.0.tar.xz'; SHA[firefox]='9549b054ec4cf85f50f6a19d8c6fb79580312e71ebc4ec2cb217ec9af09dc12a'
# END SHARED DESKTOP SOURCES

# MATE 1.28 release archives, from the official MATE download server.
VERSION[dconf]='0.40.0'; URL[dconf]='https://download.gnome.org/sources/dconf/0.40/dconf-0.40.0.tar.xz'; SHA[dconf]='cf7f22a4c9200421d8d3325c5c1b8b93a36843650c9f95d6451e20f0bcb24533'
VERSION[dbus-glib]='0.112'; URL[dbus-glib]='https://dbus.freedesktop.org/releases/dbus-glib/dbus-glib-0.112.tar.gz'; SHA[dbus-glib]='7d550dccdfcd286e33895501829ed971eeb65c614e73aadb4a08aeef719b143a'
VERSION[sqlite]='3.54.1'; URL[sqlite]='https://www.sqlite.org/2026/sqlite-autoconf-3540100.tar.gz'; SHA[sqlite]='926ef8d3eab93fbf6e06011901273eec076b25594a4e1cdadd50c987f4f6d64e'
VERSION[libpsl]='0.23.3'; URL[libpsl]='https://github.com/rockdaboot/libpsl/releases/download/0.23.3/libpsl-0.23.3.tar.gz'; SHA[libpsl]='93941f85a1e7bd593fa94f299233cb5dfc91cd144fd9a78a6ceb75001c5b03be'
VERSION[libtool]='2.6.2'; URL[libtool]='https://ftp.gnu.org/gnu/libtool/libtool-2.6.2.tar.xz'; SHA[libtool]='2ef1067c16c97db930fd740cc9bc3d3ba9a583804ae5ac42cc3e8719e49e191e'
VERSION[libogg]='1.3.6'; URL[libogg]='https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.xz'; SHA[libogg]='5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061'
VERSION[libvorbis]='1.3.7'; URL[libvorbis]='https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz'; SHA[libvorbis]='b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b'
VERSION[libcanberra]='0.30'; URL[libcanberra]='https://0pointer.de/lennart/projects/libcanberra/libcanberra-0.30.tar.xz'; SHA[libcanberra]='c2b671e67e0c288a69fc33dc1b6f1b534d07882c2aceed37004bf48c601afa72'
VERSION[libglvnd]='1.7.0'; URL[libglvnd]='https://gitlab.freedesktop.org/glvnd/libglvnd/uploads/c24806c283070dc70700234ca8ffacf8/libglvnd-1.7.0.tar.gz'; SHA[libglvnd]='13ae5bb99a5a2869fbe00aadb49b21fd9c13dfbf59844b0f88d521098094d44a'
VERSION[libxklavier]='5.4'; URL[libxklavier]='https://ftp.osuosl.org/pub/slackware/slackware64-current/source/l/libxklavier/libxklavier-5.4.tar.xz'; SHA[libxklavier]='0e5fce5db1f50ed6a8cad65dd30cbfb18271f4a2c0c1c395461e017ea7f4fc02'
VERSION[gobject-introspection]='1.86.0'; URL[gobject-introspection]='https://download.gnome.org/sources/gobject-introspection/1.86/gobject-introspection-1.86.0.tar.xz'; SHA[gobject-introspection]='920d1a3fcedeadc32acff95c2e203b319039dd4b4a08dd1a2dfd283d19c0b9ae'
VERSION[iso-codes]='4.20.1'; URL[iso-codes]='https://deb.debian.org/debian/pool/main/i/iso-codes/iso-codes_4.20.1.orig.tar.xz'; SHA[iso-codes]='5d551f3ddb32548c4321e9011720fd97751af0107592f79ebffc939bd32f2268'
VERSION[alsa-lib]='1.2.16.1'; URL[alsa-lib]='https://www.alsa-project.org/files/pub/lib/alsa-lib-1.2.16.1.tar.bz2'; SHA[alsa-lib]='f740db7f488255944ffd4428416ee3390a96742856916433df468c281436480e'
VERSION[alsa-utils]='1.2.16'; URL[alsa-utils]='https://www.alsa-project.org/files/pub/utils/alsa-utils-1.2.16.tar.bz2'; SHA[alsa-utils]='092399d5e8749a1d5e188e393157521cec4b75693b60ebb79bbce728cff2232c'
VERSION[libsndfile]='1.2.2'; URL[libsndfile]='https://github.com/libsndfile/libsndfile/releases/download/1.2.2/libsndfile-1.2.2.tar.xz'; SHA[libsndfile]='3799ca9924d3125038880367bf1468e53a1b7e3686a934f098b7e1d286cdb80e'
VERSION[pulseaudio]='17.0'; URL[pulseaudio]='https://freedesktop.org/software/pulseaudio/releases/pulseaudio-17.0.tar.xz'; SHA[pulseaudio]='053794d6671a3e397d849e478a80b82a63cb9d8ca296bd35b73317bb5ceb87b5'
VERSION[linux-firmware]='20260916'; URL[linux-firmware]='https://cdn.kernel.org/pub/linux/kernel/firmware/linux-firmware-20260916.tar.xz'; SHA[linux-firmware]='f80dcb757a623deda62200c08e0e1a88c76fb6b54964f31b35fa74da1c90ccc5'
VERSION[wireless-regdb]='2026.09.03'; URL[wireless-regdb]='https://www.kernel.org/pub/software/network/wireless-regdb/wireless-regdb-2026.09.03.tar.xz'; SHA[wireless-regdb]='b22e0901227b820cd1c280abe681a15b773a5103a5e10dc442e94ebb34cbf58d'
VERSION[libnl]='3.12.0'; URL[libnl]='https://github.com/thom311/libnl/releases/download/libnl3_12_0/libnl-3.12.0.tar.gz'; SHA[libnl]='fc51ca7196f1a3f5fdf6ffd3864b50f4f9c02333be28be4eeca057e103c0dd18'
VERSION[iw]='6.17'; URL[iw]='https://www.kernel.org/pub/software/network/iw/iw-6.17.tar.xz'; SHA[iw]='7d182e498289ab39b257da6780d562e415377107f50358ee5b55b8cfe40b1e33'
VERSION[wpa_supplicant]='2.12'; URL[wpa_supplicant]='https://w1.fi/releases/wpa_supplicant-2.12.tar.gz'; SHA[wpa_supplicant]='08e23937e16d0155e55cab2b51f51fbe10d80a1aa91c4e15442645059b737ef6'
VERSION[libndp]='1.9'; URL[libndp]='https://deb.debian.org/debian/pool/main/libn/libndp/libndp_1.9.orig.tar.gz'; SHA[libndp]='e564f5914a6b1b799c3afa64c258824a801c1b79a29e2fe6525b682249c65261'
VERSION[NetworkManager]='1.58.1'; URL[NetworkManager]='https://gitlab.freedesktop.org/NetworkManager/NetworkManager/-/releases/1.58.1/downloads/NetworkManager-1.58.1.tar.xz'; SHA[NetworkManager]='262864cfd198123d3e5dbe91937441b97ee9059d6d712e1a5bfbb1c54668d14d'
VERSION[libsecret]='0.21.7'; URL[libsecret]='https://download.gnome.org/sources/libsecret/0.21/libsecret-0.21.7.tar.xz'; SHA[libsecret]='6b452e4750590a2b5617adc40026f28d2f4903de15f1250e1d1c40bfd68ed55e'
VERSION[libnma]='1.10.6'; URL[libnma]='https://download.gnome.org/sources/libnma/1.10/libnma-1.10.6.tar.xz'; SHA[libnma]='53a6fb2b190ad37c5986caed3e98bede7c3c602399ee4f93c8fc054303d76dab'
VERSION[network-manager-applet]='1.36.0'; URL[network-manager-applet]='https://download.gnome.org/sources/network-manager-applet/1.36/network-manager-applet-1.36.0.tar.xz'; SHA[network-manager-applet]='a84704487ea3afe1485c47fb2ab598b8f779f540ae0dcbf0a1c5f85e64a7e253'
VERSION[libmnl]='1.0.5'; URL[libmnl]='https://netfilter.org/pub/libmnl/libmnl-1.0.5.tar.bz2'; SHA[libmnl]='274b9b919ef3152bfb3da3a13c950dd60d6e2bcd54230ffeca298d03b40d0525'
VERSION[libnftnl]='1.3.2'; URL[libnftnl]='https://netfilter.org/pub/libnftnl/libnftnl-1.3.2.tar.xz'; SHA[libnftnl]='c97abc3409f8fa396b4462b2bb7f147a3a47a4ddc97cfa0b2f18890c9cfde8b0'
VERSION[libnotify]='0.8.6'; URL[libnotify]='https://download.gnome.org/sources/libnotify/0.8/libnotify-0.8.6.tar.xz'; SHA[libnotify]='c5540aaefb60e1d63b1c587c05f2284ebe72ece7d0c0e5e4a778cfd5844b6b58'
VERSION[libsoup]='2.74.3'; URL[libsoup]='https://download.gnome.org/sources/libsoup/2.74/libsoup-2.74.3.tar.xz'; SHA[libsoup]='e4b77c41cfc4c8c5a035fcdc320c7bc6cfb75ef7c5a034153df1413fa1d92f13'
VERSION[mate-common]='1.28.0'; URL[mate-common]='https://pub.mate-desktop.org/releases/1.28/mate-common-1.28.0.tar.xz'; SHA[mate-common]='42b7c2cee268f71d7e1c1ad4f69bcda0ecd65578a96722187c6b76378d26ba0a'
VERSION[mate-desktop]='1.28.2'; URL[mate-desktop]='https://pub.mate-desktop.org/releases/1.28/mate-desktop-1.28.2.tar.xz'; SHA[mate-desktop]='32bb4b792014b391c1e1b8ae9c18a82b4d447650984b4cba7d28e95564964aa2'
VERSION[mate-menus]='1.28.0'; URL[mate-menus]='https://pub.mate-desktop.org/releases/1.28/mate-menus-1.28.0.tar.xz'; SHA[mate-menus]='cf40c75c7d6f0aad1d4969828fc62025c6222bc6a84f0bb9d6ead7e45970508d'
VERSION[libmatekbd]='1.28.0'; URL[libmatekbd]='https://pub.mate-desktop.org/releases/1.28/libmatekbd-1.28.0.tar.xz'; SHA[libmatekbd]='5d2e58483c2b23d33503d24c88f8b90a28cc0189d7e4001b3e273a604f6fe80e'
VERSION[marco]='1.28.1'; URL[marco]='https://pub.mate-desktop.org/releases/1.28/marco-1.28.1.tar.xz'; SHA[marco]='2496e5e40ee980cd6849493ac3e0f8fd0dec8b81c674da8d9ba19a577f0ac2e1'
VERSION[mate-session-manager]='1.28.0'; URL[mate-session-manager]='https://pub.mate-desktop.org/releases/1.28/mate-session-manager-1.28.0.tar.xz'; SHA[mate-session-manager]='d32ce4595ba1da65290777203f2bc82bd973b214a3a04080a1ef5c68990a2d7b'
VERSION[mate-settings-daemon]='1.28.0'; URL[mate-settings-daemon]='https://pub.mate-desktop.org/releases/1.28/mate-settings-daemon-1.28.0.tar.xz'; SHA[mate-settings-daemon]='4ed7cdadaaa4c99efffc0282b8411703bb76e072c41c4b57989f8c5b40611a3a'
VERSION[mate-panel]='1.28.4'; URL[mate-panel]='https://pub.mate-desktop.org/releases/1.28/mate-panel-1.28.4.tar.xz'; SHA[mate-panel]='02f09eb0314c2ac197b6f089950a571cdba39bfd03d6c3a0b8fd77252a968874'
VERSION[caja]='1.28.0'; URL[caja]='https://pub.mate-desktop.org/releases/1.28/caja-1.28.0.tar.xz'; SHA[caja]='1e3014ce1455817ec2ef74d09efdfb6835d8a372ed9a16efb5919ef7b821957a'
VERSION[mate-notification-daemon]='1.28.3'; URL[mate-notification-daemon]='https://pub.mate-desktop.org/releases/1.28/mate-notification-daemon-1.28.3.tar.xz'; SHA[mate-notification-daemon]='e00cecb1ff9f75b9ccc2644558e44343b80941edb40377dd8100ed3922adf413'
VERSION[mate-icon-theme]='1.28.0'; URL[mate-icon-theme]='https://pub.mate-desktop.org/releases/1.28/mate-icon-theme-1.28.0.tar.xz'; SHA[mate-icon-theme]='94d6079060ca5df74542921de4eea38b7d02d07561c919356d95de876f9a6d3a'
VERSION[libmateweather]='1.28.0'; URL[libmateweather]='https://pub.mate-desktop.org/releases/1.28/libmateweather-1.28.0.tar.xz'; SHA[libmateweather]='554373deb5b393b9d84b275dd2ca66c9a4a2d0e6ec92044fab8aa53e3032d2b5'
VERSION[pluma]='1.28.0'; URL[pluma]='https://pub.mate-desktop.org/releases/1.28/pluma-1.28.0.tar.xz'; SHA[pluma]='aa8adf9589345093a50e30b27ede4a78a2421d1727c27f465fc87c435965a1d4'
VERSION[engrampa]='1.28.2'; URL[engrampa]='https://pub.mate-desktop.org/releases/1.28/engrampa-1.28.2.tar.xz'; SHA[engrampa]='1e9977c23745bf8843a37f315171d9af97814a0971aeac3d774f017650ac09ef'
VERSION[eom]='1.28.1'; URL[eom]='https://github.com/mate-desktop/eom/releases/download/v1.28.1/eom-1.28.1.tar.xz'; SHA[eom]='ccc169b8e240828b36965dfd84fa1478957dec2028ffeba553ae97e542e15120'
VERSION[libexif]='0.6.26'; URL[libexif]='https://github.com/libexif/libexif/releases/download/v0.6.26/libexif-0.6.26.tar.bz2'; SHA[libexif]='0830ed253fceeb60444fb309598bc8a9491d3007dc054aad3a50a347c5597c57'
VERSION[mate-control-center]='1.28.2'; URL[mate-control-center]='https://github.com/mate-desktop/mate-control-center/releases/download/v1.28.2/mate-control-center-1.28.2.tar.xz'; SHA[mate-control-center]='6ca6205e6f89502c76bd73c2355a8ef9e3f60e478895820b94be6dde739cc798'
VERSION[mate-power-manager]='1.28.1'; URL[mate-power-manager]='https://pub.mate-desktop.org/releases/1.28/mate-power-manager-1.28.1.tar.xz'; SHA[mate-power-manager]='8ebdcb74b607e868336ba9a8146cdef8f97bce535c2b0cb3bf650c58f71eee21'
VERSION[mate-polkit]='1.28.1'; URL[mate-polkit]='https://pub.mate-desktop.org/releases/1.28/mate-polkit-1.28.1.tar.xz'; SHA[mate-polkit]='350a1dd0a8ed6a2c9c183cff2a21f394299e968fcc6ae2e8c93c565dae604ae8'
VERSION[polkit]='127'; URL[polkit]='https://github.com/polkit-org/polkit/archive/127/polkit-127.tar.gz'; SHA[polkit]='9b7bc16f086479dcc626c575976568ba4a85d34297a750d8ab3d2e57f6d8b988'
VERSION[duktape]='2.7.0'; URL[duktape]='https://duktape.org/duktape-2.7.0.tar.xz'; SHA[duktape]='90f8d2fa8b5567c6899830ddef2c03f3c27960b11aca222fa17aa7ac613c2890'
VERSION[libgtop]='2.41.3'; URL[libgtop]='https://download.gnome.org/sources/libgtop/2.41/libgtop-2.41.3.tar.xz'; SHA[libgtop]='775676df958e2ea2452f7568f28b2ea581063d312773dd5c0b7624c1b9b2da8c'
VERSION[libXScrnSaver]='1.2.4'; URL[libXScrnSaver]='https://www.x.org/releases/individual/lib/libXScrnSaver-1.2.4.tar.xz'; SHA[libXScrnSaver]='75cd2859f38e207a090cac980d76bc71e9da99d48d09703584e00585abc920fe'
VERSION[librsvg]='2.60.0'; URL[librsvg]='https://download.gnome.org/sources/librsvg/2.60/librsvg-2.60.0.tar.xz'; SHA[librsvg]='0b6ffccdf6e70afc9876882f5d2ce9ffcf2c713cbaaf1ad90170daa752e1eec3'
VERSION[libblockdev]='3.5.0'; URL[libblockdev]='https://github.com/storaged-project/libblockdev/releases/download/3.5.0/libblockdev-3.5.0.tar.gz'; SHA[libblockdev]='bccd30e6b5d11504de60d9889ff6a2a25b07a4ec8f04070f2387e168301b3e3a'
VERSION[udisks]='2.11.2'; URL[udisks]='https://github.com/storaged-project/udisks/releases/download/udisks-2.11.2/udisks-2.11.2.tar.bz2'; SHA[udisks]='18630a8aad806bea0bc626ce97e71e50ec82c742956ac1c834a4275f8f22207b'
VERSION[libusb]='1.0.30'; URL[libusb]='https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2'; SHA[libusb]='fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf'
VERSION[libgudev]='238'; URL[libgudev]='https://download.gnome.org/sources/libgudev/238/libgudev-238.tar.xz'; SHA[libgudev]='61266ab1afc9d73dbc60a8b2af73e99d2fdff47d99544d085760e4fa667b5dd1'
VERSION[upower]='1.90.9'; URL[upower]='https://gitlab.freedesktop.org/upower/upower/-/archive/v1.90.9/upower-v1.90.9.tar.bz2'; SHA[upower]='ca6018535817c2ea687e389e6b47583342154123c0eea0497b409c49dff319b6'
VERSION[libatasmart]='0.19'; URL[libatasmart]='https://0pointer.de/public/libatasmart-0.19.tar.xz'; SHA[libatasmart]='61f0ea345f63d28ab2ff0dc352c22271661b66bf09642db3a4049ac9dbdb0f8d'
VERSION[gtksourceview4]='4.8.4'; URL[gtksourceview4]='https://download.gnome.org/sources/gtksourceview/4.8/gtksourceview-4.8.4.tar.xz'; SHA[gtksourceview4]='7ec9d18fb283d1f84a3a3eff3b7a72b09a10c9c006597b3fbabbb5958420a87d'
VERSION[libpeas]='1.36.0'; URL[libpeas]='https://download.gnome.org/sources/libpeas/1.36/libpeas-1.36.0.tar.xz'; SHA[libpeas]='297cb9c2cccd8e8617623d1a3e8415b4530b8e5a893e3527bbfd1edd13237b4c'
VERSION[nettle]='4.0'; URL[nettle]='https://ftp.gnu.org/gnu/nettle/nettle-4.0.tar.gz'; SHA[nettle]='3addbc00da01846b232fb3bc453538ea5468da43033f21bb345cb1e9073f5094'
VERSION[gnutls]='3.8.13'; URL[gnutls]='https://gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz'; SHA[gnutls]='ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e'

# Show the complete stage plan before work starts. On short terminals the live
# table follows the active page; the final full table remains in scrollback.
progress_start() {
    exec 3>&1
    UI_TOTAL=$1 UI_LOG=$2; shift 2
    UI_LABELS=("$@") UI_STATES=() UI_ELAPSED=() UI_EXPECTED=() UI_STAGE_KEYS=()
    local index
    for ((index=0;index<UI_TOTAL;index++)); do
        UI_LABELS[index]=${UI_LABELS[index]:-"$(tr_text 'Stage' 'Etapas') $((index+1))"}
        UI_STATES[index]=waiting; UI_ELAPSED[index]=0
    done
    UI_ACTIVE=yes UI_DONE=0 UI_INDEX=-1 UI_PID='' UI_ROW_ACTIVE=no UI_SESSION_START=$SECONDS
    UI_TTY=no UI_DIRECT_TTY=no UI_TICK=0 UI_STAGE_TIME=$SECONDS UI_NEEDS_FULL=yes
    UI_WIDTH=0 UI_HEIGHT=0 UI_PAGE=-1 UI_VIEW_START=0 UI_FOLLOW=yes
    UI_KEY_BUFFER='' UI_SCREEN_ACTIVE=no UI_INPUT_FD='' UI_TTY_SETTINGS=''
    UI_LAST_HEADER='' UI_LAST_FOOTER=''
    mkdir -p "$(dirname "$UI_LOG")"; touch "$UI_LOG"
    progress_load_timings
    if [[ ! -t 3 && ${TERM:-dumb} != dumb ]] && { exec 3>/dev/tty; } 2>/dev/null; then
        # stdout may be piped through tee (for example by the matrix runner).
        # Draw on the controlling terminal instead of scrolling progress lines.
        UI_DIRECT_TTY=yes
    fi
    [[ ! -t 3 || ${TERM:-dumb} == dumb ]] || UI_TTY=yes
    trap 'progress_stop' EXIT
    trap 'progress_interrupt' INT TERM
    trap 'UI_NEEDS_FULL=yes' WINCH
    if [[ "$UI_TTY" == yes ]]; then
        # Read keys without kernel echo corrupting the full-screen table. Keep
        # ISIG enabled so Ctrl+C still takes the normal interrupt/cleanup path.
        if exec {UI_INPUT_FD}<>/dev/tty &&
           UI_TTY_SETTINGS=$(stty -g <&"$UI_INPUT_FD") &&
           stty -echo -icanon min 1 time 0 <&"$UI_INPUT_FD"; then
            printf '\033[?1049h\033[?25l\033[?6l\033[r' >&3
            UI_SCREEN_ACTIVE=yes
            progress_render
        else
            progress_restore_terminal
            UI_TTY=no
        fi
    fi
    if [[ "$UI_TTY" != yes ]]; then
        # A pipe/log cannot redraw earlier rows: emit the whole plan once.
        for ((index=0;index<UI_TOTAL;index++)); do
            progress_row "$index"; printf '%s\n' "$UI_TEXT" >&3
        done
    fi
}

# Timings are data, never sourced. Successful measured stages are shared by
# matching configurations in this work directory; skipped/failed runs do not train ETA.
progress_duration() {
    local seconds=$1
    if (( seconds >= 3600 )); then
        printf -v UI_TIME_TEXT '%dh %02dm %02ds' "$((seconds/3600))" "$((seconds/60%60))" "$((seconds%60))"
    else printf -v UI_TIME_TEXT '%dm %02ds' "$((seconds/60))" "$((seconds%60))"; fi
}

progress_timing_key() {
    local label=${1%% | *}
    case "$label" in
        'System configuration'|'Sistemos konfigūracija') label=configure-system ;;
        'Package configuration'|'Paketų konfigūracija') label=configure-packages ;;
        'User and sudoers'|'Vartotojas ir sudoers') label=configure-user ;;
        'Desktop configuration'|'Darbalaukio konfigūracija') label=configure-desktop ;;
        'Packaging images'|'Atvaizdų pakavimas') label=pack-images ;;
    esac
    UI_TIMING_KEY="$UI_TIMING_CONTEXT:$label"
}

progress_load_timings() {
    UI_TIMING_FILE="$UI_LOG.timings.tsv"
    # Custom/test log paths stay self-contained; real profiles share timings.
    if [[ "$UI_LOG" == "${WORK_DIR:-}/"* && -n ${WORK_DIR:-} ]]; then
        UI_TIMING_FILE="$WORK_DIR/stage-times.tsv"
    fi
    UI_TIMING_CONTEXT=$(printf '%s\n' "${TARGET_ARCH:-}:${TOOLS_CHOICE:-}:${SHELL_CHOICE:-}:${INIT_CHOICE:-}:${PACKAGE_MANAGER:-}:${DESKTOP_CHOICE:-}:${WITH_GCC:-}:${BOOT_CHOICE:-}:${JOBS:-}:${VERSION[gcc]:-}:${VERSION[glibc]:-}" | sha256sum)
    UI_TIMING_CONTEXT=${UI_TIMING_CONTEXT%% *}
    local key seconds extra index
    local -A history=()
    if [[ -r "$UI_TIMING_FILE" && -f "$UI_TIMING_FILE" ]]; then
        while IFS=$'\t' read -r key seconds extra; do
            [[ "$key" == "$UI_TIMING_CONTEXT:"* && "$seconds" =~ ^[1-9][0-9]{0,7}$ && -z "$extra" ]] || continue
            history["$key"]=$seconds
        done < "$UI_TIMING_FILE"
    fi
    for ((index=0;index<UI_TOTAL;index++)); do
        progress_timing_key "${UI_LABELS[index]}"
        UI_STAGE_KEYS[index]=$UI_TIMING_KEY
        UI_EXPECTED[index]=${history["$UI_TIMING_KEY"]:-0}
    done
}

progress_save_timing() {
    [[ ${UI_STAGE_CACHED:-no} != yes ]] || return 0
    local elapsed=${UI_ELAPSED[UI_INDEX]}
    (( elapsed > 0 )) || elapsed=1
    # Cache failure must not abort a successful build. A bounded lock lets
    # independent profiles append complete records without mixing them.
    if (flock -w 1 7 && printf '%s\t%s\n' "${UI_STAGE_KEYS[UI_INDEX]}" "$elapsed" >&7) 2>> "$UI_LOG" 7>> "$UI_TIMING_FILE"; then :
    else printf 'Timing cache could not be updated: %s\n' "$UI_TIMING_FILE" >> "$UI_LOG" || :; fi
}

progress_summary() {
    local index expected remaining=0 unknown=0 pending=0 stopped=no elapsed_text eta
    progress_duration "$((SECONDS-UI_SESSION_START))"; elapsed_text=$UI_TIME_TEXT
    for ((index=0;index<UI_TOTAL;index++)); do
        case "${UI_STATES[index]}" in
            failed|interrupted) stopped=yes; continue ;;
            done) continue ;;
        esac
        pending=$((pending+1)); expected=${UI_EXPECTED[index]}
        if (( expected == 0 )); then unknown=$((unknown+1)); continue; fi
        if [[ "${UI_STATES[index]}" == running ]]; then
            expected=$((expected-UI_ELAPSED[index]))
            # An overrun is unknown, never "0 remaining" while still compiling.
            if (( expected <= 0 )); then unknown=$((unknown+1)); continue; fi
        fi
        remaining=$((remaining+expected))
    done
    UI_ETA_SECONDS=$remaining UI_ETA_UNKNOWN=$unknown
    progress_duration "$remaining"
    if [[ "$stopped" == yes ]]; then eta="$(tr_text 'stopped' 'sustabdyta')"
    elif (( pending == 0 )); then
        if (( UI_DONE == UI_TOTAL )); then eta=$UI_TIME_TEXT
        else eta="$(tr_text 'stopped' 'sustabdyta')"; fi
    elif (( unknown == 0 )); then eta="~$UI_TIME_TEXT"
    elif (( remaining > 0 )); then eta="~$UI_TIME_TEXT + ?"
    else eta="$(tr_text 'learning' 'renkami duomenys')"; fi
    UI_SUMMARY="$(tr_text "$UI_DONE / $UI_TOTAL complete | Elapsed: $elapsed_text | ETA: $eta" "$UI_DONE / $UI_TOTAL baigta | Praėjo: $elapsed_text | Liko: $eta")"
}

progress_restore_terminal() {
    if [[ -n ${UI_INPUT_FD:-} ]]; then
        [[ -z ${UI_TTY_SETTINGS:-} ]] || stty "$UI_TTY_SETTINGS" <&"$UI_INPUT_FD" 2>/dev/null || :
        exec {UI_INPUT_FD}>&-
        UI_INPUT_FD='' UI_TTY_SETTINGS=''
    fi
}

progress_input() {
    local key='' tail='' action='' count=0
    # The bounded wait replaces sleep while building. Drain queued keys in a
    # batch, including multiple and split escape sequences from held arrows.
    if IFS= read -r -s -N 1 -t "${1:-0.5}" -u "$UI_INPUT_FD" key; then
        UI_KEY_BUFFER+=$key
        while (( count < 256 )); do
            if IFS= read -r -s -N 1 -t 0.001 -u "$UI_INPUT_FD" tail; then
                UI_KEY_BUFFER+=$tail; count=$((count+1))
            else break; fi
        done
    fi
    local page_size=$((UI_HEIGHT>2 ? UI_HEIGHT-2 : 1))
    while [[ -n "$UI_KEY_BUFFER" ]]; do
        action=''
        case "$UI_KEY_BUFFER" in
            $'\e[A'*|$'\eOA'*) action=up; UI_KEY_BUFFER=${UI_KEY_BUFFER:3} ;;
            $'\e[B'*|$'\eOB'*) action=down; UI_KEY_BUFFER=${UI_KEY_BUFFER:3} ;;
            $'\e[C'*|$'\eOC'*) action=next; UI_KEY_BUFFER=${UI_KEY_BUFFER:3} ;;
            $'\e[D'*|$'\eOD'*) action=previous; UI_KEY_BUFFER=${UI_KEY_BUFFER:3} ;;
            $'\e[5~'*) action=previous; UI_KEY_BUFFER=${UI_KEY_BUFFER:4} ;;
            $'\e[6~'*) action=next; UI_KEY_BUFFER=${UI_KEY_BUFFER:4} ;;
            $'\e[H'*|$'\eOH'*) action=home; UI_KEY_BUFFER=${UI_KEY_BUFFER:3} ;;
            $'\e[F'*|$'\eOF'*) action=end; UI_KEY_BUFFER=${UI_KEY_BUFFER:3} ;;
            $'\e[1~'*|$'\e[7~'*) action=home; UI_KEY_BUFFER=${UI_KEY_BUFFER:4} ;;
            $'\e[4~'*|$'\e[8~'*) action=end; UI_KEY_BUFFER=${UI_KEY_BUFFER:4} ;;
            $'\e'|$'\e['|$'\eO'|$'\e[1'|$'\e[4'|$'\e[5'|$'\e[6'|$'\e[7'|$'\e[8') break ;;
            f*|F*) action=follow; UI_KEY_BUFFER=${UI_KEY_BUFFER:1} ;;
            *) UI_KEY_BUFFER=${UI_KEY_BUFFER:1} ;;
        esac
        case "$action" in
            up) UI_VIEW_START=$((UI_VIEW_START-1)); UI_FOLLOW=no ;;
            down) UI_VIEW_START=$((UI_VIEW_START+1)); UI_FOLLOW=no ;;
            previous) UI_VIEW_START=$((UI_VIEW_START-page_size)); UI_FOLLOW=no ;;
            next) UI_VIEW_START=$((UI_VIEW_START+page_size)); UI_FOLLOW=no ;;
            home) UI_VIEW_START=0; UI_FOLLOW=no ;;
            end) UI_VIEW_START=$((UI_TOTAL-page_size)); UI_FOLLOW=no ;;
            follow) UI_FOLLOW=yes ;;
        esac
        [[ -z "$action" ]] || UI_NEEDS_FULL=yes
    done
}

progress_begin() {
    UI_INDEX=$UI_DONE
    (( UI_INDEX < UI_TOTAL )) || die "$(tr_text 'Progress plan has fewer stages than execution' 'Progreso plane mažiau etapų negu vykdoma')"
    UI_LABELS[UI_INDEX]=$1; UI_STATES[UI_INDEX]=running; UI_ELAPSED[UI_INDEX]=0
    UI_STAGE_TIME=$SECONDS UI_TICK=0 UI_ROW_ACTIVE=yes UI_NEEDS_FULL=yes
    UI_STAGE_CACHED=${2:-no}
    progress_draw
}

progress_row() {
    local index=$1 bar='--------------------' percent=0 suffix='' elapsed_text position
    UI_COLOR=$C_INFO
    printf -v elapsed_text '%dm %02ds' "$((UI_ELAPSED[index]/60))" "$((UI_ELAPSED[index]%60))"
    case "${UI_STATES[index]}" in
        done) bar='####################'; percent=100; UI_COLOR=$C_OK ;;
        waiting) suffix="$(tr_text ' (waiting)' ' (laukia)')" ;;
        failed) percent='--'; UI_COLOR=$C_ERROR; suffix="$(tr_text ' - failed' ' — klaida')" ;;
        interrupted) percent='--'; UI_COLOR=$C_ERROR; suffix="$(tr_text ' - interrupted' ' — nutraukta')" ;;
        running)
            # make has no reliable percentage for a complete build stage.
            percent='--'; position=$((UI_TICK%20))
            bar="${bar:0:position}#${bar:position+1}" ;;
    esac
    UI_TEXT="[$bar] $percent% / $elapsed_text | ${UI_LABELS[index]}$suffix"
}

progress_render() {
    local rows=24 columns=80 page_size page start end index row
    if read -r rows columns < <(stty size <&"$UI_INPUT_FD" 2>/dev/null); then :; fi
    [[ "$rows" =~ ^[1-9][0-9]*$ ]] || rows=24
    [[ "$columns" =~ ^[1-9][0-9]*$ ]] || columns=80
    page_size=$((rows>2 ? rows-2 : 1))
    if [[ "$UI_FOLLOW" == yes ]]; then
        page=$(((UI_INDEX<0 ? 0 : UI_INDEX)/page_size))
        start=$((page*page_size))
    else
        start=$UI_VIEW_START
        (( start >= 0 )) || start=0
        local last=$((UI_TOTAL>page_size ? UI_TOTAL-page_size : 0))
        (( start <= last )) || start=$last
    fi
    UI_VIEW_START=$start
    page=$start; end=$((start+page_size))
    (( end <= UI_TOTAL )) || end=$UI_TOTAL
    if (( rows != UI_HEIGHT || columns != UI_WIDTH || page != UI_PAGE )); then UI_NEEDS_FULL=yes; fi
    UI_WIDTH=$columns UI_HEIGHT=$rows UI_PAGE=$page
    progress_summary
    local header=$UI_SUMMARY
    local footer="$(tr_text "Stages $((start+1))-$end / $UI_TOTAL | Up/Down PgUp/PgDn | F: follow" "Etapai $((start+1))-$end / $UI_TOTAL | Rodyklės PgUp/PgDn | F: sekti")"
    if (( rows < 3 )); then
        progress_row "$((UI_INDEX<0 ? 0 : UI_INDEX))"
        printf '\033[H\033[2J%s%s%s\033[H' "$UI_COLOR" "${UI_TEXT:0:columns-1}" "$C_RESET" >&3
        UI_NEEDS_FULL=no
        return 0
    fi
    [[ "$UI_NEEDS_FULL" != yes ]] || printf '\033[H\033[2J' >&3
    if [[ "$UI_NEEDS_FULL" == yes || "$header" != "$UI_LAST_HEADER" ]]; then
        printf '\033[1;1H\033[2K%s' "${header:0:columns-1}" >&3
    fi
    for ((index=start;index<end;index++)); do
        if [[ "$UI_NEEDS_FULL" == yes || "$index" == "$UI_INDEX" ]]; then
            progress_row "$index"; row=$((index-start+2))
            printf '\033[%d;1H\033[2K%s%s%s' "$row" "$UI_COLOR" "${UI_TEXT:0:columns-1}" "$C_RESET" >&3
        fi
    done
    row=$((end-start+2)); (( row <= rows )) || row=$rows
    if [[ "$UI_NEEDS_FULL" == yes || "$footer" != "$UI_LAST_FOOTER" ]]; then
        printf '\033[%d;1H\033[2K%s' "$row" "${footer:0:columns-1}" >&3
    fi
    # Do not leave the cursor at the end of the footer (near the scroll edge).
    printf '\033[H' >&3
    UI_LAST_HEADER=$header UI_LAST_FOOTER=$footer UI_NEEDS_FULL=no
}

progress_draw() {
    [[ ${UI_ROW_ACTIVE:-no} == yes ]] || return 0
    UI_ELAPSED[UI_INDEX]=$((SECONDS-UI_STAGE_TIME)); UI_TICK=$((UI_TICK+1))
    if [[ "$UI_TTY" == yes ]]; then progress_render
    else
        progress_row "$UI_INDEX"; printf '%s\n' "$UI_TEXT" >&3
        progress_summary; printf '%s\n' "$UI_SUMMARY" >&3
    fi
}

progress_finish() {
    [[ ${UI_ROW_ACTIVE:-no} == yes ]] || return 0
    UI_STATES[UI_INDEX]=$1
    progress_draw
    [[ "$1" != done ]] || progress_save_timing
    UI_ROW_ACTIVE=no
}

progress_stop() {
    [[ ${UI_ACTIVE:-no} == yes ]] || return 0
    progress_finish interrupted
    progress_restore_terminal
    if [[ "${UI_SCREEN_ACTIVE:-no}" == yes ]]; then
        printf '\033[?25h\033[?1049l' >&3
        UI_SCREEN_ACTIVE=no
        local index
        for ((index=0;index<UI_TOTAL;index++)); do
            progress_row "$index"; printf '%s%s%s\n' "$UI_COLOR" "$UI_TEXT" "$C_RESET" >&3
        done
        progress_summary; printf '%s\n' "$UI_SUMMARY" >&3
    fi
    trap - WINCH
    UI_ACTIVE=no
}

stop_process_tree() {
    local pid=$1 child
    # Kompiliatoriai ir make nutraukiami kartu su etapo Bash procesu.
    while read -r child; do
        [[ -z "$child" ]] || stop_process_tree "$child"
    done < <(ps -o pid= --ppid "$pid" 2>/dev/null)
    kill -TERM "$pid" 2>/dev/null || :
}

progress_interrupt() {
    trap '' INT TERM
    [[ -z ${UI_PID:-} ]] || stop_process_tree "$UI_PID"
    progress_stop
    printf "$(tr_text '\nBuild interrupted. Log: %s\n' '\nDarbas nutrauktas. Žurnalas: %s\n')" "$UI_LOG" >&3
    exit 130
}

run_quiet() {
    local label=$1; shift
    # Patikros, kurios tiesiogiai kviečia step(), išlieka be UI šalutinių veiksmų.
    if [[ ${UI_ACTIVE:-no} != yes ]]; then "$@"; return; fi
    progress_begin "$label"
    local offset status=0
    offset=$(wc -l < "$UI_LOG")
    printf '\n== %s ==\n' "$label" >> "$UI_LOG"
    # Funkcija kviečiama ne if sąlygoje: errexit veikia ir jos viduje.
    (trap - EXIT INT TERM WINCH; exec 8>&-; "$@") >> "$UI_LOG" 2>&1 &
    UI_PID=$!
    while kill -0 "$UI_PID" 2>/dev/null; do
        if [[ "$UI_TTY" == yes ]]; then
            progress_input 0.5
            progress_draw
        else
            # Matrix runners and redirected logs pipe stdout through tee, so
            # they cannot use the interactive redraw path. Emit a fresh live
            # row periodically instead of leaving the initial 0% snapshot up
            # for the whole compilation stage.
            sleep 1 || :
            progress_draw
        fi
    done
    if wait "$UI_PID"; then status=0; else status=$?; fi
    UI_PID=''
    if (( status != 0 )); then
        progress_finish failed
        progress_stop
        printf "$(tr_text '\n%sStage failed: %s (status %s).%s\n' '\n%sKlaida etape „%s“ (kodas %s).%s\n')" "$C_ERROR" "$label" "$status" "$C_RESET" >&3
        # Tik šio bandymo klaidos; visas kompiliavimo tekstas lieka žurnale.
        local errors
        errors=$(tail -n "+$((offset+1))" "$UI_LOG" | grep -iE '(^|[[:space:]:])(fatal[[:space:]]+)?error([[:space:]:]|$)|relocation|cannot find|undefined reference|failed to set|unable to copy|Permission denied|killed|make.*\*\*\*|curl:[[:space:]]*\([0-9]+\)|^Klaida|trūksta|nesutampa|nepavyko' | tail -n 15) || :
        [[ -z "$errors" ]] || printf '%s%s%s\n' "$C_ERROR" "$errors" "$C_RESET" >&3
        if memory_failure_in_log "$UI_LOG"; then suggest_swap_command >&3; fi
        printf "$(tr_text 'Full log: %s\n' 'Visas žurnalas: %s\n')" "$UI_LOG" >&3
        # The live screen may bypass stdout when a tee/matrix pipeline is used;
        # still copy the failure summary to the captured stderr stream.
        if [[ "$UI_DIRECT_TTY" == yes && ! -t 2 ]]; then
            printf "$(tr_text 'Stage failed: %s (status %s).\n' 'Klaida etape „%s“ (kodas %s).\n')" "$label" "$status" >&2
            [[ -z "$errors" ]] || printf '%s\n' "$errors" >&2
            if memory_failure_in_log "$UI_LOG"; then suggest_swap_command >&2; fi
            printf "$(tr_text 'Full log: %s\n' 'Visas žurnalas: %s\n')" "$UI_LOG" >&2
        fi
        # Klaida jau paaiškinta; exit išvengia klaidinančio ERR apie return.
        exit "$status"
    fi
    UI_DONE=$((UI_DONE+1))
    progress_finish done
}

say() { printf '\n%s== %s ==%s\n' "$C_INFO" "$*" "$C_RESET"; }
die() {
    if [[ ${UI_ACTIVE:-no} == yes && $BASHPID == $$ ]]; then progress_stop; fi
    printf "$(tr_text '%sError: %s%s\n' '%sKlaida: %s%s\n')" "$C_ERROR" "$*" "$C_RESET" >&2
    exit 1
}

# Update GitHub release assets with their published SHA-256, and official GNU
# releases with a valid GPG signature from the GNU keyring. Other sources stay pinned.
update_source_versions() {
    local script_path pending pending_base
    script_path=$(realpath -e -- "${BASH_SOURCE[0]}") || die "$(tr_text 'Cannot resolve the builder script path' 'Nepavyko nustatyti kūrimo scenarijaus kelio')"
    [[ -f "$script_path" && -w "$script_path" ]] || die "$(tr_text 'The builder script must be a writable regular file to update source pins' 'Norint atnaujinti šaltinių versijas, scenarijus turi būti įprastas rašomas failas')"
    pending=$(session_pointer)
    if [[ -f "$pending" ]]; then
        IFS= read -r pending_base < "$pending" || pending_base=''
        if [[ -n "$pending_base" && -f "$pending_base/build.session" && ! -f "$pending_base/build.complete" ]]; then
            die "$(tr_text 'Finish or discard the unfinished build before updating source pins; its saved stages use the current source versions.' 'Prieš atnaujindamas šaltinių versijas užbaik arba atsisakyk nebaigto kūrimo; jo išsaugoti etapai naudoja dabartines versijas.')"
        fi
    fi
    command -v python3 >/dev/null 2>&1 || die "$(tr_text 'The --update command requires Python 3' '--update komandai reikia Python 3')"
    python3 - "$script_path" "$WORK_DIR" <<'PY'
import hashlib
from html.parser import HTMLParser
import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

script = Path(sys.argv[1])
work = Path(sys.argv[2]).expanduser().resolve()
cache = work / "downloads"
cache.mkdir(parents=True, exist_ok=True)
text = script.read_text(encoding="utf-8")
line_re = re.compile(
    r"^VERSION\[([^]]+)\]='([^']*)'; URL\[\1\]='([^']*)'; SHA\[\1\]='([0-9a-f]{64})'$",
    re.MULTILINE,
)

def get_json(url):
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "DIY-Linux-source-updater",
    })
    with urllib.request.urlopen(req, timeout=25) as response:
        if not response.geturl().startswith("https://api.github.com/"):
            raise ValueError("API redirected outside api.github.com")
        return json.load(response)

def safe_shell(value):
    if not value or any(c in value for c in "'\n\r"):
        raise ValueError("value cannot be represented in the pinned shell manifest")
    return value

class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.values = []
    def handle_starttag(self, tag, attrs):
        if tag.lower() == "a":
            self.values.extend(value for key, value in attrs if key.lower() == "href" and value)

def gnu_request(url, output=None):
    request = urllib.request.Request(url, headers={"User-Agent": "DIY-Linux-source-updater"})
    with urllib.request.urlopen(request, timeout=45) as response:
        final = urllib.parse.urlsplit(response.geturl())
        host = (final.hostname or "").lower()
        if final.scheme != "https" or not (host == "gnu.org" or host.endswith(".gnu.org")):
            raise ValueError("GNU request redirected outside trusted HTTPS *.gnu.org")
        if output is None:
            return response.read().decode("utf-8", errors="replace")
        digest = hashlib.sha256()
        with output.open("wb") as stream:
            while True:
                block = response.read(1024 * 1024)
                if not block:
                    break
                stream.write(block)
                digest.update(block)
        return digest.hexdigest()

def gnu_links(url):
    parser = Links()
    parser.feed(gnu_request(url))
    return [urllib.parse.unquote(value) for value in parser.values]

def version_key(value):
    return tuple((0, int(part)) if part.isdigit() else (1, part.lower())
                 for part in re.findall(r"[0-9]+|[^0-9]+", value))

gnu_keyring_ready = False

def gnu_latest(name, old_version, old_url, old_sha):
    global gnu_keyring_ready
    parsed = urllib.parse.urlsplit(old_url)
    if parsed.netloc != "ftp.gnu.org" or not parsed.path.startswith("/gnu/"):
        raise ValueError("not an official ftp.gnu.org archive")
    parts = parsed.path.strip("/").split("/")
    if len(parts) < 3:
        raise ValueError("unrecognized GNU archive path")
    package_dir = parts[1]
    old_filename = parts[-1]
    if old_version not in old_filename:
        raise ValueError("pinned GNU archive name does not contain its version")
    prefix, suffix = old_filename.split(old_version, 1)
    listing = f"https://ftp.gnu.org/gnu/{package_dir}/"
    candidates = {}
    for href in gnu_links(listing):
        leaf = href.rstrip("/").rsplit("/", 1)[-1]
        is_dir = href.endswith("/")
        if not leaf.startswith(prefix) or (not is_dir and suffix and not leaf.endswith(suffix)):
            continue
        version = leaf[len(prefix):len(leaf)-len(suffix) if suffix and not is_dir else None]
        if not re.fullmatch(r"[0-9][A-Za-z0-9.+_-]*", version):
            continue
        if re.search(r"(?i)(alpha|beta|rc|pre|preview|snapshot|test|git)", version):
            continue
        if is_dir:
            candidate_dir = urllib.parse.urljoin(listing, leaf + "/")
            archive_name = prefix + version + suffix
            try:
                nested_names = [item.rstrip("/").rsplit("/", 1)[-1] for item in gnu_links(candidate_dir)]
            except Exception:
                continue
            if archive_name not in nested_names:
                continue
            candidate_url = urllib.parse.urljoin(candidate_dir, archive_name)
        else:
            candidate_url = urllib.parse.urljoin(listing, leaf)
        candidates[version] = candidate_url
    if not candidates:
        raise ValueError("no stable matching GNU release archive found")
    new_version = max(candidates, key=version_key)
    new_url = candidates[new_version]
    if new_version == old_version and new_url == old_url:
        # The existing manifest hash already pins this exact source. Avoid
        # downloading multi-megabyte archives just to report it as current.
        return new_version, new_url, old_sha, cache / f"{name}-{new_version}.archive"

    gpgv = shutil.which("gpgv")
    if not gpgv:
        raise ValueError("gpgv is required to verify GNU release signatures")
    # Fetch the keyring once per updater run. The user has explicitly chosen
    # trusted GNU HTTPS as the keyring source.
    keyring = cache / "gnu-keyring.gpg"
    if not gnu_keyring_ready:
        keyring_tmp = cache / ".gnu-keyring.gpg.tmp"
        try:
            gnu_request("https://ftp.gnu.org/gnu/gnu-keyring.gpg", keyring_tmp)
            os.replace(keyring_tmp, keyring)
            gnu_keyring_ready = True
        finally:
            if keyring_tmp.exists():
                keyring_tmp.unlink()

    archive_fd, archive_name = tempfile.mkstemp(prefix=f".{name}.gnu.", dir=cache)
    sig_fd, sig_name = tempfile.mkstemp(prefix=f".{name}.sig.", dir=cache)
    os.close(archive_fd)
    os.close(sig_fd)
    archive_tmp, sig_tmp = Path(archive_name), Path(sig_name)
    try:
        local_sha = gnu_request(new_url, archive_tmp)
        gnu_request(new_url + ".sig", sig_tmp)
        import subprocess
        verified = subprocess.run([gpgv, "--keyring", str(keyring), str(sig_tmp), str(archive_tmp)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if verified.returncode:
            raise ValueError("GNU GPG signature verification failed: " + verified.stderr.strip())
        cached = cache / f"{name}-{new_version}.archive"
        os.replace(archive_tmp, cached)
        return new_version, new_url, local_sha, cached
    finally:
        for temporary_path in (archive_tmp, sig_tmp):
            if temporary_path.exists():
                temporary_path.unlink()

changed = []
skipped = []
unchanged = []
unsupported = []
all_matches = list(line_re.finditer(text))
github_matches = []
gnu_matches = []
for match in all_matches:
    parsed = urllib.parse.urlsplit(match.group(3))
    parts = parsed.path.split("/")
    if parsed.scheme == "https" and parsed.netloc == "github.com" and len(parts) >= 7 and parts[3:5] == ["releases", "download"]:
        github_matches.append(match)
    elif parsed.scheme == "https" and parsed.netloc == "ftp.gnu.org" and parsed.path.startswith("/gnu/"):
        gnu_matches.append(match)
    else:
        unsupported.append(match.group(1))

print(f"Source pins found: {len(all_matches)}; GitHub release checks: {len(github_matches)}; GNU signature checks: {len(gnu_matches)}; other sources: {len(unsupported)}", flush=True)
checks = sorted(
    [("GitHub", match) for match in github_matches] + [("GNU", match) for match in gnu_matches],
    key=lambda item: item[1].start(), reverse=True,
)
for index, (source_kind, match) in enumerate(checks, 1):
    name, old_version, old_url, old_sha = match.groups()
    print(f"CHECK [{index}/{len(checks)}] {source_kind} {name} {old_version}", flush=True)
    parsed = urllib.parse.urlsplit(old_url)
    parts = parsed.path.split("/")
    if source_kind == "GNU":
        try:
            new_version, new_url, new_sha, cached = gnu_latest(name, old_version, old_url, old_sha)
            if new_version == old_version and new_sha == old_sha and new_url == old_url:
                unchanged.append((name, old_version))
                continue
            safe_shell(new_version)
            safe_shell(new_url)
            replacement = (f"VERSION[{name}]='{new_version}'; URL[{name}]='{new_url}'; "
                           f"SHA[{name}]='{new_sha}'")
            text = text[:match.start()] + replacement + text[match.end():]
            changed.append((name, old_version, new_version, cached, "GPG signature"))
        except Exception as exc:
            skipped.append((name, str(exc)))
        continue
    if parsed.scheme != "https" or parsed.netloc != "github.com" or len(parts) < 7 or parts[3:5] != ["releases", "download"]:
        unsupported.append(name)
        continue
    owner, repo = parts[1], parts[2]
    old_asset = urllib.parse.unquote("/".join(parts[6:]))
    old_asset_name = old_asset.rsplit("/", 1)[-1]
    api = f"https://api.github.com/repos/{urllib.parse.quote(owner)}/{urllib.parse.quote(repo)}/releases/latest"
    try:
        release = get_json(api)
        if release.get("draft") or release.get("prerelease"):
            skipped.append((name, "latest-release endpoint returned a draft or prerelease"))
            continue
        assets = release.get("assets") or []
        has_version_in_asset = old_version in old_asset_name
        if has_version_in_asset:
            prefix, suffix = old_asset_name.split(old_version, 1)
            candidates = [a for a in assets if a.get("name", "").startswith(prefix)
                          and a.get("name", "").endswith(suffix)]
        else:
            prefix, suffix = "", ""
            candidates = [a for a in assets if a.get("name") == old_asset_name]
        if len(candidates) != 1:
            skipped.append((name, "no unique latest-release asset matches the pinned archive name"))
            continue
        asset = candidates[0]
        digest = asset.get("digest") or ""
        if not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
            skipped.append((name, "latest release asset has no official SHA-256 digest"))
            continue
        new_sha = digest.split(":", 1)[1].lower()
        new_url = asset.get("browser_download_url", "")
        new_parsed = urllib.parse.urlsplit(new_url)
        if new_parsed.scheme != "https" or new_parsed.netloc != "github.com":
            skipped.append((name, "release asset URL is not HTTPS on github.com"))
            continue
        new_asset_name = urllib.parse.unquote(new_parsed.path.rsplit("/", 1)[-1])
        if has_version_in_asset:
            new_version = new_asset_name[len(prefix):len(new_asset_name)-len(suffix) if suffix else None]
        else:
            new_version = re.sub(r"^[vV]", "", str(release.get("tag_name", "")))
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+_-]*", new_version):
            skipped.append((name, "cannot derive a safe package version from release asset/tag"))
            continue
        if new_version == old_version and new_sha == old_sha and new_url == old_url:
            unchanged.append((name, old_version))
            continue

        # Stream and hash the archive; it is accepted only if its bytes match
        # the digest published by the official GitHub Releases API.
        fd, temp_name = tempfile.mkstemp(prefix=f".{name}.update.", dir=cache)
        os.close(fd)
        temp_path = Path(temp_name)
        local_hash = hashlib.sha256()
        try:
            request = urllib.request.Request(new_url, headers={"User-Agent": "DIY-Linux-source-updater"})
            with urllib.request.urlopen(request, timeout=45) as response, temp_path.open("wb") as output:
                final_url = urllib.parse.urlsplit(response.geturl())
                final_host = final_url.hostname or ""
                if final_url.scheme != "https" or not (final_host == "github.com" or final_host.endswith(".githubusercontent.com")):
                    raise ValueError("archive redirected outside github.com over HTTPS")
                while True:
                    block = response.read(1024 * 1024)
                    if not block:
                        break
                    output.write(block)
                    local_hash.update(block)
            if local_hash.hexdigest() != new_sha:
                raise ValueError("archive bytes do not match GitHub's published SHA-256")
            cached = cache / (f"{name}-{new_version}-{new_sha[:12]}.archive" if name == "zstd"
                              else f"{name}-{new_version}.archive")
            os.replace(temp_path, cached)
        except Exception:
            if temp_path.exists():
                temp_path.unlink()
            raise

        safe_shell(new_version)
        safe_shell(new_url)
        replacement = (f"VERSION[{name}]='{new_version}'; URL[{name}]='{new_url}'; "
                       f"SHA[{name}]='{new_sha}'")
        text = text[:match.start()] + replacement + text[match.end():]
        changed.append((name, old_version, new_version, cached, "GitHub SHA-256"))
    except urllib.error.HTTPError as exc:
        skipped.append((name, f"GitHub API HTTP {exc.code}"))
    except Exception as exc:
        skipped.append((name, str(exc)))

if changed:
    version_match = re.search(r"^DIY_VERSION=([0-9]+\.[0-9]+\.)([0-9]+)$", text, re.MULTILINE)
    if version_match:
        next_version = int(version_match.group(2)) + 1
        text = text[:version_match.start()] + "DIY_VERSION=" + version_match.group(1) + str(next_version) + text[version_match.end():]
    backup = script.with_name(f"{script.name}.bak.{time.strftime('%Y%m%d-%H%M%S')}.{os.getpid()}")
    fd, temporary = tempfile.mkstemp(prefix=f".{script.name}.update.", dir=script.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as output:
            output.write(text)
        os.chmod(temporary, script.stat().st_mode & 0o777)
        syntax = shutil.which("bash")
        if syntax:
            import subprocess
            subprocess.run([syntax, "-n", temporary], check=True)
        shutil.copy2(script, backup)
        os.replace(temporary, script)
    except Exception:
        if Path(temporary).exists():
            Path(temporary).unlink()
        raise
    for name, old, new, archive, proof in changed:
        print(f"UPDATED {name}: {old} -> {new}; {proof} verified; cached {archive}")
    print(f"Backup: {backup}")
else:
    print("No source pins were changed.")
print(f"Summary: {len(changed)} updated; {len(unchanged)} already current; {len(skipped) + len(unsupported)} skipped.")
if unsupported:
    print(f"Skipped {len(unsupported)} unsupported source pins; they remain at their pinned versions.")
for name, reason in skipped:
    print(f"SKIPPED {name}: {reason}")
print("GitHub releases require their published SHA-256 digest; GNU releases require a valid GPG signature. Other sources remain pinned.")
PY
}

help_text() {
    if [[ $DIY_LANG != lt ]]; then
        printf 'Version: %s\n' "$DIY_VERSION"
        cat <<'HELP_EN'
DIY Linux - a standalone source-based Linux builder (no Buildroot)

Usage:
  ./diy-linux.sh                       Interactive terminal menu (English)
  ./diy-linux.sh --LT                  Interactive terminal menu (Lithuanian)
  ./diy-linux.sh --LT --help           Lithuanian help
  ./diy-linux.sh --plan --LT           Lithuanian configuration preview

Commands:
  --menu                 New system / edit existing / resume / toolchain menu
  --update               Update verified GitHub and GNU source pins
  --new                  Configure a separate new system
  --edit                 Select an existing system for maintenance
  --plan                 Preview settings without downloading or building
  --build                Build using environment settings, without the menu
  --resume               Resume the saved unfinished build
  --fresh                Start over, including a new toolchain
  --toolchain            Build only binutils, GCC, and glibc; no rootfs or ISO
  --prepare-swap [GiB]   Create temporary swap for GCC (default 8 GiB; sudo)
  --enter [profile]      Enter a prepared rootfs using chroot (sudo)
  --chroot [profile]     Same as --enter
  --iso [profile]        Create an ISO from an existing rootfs
  --img [profile]        Create an IMG from an existing rootfs
  --repack [profile]     Refresh the configured image format
  --add-user [name] [profile]  Add a user with sudo access and refresh images
  --repair-login [profile]    Install missing login tools and refresh images
  --install-deps         Install missing host dependencies and exit
  --versions             List pinned package versions
  --version              Show this builder's version
  --desktop-info [name]  Describe desktop requirements and recipe status
  --self-test            Validate settings and manifests without compilation
  --help, -h             Show help
  --LT                   Use Lithuanian; can be combined with any command

If several systems exist, maintenance commands offer a system picker when
no profile directory is specified. Chroot changes persist in the disk rootfs;
leave with exit, then use --iso, --img, or --repack to refresh images.
Chroot shares the host kernel and uptime. Live changes last only until shutdown.
--update changes pinned GitHub sources only when the official Releases API
publishes a matching SHA-256 digest. For ftp.gnu.org releases it discovers the
latest stable matching archive and verifies its detached GPG signature with
the GNU keyring downloaded over trusted HTTPS; gpgv is required. Other sources
remain pinned and are reported as skipped. The updater checks the edited script
with bash -n before replacing it and keeps a timestamped backup.

Configuration (environment variables or terminal menu):
  TARGET_ARCH=x86_64|i686|aarch64  (AMD64 and Intel64 are both x86_64)
  SHELL_CHOICE=busybox|bash|dash|zsh|fish
  TOOLS_CHOICE=busybox|gnu
  INIT_CHOICE=busybox|openrc|runit|dinit|sysvinit|s6|systemd
  PACKAGE_MANAGER=none|apt|pacman  (APT includes dpkg)
  BOOT_CHOICE=bios|uefi|syslinux|lilo|refind|efistub|limine|systemd-boot|none
  DESKTOP_CHOICE=none|mate|lxde|fluxbox
  KEEP_ROOTFS_TAR=yes|no  Also create the optional rootfs.tar.gz export
  WITH_GCC=yes|no         Include native development tools in the final system
  NETWORK=yes|no          DHCP networking
  AUTOLOGIN=yes|no        Skip the password prompt for USER_NAME on local tty1 (GNU tools only)
  DESKTOP_AUTOSTART=yes|no  Start the selected Xorg desktop after local tty1 login
PKG_NANO, PKG_WGET, PKG_OPENSSH, PKG_PING, PKG_VIM, PKG_FDISK, PKG_GEANY, PKG_FIREFOX, PKG_PLUMA, PKG_ENGRAMPA, PKG_CAJA, PKG_EOM, PKG_MATE_CONTROL_CENTER, PKG_MATE_POWER_MANAGER, PKG_NGINX, PKG_PHP: yes or no
PKG_OPENSSH=yes builds OpenSSH client and server; sshd starts at boot. Host keys are created on first boot.
  PKG_PHP=yes also enables Nginx; PHP runs through PHP-FPM on a local FastCGI socket.
  SYSTEM_NAME=diy-linux USER_NAME=user JOBS=2 WORK_DIR=/path/without/spaces
  AUTO_INSTALL_DEPS=yes|no  Install missing host packages through sudo
  COLOR=always|never      NO_COLOR=1 also disables colors

Neofetch and Welcome are always included. Bash is included to run Neofetch,
even when another login shell is selected. Zsh and Fish use dash as /bin/sh.
Nano is optional; select PKG_NANO=yes to include it. If Nano is off and Vim is
selected, the profile uses Vim as EDITOR and VISUAL; otherwise they stay unset.
Fish requires GNU utilities and host CMake >= 3.15. MATE requires host Rust,
Cargo, cargo-cbuild and target Rust std for librsvg. Rust crates are downloaded
into the local cache and verified by their Cargo.lock files.

Build flags (active / inactive):
  Every standard Autotools and Meson package prints its exact compiler flags,
  common options, and package options into build.log under "Build flags".
  Active common flags: -O2 (release optimization), -pipe (compiler pipeline),
  target sysroot include paths, --build/--host (cross-build machine / target),
  and /usr, /etc, /var install paths. -march=native is deliberately absent so
  binaries remain usable on other CPUs of the selected architecture.
  Meson packages use --buildtype=release, --wrap-mode=nodownload, and
  -Dauto_features=disabled: optional features are off unless the recipe
  explicitly enables a required one. Desktop Meson also uses -Dwerror=false.
  Optional features that are not selected are not compiled. Recipe options such
  as --disable-docs, --disable-nls, --disable-static, --disable-tests,
  -Ddocs=disabled, -Dtests=false, -Dintrospection=disabled, or
  -Dsystemd=disabled are explicit per-package switches when supported; they are
  not universal flags. An absent --enable-feature / -Dfeature=enabled is not
  itself a guarantee if upstream defaults that feature on, so recipes explicitly
  disable optional features where needed. In package recipes, --disable-X and
  --without-X turn an optional capability/dependency off; --enable-X and
  --with-X turn it on or select its implementation. Meson's -Dfeature=disabled/
  enabled/false/true and CMake's -DNAME=OFF/ON express the same kind of choice.
  These switches are package-specific, so consult the package's logged options
  and the upstream build system for the exact meaning of X. Commented examples
  are never passed. --enable-shared builds .so libraries; --disable-static
  prevents .a archives (it does not make a program statically linked).
  --disable-doc, --disable-tests and --disable-tools omit those optional
  package components. Keep an explicit disable switch active when it prevents an
  upstream default from pulling in an unwanted feature or dependency.
SysVinit, runit, dinit, s6, systemd, APT and pacman require GNU utilities.
APT and pacman need your own compatible signed repositories. Base files
built from source are not registered in their package databases. Debian or
Arch packages are not automatically compatible with this system.

Build as a normal user on Linux x86_64. The first build takes considerable
time, disk space, and memory. GCC bootstrap uses one job. The memory check
requires at least 6 GiB of available RAM + free swap, without guaranteeing
that every generator will fit. For Killed / Error 137, inspect memory and try:
  bash diy-linux.sh --prepare-swap 8
Swap does not change /etc/fstab and will not survive reboot.

Missing host dependencies can be installed with apt-get, pacman, or dnf.
Host dependency installation is independent of the target package manager.
Manual Debian / Ubuntu base dependencies:
  sudo apt-get install build-essential bison flex gawk texinfo patch curl \
    xz-utils bzip2 gzip tar cpio rsync file perl python3 python3-jinja2 \
    pkg-config meson ninja-build gperf bc libssl-dev libelf-dev \
    libncurses-dev ncurses-bin fakeroot openssl kmod autoconf automake libtool
ISO creation also needs xorriso and mtools; GRUB needs the grub-common font.
Meson >= 0.62 is required for OpenRC/systemd; MATE needs >= 1.4.
MATE additionally needs msgfmt, intltool, gtk-encode-symbolic-svg, and hwdata/pnp.ids.
APT needs CMake >= 3.13; Fish and MATE builds also need host CMake.
See missing-dependency messages for selected extras.
The menu requires dialog and an interactive terminal. Arrows navigate,
Enter opens an entry, Space toggles options; Help explains each choice.

User passwords:
  The menu prompts for passwords locally. Root is locked by default.
  --build accounts stay locked unless password hashes are supplied:
  USER_PASSWORD_HASH="$(openssl passwd -6)" bash diy-linux.sh --build
  ROOT_PASSWORD_HASH="$(openssl passwd -6)" bash diy-linux.sh --build
  SHA-512 crypt and yescrypt (\$y\$) hashes are accepted. Hashes are saved
  in settings and /etc/shadow; do not publish them.
  Administration after login: sudo -i (regular user password).

Examples:
  SHELL_CHOICE=dash TOOLS_CHOICE=gnu INIT_CHOICE=openrc bash diy-linux.sh --plan
  PACKAGE_MANAGER=apt bash diy-linux.sh --plan
  PKG_VIM=yes PKG_WGET=no bash diy-linux.sh --plan
  TARGET_ARCH=aarch64 bash diy-linux.sh --toolchain

Toolchains persist under WORK_DIR/toolchains and are reused automatically.
Do not move their directories: tools reference their original sysroot paths.
Successful package stages are cached under WORK_DIR/artifacts and reused across
compatible profiles. Each package key includes target, toolchain, that package's
pinned source checksum, compiler flags, recipe ID, and stage-specific options.
When changing a package recipe or an ABI-relevant dependency, bump the affected
stage ID (for example, v1 to v2). Unrelated package or script edits keep other
artifacts. Remove WORK_DIR/artifacts only to deliberately rebuild them.
To compile additional packages on the host for an existing system:
  source /path/profile/sdk-env.sh
  ./configure --host=x86_64-diy-linux-gnu --prefix=/usr
  make
  make DESTDIR="$DIY_ROOT" install
  WITH_GCC=no omits the compiler only from the final system, not the build.

Outputs under the profile images/ directory:
  rootfs.squashfs, small initramfs.cpio.zst, bzImage, SHA256SUMS; optional rootfs.tar.gz
  <hostname>.iso, diy-linux.img, or diy-linux-esp.img (bootloader-dependent)
The live rootfs is read-only SquashFS with a temporary writable RAM overlay.
Live changes are discarded at shutdown.
IMG can be a hybrid ISO or FAT ESP, not necessarily an installed persistent OS.
GRUB bios/uefi select the firmware mode; rEFInd, EFISTUB and systemd-boot need
UEFI. systemd-boot works with any init.
Not all bootloaders support all architectures; validation checks combinations.
ARM64 targets QEMU virt / UEFI, not every board. i686/ARM64 executable build
checks and chroot require qemu-user binfmt_misc registration with the F flag.

Experimental MATE + Xorg:
  DESKTOP_CHOICE=mate TOOLS_CHOICE=gnu INIT_CHOICE=systemd bash diy-linux.sh --plan
  Current source recipe requires x86_64. GNU utilities allow all supported init
  choices; BusyBox utilities pair with BusyBox init. Login shell, package manager,
  GCC, network, and compatible bootloader are selectable. Mesa GLX/DRI3 and Xorg
  glamor are built for selected Intel, AMD, nouveau, VMware and virtio GPUs.
  There is no graphical login or USB automount. ALSA + PulseAudio and a Sound
  Mixer are included.
  All profiles include common Intel/AMD/nouveau GPU, HDA/USB audio, and
  Intel/Realtek/Atheros/MediaTek/Broadcom Wi-Fi kernel modules plus selected
  linux-firmware. NETWORK=yes adds Wi-Fi user-space tools; MATE also adds
  NetworkManager and its tray applet. MacBook Pro support depends on model:
  some Intel models use included Broadcom firmware, while older b43 chips need
  separately extracted firmware and T2 / Apple Silicon support is not guaranteed.

QEMU BIOS ISO:
  qemu-system-x86_64 -m 2048 -boot d -cdrom /path/<hostname>.iso -nographic
QEMU UEFI ISO (Debian / Ubuntu ovmf package; firmware path may differ):
  qemu-system-x86_64 -m 2048 -bios /usr/share/ovmf/OVMF.fd \
    -boot d -cdrom /path/<hostname>.iso -nographic
Direct kernel boot (the initramfs mounts the attached SquashFS root):
  qemu-system-x86_64 -m 2048 -kernel /path/bzImage \
    -initrd /path/initramfs.cpio.zst -append 'console=ttyS0,115200' \
    -drive file=/path/rootfs.squashfs,format=raw,if=virtio,readonly=on -nographic
ARM64 direct boot (kernel filename is also bzImage):
  qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2048 -nographic \
    -kernel images/bzImage -initrd images/initramfs.cpio.zst -append console=ttyAMA0
For MATE use a graphical QEMU window, e.g. -vga std or -vga virtio;
do not use only -nographic. Not every architecture / init / boot combination
has been boot-tested. --self-test is not a boot test.
The generated QEMU command defaults to one vCPU to avoid spurious remote-CPU
clocksource-watchdog timeouts under virtualization. Set QEMU_CPUS=2 (or more)
when invoking the script to request multiple guest CPUs.

Compiler output is saved to build.log. Progress measures completed stages,
not remaining time; a percentage can stay unchanged during a long GCC stage.
The activity indicator and elapsed timer show work in progress. Failed stages
can reuse compiled objects when resumed. Host dependencies log:
  WORK_DIR/host-dependencies.log
HELP_EN
        return
    fi
    printf 'Scenarijaus versija: %s\n' "$DIY_VERSION"
    cat <<'HELP'
Vienas Bash scenarijus kuria x86_64, i686 arba ARM64 GNU/Linux iš šaltinių.
Kalba: pagal nutylėjimą anglų; --LT įjungia lietuvių kalbą.
Paleidus be argumentų: kurti naują / redaguoti esamą / tęsti nebaigtą kūrimą.
  bash diy-linux.sh --new    # naujos sistemos komponentų meniu
  bash diy-linux.sh --edit   # esamos sistemos pasirinkimas ir priežiūra
TARGET_ARCH=x86_64|i686|aarch64. AMD64 ir Intel64 yra tas pats x86_64.
ARM64 receptas skirtas QEMU virt / UEFI, ne visoms ARM plokštėms.
ARM64 ir i686 Limine receptas dar neįtrauktas; rinkis GRUB / rEFInd / EFISTUB.
ARM64 ir i686 chroot / build patikroms reikia qemu-user binfmt_misc su F vėliava.
Automatinės priklausomybės įtraukia emuliatorių; neaktyvią registraciją reikia įjungti.
ARM64 QEMU pavyzdys (Image išsaugomas bendru vardu bzImage):
  qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2048 -nographic \
    -kernel images/bzImage -initrd images/initramfs.cpio.zst -append console=ttyAMA0
Nano yra pasirenkamas (PKG_NANO=yes). Jei Nano išjungtas, o Vim pasirinktas,
EDITOR ir VISUAL naudos vim; jei abu išjungti, šie kintamieji nenustatomi.
Neofetch įtrauktas visais variantais: prieš login ir automatiškai su Welcome prisijungus.
Welcome veikia su Bash, dash / ash, Zsh, Fish ir chroot; antriniai shell jo nekartoja.
Bash papildomai įtraukiamas Neofetch vykdymui, nekeičiant pasirinkto apvalkalo.

Kompiliavimo vėliavėlės (aktyvios ir išjungtos):
  Kiekvienas standartinis Autotools ir Meson paketas į build.log įrašo tikslias
  kompiliatoriaus, bendrąsias ir konkretaus paketo parinktis („Build flags“).
  Aktyvios bendros vėliavėlės: -O2 (leidimo optimizavimas), -pipe (kompiliavimo
  vamzdžiai), tikslinio sysroot antraščių keliai, --build/--host (kūrimo
  kompiuteris / tikslinė architektūra) bei /usr, /etc ir /var diegimo keliai.
  -march=native sąmoningai nenaudojama, kad programa veiktų kituose tos pačios
  architektūros procesoriuose.
  Meson paketams aktyvuojama release kūrimo konfigūracija, išjungiami tinklo
  wrapper atsisiuntimai (--wrap-mode=nodownload) ir automatinės pasirenkamos
  funkcijos (-Dauto_features=disabled). Darbalaukio Meson papildomai naudoja
  -Dwerror=false. Pasirinktos funkcijos įjungiamos tik konkretaus recepto
  parinktimis.
  Nepasirinktos funkcijos nekompiliuojamos. Kai paketas tai palaiko, receptuose
  aiškiai išjungiami dokumentai, vertimai, statinės bibliotekos, testai,
  introspekcija ar systemd integracija (pvz. --disable-docs, --disable-nls,
  --disable-static, --disable-tests, -Ddocs=disabled, -Dtests=false,
  -Dintrospection=disabled, -Dsystemd=disabled). Tai nėra universalios
  parinktys: naudojama tik tai, ką priima konkretus paketas. Komentuoti pavyzdžiai
  į kompiliavimo komandą nepatenka. Jei upstream pagal nutylėjimą įjungia
  pasirenkamą funkciją, recepte ji aiškiai išjungiama. Receptuose --disable-X ir
  --without-X išjungia pasirenkamą funkciją / priklausomybę, o --enable-X ir
  --with-X ją įjungia arba parenka jos įgyvendinimą. Meson naudoja -Dfeature=
  disabled/enabled/false/true, o CMake -DNAME=OFF/ON. X reikšmė priklauso nuo
  konkrečios programos, todėl tikslias parinktis ir jų aprašus skaityk prie
  recepto; faktinės perduotos reikšmės bus build.log faile. Komentuoti pavyzdžiai
  nepatenka į kompiliavimo komandą. --enable-shared kuria bendrąsias .so
  bibliotekas, o --disable-static nekuria .a archyvų (ši parinktis nepadaro
  programos statiškai susietos). --disable-doc, --disable-tests ir
  --disable-tools praleidžia atitinkamus pasirenkamus paketo komponentus.
  Aiškią išjungimo parinktį palik aktyvią, jei
  ji apsaugo nuo upstream pagal nutylėjimą įjungiamos nereikalingos funkcijos.

  --menu / be argumentų  Interaktyvus pasirinkimų meniu ir plano peržiūra.
  --update               Atnaujinti SHA-256 patikrintus GitHub ir GPG patikrintus GNU šaltinius.
  --plan                Tik parodyti pasirinktą planą.
  --build               Kurti be meniu pagal aplinkos kintamuosius.
  --resume              Tęsti išsaugotą nebaigtą kūrimą.
  --fresh               Naujas meniu ir kūrimas nuo nulio, įskaitant toolchain.
Nutraukus darbą, įprastas paleidimas pasiūlo tęsti arba pradėti iš naujo.
  --prepare-swap [GiB]  Paruošti swap GCC kūrimui (numatyta 8 GiB, sudo).
  --chroot [katalogas]   Bash sesija sukurto rootfs viduje (sudo + chroot).
  --enter [katalogas]    Tas pats kaip --chroot.
  --add-user [vardas] [katalogas] Sukurti vartotoją su sudo ir perkurti ISO.
  --repair-login [katalogas] Įdiegti trūkstamą login ir perkurti atvaizdus.
  --repack [katalogas]   Iš naujo supakuoti rootfs po programų diegimo.
  --iso [katalogas]      Sukurti ISO iš esamo rootfs (be kompiliavimo).
  --img [katalogas]      Sukurti IMG iš esamo rootfs (be kompiliavimo).
Jei katalogas nenurodytas ir sistemų daugiau nei viena, pateikiamas jų meniu.
--update GitHub šaltinius keičia tik kai oficiali Releases API pateikia
sutampantį failą ir SHA-256. ftp.gnu.org atveju randa naujausią atitinkantį
stabilų archyvą ir patikrina jo GPG parašą GNU raktų žiedu (reikia gpgv).
Kiti šaltiniai paliekami nepakeisti ir parodomi kaip praleisti. Prieš
perrašant scenarijų patikrinama Bash sintaksė; išsaugoma atsarginė kopija.
  --install-deps        Įdiegti trūkstamas šeimininko priklausomybes ir baigti.
  --versions            Parodyti užfiksuotų paketų versijas.
  --version             Parodyti scenarijaus versiją.
  --self-test           Patikrinti pasirinkimų logiką; nieko nekompiliuoti.

Pavyzdžiai:
  SHELL_CHOICE=dash TOOLS_CHOICE=gnu INIT_CHOICE=openrc bash diy-linux.sh --plan
  SHELL_CHOICE=busybox TOOLS_CHOICE=busybox INIT_CHOICE=busybox bash diy-linux.sh --build
  INIT_CHOICE=systemd WITH_GCC=yes JOBS=1 bash diy-linux.sh --build
  PACKAGE_MANAGER=apt bash diy-linux.sh --plan
  PACKAGE_MANAGER=pacman WITH_GCC=yes bash diy-linux.sh --build

GCC kompiliuojamas su -j1. RAM + laisvo swap patikra prašo bent 6 GiB
(tai negarantuoja, kad atminties pakaks visiems GCC generatoriams).
Jei genautomata gauni Killed / Error 137:
  bash diy-linux.sh --prepare-swap 8
Swap nekeičia /etc/fstab ir neveiks po perkrovimo.

MATE + Xorg (pavyzdinis x86_64 / GNU / OpenRC / GRUB BIOS profilis):
  DESKTOP_CHOICE=mate TOOLS_CHOICE=gnu INIT_CHOICE=openrc bash diy-linux.sh --build
Paleidus sistemą vietiniame tty: startmate. QEMU bandymui reikia grafinio lango,
ne vien -nographic; pvz. -vga std arba -vga virtio. ISO visas rootfs laikomas RAM.
Tai pirmas 2D variantas be 3D, grafinio prisijungimo ir USB automount paslaugų. Įtraukiami ALSA, PulseAudio ir darbalaukio garso maišytuvas. GPU ir garso moduliai įtraukiami darbalaukio profiliuose; Wi-Fi moduliai ir jų firmware — kai NETWORK=yes. Konsolės profiliai praleidžia nereikalingus tvarkyklių modulius. MATE profilyje NETWORK=yes taip pat įjungia NetworkManager ir jo piktogramą.
MacBook Pro Wi-Fi priklauso nuo modelio: kai kuriems Intel modeliams tiks įtraukti Broadcom tvarkyklės ir firmware; senesniems b43 lustams firmware reikia išgauti atskirai, o T2 ir Apple Silicon palaikymas negarantuojamas.
Darbalaukių reikalavimai ir aprašymai:
  bash diy-linux.sh --desktop-info mate

Tik toolchain (be sistemos / ISO, pakartojimas tęsia baigtus etapus):
  bash diy-linux.sh --toolchain
  TARGET_ARCH=aarch64 bash diy-linux.sh --toolchain

Toolchain išlieka darbo katalogo toolchains/; suderinamas naudojamas automatiškai.
Sėkmingų paketų artefaktai saugomi WORK_DIR/artifacts/ ir pakartotinai naudojami
suderinamuose profiliuose. Kiekvieno paketo raktas apima architektūrą, toolchain,
to paketo šaltinio SHA-256, kompiliatoriaus vėliavas, recepto ID ir etapo parinktis.
Keičiant receptą arba ABI svarbią priklausomybę, padidink atitinkamo etapo ID
(pvz., v1 į v2). Nesusiję paketų ar scenarijaus pakeitimai kitų artefaktų nekeičia.
Katalogą ištrink tik norėdamas priverstinai viską perkompiliuoti.
Profilio sdk-env.sh paruošia kryžminio kūrimo aplinką šeimininke:
  source /kelias/profilis/sdk-env.sh
  ./configure --host=x86_64-diy-linux-gnu --prefix=/usr
  make
  make DESTDIR="$DIY_ROOT" install
Galutinėje sistemoje diegimui / kūrimui:
  bash diy-linux.sh --chroot /kelias/profilis
  # viduje: apt install ./paketas.deb arba pacman -U ./paketas.pkg.tar.zst
  # su WITH_GCC=yes: ./configure --prefix=/usr; make; make install
  exit
  bash diy-linux.sh --repack /kelias/profilis
--chroot / --enter naudoja Bash priežiūros sesijai. Savos suderinamos saugyklos vis tiek būtinos.
--chroot / --enter pakeitimai išlieka disko rootfs. Live ISO pakeitimai laikini
ir prarandami išjungus sistemą.
Toolchain katalogo neperkelk: įrankiai susieti su jo sysroot keliu.

„Be GCC“ reiškia BE kompiliatoriaus galutinėje sistemoje. Kūrimo metu GCC būtinas.
Paketų tvarkyklė: PACKAGE_MANAGER=none|apt|pacman. APT apima dpkg.
APT / pacman receptams reikia GNU įrankių; pacman papildomai įtraukia Bash dėl makepkg.
Zsh / Fish yra prisijungimo apvalkalai; jų /bin/sh yra dash.
Fish reikia GNU įrankių, šeimininko CMake >= 3.15 ir Rust >= 1.85 / Cargo.
Fish Rust priklausomybės atsisiunčiamos pagal jo Cargo.lock.
Saugyklos neprijungiamos automatiškai: reikia savų suderinamų, pasirašytų paketų.
Baziniai failai neįregistruoti paketų bazėje; RAM rootfs pakeitimai nėra nuolatiniai.
APT kūrimui šeimininke reikia cmake (bent 3.13); Fish ir MATE profiliams taip pat.
Systemd naudojamas su GNU įrankiais; BusyBox apvalkalą galima pasirinkti atskirai.

Trūkstamos šeimininko priklausomybės automatiškai įdiegiamos per sudo.
Palaikoma apt-get (Debian / Ubuntu), pacman (Arch), dnf (Fedora).
Išjungimas: AUTO_INSTALL_DEPS=no bash diy-linux.sh --build
Tik priklausomybės: bash diy-linux.sh --install-deps
--plan, --help ir --self-test nieko neįdiegia.
Kompiliavimo išvestis saugoma build.log; ekrane rodomas etapas ir progreso juosta.
Procentai yra baigtų etapų dalis, o ne kompiliavimo laiko prognozė.
Pirmasis kūrimas suskaidytas į binutils, pradinį GCC, glibc ir pilną GCC.
Sukamas indikatorius ir sekundės rodo tebevykstantį etapą.
Spalvos: COLOR=always priverstinai įjungia; COLOR=never arba NO_COLOR=1 išjungia.
Priklausomybių diegimo žurnalas: darbo katalogo host-dependencies.log.

Rankinis priklausomybių diegimas Ubuntu / Debian:
  sudo apt-get install build-essential bison flex gawk texinfo patch curl \
    xz-utils bzip2 gzip tar cpio rsync file perl python3 python3-jinja2 \
    pkg-config meson ninja-build gperf bc libssl-dev libelf-dev \
    libncurses-dev ncurses-bin fakeroot openssl kmod autoconf automake libtool
ISO kūrimui reikia xorriso ir mtools. GRUB papildomai reikia grub-common šrifto.
Init: INIT_CHOICE=busybox|openrc|runit|dinit|sysvinit|s6|systemd.
SysVinit / runit / Dinit / s6 / systemd receptams reikia GNU įrankių.
Paleidyklė: BOOT_CHOICE=bios|uefi|syslinux|lilo|refind|efistub|limine|systemd-boot|none.
bios/uefi yra GRUB variantai; Limine ISO palaiko abu firmware tipus.
rEFInd, EFISTUB ir systemd-boot yra UEFI; systemd-boot nepriklauso nuo init.
QEMU patikrai: qemu-system-x86; UEFI paleidimui Ubuntu / Debian reikia ovmf.
Meson turi būti bent 0.62.0 (OpenRC ir systemd).

Reikia daug laiko, vietos diske ir laisvos RAM. JOBS pagal laisvą RAM parenka saugų lygiagretumą; GCC etapai naudoja vieną darbą. Pakavimui nustatyk SQUASH_JOBS atskirai.
Scenarijų vykdyk paprasto naudotojo teisėmis, Linux x86_64 sistemoje.
Darbo katalogo kelias turi būti be tarpų. Kiekvienas pasirinkimų derinys
turi savo rootfs ir etapų žymas. Pakartotinis paleidimas tęsia baigtus etapus.
Nepavykusio etapo Makefiles panaudoja jau sukompiliuotus objektus.

Rezultatas: rootfs.squashfs, mažas initramfs.cpio.zst, bzImage ir pasirinktinai <hostname>.iso; KEEP_ROOTFS_TAR=yes prideda rootfs.tar.gz.
--img: UEFI EFI variantams kopijuojamas FAT ESP, BIOS / GRUB / Limine — hibridinis ISO.
UEFI variantas nenaudoja Secure Boot. Jei neįvedamas bendras slaptažodis, root paskyra lieka užrakinta.
Numatytasis vartotojas yra user. Meniu ir interaktyvus --build vieną pasirinktą slaptažodį nustato root ir user paskyroms.
Meniu: rodyklės juda, Enter atveria, tarpas uždeda / nuima varneles.
Meniu reikia dialog (jei trūksta, įdiegiamas automatiškai).
PKG_NANO, PKG_WGET, PKG_OPENSSH, PKG_PING, PKG_VIM, PKG_FDISK, PKG_GEANY, PKG_FIREFOX, PKG_PLUMA, PKG_ENGRAMPA, PKG_CAJA, PKG_EOM, PKG_NGINX, PKG_PHP: yes arba no.
PKG_OPENSSH=yes įtraukia OpenSSH klientą ir serverį; sshd paleidžiamas su sistema. Host raktai sukuriami pirmo paleidimo metu.
PKG_PHP=yes taip pat įjungia Nginx; PHP vykdomas per PHP-FPM ir vietinį FastCGI lizdą.
Neofetch ir Welcome naujuose kūrimuose visada įtraukiami.
Pavyzdys: PKG_VIM=yes PKG_WGET=no bash diy-linux.sh --build
USER_NAME pasirenka vartotoją; ROOT_PASSWORD_HASH nustato bendrą slaptažodį.
Nepateikus ROOT_PASSWORD_HASH, numatytasis USER_PASSWORD_HASH paveldi root hash. Atskirą user slaptažodį galima aiškiai nurodyti su USER_PASSWORD_HASH.
Sudo prašo vartotojo slaptažodžio; sudoers taisyklė: %sudo ALL=(ALL:ALL) ALL.
Root --build slaptažodžio pavyzdys:
  ROOT_PASSWORD_HASH="$(openssl passwd -6)" bash diy-linux.sh --build
Priimami SHA-512 crypt ir yescrypt (\$y\$) hash'ai. Hash pateks į /etc/shadow
ir kūrimo sesijos nustatymų failą; jo nekelk į Git.

Paleidimas QEMU (BIOS ISO):
  qemu-system-x86_64 -m 2048 -cdrom /kelias/<hostname>.iso -nographic
Paleidimas QEMU (UEFI ISO, Ubuntu / Debian, ovmf paketas):
  qemu-system-x86_64 -m 2048 -bios /usr/share/ovmf/OVMF.fd \
    -boot d -cdrom /kelias/<hostname>.iso -nographic
UEFI ISO su SeaBIOS nepasileis: naudok OVMF arba BIOS variantą.
Generuojama QEMU komanda numatytai naudoja vieną vCPU, kad virtualioje aplinkoje
nekiltų klaidingas nuotolinio CPU clocksource-watchdog įspėjimas. Nustatyk
QEMU_CPUS=2 (ar daugiau), jei reikia kelių virtualių CPU.
Live pakeitimai laikomi RAM ir prarandami išjungus sistemą.
Arba be GRUB: mažasis initramfs prijungia SquashFS ir RAM perdangą:
  qemu-system-x86_64 -m 2048 -kernel /kelias/bzImage \
    -initrd /kelias/initramfs.cpio.zst -append 'console=ttyS0,115200' \
    -drive file=/kelias/rootfs.squashfs,format=raw,if=virtio,readonly=on -nographic
HELP
}

validation_error() { VALIDATION_ERROR=$1; return 1; }

# Vienoje vietoje susiejame CPU, ABI, branduolį ir EFI failų vardus.
architecture() {
    case "$TARGET_ARCH" in
        amd64|x64) TARGET_ARCH=x86_64 ;;
        x86|i386|i486|i586) TARGET_ARCH=i686 ;;
        arm64) TARGET_ARCH=aarch64 ;;
    esac
    SERIAL_TTY=ttyS0; EMULATOR=
    case "$TARGET_ARCH" in
        x86_64) TARGET=x86_64-diy-linux-gnu; KERNEL_ARCH=x86; KERNEL_CONFIG=x86_64_defconfig
            KERNEL_IMAGE=arch/x86/boot/bzImage; CPU_FAMILY=x86_64; DEB_ARCH=amd64
            ELF_LOADER=/lib64/ld-linux-x86-64.so.2; OPENSSL_ARCH=linux-x86_64; EFI_CPU=x86_64; EFI_SUFFIX=x64 ;;
        i686) EMULATOR=qemu-i386; TARGET=i686-diy-linux-gnu; KERNEL_ARCH=x86; KERNEL_CONFIG=i386_defconfig
            KERNEL_IMAGE=arch/x86/boot/bzImage; CPU_FAMILY=x86; DEB_ARCH=i386
            ELF_LOADER=/lib/ld-linux.so.2; OPENSSL_ARCH=linux-x86; EFI_CPU=i386; EFI_SUFFIX=ia32 ;;
        aarch64) EMULATOR=qemu-aarch64; TARGET=aarch64-diy-linux-gnu; KERNEL_ARCH=arm64; KERNEL_CONFIG=defconfig
            KERNEL_IMAGE=arch/arm64/boot/Image; CPU_FAMILY=aarch64; DEB_ARCH=arm64
            ELF_LOADER=/lib/ld-linux-aarch64.so.1; OPENSSL_ARCH=linux-aarch64; EFI_CPU=aarch64; EFI_SUFFIX=aa64
            SERIAL_TTY=ttyAMA0 ;;
        *) validation_error "$(tr_text 'Architecture: x86_64 / AMD64, i686 / x86, or aarch64 / ARM64' 'Architektūra: x86_64 / AMD64, i686 / x86 arba aarch64 / ARM64')"; return 1 ;;
    esac
    EFI_BOOT="BOOT${EFI_SUFFIX^^}.EFI"
    RUST_TARGET="$TARGET_ARCH-unknown-linux-gnu"
    SDBOOT_PACKAGE=sdboot; [[ "$TARGET_ARCH" != aarch64 ]] || SDBOOT_PACKAGE=sdboot-arm64
}

boot_compatible() {
    case "$TARGET_ARCH:$1" in
        aarch64:bios|aarch64:lilo|aarch64:syslinux|aarch64:limine|i686:systemd-boot|i686:limine) return 1 ;;
    esac
}

password_hash_valid() {
    local hash=$1
    [[ "$hash" == '!' ]] ||
        [[ "$hash" =~ ^\$6\$(rounds=[0-9]+\$)?[./a-zA-Z0-9]{1,16}\$[./a-zA-Z0-9]{86}$ ]] ||
        [[ "$hash" =~ ^\$y\$[./a-zA-Z0-9]+\$[./a-zA-Z0-9]{0,86}\$[./a-zA-Z0-9]{43}$ ]]
}

validate() {
    architecture || return 1
    local option
    for option in PKG_NANO PKG_WGET PKG_OPENSSH PKG_PING PKG_NEOFETCH PKG_VIM PKG_FDISK PKG_GEANY PKG_FIREFOX PKG_PLUMA PKG_ENGRAMPA PKG_CAJA PKG_EOM PKG_MATE_CONTROL_CENTER PKG_MATE_POWER_MANAGER PKG_NGINX PKG_PHP; do
        case ${!option} in yes|no) ;; *) validation_error "$(tr_text "$option: choose yes or no" "$option: pasirink yes arba no")"; return 1 ;; esac
    done
    # PHP is served through FastCGI, so its menu toggle also selects Nginx.
    [[ "$PKG_PHP" != yes ]] || PKG_NGINX=yes
    VALIDATION_ERROR=''
    case "$DESKTOP_CHOICE" in none|mate|lxde|fluxbox) ;; *) validation_error "$(tr_text 'Desktop: none, mate, lxde, or fluxbox' 'Darbalaukis: none, MATE, LXDE arba Fluxbox')"; return 1 ;; esac
    if [[ "$PKG_GEANY" == yes ]]; then
        [[ "$DESKTOP_CHOICE" == mate && "$TARGET_ARCH:$TOOLS_CHOICE" == x86_64:gnu ]] || {
            validation_error "$(tr_text 'Geany currently requires the x86_64 GNU MATE desktop' 'Geany kol kas reikia x86_64 GNU MATE darbalaukio')"; return 1; }
    fi
    if [[ "$PKG_FIREFOX" == yes ]]; then
        [[ ( "$DESKTOP_CHOICE" == mate || "$DESKTOP_CHOICE" == lxde || "$DESKTOP_CHOICE" == fluxbox ) && "$TARGET_ARCH:$TOOLS_CHOICE" == x86_64:gnu ]] || {
            validation_error "$(tr_text 'Firefox currently requires an x86_64 GNU Xorg desktop' 'Firefox kol kas reikia x86_64 GNU Xorg darbalaukio')"; return 1; }
    fi
    if [[ "$PKG_PLUMA" == yes || "$PKG_ENGRAMPA" == yes || "$PKG_CAJA" == yes || "$PKG_EOM" == yes || "$PKG_MATE_CONTROL_CENTER" == yes || "$PKG_MATE_POWER_MANAGER" == yes ]]; then
        [[ "$DESKTOP_CHOICE" == mate && "$TARGET_ARCH:$TOOLS_CHOICE" == x86_64:gnu ]] || {
            validation_error "$(tr_text 'MATE applications require the x86_64 GNU MATE desktop' 'MATE programoms reikia x86_64 GNU MATE darbalaukio')"; return 1; }
    fi
    if [[ "$PKG_MATE_CONTROL_CENTER" == yes || "$PKG_MATE_POWER_MANAGER" == yes ]]; then
        [[ "$TOOLS_CHOICE" == gnu ]] || {
            validation_error "$(tr_text 'MATE Control Center and Power Manager need GNU login tools with PAM session support.' 'MATE Control Center ir Power Manager reikia GNU prisijungimo įrankių su PAM sesijų palaikymu.')"; return 1; }
    fi
    if [[ "$DESKTOP_CHOICE" != none && "$TARGET_ARCH" != x86_64 ]]; then
        validation_error "$(tr_text 'Current graphical desktop profiles require TARGET_ARCH=x86_64.' 'Dabartiniams grafiniams profiliams reikia TARGET_ARCH=x86_64.')"; return 1
    fi
    if [[ "$DESKTOP_CHOICE" != none && "$TOOLS_CHOICE" == busybox && "$INIT_CHOICE" != busybox ]]; then
        validation_error "$(tr_text 'Desktop profiles with BusyBox utilities currently require BusyBox init; choose GNU utilities for other init systems.' 'Darbalaukio profiliui su BusyBox įrankiais kol kas reikia BusyBox init; kitoms init sistemoms pasirink GNU įrankius.')"; return 1
    fi
    [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$USER_NAME" != root ]] || { validation_error "$(tr_text 'Invalid username (root is reserved)' 'Netinkamas vartotojo vardas (root rezervuotas)')"; return 1; }
    [[ "$PKG_OPENSSH" != yes || "$USER_NAME" != sshd ]] || {
        validation_error "$(tr_text 'Username sshd is reserved for OpenSSH privilege separation' 'Vardas sshd rezervuotas OpenSSH privilegijų atskyrimui')"; return 1; }
    password_hash_valid "$USER_PASSWORD_HASH" || { validation_error "$(tr_text 'USER_PASSWORD_HASH must be !, SHA-512 crypt, or yescrypt' 'USER_PASSWORD_HASH turi būti !, SHA-512 crypt arba yescrypt')"; return 1; }
    case "$AUTO_INSTALL_DEPS" in yes|no) ;; *) validation_error "$(tr_text 'AUTO_INSTALL_DEPS must be yes or no' 'AUTO_INSTALL_DEPS turi būti yes arba no')"; return 1 ;; esac
    case "$AUTOLOGIN" in yes|no) ;; *) validation_error "$(tr_text 'AUTOLOGIN must be yes or no' 'AUTOLOGIN turi būti yes arba no')"; return 1 ;; esac
    case "$DESKTOP_AUTOSTART" in yes|no) ;; *) validation_error "$(tr_text 'DESKTOP_AUTOSTART must be yes or no' 'DESKTOP_AUTOSTART turi būti yes arba no')"; return 1 ;; esac
    case "$KEEP_ROOTFS_TAR" in yes|no) ;; *) validation_error "$(tr_text 'KEEP_ROOTFS_TAR must be yes or no' 'KEEP_ROOTFS_TAR turi būti yes arba no')"; return 1 ;; esac
    [[ "$DESKTOP_AUTOSTART" != yes || "$DESKTOP_CHOICE" == mate || "$DESKTOP_CHOICE" == lxde || "$DESKTOP_CHOICE" == fluxbox ]] || {
        validation_error "$(tr_text 'DESKTOP_AUTOSTART requires an Xorg desktop profile' 'DESKTOP_AUTOSTART reikia Xorg darbalaukio profilio')"; return 1; }
    [[ "$AUTOLOGIN" != yes || "$TOOLS_CHOICE" == gnu ]] || {
        validation_error "$(tr_text 'AUTOLOGIN requires GNU utilities (util-linux agetty and the shadow login program)' 'AUTOLOGIN reikia GNU įrankių (util-linux agetty ir Shadow login programa)')"; return 1; }
    # Vardas visada saugomas mažosiomis raidėmis, tiek meniu, tiek --build.
    SYSTEM_NAME=${SYSTEM_NAME,,}
    case "$SHELL_CHOICE" in busybox|bash|dash|zsh|fish) ;; *) validation_error "$(tr_text 'Shell: choose busybox, bash, dash, zsh, or fish' 'Apvalkalas: pasirink busybox, bash, dash, zsh arba fish')"; return 1 ;; esac
    case "$TOOLS_CHOICE" in busybox|gnu) ;; *) validation_error "$(tr_text 'Utilities: choose busybox or gnu' 'Įrankiai: pasirink busybox arba gnu')"; return 1 ;; esac
    case "$INIT_CHOICE" in busybox|openrc|sysvinit|runit|dinit|s6|systemd) ;; *) validation_error "$(tr_text 'Init: choose busybox, openrc, runit, dinit, sysvinit, s6, or systemd' 'Init: pasirink busybox, openrc, runit, dinit, sysvinit, s6 arba systemd')"; return 1 ;; esac
    case "$PACKAGE_MANAGER" in none|apt|pacman) ;; *) validation_error "$(tr_text 'Package manager: choose none, apt, or pacman' 'Paketų tvarkyklė: pasirink none, apt arba pacman')"; return 1 ;; esac
    [[ "$PACKAGE_MANAGER" == none || "$TOOLS_CHOICE" == gnu ]] || { validation_error "$(tr_text 'APT / pacman requires TOOLS_CHOICE=gnu' 'APT / pacman reikia TOOLS_CHOICE=gnu')"; return 1; }
    [[ "$SHELL_CHOICE" != fish || "$TOOLS_CHOICE" == gnu ]] || { validation_error "$(tr_text 'Fish requires TOOLS_CHOICE=gnu' 'Fish receptui reikia TOOLS_CHOICE=gnu')"; return 1; }
    case "$WITH_GCC:$NETWORK" in yes:yes|yes:no|no:yes|no:no) ;; *) validation_error "$(tr_text 'WITH_GCC and NETWORK must be yes or no' 'WITH_GCC ir NETWORK turi būti yes arba no')"; return 1 ;; esac
    case "$BOOT_CHOICE" in bios|uefi|syslinux|lilo|refind|efistub|limine|systemd-boot|none) ;; *) validation_error "$(tr_text 'Unknown bootloader' 'Neatpažinta paleidyklė')"; return 1 ;; esac
    boot_compatible "$BOOT_CHOICE" || { validation_error "$(tr_text "The $BOOT_CHOICE recipe does not support $TARGET_ARCH; choose another bootloader" "Šis $BOOT_CHOICE receptas nepalaiko $TARGET_ARCH; pasirink kitą paleidyklę")"; return 1; }
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { validation_error "$(tr_text 'Build jobs: enter a positive integer' 'Kompiliavimo užduotys: įrašyk sveiką skaičių nuo 1')"; return 1; }
    [[ -z "$SQUASH_JOBS" || "$SQUASH_JOBS" =~ ^[1-9][0-9]*$ ]] || {
        validation_error "$(tr_text 'SQUASH_JOBS must be a positive integer' 'SQUASH_JOBS turi būti teigiamas sveikasis skaičius')"; return 1; }
    [[ "$SYSTEM_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || {
        validation_error "$(tr_text 'Hostname: 1-63 Latin letters, digits, or hyphens; cannot begin or end with a hyphen' 'Kompiuterio vardas: 1–63 lotyniškos raidės, skaitmenys arba brūkšneliai; pradžia ir pabaiga negali būti brūkšnelis')"
        return 1
    }
    [[ "$OS_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]{0,63}$ ]] || {
        validation_error "$(tr_text 'OS name: use 1-64 letters, digits, spaces, dots, underscores, or hyphens; start with a letter or digit' 'OS pavadinimas: naudok 1–64 raides, skaitmenis, tarpus, taškus, pabraukimus arba brūkšnelius; pradėk raide arba skaitmeniu')"
        return 1
    }
    valid_work_dir_path "$WORK_DIR" || {
        validation_error "$(tr_text 'Working directory may use only ASCII letters, digits, dot, underscore, plus, hyphen and slash' 'Darbo kataloge galima naudoti tik lotyniškas raides, skaitmenis, tašką, pabraukimą, pliusą, brūkšnelį ir /')"; return 1
    }
    password_hash_valid "$ROOT_PASSWORD_HASH" || {
        validation_error "$(tr_text 'ROOT_PASSWORD_HASH must be !, SHA-512 crypt, or yescrypt' 'ROOT_PASSWORD_HASH turi būti !, SHA-512 crypt arba yescrypt')"; return 1
    }
    [[ ! "$INIT_CHOICE" =~ ^(systemd|sysvinit|runit|dinit|s6)$ || "$TOOLS_CHOICE" == gnu ]] || {
        validation_error "$(tr_text 'This init recipe requires TOOLS_CHOICE=gnu.' 'Šiai init sistemai reikia TOOLS_CHOICE=gnu.')"
        return 1
    }
}

needs_busybox() {
    [[ "$SHELL_CHOICE" == busybox || "$TOOLS_CHOICE" == busybox || "$INIT_CHOICE" == busybox ]]
}

plan() {
    local posix_shell=$SHELL_CHOICE
    case "$SHELL_CHOICE" in zsh|fish) posix_shell=dash ;; busybox) posix_shell='BusyBox ash' ;; esac
    if [[ $DIY_LANG == lt ]]; then
    cat <<PLAN

Architektūra:               $TARGET_ARCH ($TARGET)
Apvalkalas:                 $SHELL_CHOICE
/bin/sh sistemos scenarijams: $posix_shell
Sistemos įrankiai:           $TOOLS_CHOICE
Init sistema:               $INIT_CHOICE
Paketų tvarkyklė:            $PACKAGE_MANAGER
Darbalaukis:                 $DESKTOP_CHOICE
GCC galutinėje sistemoje:    $WITH_GCC
Paleidyklė / atvaizdas:       $BOOT_CHOICE
DHCP tinklas:               $NETWORK
Automatinis prisijungimas tty1: $AUTOLOGIN
Automatinis MATE paleidimas:   $DESKTOP_AUTOSTART
Automatinės priklausomybės:  $AUTO_INSTALL_DEPS
Kompiliavimo užduotys:       $JOBS
ISO pakavimo užduotys:       ${SQUASH_JOBS:-$JOBS}
Kompiuterio vardas:          $SYSTEM_NAME
OS pavadinimas:              $OS_NAME
Vartotojas su sudo:          $USER_NAME
Papildomos programos:       Nginx=$PKG_NGINX PHP-FPM=$PKG_PHP nano=$PKG_NANO wget=$PKG_WGET OpenSSH=$PKG_OPENSSH ping=$PKG_PING neofetch=$PKG_NEOFETCH vim=$PKG_VIM fdisk=$PKG_FDISK Geany=$PKG_GEANY Firefox=$PKG_FIREFOX Caja=$PKG_CAJA Pluma=$PKG_PLUMA Engrampa=$PKG_ENGRAMPA EOM=$PKG_EOM MCC=$PKG_MATE_CONTROL_CENTER Power-Manager=$PKG_MATE_POWER_MANAGER Marco=built-in
Pasirinktų komponentų ISO prieaugis (apytiksliai): +$(selected_iso_delta)
Darbo katalogas:            $WORK_DIR

Eiga: binutils/GCC → glibc → GCC → programos → init → paketų tvarkyklė → Linux → pakavimas.
Baigti etapai bus praleisti. Kuriami failai lieka darbo kataloge.
PLAN
    else
        cat <<PLAN_EN

Architecture:                $TARGET_ARCH ($TARGET)
Login shell:                 $SHELL_CHOICE
/bin/sh for system scripts:  $posix_shell
System utilities:            $TOOLS_CHOICE
Init system:                 $INIT_CHOICE
Package manager:             $PACKAGE_MANAGER
Desktop:                     $DESKTOP_CHOICE
GCC in final system:         $WITH_GCC
Bootloader / image:          $BOOT_CHOICE
DHCP networking:             $NETWORK
Automatic login on tty1:     $AUTOLOGIN
Start MATE automatically:    $DESKTOP_AUTOSTART
Automatic host dependencies: $AUTO_INSTALL_DEPS
Build jobs:                  $JOBS
Image packaging jobs:        ${SQUASH_JOBS:-$JOBS}
Hostname:                    $SYSTEM_NAME
OS name:                     $OS_NAME
User with sudo access:       $USER_NAME
Extra programs:              Nginx=$PKG_NGINX PHP-FPM=$PKG_PHP nano=$PKG_NANO wget=$PKG_WGET OpenSSH=$PKG_OPENSSH ping=$PKG_PING neofetch=$PKG_NEOFETCH vim=$PKG_VIM fdisk=$PKG_FDISK Geany=$PKG_GEANY Firefox=$PKG_FIREFOX Caja=$PKG_CAJA Pluma=$PKG_PLUMA Engrampa=$PKG_ENGRAMPA EOM=$PKG_EOM MCC=$PKG_MATE_CONTROL_CENTER Power-Manager=$PKG_MATE_POWER_MANAGER Marco=built-in
Estimated selected-component ISO increase: +$(selected_iso_delta)
Working directory:           $WORK_DIR

Stages: binutils/GCC -> glibc -> GCC -> utilities -> init -> package manager -> Linux -> packaging.
Completed stages are skipped. Generated files remain in the working directory.
PLAN_EN
    fi
    if needs_busybox; then
        printf "$(tr_text 'BusyBox is included only when required by the selected shell, utilities, or init.\n' 'BusyBox bus įtrauktas tik pagal pasirinktą apvalkalą / įrankius / init.\n')"
    else
        printf "$(tr_text 'BusyBox will not be compiled or included for this configuration.\n' 'Šiam deriniui BusyBox nebus kompiliuojamas ar įtraukiamas.\n')"
    fi
    [[ "$PACKAGE_MANAGER" == none ]] || printf "$(tr_text 'Packages require your own compatible repository; base files are not registered in its database.\n' 'Paketams reikės savo suderinamos saugyklos; bazė neįregistruota jos duomenų bazėje.\n')"
    [[ "$ROOT_PASSWORD_HASH" != '!' ]] || printf "$(tr_text 'Root account is locked; set a password to log in as root.\n' 'Root paskyra užrakinta; prisijungimui reikia nustatyti slaptažodį.\n')"
}

# dialog naudoja ncurses: rodyklės juda, tarpas keičia varnelę, Enter patvirtina.
tui_ready() {
    [[ -t 0 && -t 1 && ${TERM:-dumb} != dumb ]] || die "$(tr_text 'The menu requires an interactive terminal (TERM must not be dumb). --build works without a menu.' 'Meniu reikia interaktyvaus terminalo (TERM ne dumb). --build veikia be meniu.')"
    if ! command -v dialog >/dev/null; then
        [[ "$AUTO_INSTALL_DEPS" == yes ]] || die "$(tr_text 'The menu requires dialog. Install dialog or use --build.' 'Meniu reikia dialog paketo. Įdiek dialog arba naudok --build.')"
        host_package_manager || die "$(tr_text 'Install dialog using your package manager' 'Įdiek dialog paketą savo paketų tvarkykle')"
        HOST_PACKAGES=(dialog)
        install_host_dependencies
    fi
    command -v dialog >/dev/null || die "$(tr_text 'Failed to install dialog' 'Nepavyko įdiegti dialog')"
}

tui() {
    local status rc
    rc=$(mktemp "${TMPDIR:-/tmp}/diy-linux-dialog.XXXXXX")
    cat > "$rc" <<'DIALOGRC'
# Shared DIY Linux terminal dialog palette: blue panels, white borders/text.
use_colors = ON
use_shadow = OFF
screen_color = (WHITE,BLUE,OFF)
shadow_color = (BLACK,BLUE,OFF)
dialog_color = (WHITE,BLUE,OFF)
title_color = (WHITE,BLUE,ON)
border_color = (WHITE,BLUE,ON)
border2_color = (WHITE,BLUE,ON)
button_active_color = (BLUE,WHITE,ON)
button_inactive_color = (WHITE,BLUE,OFF)
button_key_active_color = (BLUE,WHITE,ON)
button_key_inactive_color = (WHITE,BLUE,ON)
button_label_active_color = (BLUE,WHITE,ON)
button_label_inactive_color = (WHITE,BLUE,OFF)
inputbox_color = (WHITE,BLUE,OFF)
inputbox_border_color = (WHITE,BLUE,ON)
inputbox_border2_color = (WHITE,BLUE,ON)
searchbox_color = (WHITE,BLUE,OFF)
searchbox_title_color = (WHITE,BLUE,ON)
searchbox_border_color = (WHITE,BLUE,ON)
position_indicator_color = (WHITE,BLUE,ON)
menubox_color = (WHITE,BLUE,OFF)
menubox_border_color = (WHITE,BLUE,ON)
menubox_border2_color = (WHITE,BLUE,ON)
item_color = (WHITE,BLUE,OFF)
item_selected_color = (BLUE,WHITE,ON)
tag_color = (WHITE,BLUE,ON)
tag_selected_color = (BLUE,WHITE,ON)
tag_key_color = (WHITE,BLUE,ON)
tag_key_selected_color = (BLUE,WHITE,ON)
check_color = (WHITE,BLUE,OFF)
check_selected_color = (BLUE,WHITE,ON)
uarrow_color = (WHITE,BLUE,ON)
darrow_color = (WHITE,BLUE,ON)
itemhelp_color = (WHITE,BLUE,OFF)
form_active_text_color = (BLUE,WHITE,ON)
form_text_color = (WHITE,BLUE,OFF)
form_item_readonly_color = (WHITE,BLUE,ON)
gauge_color = (WHITE,BLUE,ON)
DIALOGRC
    if TUI_VALUE=$(DIALOGRC="$rc" dialog --stdout --clear --backtitle "$(tr_text 'DIY Linux - configuration' 'DIY Linux — konfigūracija')" --ok-label "$(tr_text 'OK' 'Gerai')" --cancel-label "$(tr_text 'Back' 'Atgal')" --yes-label "$(tr_text 'Yes' 'Taip')" --no-label "$(tr_text 'No' 'Ne')" --help-label "$(tr_text 'Help' 'Pagalba')" "$@"); then
        rm -f -- "$rc"
        return 0
    else
        status=$?
        rm -f -- "$rc"
        case "$status" in 1|255) return 1 ;; 2) return 2 ;; *) die "$(tr_text "dialog error (status $status)" "dialog klaida (kodas $status)")" ;; esac
    fi
}

tui_input() {
    local variable=$1 title=$2
    if tui --title "$title" --inputbox "$title" 10 76 "${!variable}"; then
        printf -v "$variable" '%s' "$TUI_VALUE"
    fi
    return 0
}

language_options() {
    if [[ $DIY_LANG == lt ]]; then
        cat <<'OPTIONS_LT'
WITH_GCC GCC, binutils, make ir antraštės galutinėje sistemoje
NETWORK DHCP tinklas
AUTO_INSTALL_DEPS Automatiškai įdiegti trūkstamus šeimininko paketus
AUTOLOGIN Automatinis vartotojo prisijungimas vietinėje tty1 konsolėje (be slaptažodžio)
PKG_NGINX Nginx — HTTP žiniatinklio serveris
PKG_PHP PHP-FPM — PHP FastCGI vykdymo aplinka (kartu įjungia Nginx)
PKG_NANO nano — teksto redaktorius
PKG_WGET wget — atsisiuntimai su HTTPS
PKG_OPENSSH OpenSSH klientas ir serveris — sshd paleidžiamas automatiškai
PKG_PING ping / ping6 — tinklo patikra
PKG_VIM vim — teksto redaktorius
PKG_FDISK fdisk — disko skaidinių įrankis
OPTIONS_LT
        if [[ "$DESKTOP_CHOICE" == mate || "$DESKTOP_CHOICE" == lxde || "$DESKTOP_CHOICE" == fluxbox ]]; then
            printf '%s\n' 'DESKTOP_AUTOSTART Automatiškai paleisti grafinę sesiją prisijungus vietinėje tty1 konsolėje'
        fi
        if [[ "$DESKTOP_CHOICE" == mate ]]; then
            printf '%s\n' 'PKG_GEANY Geany — Notepad++ alternatyva' 'PKG_FIREFOX Firefox — Mozilla naršyklė (x86_64)' 'PKG_PLUMA Pluma — MATE teksto redaktorius' 'PKG_CAJA Caja — failų tvarkyklė' 'PKG_ENGRAMPA Engrampa — archyvų tvarkyklė' 'PKG_EOM Eye of MATE — paveikslėlių peržiūra' 'PKG_MATE_CONTROL_CENTER MATE Control Center — nustatymai (Polkit / UDisks2; systemd arba elogind)' 'PKG_MATE_POWER_MANAGER MATE Power Manager — energijos valdymas (Polkit / UPower; systemd arba elogind)'
        elif [[ "$DESKTOP_CHOICE" == fluxbox ]]; then
            printf '%s\n' 'PKG_FIREFOX Firefox — Mozilla naršyklė smėlio dėžėje (x86_64)'
        elif [[ "$DESKTOP_CHOICE" == lxde ]]; then
            printf '%s\n' 'PKG_FIREFOX Firefox — Mozilla naršyklė smėlio dėžėje (x86_64)'
        fi
    else
        cat <<'OPTIONS_EN'
WITH_GCC GCC, binutils, make, and headers in the final system
NETWORK DHCP networking
AUTO_INSTALL_DEPS Automatically install missing host packages
AUTOLOGIN Automatically log in to the configured user account on local tty1 (no password prompt)
PKG_NGINX Nginx - HTTP web server
PKG_PHP PHP-FPM - PHP FastCGI runtime (also enables Nginx)
PKG_NANO nano - text editor
PKG_WGET wget - HTTPS downloads
PKG_OPENSSH OpenSSH client and server - sshd starts automatically at boot
PKG_PING ping / ping6 - network checks
PKG_VIM vim - text editor
PKG_FDISK fdisk - disk partition tool
OPTIONS_EN
        if [[ "$DESKTOP_CHOICE" == mate || "$DESKTOP_CHOICE" == lxde || "$DESKTOP_CHOICE" == fluxbox ]]; then
            printf '%s\n' 'DESKTOP_AUTOSTART Start the graphical session automatically after local tty1 login'
        fi
        if [[ "$DESKTOP_CHOICE" == mate ]]; then
            printf '%s\n' 'PKG_GEANY Geany - Notepad++ alternative' 'PKG_FIREFOX Firefox - Mozilla browser (x86_64)' 'PKG_PLUMA Pluma - MATE text editor' 'PKG_CAJA Caja - file manager' 'PKG_ENGRAMPA Engrampa - archive manager' 'PKG_EOM Eye of MATE - image viewer' 'PKG_MATE_CONTROL_CENTER MATE Control Center - settings (Polkit / UDisks2; systemd or elogind)' 'PKG_MATE_POWER_MANAGER MATE Power Manager - power management (Polkit / UPower; systemd or elogind)'
        elif [[ "$DESKTOP_CHOICE" == fluxbox ]]; then
            printf '%s\n' 'PKG_FIREFOX Firefox - Mozilla browser in a filesystem sandbox (x86_64)'
        elif [[ "$DESKTOP_CHOICE" == lxde ]]; then
            printf '%s\n' 'PKG_FIREFOX Firefox - Mozilla browser in a filesystem sandbox (x86_64)'
        fi
    fi
}

# Conservative estimates of incremental compressed ISO size, in 0.1 MiB units.
# Shared libraries already present in the chosen base/desktop are not counted
# twice; actual SquashFS compression depends on the final package set.
estimate_iso_tenths() {
    local key=$1 low=0 high=0
    case "$key" in
        extra:PKG_NANO) low=2; high=5 ;;
        extra:PKG_WGET) low=8; high=15 ;;
        extra:PKG_OPENSSH) low=25; high=50 ;;
        extra:PKG_PING) low=1; high=3 ;;
        extra:PKG_NEOFETCH) low=1; high=2 ;;
        extra:PKG_VIM) low=15; high=30 ;;
        extra:PKG_FDISK) low=2; high=6 ;;
        extra:PKG_GEANY) low=20; high=50 ;;
        extra:PKG_FIREFOX) low=800; high=1200 ;;
        extra:PKG_PLUMA) low=10; high=30 ;;
        extra:PKG_CAJA) low=30; high=80 ;;
        extra:PKG_ENGRAMPA) low=10; high=30 ;;
        extra:PKG_EOM) low=30; high=90 ;;
        extra:PKG_MATE_CONTROL_CENTER) low=100; high=260 ;;
        extra:PKG_MATE_POWER_MANAGER) low=40; high=110 ;;
        extra:PKG_NGINX) low=25; high=60 ;;
        extra:PKG_PHP) low=100; high=220 ;;
        extra:WITH_GCC) low=400; high=1000 ;;
        extra:NETWORK) low=1000; high=3000 ;;
        extra:AUTOLOGIN) low=0; high=0 ;;
        extra:DESKTOP_AUTOSTART) low=0; high=0 ;;
        manager:apt) low=80; high=200 ;;
        manager:pacman) low=50; high=120 ;;
        desktop:none) low=0; high=0 ;;
        desktop:mate) low=700; high=1400 ;;
        desktop:fluxbox) low=800; high=1600 ;;
        desktop:lxde) low=900; high=1800 ;;
        shell:zsh) low=10; high=30 ;;
        shell:fish) low=50; high=150 ;;
        shell:dash) low=1; high=3 ;;
        shell:busybox)
            if [[ ${TOOLS_CHOICE:-gnu} == busybox ]]; then low=0; high=0; else low=5; high=20; fi ;;
        tools:busybox) low=5; high=20 ;;
        tools:gnu) low=100; high=250 ;;
        init:busybox)
            if [[ ${TOOLS_CHOICE:-gnu} == busybox || ${SHELL_CHOICE:-bash} == busybox ]]; then low=0; high=0; else low=5; high=20; fi ;;
        init:openrc) low=5; high=15 ;;
        init:sysvinit) low=1; high=3 ;;
        init:runit) low=2; high=5 ;;
        init:dinit) low=3; high=8 ;;
        init:s6) low=5; high=12 ;;
        init:systemd) low=100; high=250 ;;
        boot:bios|boot:uefi) low=10; high=30 ;;
        boot:syslinux|boot:lilo) low=5; high=15 ;;
        boot:refind) low=20; high=50 ;;
        boot:limine) low=10; high=30 ;;
        boot:systemd-boot) low=10; high=30 ;;
        boot:efistub|boot:none) low=0; high=0 ;;
        # Bash is included for the system helpers even when another shell is
        # selected, so selecting Bash itself adds no extra ISO data.
        shell:bash|shell:dash|shell:busybox) low=0; high=0 ;;
    esac
    printf '%s %s\n' "$low" "$high"
}

format_iso_tenths() {
    printf '%d.%d' "$(( $1 / 10 ))" "$(( $1 % 10 ))"
}

iso_estimate_label() {
    local low high
    read -r low high <<< "$(estimate_iso_tenths "$1:$2")"
    if (( high == 0 )); then
        printf '%s' "$(tr_text '+0 MiB ISO' '+0 MiB ISO')"
    else
        printf '+~%s–%s MiB ISO' "$(format_iso_tenths "$low")" "$(format_iso_tenths "$high")"
    fi
}

profile_choice_iso_range() {
    local key low high total_low=0 total_high=0
    for key in "desktop:$DESKTOP_CHOICE" "shell:$SHELL_CHOICE" "tools:$TOOLS_CHOICE" \
        "init:$INIT_CHOICE" "manager:$PACKAGE_MANAGER" "boot:$BOOT_CHOICE"; do
        read -r low high <<< "$(estimate_iso_tenths "$key")"
        total_low=$((total_low + low)); total_high=$((total_high + high))
    done
    printf '%s %s\n' "$total_low" "$total_high"
}

selected_iso_delta() {
    local option low high total_low total_high
    read -r total_low total_high <<< "$(profile_choice_iso_range)"
    for option in PKG_NANO PKG_WGET PKG_OPENSSH PKG_PING PKG_NEOFETCH PKG_VIM PKG_FDISK PKG_GEANY \
        PKG_FIREFOX PKG_PLUMA PKG_CAJA PKG_ENGRAMPA PKG_EOM \
        PKG_MATE_CONTROL_CENTER PKG_MATE_POWER_MANAGER PKG_NGINX PKG_PHP WITH_GCC NETWORK AUTOLOGIN DESKTOP_AUTOSTART; do
        [[ ${!option} == yes ]] || continue
        read -r low high <<< "$(estimate_iso_tenths "extra:$option")"
        total_low=$((total_low + low)); total_high=$((total_high + high))
    done
    printf '%s–%s MiB' "$(format_iso_tenths "$total_low")" "$(format_iso_tenths "$total_high")"
}

pending_iso_delta() {
    local -n choices=$1
    local option low high total_low total_high
    read -r total_low total_high <<< "$(profile_choice_iso_range)"
    for option in "${!choices[@]}"; do
        [[ ${choices[$option]} == yes ]] || continue
        read -r low high <<< "$(estimate_iso_tenths "extra:$option")"
        total_low=$((total_low + low)); total_high=$((total_high + high))
    done
    if [[ ${choices[PKG_PHP]:-no} == yes && ${choices[PKG_NGINX]:-no} != yes ]]; then
        read -r low high <<< "$(estimate_iso_tenths extra:PKG_NGINX)"
        total_low=$((total_low + low)); total_high=$((total_high + high))
    fi
    printf '%s–%s MiB' "$(format_iso_tenths "$total_low")" "$(format_iso_tenths "$total_high")"
}

extras_menu() {
    local option state selected status help_tag
    local menu_note base_note size_label
    local -A pending=()
    local -a entries=()
    base_note="$(tr_text 'Common console tools are shared by all profiles. Graphical applications below are filtered for the selected desktop.' 'Bendros terminalo programos tinka visiems profiliams. Grafinės programos parodomos pagal pasirinktą darbalaukį.')"
    case "$DESKTOP_CHOICE" in
        mate) base_note+=$'\n'"$(tr_text 'Marco and xterm are included; xterm is the desktop terminal. Firefox, Pluma, Caja, Engrampa, and Eye of MATE are optional.' 'Marco ir xterm įtraukti; xterm yra darbalaukio terminalas. Firefox, Pluma, Caja, Engrampa ir Eye of MATE pasirenkami papildomai.')" ;;
        fluxbox) base_note+=$'\n'"$(tr_text 'Fluxbox is a standalone window-manager desktop. XTerm is included; select optional applications below.' 'Fluxbox yra atskiras langų tvarkyklės darbalaukis. XTerm įtrauktas; papildomas programas pasirink žemiau.')" ;;
    esac
    while read -r option description; do
        state=off; [[ ${!option} != yes ]] || state=on
        pending[$option]=${!option}
        size_label=$(iso_estimate_label extra "$option")
        entries+=("$option" "$description ($size_label)" "$state" "$(tr_text "$description - Help: advantages and limitations" "$description — Pagalba: privalumai ir trūkumai")")
    done < <(language_options)
    while :; do
        menu_note=$base_note
        menu_note+=$'\n'"$(tr_text 'Estimated ISO increase (base system/kernel excluded): +' 'Numatomas ISO prieaugis (bazinė sistema ir branduolys neįtraukti): +')$(pending_iso_delta pending). $(tr_text 'Approximate; shared dependencies and compression affect the result.' 'Apytiksliai; rezultatą keičia bendros priklausomybės ir glaudinimas.')"
        if tui --title "$(tr_text "Applications for $DESKTOP_CHOICE and system features" "$DESKTOP_CHOICE programos ir sistemos funkcijos")" --help-button --help-tags --help-status --item-help --separate-output --checklist \
            "$menu_note
$(tr_text 'Space: toggle | Enter: save | Help: description | Esc: cancel.' 'Tarpas: varnelė | Enter: išsaugoti | Pagalba: aprašymas | Esc: atšaukti.')" 22 80 12 "${entries[@]}"; then
            for option in "${!pending[@]}"; do printf -v "$option" no; done
            while IFS= read -r selected; do
                [[ -z "$selected" || ! -v pending[$selected] ]] || printf -v "$selected" yes
            done <<< "$TUI_VALUE"
            break
        else
            status=$?
            [[ "$status" == 2 ]] || break
            # --help-status su --separate-output grąžina HELP tag, tada pažymėtas eilutes.
            help_tag=${TUI_VALUE%%$'\n'*}; help_tag=${help_tag#HELP }
            for option in "${!pending[@]}"; do pending[$option]=no; done
            while IFS= read -r selected; do
                [[ -z "$selected" || ! -v pending[$selected] ]] || pending[$selected]=yes
            done <<< "${TUI_VALUE#*$'\n'}"
            for ((option=0; option<${#entries[@]}; option+=4)); do
                selected=${entries[option]}; state=off
                [[ ${pending[$selected]} != yes ]] || state=on
                entries[option+2]=$state
            done
            tui --title "$(tr_text 'Program / feature description' 'Programos / funkcijos aprašymas')" --scrolltext --msgbox \
                "$(platform_description extra "$help_tag")" 20 78 || :
        fi
    done
    return 0
}

platform_description() {
    case "$1:$2" in
        desktop:none) printf '%s' "$(tr_text 'Console only: smaller image and fewer dependencies. Graphical applications are not included.' 'Tik terminalas: mažesnis atvaizdas ir mažiau priklausomybių. Grafinės programos neįtraukiamos.')" ;;
        desktop:mate) printf '%s' "$(tr_text 'MATE + Xorg

+ Classic GTK desktop; includes Marco, panel, session and notification services.
- Source build is experimental and takes more time, disk space, and RAM; source recipe targets x86_64. GNU utilities support every init choice; BusyBox utilities pair with BusyBox init. Shell, compatible bootloader, package manager, GCC and network options are selectable.
Run startmate after logging into a local console. PulseAudio starts in the desktop session; Sound Mixer opens the ALSA controls. NetworkManager tray applet is included when NETWORK=yes.' 'MATE + Xorg

+ Klasikinis GTK darbalaukis; Marco, skydelis, sesija ir pranešimų tarnybos.
- Šaltinių kūrimas eksperimentinis, užima laiko, vietos diske ir RAM; receptas skirtas x86_64. GNU įrankiai palaiko visas init sistemas, o BusyBox įrankiai derinami su BusyBox init. Galima pasirinkti apvalkalą, suderinamą paleidyklę, paketų tvarkyklę, GCC ir tinklą.
Prisijungęs vietinėje konsolėje paleisk startmate. PulseAudio paleidžiamas darbalaukio sesijoje, „Garso maišytuvas“ atveria ALSA valdiklius. NetworkManager piktograma įtraukiama, kai NETWORK=yes.')" ;;
        desktop:fluxbox) printf '%s' "$(tr_text 'Fluxbox + Xorg

+ Lightweight standalone window-manager desktop; works with the selected init system.
- No full desktop suite or file manager. XTerm is included; networking and Firefox are optional.
Start with startfluxbox.' 'Fluxbox + Xorg

+ Lengvas atskiras langų tvarkyklės darbalaukis; veikia su pasirinkta init sistema.
- Nėra pilno darbalaukio paketo ar failų tvarkyklės. Įtraukiamas XTerm; tinklas ir Firefox pasirenkami.
Paleisk komanda startfluxbox.')" ;;
        desktop:lxde) printf '%s' "$(tr_text 'LXDE + Xorg\n\n+ Lightweight GTK desktop with a panel, session manager and PCManFM file manager.\n- Source compilation takes time and space; profile currently targets x86_64. GNU utilities support all init choices; BusyBox utilities pair with BusyBox init.\nFluxbox is used as LXDE window manager but remains a separate desktop choice. Run startlxde after local login.' 'LXDE + Xorg\n\n+ Lengvas GTK darbalaukis su skydeliu, sesijų valdikliu ir PCManFM failų tvarkykle.\n- Kompiliavimas užima laiko ir vietos; profilis kol kas skirtas x86_64. GNU įrankiai palaiko visas init sistemas, BusyBox įrankiai derinami su BusyBox init.\nLXDE langų tvarkyklė yra Fluxbox, bet Fluxbox lieka atskiras darbalaukio pasirinkimas. Prisijungęs vietinėje konsolėje paleisk startlxde.')" ;;
        arch:x86_64) printf '%s' "$(tr_text 'AMD64 / Intel64

+ 64-bit AMD and Intel PCs, broad software support.
- Not for 32-bit or ARM processors. This build currently targets this architecture.' 'AMD64 / Intel64

+ 64 bitų AMD ir Intel PC, platus programų palaikymas.
- Netinka 32 bitų ar ARM procesoriams. Šiame kūrime kol kas palaikoma ši architektūra.')" ;;
        arch:i686) printf '%s' "$(tr_text 'x86 / i686

+ For older 32-bit PCs.
- Limited address space and declining support in new software. Cross execution requires QEMU binfmt.' 'x86 / i686

+ Senesniems 32 bitų PC.
- Ribota adresuojama atmintis ir mažėjantis naujų programų palaikymas. Kryžminiam vykdymui reikia QEMU binfmt.')" ;;
        arch:aarch64) printf '%s' "$(tr_text 'ARM64

+ 64-bit ARM, QEMU virt / UEFI.
- Board support may require a specific kernel, DTB, and firmware. ' 'ARM64

+ 64 bitų ARM, QEMU virt / UEFI.
- Vien architektūros nepakanka konkrečiai plokštei: gali reikėti jos branduolio, DTB ir firmware. ')" ;;
        shell:busybox) printf '%s' "$(tr_text 'BusyBox ash

+ Small POSIX shell for minimal systems.
- Lacks Bash extensions and many interactive conveniences. Requires BusyBox.' 'BusyBox ash

+ Mažas POSIX apvalkalas, tinka minimaliai sistemai.
- Neturi Bash plėtinių ir tokio interaktyvaus patogumo. Įtraukiamas BusyBox.')" ;;
        shell:bash) printf '%s' "$(tr_text 'Bash

+ Widely used, convenient for interactive work and scripts.
- Larger than dash / ash; Bash extensions are not POSIX.' 'Bash

+ Plačiai naudojamas, patogus interaktyviai ir scenarijams.
- Didesnis už dash / ash; Bash plėtiniai nėra POSIX.')" ;;
        shell:dash) printf '%s' "$(tr_text 'dash

+ Small, fast POSIX shell.
- Basic interactive editing, no Bash extensions. Bash is still included for system helper tools.' 'dash

+ Mažas ir greitas POSIX apvalkalas.
- Kuklus interaktyvus redagavimas, nėra Bash plėtinių. Bash vis tiek įtraukiamas pagalbiniams sistemos įrankiams.')" ;;
        shell:zsh) printf '%s' "$(tr_text 'Zsh

+ Convenient completion, history, and interactive use.
- More configuration; system /bin/sh will be dash.' 'Zsh

+ Patogus užbaigimas, istorija ir interaktyvus darbas.
- Daugiau konfigūracijos; sistemos /bin/sh bus dash.')" ;;
        shell:fish) printf '%s' "$(tr_text 'Fish

+ Suggestions and convenient interactive completion.
- Non-POSIX syntax; building requires Rust / Cargo. System /bin/sh will be dash.' 'Fish

+ Pasiūlymai ir patogus interaktyvus užbaigimas.
- Ne POSIX sintaksė; kompiliavimui reikia Rust / Cargo. Sistemos /bin/sh bus dash.')" ;;
        tools:busybox) printf '%s' "$(tr_text 'BusyBox utilities

+ Many commands in one small binary, smaller image.
- Some GNU options and features are missing; not compatible with every init recipe.' 'BusyBox įrankiai

+ Daug komandų viename mažame faile, mažesnis atvaizdas.
- Kai kurių GNU parametrų ir funkcijų nėra; ne visi init receptai su jais suderinami.')" ;;
        tools:gnu) printf '%s' "$(tr_text 'GNU + util-linux

+ Full-featured commands and better script compatibility.
- More sources, build time, and disk space.' 'GNU + util-linux

+ Išsamios komandos ir geresnis scenarijų suderinamumas.
- Daugiau šaltinių, kompiliavimo laiko ir vietos diske.')" ;;
        manager:none) printf '%s' "$(tr_text 'No package manager

+ Smaller system, fewer dependencies.
- You manage files and updates yourself; source builds are possible with development tools.' 'Be paketų tvarkyklės

+ Mažesnė sistema, mažiau priklausomybių.
- Failus ir atnaujinimus administruoji pats; galima kompiliuoti iš šaltinių su kūrimo įrankiais.')" ;;
        manager:apt) printf '%s' "$(tr_text 'APT + dpkg

+ Tracks .deb packages; APT resolves dependencies.
- Requires your own compatible, signed repository. Debian / Ubuntu package compatibility is not guaranteed. Source-built base files are not automatically registered with dpkg.' 'APT + dpkg

+ .deb paketų apskaita, priklausomybių sprendimas su APT.
- Reikia savo suderinamos, pasirašytos saugyklos. Debian / Ubuntu paketų suderinamumas negarantuotas. Šaltinių bazė savaime neįregistruojama dpkg.')" ;;
        manager:pacman) printf '%s' "$(tr_text 'pacman

+ Straightforward package and repository management.
- Requires packages and a repository matching the DIY ABI. Arch packages are not automatically compatible; base files are not automatically registered.' 'pacman

+ Paprastas paketų administravimas ir saugyklų naudojimas.
- Reikia savo DIY ABI atitinkančių paketų ir saugyklos. Arch paketai savaime nesuderinami; bazės failai neįregistruojami automatiškai.')" ;;
        extra:WITH_GCC) printf '%s' "$(tr_text 'GCC and development tools

+ Compile C / C++ programs inside the final system.
- Much larger image. Other software may also need libraries, Meson, CMake, or Rust.' 'GCC ir kūrimo įrankiai

+ Galutinėje sistemoje galima kompiliuoti C / C++ programas.
- Gerokai didesnis atvaizdas. Kitoms programoms dar gali reikėti bibliotekų, Meson, CMake ar Rust.')" ;;
        extra:NETWORK) printf '%s' "$(tr_text 'DHCP networking

+ Obtains an IP address automatically for supported network adapters.
- Requires a DHCP server; does not manage Wi-Fi connections or passwords.' 'DHCP tinklas

+ Automatinis IP adreso gavimas palaikomai tinklo plokštei.
- Reikia DHCP serverio; tai nėra Wi-Fi prisijungimo ar slaptažodžių valdymas.')" ;;
        extra:AUTOLOGIN) printf '%s' "$(tr_text 'Automatic console login

+ Opens the configured user account on local tty1 without asking for its password.
- Anyone with physical access gets that account immediately. sudo still asks for the user password; serial consoles remain protected.' 'Automatinis prisijungimas konsolėje

+ Vietinėje tty1 konsolėje iškart atveria pasirinktą vartotojo paskyrą, neprašydamas slaptažodžio.
- Kiekvienas, turintis fizinę prieigą, iškart gauna šią paskyrą. sudo vis tiek prašo vartotojo slaptažodžio; nuoseklioji konsolė lieka apsaugota.')" ;;
        extra:DESKTOP_AUTOSTART) printf '%s' "$(tr_text 'Automatic desktop startup

+ Starts the selected desktop on tty1 after the user logs in; manual start command remains available on other consoles.
- Requires a local graphical tty and starts Xorg automatically. After the desktop exits, the console returns to the shell.' 'Automatinis MATE paleidimas

+ Prisijungus pasirinktam vartotojui tty1 konsolėje automatiškai paleidžia pasirinktą darbalaukį; kitose konsolėse sesiją galima paleisti rankiniu būdu.
- Reikia vietinės grafinės konsolės ir automatiškai paleidžia Xorg. Uždarius darbalaukį grįžtama į terminalą.')" ;;
        extra:AUTO_INSTALL_DEPS) printf '%s' "$(tr_text 'Host dependencies

+ Installs missing build packages automatically using apt, pacman, or dnf.
- Requires sudo and internet access; changes the host installed package list.' 'Šeimininko priklausomybės

+ Automatiškai įdiegia trūkstamus kūrimo paketus per apt, pacman ar dnf.
- Reikia sudo ir interneto; pakeičiamas šeimininko įdiegtų paketų sąrašas.')" ;;
        extra:PKG_NGINX) printf '%s' "$(tr_text 'Nginx HTTP web server

+ Serves static websites over HTTP; with PHP selected, sends PHP scripts to PHP-FPM.
- This source recipe enables HTTP/1.1, HTTP/2, TLS, gzip, and status support; TLS certificates and firewall rules must be configured by the administrator.' 'Nginx HTTP žiniatinklio serveris

+ Aptarnauja statines svetaines per HTTP; kartu pasirinkus PHP, PHP scenarijus perduoda PHP-FPM.
- Šaltinių receptas įjungia HTTP/1.1, HTTP/2, TLS, gzip ir būsenos modulį; TLS sertifikatus ir ugniasienės taisykles turi sukonfigūruoti administratorius.')" ;;
        extra:PKG_PHP) printf '%s' "$(tr_text 'PHP-FPM FastCGI support

+ Executes PHP scripts through a local FastCGI socket and includes PHP CLI for administration.
- Requires Nginx and builds the core runtime with common OpenSSL, zlib, XML, and SQLite support; application-specific extensions may need to be added later.' 'PHP-FPM FastCGI palaikymas

+ Vykdo PHP scenarijus per vietinį FastCGI lizdą ir įtraukia PHP CLI administravimui.
- Reikia Nginx. Kuriama pagrindinė aplinka su OpenSSL, zlib, XML ir SQLite palaikymu; konkrečiai programai gali reikėti papildomų plėtinių.')" ;;
        extra:PKG_NANO) printf '%s' "$(tr_text 'nano

+ Simple terminal editor with visible keyboard shortcuts.
- Less automation and fewer extensions than Vim.' 'nano

+ Paprastas terminalo redaktorius su matomomis klavišų nuorodomis.
- Mažiau automatizavimo ir plėtinių negu Vim.')" ;;
        extra:PKG_OPENSSH) printf '%s' "$(tr_text 'OpenSSH client and server

Provides ssh/scp/sftp client tools and the sshd server. The server starts automatically; host keys are generated on first boot, password login is enabled for the configured user, and direct root login is disabled.
The login welcome message prints the current IPv4 address and an ssh command when the network is up.' 'OpenSSH klientas ir serveris

Įtraukia ssh/scp/sftp klientus ir sshd serverį. Serveris paleidžiamas automatiškai; host raktai sukuriami pirmo paleidimo metu, slaptažodžiu gali jungtis nustatytas vartotojas, o tiesioginis root prisijungimas išjungtas.
Prisijungimo pasisveikinime rodomas dabartinis IPv4 adresas ir ssh komanda, kai tinklas veikia.')" ;;
        extra:PKG_WGET) printf '%s' "$(tr_text 'wget

+ HTTP / HTTPS downloads, including resuming downloads.
- HTTPS requires a TLS library and trusted certificates.' 'wget

+ Failų atsisiuntimas per HTTP / HTTPS, tęsiami atsisiuntimai.
- HTTPS reikia TLS bibliotekos ir patikimų sertifikatų.')" ;;
        extra:PKG_PING) printf '%s' "$(tr_text 'ping / ping6

+ Checks ICMP reachability and latency.
- Does not diagnose every network problem; ICMP may be filtered.' 'ping / ping6

+ Tikrina ICMP pasiekiamumą ir uždelsimą.
- Neparodo visų tinklo problemų; ICMP gali būti filtruojamas.')" ;;
        extra:PKG_VIM) printf '%s' "$(tr_text 'Vim

+ Powerful modal editor, macros, and search.
- Requires learning modes: i to type, Esc and :wq to save / quit.' 'Vim

+ Galingas modalinis redaktorius, makrokomandos ir paieška.
- Reikia išmokti režimus: i rašyti, Esc ir :wq išsaugoti / išeiti.')" ;;
        extra:PKG_FDISK) printf '%s' "$(tr_text 'fdisk

+ Interactive disk partition table management.
- Writing changes can destroy data; does not format filesystems.' 'fdisk

+ Interaktyvus disko skaidinių lentelės tvarkymas.
- Įrašius pakeitimus galima prarasti duomenis; tai nėra failų sistemos formatavimo įrankis.')" ;;
        extra:PKG_GEANY) printf '%s' "$(tr_text 'Geany — native Linux editor

+ Tabs, syntax highlighting, and a lightweight interface; a practical Notepad++ alternative without Wine.
- Notepad++ plugins and Windows macros do not transfer automatically. Requires MATE / GTK desktop.' 'Geany — natyvus Linux redaktorius

+ Skirtukai, sintaksės spalvinimas ir lengva sąsaja; praktiška Notepad++ alternatyva be Wine.
- Notepad++ papildiniai ir Windows makrokomandos automatiškai neperkeliami. Reikia MATE / GTK darbalaukio.')" ;;
        extra:PKG_FIREFOX) printf '%s' "$(tr_text 'Firefox browser with a filesystem sandbox

+ Bubblewrap gives Firefox a private HOME, read-only system files, and access only to its profile plus ~/Downloads/Firefox; works on MATE and Fluxbox.
- Network access stays enabled. Xorg shares the display and clipboard, so this is not Qubes or a VM security boundary. Firefox is Mozilla x86_64 binary archive.' 'Firefox naršyklė su failų sistemos smėlio dėže

+ Bubblewrap suteikia Firefox atskirą HOME, tik skaitymui skirtus sistemos failus ir prieigą tik prie savo profilio bei ~/Downloads/Firefox; veikia MATE ir Fluxbox.
- Tinklas lieka pasiekiamas. Xorg dalijasi ekranu ir iškarpine, todėl tai nėra Qubes ar virtualios mašinos saugumo riba. Firefox yra Mozilla x86_64 dvejetainis archyvas.')" ;;
        extra:PKG_PLUMA) printf '%s' "$(tr_text 'Pluma — MATE text editor

+ GTK text editor with syntax highlighting, tabs, and MATE integration.
- Requires the MATE desktop and GtkSourceView; built from source.' 'Pluma — MATE teksto redaktorius

+ GTK redaktorius su sintaksės spalvinimu, skirtukais ir MATE integracija.
- Reikia MATE darbalaukio ir GtkSourceView; kompiliuojamas iš šaltinių.')" ;;
        extra:PKG_CAJA) printf '%s' "$(tr_text 'Caja

+ MATE file manager with desktop and archive integration.
- Optional; without it, MATE has no graphical file manager.' 'Caja

+ MATE failų tvarkyklė su darbalaukio ir archyvų integracija.
- Pasirenkama; be jos MATE neturės grafinės failų tvarkyklės.')" ;;
        extra:PKG_ENGRAMPA) printf '%s' "$(tr_text 'Engrampa — MATE archive manager

+ Graphical archive tool integrated with Caja and MATE.
- Supported formats depend on the archive commands included in the system.' 'Engrampa — MATE archyvų tvarkyklė

+ Grafinis archyvų įrankis, integruotas su Caja ir MATE.
- Palaikomi formatai priklauso nuo sistemoje esančių archyvavimo komandų.')" ;;
        extra:PKG_EOM) printf '%s' "$(tr_text 'Eye of MATE (EOM) — image viewer

+ Opens common image formats and integrates with the MATE desktop.
- Optional application; GTK image codecs determine which formats can be opened.' 'Eye of MATE (EOM) — paveikslėlių peržiūros programa

+ Atidaro įprastus paveikslėlių formatus ir integruojasi su MATE darbalaukiu.
- Pasirenkama programa; palaikomus formatus lemia įdiegtos GTK bibliotekos.')" ;;
        init:busybox) printf "$(tr_text 'BusyBox init\n\n+ Very small; simple inittab and shell scripts.\n- Few service management features; dependencies are managed manually.\nRequires the BusyBox binary.' 'BusyBox init\n\n+ Labai mažas, paprastas inittab ir shell scenarijai.\n- Nedaug paslaugų valdymo funkcijų; priklausomybes tvarkai pats.\nReikia BusyBox dvejetainio failo.')" ;;
        init:openrc) printf "$(tr_text 'OpenRC\n\n+ Shell scripts, service dependencies, straightforward administration; works with GNU or BusyBox utilities.\n- Less integrated than systemd; automatic login still needs GNU agetty.' 'OpenRC\n\n+ Shell scenarijai, paslaugų priklausomybės, lengvas administravimas; veikia su GNU arba BusyBox įrankiais.\n- Mažiau integracijos negu systemd; automatiniam prisijungimui vis tiek reikia GNU agetty.')" ;;
        init:sysvinit) printf "$(tr_text 'SysVinit\n\n+ Classic inittab, runlevels, and simple shell scripts.\n- Service dependencies and ordering are mostly configured manually.\nThis recipe includes getty, DHCP, and shutdown scripts; requires GNU utilities.' 'SysVinit\n\n+ Klasikinis inittab, runlevel ir paprasti shell scenarijai.\n- Paslaugų priklausomybes ir tvarką dažniausiai aprašo administratorius.\nŠis receptas įtraukia getty, DHCP ir išjungimo scenarijus; reikia GNU įrankių.')" ;;
        init:runit) printf "$(tr_text 'runit\n\n+ Small; supervises processes and restarts them after failure.\n- Dependencies lack the declarative model of systemd.\nServices in /etc/service, three boot stages in /etc/runit; requires GNU utilities.' 'runit\n\n+ Mažas, nuolat prižiūri procesus ir paleidžia juos po gedimo.\n- Priklausomybėms nėra tokio deklaratyvaus modelio kaip systemd.\nPaslaugos /etc/service, trys boot etapai /etc/runit; reikia GNU įrankių.')" ;;
        init:dinit) printf "$(tr_text 'Dinit 0.22.1 (beta)\n\n+ Lightweight service manager with explicit dependencies and process supervision.\n- Services need Dinit-specific descriptions; existing OpenRC / systemd scripts are not converted automatically.\nThis recipe uses /etc/dinit.d/boot, tty gettys, optional dhcpcd, and Dinit shutdown hooks. Requires GNU utilities and a C++ compiler.' 'Dinit 0.22.1 (beta)\n\n+ Lengva paslaugų tvarkyklė su aiškiomis priklausomybėmis ir procesų priežiūra.\n- Paslaugoms reikia Dinit formato aprašų; OpenRC / systemd scenarijai automatiškai nekonvertuojami.\nŠis receptas naudoja /etc/dinit.d/boot, tty getty, pasirenkamą dhcpcd ir Dinit išjungimo kablį. Reikia GNU įrankių ir C++ kompiliatoriaus.')" ;;
        init:s6) printf "$(tr_text 's6 + s6-rc + s6-linux-init\n\n+ s6 supervises processes; s6-rc orders one-shot and long-running services by dependencies.\n+ s6-linux-init supplies PID 1 startup, shutdown daemon, reboot and poweroff tools.\n- More components and configuration than a basic init.\nThe service database is compiled during boot and switched to the default state. Requires GNU utilities.' 's6 + s6-rc + s6-linux-init\n\n+ s6 prižiūri procesus, s6-rc pagal priklausomybes tvarko vienkartines ir nuolatines paslaugas.\n+ s6-linux-init pateikia PID 1 paleidimą, išjungimo tarnybą, perkrovimo ir išjungimo įrankius.\n- Daugiau komponentų ir konfigūracijos negu paprastas init.\nPaslaugų duomenų bazė sukompiliuojama paleidžiant sistemą ir įjungiama numatytoji būsena. Reikia GNU įrankių.')" ;;
        init:systemd) printf "$(tr_text 'systemd\n\n+ Service dependencies, cgroups, journal, socket activation.\n- Larger, more tightly integrated system.\nRequires GNU utilities. systemd-boot is a separate bootloader option.' 'systemd\n\n+ Paslaugų priklausomybės, cgroups, žurnalas, socket activation.\n- Didesnė ir glaudžiau integruota sistema.\nReikia GNU įrankių. systemd-boot yra atskiras paleidyklės pasirinkimas.')" ;;
        boot:bios) printf "$(tr_text 'GRUB 2 BIOS\n\n+ Flexible configuration, widely used; BIOS ISO.\n- Larger and more complex than small bootloaders.\nThis image targets BIOS / SeaBIOS.' 'GRUB 2 BIOS\n\n+ Lanksti konfigūracija, plačiai naudojamas; BIOS ISO.\n- Didesnis ir sudėtingesnis už mažas paleidykles.\nŠis atvaizdas skirtas BIOS / SeaBIOS.')" ;;
        boot:uefi) printf "$(tr_text 'GRUB 2 UEFI\n\n+ Flexible configuration and UEFI ISO.\n- More modules and build dependencies.\nRequires UEFI / OVMF to boot.' 'GRUB 2 UEFI\n\n+ Lanksti konfigūracija ir UEFI ISO.\n- Daugiau modulių bei kūrimo priklausomybių.\nPaleidimui reikia UEFI / OVMF.')" ;;
        boot:syslinux) printf "$(tr_text 'Syslinux / ISOLINUX\n\n+ Small, simple BIOS ISO bootloader with plain-text configuration.\n- Old stable release; this recipe has no UEFI variant.\nOutput: BIOS ISO with hybrid MBR.' 'Syslinux / ISOLINUX\n\n+ Maža, paprasta BIOS ISO paleidyklė, aiškus tekstinis konfigas.\n- Senoji stabili versija; šis receptas neturi UEFI varianto.\nRezultatas: BIOS ISO su hibridiniu MBR.')" ;;
        boot:lilo) printf "$(tr_text 'LILO 24.2 (legacy BIOS)\n\n+ Writes a traditional BIOS boot sector and works without GRUB.\n- Legacy project, x86 only; no UEFI and no ISO output.\nCreates a raw, partitioned IMG and uses sudo only to attach a loop device, format that new image, and install its boot sector. Never targets a physical disk.' 'LILO 24.2 (senasis BIOS)\n\n+ Įrašo tradicinį BIOS paleidimo sektorių ir veikia be GRUB.\n- Pasenęs projektas, tik x86; nepalaiko UEFI ir ISO.\nSukuria skaidytą raw IMG. sudo naudojamas tik tam naujam atvaizdui prijungti per loop, suformatuoti ir įrašyti paleidimo sektorių. Fizinis diskas neliečiamas.')" ;;
        boot:refind) printf "$(tr_text 'rEFInd\n\n+ Convenient UEFI multi-system selection; launches the EFI Linux stub.\n- Requires UEFI; this recipe configures a text entry for one system.\nOutput: UEFI ISO and FAT ESP image.' 'rEFInd\n\n+ Patogus UEFI kelių sistemų pasirinkimas, paleidžia EFI Linux stub.\n- UEFI būtinas; šiame recepte nustatomas tekstinis vienos sistemos įrašas.\nRezultatas: UEFI ISO ir FAT ESP atvaizdas.')" ;;
        boot:efistub) printf "$(tr_text 'EFISTUB\n\n+ The kernel is itself an EFI application; no separate bootloader needed.\n- No OS selection menu; initrd path is compiled into the kernel.\nOutput: UEFI ISO and FAT ESP; requires EFI_STUB support.' 'EFISTUB\n\n+ Branduolys pats yra EFI programa; nereikia atskiros paleidyklės.\n- Nėra OS pasirinkimo meniu; initrd kelias įkompiliuojamas į branduolį.\nRezultatas: UEFI ISO ir FAT ESP; reikia EFI_STUB palaikymo.')" ;;
        boot:limine) printf "$(tr_text 'Limine\n\n+ Modern bootloader; one hybrid BIOS and UEFI ISO.\n- Configuration syntax differs from GRUB and needs learning.\nLinux kernel and initramfs are loaded using the Linux protocol.' 'Limine\n\n+ Moderni paleidyklė, vienas BIOS ir UEFI hibridinis ISO.\n- Kitokia konfigūracijos sintaksė negu GRUB; reikia mokytis jos formato.\nLinux branduolys ir initramfs įkeliami Linux protokolu.')" ;;
        boot:systemd-boot) printf "$(tr_text 'systemd-boot\n\n+ Small UEFI bootloader with simple individual entry files.\n- No BIOS; kernel and initrd must be in a FAT area accessible to UEFI.\nWorks with OpenRC, runit, or other init systems; systemd PID 1 is not required.\nOutput: UEFI ISO and FAT ESP image.' 'systemd-boot\n\n+ Nedidelė UEFI paleidyklė, paprasti atskiri įrašų failai.\n- Nėra BIOS; branduolys ir initrd turi būti UEFI pasiekiamoje FAT srityje.\nVeikia ir su OpenRC, runit ar kitu init; systemd PID 1 nereikia.\nRezultatas: UEFI ISO ir FAT ESP atvaizdas.')" ;;
        boot:none) printf "$(tr_text 'No bootloader\n\n+ Only rootfs, kernel, and initramfs; convenient for direct QEMU boot.\n- No ISO / disk boot sector is created.' 'Be paleidyklės\n\n+ Tik rootfs, branduolys ir initramfs; patogu tiesioginiam QEMU boot.\n- ISO / disko boot sektorius nekuriamas.')" ;;
    esac
}

# Informaciniai darbalaukio profiliai ir build instrukcijos.
desktop_description() {
    case "$1" in
        lxde) printf '%s\n' "$(tr_text 'LXDE + Xorg

+ Lightweight GTK desktop with LXPanel, LXSession and PCManFM. Fluxbox is included as its window manager; the standalone Fluxbox desktop remains a separate choice.
- Source build takes extra time and disk space; profile targets x86_64. GNU utilities work with the selected init system; BusyBox utilities pair with BusyBox init.
Start from a local console with startlxde. NetworkManager and the sound mixer tray entries are configured when their features are selected.

Official component releases: https://github.com/lxde/releases' 'LXDE + Xorg

+ Lengvas GTK darbalaukis su LXPanel, LXSession ir PCManFM. Langų tvarkyklė yra Fluxbox; atskiras Fluxbox darbalaukis lieka atskiras pasirinkimas.
- Kompiliavimas užima papildomo laiko ir vietos; profilis skirtas x86_64. GNU įrankiai veikia su pasirinkta init sistema, BusyBox įrankiai derinami su BusyBox init.
Paleisk vietinėje konsolėje komanda startlxde. Pasirinkus tinklą ir garsą, sukonfigūruojamos NetworkManager ir maišytuvo dėklo piktogramos.

Oficialūs komponentų leidimai: https://github.com/lxde/releases')" ;;
        fluxbox) printf '%s\n' "$(tr_text 'Fluxbox + Xorg

+ Small, fast standalone X11 desktop session with a right-click menu and low memory use.
- No full desktop panel or file manager; XTerm is included and optional network tools are selected separately.
Source: Fluxbox 1.3.7, pinned and verified by SHA-256.
Log in locally and run startfluxbox; DESKTOP_AUTOSTART=yes starts it after tty1 login.
Upstream: https://fluxbox.org/download/' 'Fluxbox + Xorg

+ Nedidelė ir greita atskira X11 darbalaukio sesija su dešiniojo pelės mygtuko meniu; naudoja mažai atminties.
- Nėra viso darbalaukio skydelio ar failų tvarkyklės; XTerm įtrauktas, o tinklo programas galima pasirinkti atskirai.
Šaltinis: Fluxbox 1.3.7, versija prisegta ir tikrinama SHA-256 suma.
Prisijunk vietinėje konsolėje ir paleisk startfluxbox; DESKTOP_AUTOSTART=yes paleidžia jį prisijungus tty1.
Projektas: https://fluxbox.org/download/')" ;;
        mate) printf '%s\n' "$(tr_text 'MATE

+ Traditional, lightweight GTK desktop with panel, Marco window manager and session manager; select MATE Terminal, Pluma, Caja and Engrampa separately.
- The current source recipe targets x86_64 + Xorg; GNU utilities support all init choices, while BusyBox utilities pair with BusyBox init. Shell, bootloader, package manager, GCC and network options are selectable. The control center and optional applets are not included yet.
Pinned source line: official MATE 1.28 release tarballs. Desktop stack is built from source.
PulseAudio starts in the desktop session; the Sound Mixer opens ALSA volume and mute controls. With NETWORK=yes, NetworkManager provides Ethernet and Wi-Fi management with an autostarting GTK tray applet.

Upstream source: https://mate-desktop.org/
Build components: https://github.com/mate-desktop' 'MATE

+ Tradicinis, lengvas GTK darbalaukis su skydeliu, Marco ir sesijų valdikliu; MATE Terminal, Pluma, Caja ir Engrampa parenkami atskirai.
- Dabartinis šaltinių receptas skirtas x86_64 + Xorg; GNU įrankiai palaiko visas init sistemas, o BusyBox įrankiai derinami su BusyBox init. Galima pasirinkti apvalkalą, paleidyklę, paketų tvarkyklę, GCC ir tinklą. Nustatymų centras ir papildomos programėlės kol kas neįtraukti.
Užfiksuoti oficialūs MATE 1.28 leidimų archyvai. Darbalaukis kompiliuojamas iš šaltinių.
PulseAudio paleidžiamas darbalaukio sesijoje; „Garso maišytuvas“ keičia ALSA garsumą ir nutildymą. Kai NETWORK=yes, NetworkManager valdo Ethernet ir Wi-Fi, o GTK skydelio piktograma paleidžiama automatiškai.

Šaltiniai: https://mate-desktop.org/
Kūrimo komponentai: https://github.com/mate-desktop')" ;;
        *) die "$(tr_text 'Unknown desktop: mate' 'Nežinomas darbalaukis: mate')" ;;
    esac
    if [[ "$1" == lxde ]]; then
        printf "$(tr_text '\nLXDE recipe: TARGET_ARCH=x86_64 + Xorg. GNU utilities allow all init choices; BusyBox utilities require BusyBox init.\n' '\nLXDE receptas: TARGET_ARCH=x86_64 + Xorg. GNU įrankiai leidžia rinktis visas init sistemas; BusyBox įrankiams reikia BusyBox init.\n')"
        printf "$(tr_text 'Start after local login: startlxde. Includes LXPanel system tray, PCManFM desktop/file manager, sound mixer, and NetworkManager applet when enabled.\n' 'Paleisk prisijungęs vietinėje konsolėje: startlxde. Įtraukti LXPanel dėklas, PCManFM darbalaukis/failų tvarkyklė, garso maišytuvas ir įjungus tinklą NetworkManager piktograma.\n')"
        return
    fi
    if [[ "$1" == mate ]]; then
        printf "$(tr_text '\nMATE recipe: TARGET_ARCH=x86_64. GNU utilities allow all init choices; BusyBox utilities require BusyBox init. Choose a compatible bootloader.\n' '\nMATE receptas: TARGET_ARCH=x86_64. GNU įrankiai leidžia rinktis visas init sistemas; BusyBox įrankiams reikia BusyBox init. Pasirink suderinamą paleidyklę.\n')"
        printf "$(tr_text 'Start from a local console after boot: startmate. Mesa enables GLX, DRI3 and Xorg glamor acceleration for supported Intel, AMD, NVIDIA nouveau and virtio GPUs.\n' 'Paleisk užkrovęs sistemą vietinėje konsolėje: startmate. Mesa įjungia GLX, DRI3 ir Xorg glamor spartinimą palaikomoms Intel, AMD, NVIDIA nouveau ir virtio vaizdo plokštėms.\n')"
        printf "$(tr_text 'Built from pinned official MATE 1.28 source archives; session, Marco, panel and notification daemon are included. The application checklist selects MATE Terminal, Pluma, Caja and Engrampa.\n' 'Kompiliuojami oficialūs MATE 1.28 archyvai; įtraukiama sesija, Marco, skydelis ir pranešimų tarnyba. Programų meniu leidžia pasirinkti MATE Terminal, Pluma, Caja ir Engrampa.\n')"
        return
    fi
    if [[ "$1" == fluxbox ]]; then
        printf "$(tr_text '\nFluxbox recipe: TARGET_ARCH=x86_64 + Xorg; compatible with the selected init and utility profile. XTerm is included.\n' '\nFluxbox receptas: TARGET_ARCH=x86_64 + Xorg; suderinamas su pasirinkta init ir įrankių konfigūracija. Įtraukiamas XTerm.\n')"
        printf "$(tr_text 'Start after boot from a local console: startfluxbox. The root menu provides XTerm, audio mixer, network settings when enabled, and Firefox when selected.\n' 'Paleisk užkrovęs sistemą vietinėje konsolėje: startfluxbox. Pagrindiniame meniu yra XTerm, garso maišytuvas, įjungus tinklą — jo nustatymai, pasirinkus Firefox — naršyklė.\n')"
        return
    fi
    printf "$(tr_text '\nStatus: this script does not yet provide an automatic build recipe.\n' '\nBūsena: automatinio diegimo recepto šiame skripte dar nėra.\n')"
    printf "$(tr_text 'Graphics drivers, Mesa, fonts, input, D-Bus, PAM, and session infrastructure are required first.\n' 'Pirmiausia reikia grafikos tvarkyklių, Mesa, šriftų, įvesties, D-Bus, PAM ir sesijų infrastruktūros.\n')"
}

platform_menu() {
    local kind=$1 variable=$2 title=$3 tag description state status selected
    local -a entries=()
    shift 3
    while (( $# )); do
        tag=$1 description=$2; shift 2
        if [[ "$kind" == boot ]] && ! boot_compatible "$tag"; then continue; fi
        state=off; [[ ${!variable} != "$tag" ]] || state=on
        case "$kind" in desktop|shell|tools|init|manager|boot)
            description+=" ($(iso_estimate_label "$kind" "$tag"))"
            ;;
        esac
        entries+=("$tag" "$description" "$state" "$(tr_text "Help: $description" "Pagalba: $description")")
    done
    while :; do
        if tui --title "$title" --help-button --help-tags --item-help --radiolist \
            "$(tr_text 'Space: select | Enter: save | Help: advantages and limitations' 'Tarpas: pasirinkti | Enter: išsaugoti | Pagalba: privalumai ir trūkumai')" 22 80 12 "${entries[@]}"; then
            printf -v "$variable" '%s' "$TUI_VALUE"
            return 0
        else
            status=$?
            [[ "$status" == 2 ]] || return 0
            selected=${TUI_VALUE#HELP }
            tui --title "$(tr_text 'Advantages and limitations' 'Privalumai ir trūkumai')" --scrolltext --msgbox \
                "$(platform_description "$kind" "$selected")" 19 78 || :
        fi
    done
}

# Pradinis pasirinkimas atskiria naują kūrimą nuo esamo rootfs priežiūros.
start_menu() {
    local pending selected cpu_jobs recommended_jobs run_toolchain
    local -a entries=()
    tui_ready
    while :; do
        entries=(new "$(tr_text 'Create a new system - choose components' 'Kurti naują sistemą — pasirinkti komponentus')" edit "$(tr_text 'Edit an existing system - chroot, users, ISO / IMG' 'Redaguoti esamą sistemą — chroot, vartotojai, ISO / IMG')" toolchain "$(tr_text 'Build only the toolchain - no rootfs or ISO' 'Kurti tik toolchain — be rootfs ir ISO')" update "$(tr_text 'Update eligible pinned source versions' 'Atnaujinti patikrinamas šaltinių versijas')")
        pending=$(session_pointer)
        if [[ -f "$pending" ]]; then
            IFS= read -r selected < "$pending" || :
            if [[ -f "$selected/build.session" && ! -f "$selected/build.complete" ]]; then
                entries+=(resume "$(tr_text 'Resume an interrupted build' 'Tęsti nutrauktą kūrimą')")
            fi
        fi
        if ! tui --title "$(tr_text 'DIY Linux - start' 'DIY Linux — pradžia')" --cancel-label "$(tr_text 'Exit' 'Išeiti')" --menu \
            "$(tr_text 'Choose an action. New builds preserve previous systems and reuse a compatible toolchain.' 'Pasirink veiksmą. Naujas kūrimas išsaugo ankstesnes sistemas ir naudoja tinkamą toolchain.')" \
            15 80 5 "${entries[@]}"; then return 1; fi
        case "$TUI_VALUE" in
            new) START_MODE=--new; return 0 ;;
            resume) START_MODE=--resume; return 0 ;;
            edit) (edit_system_menu) ;;
            update) update_source_versions ;;
            toolchain)
                platform_menu arch TARGET_ARCH "$(tr_text 'Toolchain architecture' 'Toolchain architektūra')" x86_64 'AMD64 / Intel64' i686 'x86 / i686' aarch64 ARM64
                tui_input WORK_DIR "$(tr_text 'Working directory' 'Darbo katalogas')"
                cpu_jobs=$(maximum_build_jobs)
                recommended_jobs=$(recommended_memory_jobs MemTotal)
                [[ -n "$JOBS_WAS_EXPLICIT" ]] || JOBS=$(default_build_jobs)
                run_toolchain=yes
                while :; do
                    if ! tui --title "$(tr_text 'Toolchain build jobs' 'Toolchain kompiliavimo užduotys')" --inputbox \
                        "$(tr_text "CPU parallelism limit: $cpu_jobs jobs. Default: 80% of the CPU limit. RAM-based recommendation using total installed RAM: $recommended_jobs jobs; current RAM use and swap are not included. GCC bootstrap stages always use one job for memory safety." "CPU lygiagretumo riba: $cpu_jobs užduočių. Numatytasis skaičius: 80% CPU ribos. Rekomendacija pagal visą įdiegtą RAM: $recommended_jobs užduočių; dabartinis RAM naudojimas ir swap neįtraukiami. Saugumo dėlei GCC pradiniai etapai visada naudoja vieną užduotį.")" \
                        12 78 "$JOBS"; then
                        run_toolchain=no
                        break
                    fi
                    JOBS=$TUI_VALUE
                    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] && break
                    tui --title "$(tr_text 'Invalid job count' 'Netinkamas užduočių skaičius')" --msgbox \
                        "$(tr_text 'Enter a positive whole number, such as 4.' 'Įrašyk teigiamą sveikąjį skaičių, pavyzdžiui, 4.')" 9 68 || :
                done
                [[ "$run_toolchain" == yes ]] || continue
                if (build_toolchain_only); then
                    tui --title "$(tr_text 'Toolchain complete' 'Toolchain paruoštas')" --msgbox \
                        "$(tr_text 'The toolchain is saved and will be reused automatically by compatible system builds.' 'Toolchain išsaugotas ir bus automatiškai naudojamas suderinamiems sistemos kūrimams.')" 11 76 || :
                else
                    tui --title "$(tr_text 'Toolchain build failed' 'Toolchain kūrimas nepavyko')" --scrolltext --msgbox \
                        "$(tr_text "Toolchain build failed. Check the latest log under:\\n$WORK_DIR/toolchains/*/build.log\\n\\nYou can return to this menu and retry." "Toolchain kūrimas nepavyko. Patikrink naujausią žurnalą aplanke:\\n$WORK_DIR/toolchains/*/build.log\\n\\nGali grįžti į meniu ir bandyti dar kartą.")" 14 78 || :
                fi ;;
        esac
    done
}

edit_system_menu() {
    tui_ready
    list_systems
    if (( ${#SYSTEM_PATHS[@]} == 0 )); then
        tui --title "$(tr_text 'Existing systems' 'Esamos sistemos')" --msgbox "$(tr_text "No prepared systems in working directory: $WORK_DIR" "Darbo kataloge nėra paruoštų sistemų: $WORK_DIR")" 12 76 || :
        return 0
    fi
    select_system '' "$(tr_text 'Which existing system should be edited?' 'Kurią esamą sistemą redaguoti?')" || return 0
    load_system "$SELECTED_SYSTEM"
    local chosen=$BASE username
    while :; do
        if ! tui --title "$(tr_text "Edit: $SYSTEM_NAME ($TARGET_ARCH)" "Redaguoti: $SYSTEM_NAME ($TARGET_ARCH)")" --cancel-label "$(tr_text 'Back' 'Atgal')" --menu \
            "$(tr_text "Rootfs: $ROOT\nChanges in chroot persist; create ISO / IMG separately afterwards." "Rootfs: $ROOT\nPakeitimai chroot išlieka; po jų atskirai sukurk ISO / IMG.")" 20 80 8 \
            enter "$(tr_text 'Enter chroot - edit files and install programs' 'Prisijungti per chroot — keisti failus ir diegti programas')" \
            user "$(tr_text 'Add a user with sudo access' 'Pridėti vartotoją su sudo teisėmis')" \
            iso "$(tr_text 'Create ISO from the modified system' 'Sukurti ISO iš pakeistos sistemos')" img "$(tr_text 'Create IMG from the modified system' 'Sukurti IMG iš pakeistos sistemos')" \
            repack "$(tr_text 'Refresh all normal images for this profile' 'Atnaujinti visus šio profilio atvaizdus')" \
            info "$(tr_text 'View this system configuration' 'Peržiūrėti šios sistemos nustatymus')"; then return 0; fi
        case "$TUI_VALUE" in
            enter) (enter_system "$chosen") ;;
            user)
                username=$USER_NAME
                if tui --title "$(tr_text 'User with sudo access' 'Vartotojas su sudo')" --inputbox "$(tr_text 'Username; the password will be requested separately.' 'Vartotojo vardas; slaptažodžio bus paprašyta atskirai.')" 11 76 "$username"; then
                    username=$TUI_VALUE
                    (USER_PASSWORD_HASH='!'; add_user "$username" "$chosen")
                fi ;;
            iso|img)
                if [[ "$BOOT_CHOICE" == none ]]; then
                    tui --msgbox "$(tr_text 'This profile has no bootloader. Refresh the archives only.' 'Šis profilis neturi paleidyklės. Galima tik atnaujinti archyvus.')" 10 76 || :
                else (repack_system "$chosen" "$TUI_VALUE"); fi ;;
            repack) (repack_system "$chosen" auto) ;;
            info) tui --title "$(tr_text 'Saved system configuration' 'Išsaugoti sistemos nustatymai')" --textbox "$chosen/system.settings" 21 78 || : ;;
        esac
    done
}

menu_description() {
    case "$1" in
        arch) printf '%s' "$(tr_text 'Architecture defines the target CPU and ABI. AMD64 works on AMD and Intel. Help describes the limitations of each option.' 'Architektūra nusako tikslinį CPU ir ABI. AMD64 tinka ir AMD, ir Intel. Pasirinkimų lange Pagalba parodo kiekvieno varianto apribojimus.')" ;;
        shell) printf '%s' "$(tr_text 'The login shell controls terminal syntax and interactive work. System /bin/sh is chosen separately for compatibility. Each option has Help.' 'Prisijungimo apvalkalas valdo terminalo sintaksę ir interaktyvų darbą. Sistemos /bin/sh parenkamas atskirai pagal suderinamumą. Kiekvienas variantas turi Pagalbą.')" ;;
        tools) printf '%s' "$(tr_text 'BusyBox provides a small command set; GNU + util-linux offers more features and better option compatibility. Help lists advantages and limitations.' 'BusyBox yra mažas komandų rinkinys; GNU + util-linux turi daugiau funkcijų ir geresnį parametrų suderinamumą. Pasirinkimų lange yra privalumai ir trūkumai.')" ;;
        init) printf '%s' "$(tr_text 'Init is the first process (PID 1), starting and supervising services. Option Help describes each system.' 'Init yra pirmasis procesas (PID 1), kuris paleidžia ir prižiūri paslaugas. Pasirinkimų Pagalba aprašo kiekvieną sistemą.')" ;;
        manager) printf '%s' "$(tr_text 'The package manager installs prepared compatible packages. It does not turn DIY Linux into Debian or Arch. Supply your own packages and repositories.' 'Paketų tvarkyklė diegia paruoštus suderinamus paketus. Ji nepadaro DIY Linux Debian ar Arch sistema. Reikia savo paketų ir saugyklų.')" ;;
        boot) printf '%s' "$(tr_text 'The bootloader loads the kernel and initramfs. BIOS and UEFI differ; option Help describes available image types.' 'Paleidyklė įkelia branduolį ir initramfs. BIOS ir UEFI skiriasi; konkrečias atvaizdų galimybes rodo pasirinkimo Pagalba.')" ;;
        extras) printf '%s' "$(tr_text 'The checklist shows per-package estimates, and the combined profile estimate includes desktop, shell, tools, init, bootloader, package manager, and selected extras. It estimates added compressed ISO size, not the mandatory base system or kernel. Shared dependencies and compression can change the result. Neofetch and Welcome are included automatically.' 'Sąraše rodomas kiekvieno paketo įvertis, o bendra profilio suma apima darbalaukį, apvalkalą, įrankius, init, paleidyklę, paketų tvarkyklę ir papildomas programas. Tai papildomas suspausto ISO dydis, ne privalomos bazinės sistemos ar branduolio dydis. Bendros priklausomybės ir glaudinimas gali keisti rezultatą. Neofetch ir Welcome įtraukiami automatiškai.')" ;;
        jobs) printf '%s' "$(tr_text 'More parallel jobs can speed up builds but use more RAM. GCC uses one job. A safe initial choice is 1.' 'Didesnis lygiagrečių užduočių skaičius gali paspartinti kūrimą, bet naudoja daugiau RAM. GCC kuriamas su viena užduotimi. Saugus pradinis pasirinkimas: 1.')" ;;
        osname) printf '%s' "$(tr_text 'The OS name appears in /etc/os-release, login banners, and system lists. It is separate from the network hostname.' 'OS pavadinimas rodomas /etc/os-release faile, prisijungimo lange ir sistemų sąraše. Jis atskiras nuo tinklo kompiuterio vardo.')" ;;
        hostname) printf '%s' "$(tr_text 'The hostname is written to /etc/hostname and shown in the terminal. Use letters, digits, and hyphens, without spaces.' 'Kompiuterio vardas bus įrašytas į /etc/hostname ir rodomas terminale. Naudok raides, skaičius ir brūkšnelius, be tarpų.')" ;;
        user) printf '%s' "$(tr_text 'Regular user with sudo access. A password is requested before building. System administration: sudo -i.' 'Paprastas vartotojas su sudo teisėmis. Slaptažodžio bus paprašyta prieš kūrimą. Administravimas sistemoje: sudo -i.')" ;;
        directory) printf '%s' "$(tr_text 'Downloads, rootfs, images, and shared toolchains are stored here. Plenty of free space is required. The path must not contain spaces or apostrophes.' 'Čia laikomi atsisiuntimai, rootfs, atvaizdai ir bendri toolchain. Reikia daug laisvos vietos. Kelias turi būti be tarpų ir apostrofų.')" ;;
        toolchain) printf '%s' "$(tr_text 'Build only binutils, initial GCC, glibc, and final GCC. No rootfs or ISO. The compatible SDK is reused later. Repeating resumes completed stages.' 'Kurti tik binutils, pradinį GCC, glibc ir galutinį GCC. Rootfs ir ISO nekuriami. Suderinamas SDK panaudojamas vėliau. Pakartojus tęsiami baigti etapai.')" ;;
        desktop) printf '%s' "$(tr_text 'Choose console-only or MATE + Xorg.' 'Rinkis tik konsolę arba MATE + Xorg.')" ;;
        plan) printf '%s' "$(tr_text 'Preview selected settings without compiling anything.' 'Peržiūrėti pasirinktus nustatymus nieko nekompiliuojant.')" ;;
        build) printf '%s' "$(tr_text 'Start the full system build after reviewing the plan and entering passwords. Completed toolchain stages are reused.' 'Pradėti visos sistemos kūrimą po plano ir slaptažodžių įvedimo. Baigti toolchain etapai naudojami pakartotinai.')" ;;
        *) printf '%s' "$(tr_text 'Select an entry to open its settings.' 'Pasirink įrašą ir atverk jo nustatymus.')" ;;
    esac
}

menu_section_label() {
    case "$1" in
        arch) printf '%s' "$(tr_text "Architecture [$TARGET_ARCH]" "Architektūra [$TARGET_ARCH]")" ;;
        shell) printf '%s' "$(tr_text "Shell [$SHELL_CHOICE]" "Apvalkalas [$SHELL_CHOICE]")" ;;
        init) printf 'Init [%s]' "$INIT_CHOICE" ;;
        manager) printf '%s' "$(tr_text "Package manager [$PACKAGE_MANAGER]" "Paketų tvarkyklė [$PACKAGE_MANAGER]")" ;;
        desktop) printf '%s' "$(tr_text "Desktop [$DESKTOP_CHOICE]" "Darbalaukis [$DESKTOP_CHOICE]")" ;;
        extras) printf '%s' "$(tr_text 'Applications and features' 'Programos ir funkcijos')" ;;
        tools) printf '%s' "$(tr_text "System tools [$TOOLS_CHOICE]" "Sistemos įrankiai [$TOOLS_CHOICE]")" ;;
        boot) printf '%s' "$(tr_text "Bootloader [$BOOT_CHOICE]" "Paleidyklė [$BOOT_CHOICE]")" ;;
        jobs) printf '%s' "$(tr_text "Build jobs [$JOBS]" "Kompiliavimo užduotys [$JOBS]")" ;;
        osname) printf '%s' "$(tr_text "OS name [$OS_NAME]" "OS pavadinimas [$OS_NAME]")" ;;
        hostname) printf '%s' "$(tr_text "Hostname [$SYSTEM_NAME]" "Kompiuterio vardas [$SYSTEM_NAME]")" ;;
        user) printf '%s' "$(tr_text "User [$USER_NAME]" "Vartotojas [$USER_NAME]")" ;;
        directory) printf '%s' "$(tr_text 'Working directory' 'Darbo katalogas')" ;;
        plan) printf '%s' "$(tr_text 'Review selected settings' 'Peržiūrėti nustatymus')" ;;
        build) printf '%s' "$(tr_text 'Start build' 'Pradėti kūrimą')" ;;
    esac
}

menu_section_preview() {
    local extra_delta
    case "$1" in
        arch)
            printf '%s\n' "$(tr_text 'CPU ARCHITECTURE' 'CPU ARCHITEKTŪRA')" '' "$(tr_text "Selected: $TARGET_ARCH" "Pasirinkta: $TARGET_ARCH")" \
                'x86_64  AMD64 / Intel64, 64-bit PC' 'i686    32-bit x86 PC' 'aarch64 ARM64 / UEFI ARM' '' \
                "$(tr_text 'Enter to open the architecture choices.' 'Enter — atverti architektūros pasirinkimus.')" ;;
        shell)
            printf '%s\n' "$(tr_text 'LOGIN SHELL' 'PRISIJUNGIMO APVALKALAS')" '' "$(tr_text "Selected: $SHELL_CHOICE" "Pasirinkta: $SHELL_CHOICE")" \
                'bash  Bash interactive shell' 'dash  Small POSIX shell' 'zsh / fish  Optional shells' 'BusyBox ash  Minimal shell' '' \
                "$(tr_text 'Enter to choose a shell.' 'Enter — pasirinkti apvalkalą.')" ;;
        init)
            printf '%s\n' 'INIT SYSTEM' '' "$(tr_text "Selected: $INIT_CHOICE" "Pasirinkta: $INIT_CHOICE")" \
                'OpenRC / systemd / SysVinit' 'runit / s6 (s6-rc) / Dinit' 'BusyBox init' '' \
                "$(tr_text 'Enter to choose an init system.' 'Enter — pasirinkti init sistemą.')" ;;
        manager)
            printf '%s\n' "$(tr_text 'PACKAGE MANAGER' 'PAKETŲ TVARKYKLĖ')" '' "$(tr_text "Selected: $PACKAGE_MANAGER" "Pasirinkta: $PACKAGE_MANAGER")" \
                'none  No package manager' 'apt   APT + dpkg' 'pacman  pacman' '' \
                "$(tr_text 'Enter to choose a package manager.' 'Enter — pasirinkti paketų tvarkyklę.')" ;;
        desktop)
            printf '%s\n' "$(tr_text 'DESKTOP ENVIRONMENT' 'GRAFINĖ APLINKA')" '' "$(tr_text "Selected: $DESKTOP_CHOICE" "Pasirinkta: $DESKTOP_CHOICE")" \
                'none  Console only' 'MATE + Xorg' 'LXDE + Xorg' 'Fluxbox + Xorg' '' \
                "$(tr_text 'Enter to choose a desktop.' 'Enter — pasirinkti darbalaukį.')" ;;
        extras)
            extra_delta=$(selected_iso_delta)
            printf '%s\n' "$(tr_text 'APPLICATIONS AND FEATURES' 'PROGRAMOS IR FUNKCIJOS')" '' \
                "$(tr_text "Estimated ISO increase: +$extra_delta" "Numatomas ISO prieaugis: +$extra_delta")" \
                "$(tr_text 'Optional applications are selected with checkboxes.' 'Papildomos programos pasirenkamos varnelėmis.')" \
                'nano / wget / ping / vim' 'Firefox / Geany / XTerm' 'Wi-Fi, sound and web server' '' \
                "$(tr_text 'Enter to open the application checklist.' 'Enter — atverti programų sąrašą.')" ;;
        tools)
            printf '%s\n' "$(tr_text 'SYSTEM UTILITIES' 'SISTEMOS ĮRANKIAI')" '' "$(tr_text "Selected: $TOOLS_CHOICE" "Pasirinkta: $TOOLS_CHOICE")" \
                'GNU + util-linux  Full utilities' 'BusyBox  Compact applet set' '' \
                "$(tr_text 'Enter to choose utilities.' 'Enter — pasirinkti sistemos įrankius.')" ;;
        boot)
            printf '%s\n' "$(tr_text 'BOOTLOADER AND IMAGE' 'PALEIDYKLĖ IR ATVAIZDAS')" '' "$(tr_text "Selected: $BOOT_CHOICE" "Pasirinkta: $BOOT_CHOICE")" \
                'GRUB 2  BIOS or UEFI' 'Syslinux / LILO  BIOS' 'Limine / systemd-boot / EFISTUB' '' \
                "$(tr_text 'Available choices depend on architecture.' 'Pasirinkimai priklauso nuo architektūros.')" \
                "$(tr_text 'Enter to choose a bootloader.' 'Enter — pasirinkti paleidyklę.')" ;;
        jobs)
            printf '%s\n' "$(tr_text 'BUILD PARALLELISM' 'KOMPILIAVIMO LYGIAGRETUMAS')" '' "$(tr_text "Current: $JOBS jobs" "Dabar: $JOBS užduotys")" \
                "$(tr_text 'More jobs can use more RAM.' 'Daugiau užduočių naudoja daugiau RAM.')" \
                "$(tr_text 'GCC bootstrap stages always use one job.' 'Pradiniai GCC etapai visada naudoja vieną užduotį.')" '' \
                "$(tr_text 'Enter to change the job count.' 'Enter — pakeisti užduočių skaičių.')" ;;
        osname)
            printf '%s\n' 'OPERATING SYSTEM NAME' '' "$OS_NAME" '' \
                "$(tr_text 'Shown in the boot menu and system information.' 'Rodomas paleidimo meniu ir sistemos informacijoje.')" '' \
                "$(tr_text 'Enter to edit the name.' 'Enter — pakeisti pavadinimą.')" ;;
        hostname)
            printf '%s\n' 'HOSTNAME' '' "$SYSTEM_NAME" '' \
                "$(tr_text 'Used as the machine name in the terminal and network.' 'Kompiuterio vardas terminale ir tinkle.')" '' \
                "$(tr_text 'Enter to edit the hostname.' 'Enter — pakeisti kompiuterio vardą.')" ;;
        user)
            printf '%s\n' "$(tr_text 'ADMINISTRATOR USER' 'ADMINISTRATORIAUS VARTOTOJAS')" '' "$USER_NAME" '' \
                "$(tr_text 'This regular account receives sudo access.' 'Ši įprasta paskyra gauna sudo teises.')" '' \
                "$(tr_text 'Enter to change the username.' 'Enter — pakeisti vartotojo vardą.')" ;;
        directory)
            printf '%s\n' "$(tr_text 'WORKING DIRECTORY' 'DARBO KATALOGAS')" '' "$WORK_DIR" '' \
                "$(tr_text 'Stores sources, build files, rootfs, images and toolchains.' 'Čia saugomi šaltiniai, kūrimo failai, rootfs, atvaizdai ir toolchain.')" '' \
                "$(tr_text 'Enter to change the directory.' 'Enter — pakeisti katalogą.')" ;;
        plan)
            printf '%s\n' "$(tr_text 'BUILD PLAN' 'KŪRIMO PLANAS')" '' \
                "$(tr_text 'Review the selected components and estimated ISO size.' 'Peržiūrėk pasirinktus komponentus ir numatomą ISO dydį.')" '' \
                "$(tr_text 'Enter to open the full plan.' 'Enter — atverti visą planą.')" ;;
        build)
            printf '%s\n' "$(tr_text 'READY TO BUILD' 'PASIRUOŠĘ KURTI')" '' \
                "$(tr_text 'Validate settings, confirm the plan, then build the system.' 'Patikrink nustatymus, patvirtink planą ir kurk sistemą.')" '' \
                "$(tr_text 'Enter to review and start.' 'Enter — peržiūrėti ir pradėti.')" ;;
    esac
}

MENU_TTY_STATE=''
menu_tty_restore() {
    [[ -z ${MENU_TTY_STATE:-} ]] || stty "$MENU_TTY_STATE" 2>/dev/null || :
    MENU_TTY_STATE=''
    printf '\033[?25h\033[0m\033[H\033[2J' 2>/dev/null || :
}
menu_restore_signal_traps() {
    if [[ -n ${MENU_SAVED_INT_TRAP:-} ]]; then eval "$MENU_SAVED_INT_TRAP"; else trap - INT; fi
    if [[ -n ${MENU_SAVED_TERM_TRAP:-} ]]; then eval "$MENU_SAVED_TERM_TRAP"; else trap - TERM; fi
}

menu_split_select() {
    local -a tags=(arch shell init manager desktop extras tools boot jobs osname hostname user directory plan build)
    local -a labels=()
    local index=${MENU_INDEX:-0} top=0 rows cols left_width right_width body_rows i key seq line preview old_stty saved_int saved_term left_rule right_rule
    for key in "${tags[@]}"; do labels+=("$(menu_section_label "$key")"); done
    rows=$(stty size 2>/dev/null | awk '{print $1}') || rows=24
    cols=$(stty size 2>/dev/null | awk '{print $2}') || cols=80
    [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    if (( rows < 20 || cols < 76 )); then
        if tui --title "$(tr_text 'Main menu' 'Pagrindinis meniu')" --cancel-label "$(tr_text 'Exit' 'Išeiti')" --menu \
            "$(tr_text 'Choose a section. Enter opens its settings.' 'Pasirink skiltį. Enter atveria jos nustatymus.')" 23 80 15 \
            arch "${labels[0]}" shell "${labels[1]}" init "${labels[2]}" manager "${labels[3]}" desktop "${labels[4]}" \
            extras "${labels[5]}" tools "${labels[6]}" boot "${labels[7]}" jobs "${labels[8]}" osname "${labels[9]}" \
            hostname "${labels[10]}" user "${labels[11]}" directory "${labels[12]}" plan "${labels[13]}" build "${labels[14]}"; then
            MENU_CHOICE=$TUI_VALUE
            return 0
        fi
        return 1
    fi
    old_stty=$(stty -g)
    saved_int=$(trap -p INT || :)
    saved_term=$(trap -p TERM || :)
    MENU_SAVED_INT_TRAP=$saved_int
    MENU_SAVED_TERM_TRAP=$saved_term
    MENU_TTY_STATE=$old_stty
    trap 'menu_tty_restore; exit 130' INT TERM
    left_width=$(( cols * 34 / 100 ))
    (( left_width < 26 )) && left_width=26
    right_width=$(( cols - left_width - 7 ))
    body_rows=$(( rows - 7 ))
    (( body_rows > ${#tags[@]} )) && body_rows=${#tags[@]}
    (( body_rows < 8 )) && body_rows=8
    (( index >= ${#tags[@]} )) && index=$((${#tags[@]} - 1))
    stty -echo -icanon min 1 time 0
    printf '\033[?25l'
    while :; do
        (( index < top )) && top=$index
        (( index >= top + body_rows )) && top=$((index - body_rows + 1))
        preview=$(menu_section_preview "${tags[index]}")
        printf '\033[44;97m\033[H\033[2J'
        printf '\033[1;97m%s\033[44;97m\n' "$(tr_text 'DIY Linux — system configuration' 'DIY Linux — sistemos konfigūracija')"
        printf '\033[44;97m%s\n' "$(tr_text 'Choose a section on the left; its settings are shown on the right.' 'Kairėje pasirink skiltį — jos nustatymai rodomi dešinėje.')"
        printf -v left_rule '%*s' "$((left_width + 2))" ''; left_rule=${left_rule// /─}
        printf -v right_rule '%*s' "$((right_width + 2))" ''; right_rule=${right_rule// /─}
        printf '\033[97m┌%s┬%s┐\n' "$left_rule" "$right_rule"
        printf '│ \033[1;97m%-*.*s\033[44;97m │ %-*.*s │\n' "$left_width" "$left_width" "$(tr_text 'SECTIONS' 'SKILTYS')" "$right_width" "$right_width" "$(tr_text 'SETTINGS' 'NUSTATYMAI')"
        for ((i=0; i<body_rows; i++)); do
            if (( top + i < ${#tags[@]} )); then
                if (( top + i == index )); then
                    printf '│ \033[47;34;1m%-*.*s\033[44;97m │' "$left_width" "$left_width" "${labels[top+i]}"
                else
                    printf '│ %-*.*s │' "$left_width" "$left_width" "${labels[top+i]}"
                fi
            else
                printf '│ %-*s │' "$left_width" ''
            fi
            if (( i == 0 )); then
                printf ' %-*.*s │\n' "$right_width" "$right_width" "${labels[index]}"
            elif (( i == 1 )); then
                printf ' %-*.*s │\n' "$right_width" "$right_width" "$(tr_text '────────────────────────────────' '────────────────────────────────')"
            else
                line=$(printf '%s\n' "$preview" | sed -n "$((i - 1))p")
                printf ' %-*.*s │\n' "$right_width" "$right_width" "$line"
            fi
        done
        printf '\033[97m└%s┴%s┘\033[44;97m\n' "$left_rule" "$right_rule"
        printf '\033[44;97m%s\033[0m\n' "$(tr_text '↑/↓ select section   Enter/→ open settings   ? help   Esc exit' '↑/↓ pasirinkti skiltį   Enter/→ atverti nustatymus   ? pagalba   Esc išeiti')"
        IFS= read -r -s -n 1 key || :
        case "$key" in
            $'\x1b')
                seq=''; IFS= read -r -s -n 2 -t 0.1 seq || :
                case "$seq" in
                    '[A') (( index > 0 )) && index=$((index - 1)) || : ;;
                    '[B') (( index + 1 < ${#tags[@]} )) && index=$((index + 1)) || : ;;
                    '[C') MENU_CHOICE=${tags[index]}; MENU_INDEX=$index; menu_tty_restore; menu_restore_signal_traps; return 0 ;;
                    *) menu_tty_restore; menu_restore_signal_traps; MENU_INDEX=$index; return 1 ;;
                esac ;;
            '') MENU_CHOICE=${tags[index]}; MENU_INDEX=$index; menu_tty_restore; menu_restore_signal_traps; return 0 ;;
            '?')
                stty "$old_stty"; MENU_TTY_STATE=''; printf '\033[?25h\033[H\033[2J'
                tui --title "$(tr_text 'Section help' 'Skilties pagalba')" --scrolltext --msgbox "$(menu_description "${tags[index]}")" 18 76 || :
                MENU_TTY_STATE=$(stty -g); stty -echo -icanon min 1 time 0; printf '\033[?25l' ;;
            'q'|'Q') MENU_INDEX=$index; menu_tty_restore; menu_restore_signal_traps; return 1 ;;
        esac
    done
}

menu() {
    local password confirmation autostart_before
    tui_ready
    while :; do
        if ! menu_split_select; then exit 0; fi
        case "$MENU_CHOICE" in
            arch)
                platform_menu arch TARGET_ARCH "$(tr_text 'CPU architecture - AMD64 works on AMD and Intel' 'CPU architektūra — AMD64 tinka AMD ir Intel')" \
                    x86_64 "$(tr_text 'x64 / AMD64 / Intel64 - 64-bit PC' 'x64 / AMD64 / Intel64 — 64 bitų PC')" \
                    i686 "$(tr_text 'x86 / i686 - 32-bit PC (Pentium Pro and newer)' 'x86 / i686 — 32 bitų PC (Pentium Pro ir naujesni)')" \
                    aarch64 "$(tr_text 'ARM64 / AArch64 - QEMU virt or UEFI ARM64' 'ARM64 / AArch64 — QEMU virt arba UEFI ARM64')"
                architecture
                if ! boot_compatible "$BOOT_CHOICE"; then BOOT_CHOICE=uefi; fi
                ;;
            shell) platform_menu shell SHELL_CHOICE "$(tr_text 'Login shell' 'Prisijungimo apvalkalas')" busybox 'BusyBox ash' bash Bash dash dash zsh Zsh fish Fish ;;
            tools) platform_menu tools TOOLS_CHOICE "$(tr_text 'System utilities' 'Sistemos įrankiai')" busybox 'BusyBox' gnu 'GNU + util-linux' ;;
            init) platform_menu init INIT_CHOICE "$(tr_text 'Init system' 'Init sistema')" \
                busybox "$(tr_text 'BusyBox: small / limited features' 'BusyBox: mažas / mažai funkcijų')" openrc "$(tr_text 'OpenRC: shell scripts and dependencies' 'OpenRC: shell ir priklausomybės')" \
                runit "$(tr_text 'runit: small / process supervision' 'runit: mažas / procesų priežiūra')" \
                dinit "$(tr_text 'Dinit: dependency services / lightweight' 'Dinit: paslaugų priklausomybės / lengva')" \
                systemd "$(tr_text 'systemd: integration / larger system' 'systemd: integracija / didesnė sistema')" \
                sysvinit "$(tr_text 'SysVinit: classic / more manual scripts' 'SysVinit: klasikinis / daugiau rankinių scenarijų')" \
                s6 "$(tr_text 's6: s6-rc service manager and s6-linux-init included' 's6: įtrauktos s6-rc paslaugos ir s6-linux-init')" ;;
            manager) platform_menu manager PACKAGE_MANAGER "$(tr_text 'Package manager' 'Paketų tvarkyklė')" none "$(tr_text 'No package manager' 'Be paketų tvarkyklės')" apt 'APT + dpkg' pacman pacman ;;
            boot) platform_menu boot BOOT_CHOICE "$(tr_text 'Bootloader and firmware' 'Paleidyklė ir firmware')" \
                bios 'GRUB 2 — BIOS ISO' uefi 'GRUB 2 — UEFI ISO' syslinux 'Syslinux — BIOS ISO' \
                lilo "$(tr_text 'LILO — legacy BIOS IMG only' 'LILO — senasis BIOS, tik IMG')" \
                efistub "$(tr_text 'EFISTUB - direct UEFI kernel' 'EFISTUB — tiesioginis UEFI branduolys')" limine "$(tr_text 'Limine - BIOS + UEFI ISO' 'Limine — BIOS + UEFI ISO')" \
                systemd-boot 'systemd-boot — UEFI ISO / ESP' none "$(tr_text 'Only rootfs / initramfs' 'Tik rootfs / initramfs')" ;;
            extras)
                autostart_before=$DESKTOP_AUTOSTART
                extras_menu
                [[ "$autostart_before" == "$DESKTOP_AUTOSTART" ]] || DESKTOP_AUTOSTART_WAS_SET=x
                ;;
            desktop)
                platform_menu desktop DESKTOP_CHOICE "$(tr_text 'Desktop environment' 'Grafinė aplinka')" \
                    none "$(tr_text 'Console only' 'Tik terminalas')" \
                    mate 'MATE 1.28 + Xorg (x86_64; GNU or BusyBox utilities)' \
                    lxde 'LXDE + Xorg (x86_64; GTK desktop)' \
                    fluxbox 'Fluxbox 1.3.7 + Xorg (x86_64; standalone desktop session)'
                case "$DESKTOP_CHOICE" in
                    mate) PKG_FIREFOX=yes; PKG_CAJA=yes ;;
                    lxde) PKG_GEANY=no; PKG_FIREFOX=no; PKG_PLUMA=no; PKG_CAJA=no; PKG_ENGRAMPA=no; PKG_EOM=no ;;
                    fluxbox) PKG_FIREFOX=no; PKG_PLUMA=no; PKG_CAJA=no; PKG_ENGRAMPA=no; PKG_EOM=no ;;
                    none) PKG_GEANY=no; PKG_FIREFOX=no; PKG_PLUMA=no; PKG_ENGRAMPA=no ;;
                esac
                if [[ -z "$DESKTOP_AUTOSTART_WAS_SET" ]]; then
                    DESKTOP_AUTOSTART=no
                fi
                ;;
            jobs) tui_input JOBS "$(tr_text 'Build jobs' 'Kompiliavimo užduotys')" ;;
            osname) tui_input OS_NAME "$(tr_text 'OS name' 'OS pavadinimas')" ;;
            hostname) tui_input SYSTEM_NAME "$(tr_text 'Hostname' 'Kompiuterio vardas')" ;;
            user) tui_input USER_NAME "$(tr_text 'Username (sudo access)' 'Vartotojo vardas (sudo teisės)')" ;;
            directory) tui_input WORK_DIR "$(tr_text 'Working directory' 'Darbo katalogas')" ;;
            plan) tui --title "$(tr_text 'Selected plan' 'Pasirinktas planas')" --scrolltext --msgbox "$(plan)" 20 78 || : ;;
            build)
                if ! validate; then
                    tui --title "$(tr_text 'Configuration error' 'Nustatymų klaida')" --msgbox "$VALIDATION_ERROR" 12 76 || :
                    continue
                fi
                if tui --title "$(tr_text 'Start build?' 'Pradėti kūrimą?')" --defaultno --scrolltext --yesno "$(plan)" 20 78; then break; fi
                ;;
        esac
    done
    # Sudo ir priklausomybių diegimas atliekami įprastame terminale.
    check_host
    if tui --title "$(tr_text 'System and user password' 'Sistemos ir vartotojo slaptažodis')" --insecure --passwordbox \
        "$(tr_text 'This password will be used for both root and the default user. Enter keeps the current passwords; Esc cancels the build.' 'Šis slaptažodis bus naudojamas root ir numatytajam vartotojui. Enter palieka esamus slaptažodžius; Esc atšaukia kūrimą.')" 11 76; then
        password=$TUI_VALUE
    else exit 0; fi
    if [[ -n "$password" ]]; then
        tui --title "$(tr_text 'Confirm password' 'Patvirtink slaptažodį')" --insecure --passwordbox "$(tr_text 'Repeat the password once.' 'Pakartok slaptažodį vieną kartą.')" 10 76 || exit 0
        confirmation=$TUI_VALUE
        [[ "$password" == "$confirmation" ]] || die "$(tr_text 'Passwords do not match' 'Slaptažodžiai nesutampa')"
        ROOT_PASSWORD_HASH=$(printf '%s\n' "$password" | openssl passwd -6 -stdin)
        USER_PASSWORD_HASH=$ROOT_PASSWORD_HASH
    fi
    unset password confirmation TUI_VALUE
}

# Šeimininko paketai nesusiję su PACKAGE_MANAGER galutinėje sistemoje.
# Vienu kartu surenkami visi trūkumai; sudo naudojamas tik paketų diegimui.
host_package_manager() {
    local ID='' ID_LIKE=''
    [[ ! -r /etc/os-release ]] || source /etc/os-release
    case " $ID $ID_LIKE " in
        *debian*|*ubuntu*) HOST_PM=apt-get ;;
        *arch*) HOST_PM=pacman ;;
        *fedora*|*rhel*|*centos*) HOST_PM=dnf ;;
        *) HOST_PM=''
           local candidate
           for candidate in apt-get pacman dnf; do
               if command -v "$candidate" >/dev/null; then HOST_PM=$candidate; break; fi
           done ;;
    esac
    [[ -n "$HOST_PM" ]] && command -v "$HOST_PM" >/dev/null
}

host_needs_cmake() {
    [[ "$PACKAGE_MANAGER" == apt || "$SHELL_CHOICE" == fish || "$DESKTOP_CHOICE" != none ]]
}

collect_host_dependencies() {
    HOST_MISSING=(); HOST_PACKAGES=()
    local tool deb arch fedora package header
    local -A seen=()
    while read -r tool deb arch fedora; do
        [[ -n "$tool" ]] || continue
        [[ "$tool" != visudo || ! -x /usr/sbin/visudo ]] || continue
        if { [[ "$tool" == target-binfmt && ! -r /proc/sys/fs/binfmt_misc/$EMULATOR ]]; } ||
           { [[ "$tool" != target-binfmt ]] && ! command -v "$tool" >/dev/null; }; then
            HOST_MISSING+=("$tool")
            case "$HOST_PM" in apt-get) package=$deb ;; pacman) package=$arch ;; dnf) package=$fedora ;; *) package='' ;; esac
            if [[ -n "$package" && ! -v seen[$package] ]]; then
                HOST_PACKAGES+=("$package"); seen[$package]=1
            fi
        fi
    done <<'TOOLS'
visudo sudo sudo sudo
gcc gcc gcc gcc
g++ g++ gcc gcc-c++
make make make make
curl curl curl curl
sha256sum coreutils coreutils coreutils
tar tar tar tar
patch patch patch patch
bison bison bison bison
flex flex flex flex
gawk gawk gawk gawk
makeinfo texinfo texinfo texinfo
python3 python3 python python3
pkg-config pkg-config pkgconf pkgconf-pkg-config
meson meson meson meson
ninja ninja-build ninja ninja-build
gperf gperf gperf gperf
bc bc bc bc
perl perl perl perl
cpio cpio cpio cpio
gzip gzip gzip gzip
fakeroot fakeroot fakeroot fakeroot
openssl openssl openssl openssl
tic ncurses-bin ncurses ncurses
depmod kmod kmod kmod
readelf binutils binutils binutils
autoconf autoconf autoconf autoconf
automake automake automake automake
libtoolize libtool libtool libtool
xz xz-utils xz xz
bzip2 bzip2 bzip2 bzip2
file file file file
ps procps procps-ng procps-ng
flock util-linux util-linux util-linux
find findutils findutils findutils
sed sed sed sed
grep grep grep grep
zstd zstd zstd zstd
mksquashfs squashfs-tools squashfs-tools squashfs-tools
mkfs.ext4 e2fsprogs e2fsprogs e2fsprogs
blkid util-linux util-linux util-linux
TOOLS
    # Papildomos priklausomybės tik pasirinktiems receptams.
    while read -r tool deb arch fedora; do
        [[ -n "$tool" ]] || continue
        if { [[ "$tool" == target-binfmt && ! -r /proc/sys/fs/binfmt_misc/$EMULATOR ]]; } ||
           { [[ "$tool" != target-binfmt ]] && ! command -v "$tool" >/dev/null; }; then
            HOST_MISSING+=("$tool")
            case "$HOST_PM" in apt-get) package=$deb ;; pacman) package=$arch ;; dnf) package=$fedora ;; *) package='' ;; esac
            if [[ -n "$package" && ! -v seen[$package] ]]; then
                HOST_PACKAGES+=("$package"); seen[$package]=1
            fi
        fi
    done < <(
        # Bitmap X11 fonts are converted during the font package build and
        # indexed in the target rootfs after install; these are host tools.
        [[ "$DESKTOP_CHOICE" == none ]] || printf 'bdftopcf bdftopcf bdftopcf xorg-x11-font-utils\nmkfontdir xfonts-utils xorg-mkfontscale xorg-x11-font-utils\n'
        [[ "$DESKTOP_CHOICE" != mate && "$DESKTOP_CHOICE" != lxde ]] || printf 'msgfmt gettext gettext gettext\nintltool-update intltool intltool intltool\nintltool-merge intltool intltool intltool\nintltool-extract intltool intltool intltool\nitstool itstool itstool itstool\n'
        [[ "$DESKTOP_CHOICE" != mate ]] || printf 'gtk-encode-symbolic-svg libgtk-3-bin gtk3 gtk3\n'
        [[ "$DESKTOP_CHOICE" != mate ]] ||
            printf 'cargo-cbuild cargo-c cargo-c cargo-c\n'
        if [[ "$DESKTOP_CHOICE" == mate && ${PKG_EOM:-no} == yes ]]; then
            # GIR scanners execute on the build host during cross compilation.
            printf 'g-ir-scanner gobject-introspection gobject-introspection gobject-introspection\ng-ir-compiler gobject-introspection gobject-introspection gobject-introspection\n'
        fi
        [[ "$DESKTOP_CHOICE" != mate ]] || printf 'rustc rustc rust rust\ncargo cargo cargo cargo\n'
        [[ "$DESKTOP_CHOICE" != lxde ]] || printf 'valac valac vala vala\n'
        if [[ -n "$EMULATOR" ]]; then
            printf '%s qemu-user qemu-user-static qemu-user\ntarget-binfmt qemu-user-binfmt qemu-user-static-binfmt qemu-user-binfmt\n' "$EMULATOR"
        fi
        [[ "$BOOT_CHOICE" == none || "$BOOT_CHOICE" == lilo ]] || printf 'xorriso xorriso libisoburn xorriso\nmformat mtools mtools mtools\n'
        if [[ "$BOOT_CHOICE" == bios && "$TARGET_ARCH" == x86_64 ]]; then
            printf 'grub-mkrescue grub-common grub grub2-tools-extra\n'
            [[ -d /usr/lib/grub/i386-pc ]] || printf 'grub-pc-modules grub-pc-bin grub grub2-pc-modules\n'
        fi
        if [[ "$BOOT_CHOICE" == lilo ]]; then
            printf 'losetup util-linux util-linux util-linux\nsfdisk util-linux util-linux util-linux\nmkfs.ext2 e2fsprogs e2fsprogs e2fsprogs\nmount util-linux util-linux util-linux\numount util-linux util-linux util-linux\nmountpoint util-linux util-linux util-linux\n'
        fi
        host_needs_cmake && printf 'cmake cmake cmake cmake\n'
        [[ "$INIT_CHOICE" != dinit ]] || printf 'm4 m4 m4 m4\n'
        case "$BOOT_CHOICE" in
            refind) printf 'unzip unzip unzip unzip\n' ;;
            systemd-boot) printf 'ar binutils binutils binutils\nzstd zstd zstd zstd\n' ;;
            syslinux|lilo) : ;;
            limine) : ;;
        esac
        [[ "$SHELL_CHOICE" != fish ]] || printf 'rustc rustc rust rust\ncargo cargo cargo cargo\n' 
        [[ ${PKG_MATE_CONTROL_CENTER:-no} != yes || "$SHELL_CHOICE" == fish ]] || printf 'rustc rustc rust rust\ncargo cargo cargo cargo\n'
        [[ ${PKG_PHP:-no} != yes ]] || printf 're2c re2c re2c re2c\n'
    )
    while read -r header deb arch fedora; do
        if ! command -v gcc >/dev/null || ! printf '' | gcc -E -x c -include "$header" - >/dev/null 2>&1; then
            HOST_MISSING+=("$header")
            case "$HOST_PM" in apt-get) package=$deb ;; pacman) package=$arch ;; dnf) package=$fedora ;; *) package='' ;; esac
            if [[ -n "$package" && ! -v seen[$package] ]]; then
                HOST_PACKAGES+=("$package"); seen[$package]=1
            fi
        fi
    done <<'HEADERS'
stdio.h libc6-dev glibc glibc-devel
openssl/ssl.h libssl-dev openssl openssl-devel
gelf.h libelf-dev libelf elfutils-libelf-devel
ncurses.h libncurses-dev ncurses ncurses-devel
HEADERS
    if [[ "$BOOT_CHOICE" == bios || "$BOOT_CHOICE" == uefi ]] && ! grub_font_path >/dev/null; then
        HOST_MISSING+=('GRUB unicode.pf2')
        case "$HOST_PM" in apt-get) package=grub-common ;; pacman) package=grub ;; dnf) package=grub2-common ;; *) package='' ;; esac
        if [[ -n "$package" && ! -v seen[$package] ]]; then
            HOST_PACKAGES+=("$package"); seen[$package]=1
        fi
    fi
    if [[ "$DESKTOP_CHOICE" == mate && ! -f /usr/share/hwdata/pnp.ids ]]; then
        HOST_MISSING+=('/usr/share/hwdata/pnp.ids')
        [[ -v seen[hwdata] ]] || HOST_PACKAGES+=(hwdata)
    fi
    if [[ ! -r /usr/share/zoneinfo/Europe/Vilnius ]]; then
        HOST_MISSING+=('Europe/Vilnius timezone database')
        case "$HOST_PM" in apt-get) package=tzdata ;; pacman) package=tzdata ;; dnf) package=tzdata ;; *) package='' ;; esac
        if [[ -n "$package" && ! -v seen[$package] ]]; then
            HOST_PACKAGES+=("$package"); seen[$package]=1
        fi
    fi
    if [[ "$INIT_CHOICE" == systemd ]] && ! python3 -c 'import jinja2' >/dev/null 2>&1; then
        HOST_MISSING+=('Python jinja2')
        case "$HOST_PM" in apt-get) package=python3-jinja2 ;; pacman) package=python-jinja ;; dnf) package=python3-jinja2 ;; *) package='' ;; esac
        [[ -z "$package" || -v seen[$package] ]] || HOST_PACKAGES+=("$package")
    fi
    if [[ "$DESKTOP_CHOICE" != none ]] && ! python3 -c 'import mako' >/dev/null 2>&1; then
        HOST_MISSING+=('Python Mako')
        case "$HOST_PM" in apt-get) package=python3-mako ;; pacman) package=python-mako ;; dnf) package=python3-mako ;; *) package='' ;; esac
        [[ -z "$package" || -v seen[$package] ]] || HOST_PACKAGES+=("$package")
    fi
    if [[ "$DESKTOP_CHOICE" != none ]] && ! python3 -c 'import yaml' >/dev/null 2>&1; then
        HOST_MISSING+=('Python PyYAML')
        case "$HOST_PM" in apt-get) package=python3-yaml ;; pacman) package=python-yaml ;; dnf) package=python3-pyyaml ;; *) package='' ;; esac
        [[ -z "$package" || -v seen[$package] ]] || HOST_PACKAGES+=("$package")
    fi
}

install_host_dependencies() {
    local -a privilege=(sudo)
    command -v sudo >/dev/null || die "$(tr_text 'Automatic installation requires sudo; an administrator can install the package list' 'Automatiniam diegimui reikia sudo; paketų sąrašą gali įdiegti administratorius')"
    say "$(tr_text "Installing missing host dependencies ($HOST_PM)" "Diegiamos trūkstamos šeimininko priklausomybės ($HOST_PM)")"
    printf "$(tr_text 'Packages:' 'Paketai:')"; printf ' %s' "${HOST_PACKAGES[@]}"; printf '\n'
    # sudo slaptažodžio užklausa turi likti matoma prieš tylų diegimą.
    "${privilege[@]}" -v || die "$(tr_text 'Failed to obtain sudo access' 'Nepavyko gauti sudo teisių')"
    local stages=1
    [[ "$HOST_PM" != apt-get ]] || stages=2
    local -a labels=()
    [[ "$HOST_PM" != apt-get ]] || labels+=("$(tr_text 'Updating APT package lists' 'APT sąrašų atnaujinimas')")
    labels+=("$(tr_text 'Installing dependencies' 'Priklausomybių diegimas')")
    progress_start "$stages" "$WORK_DIR/host-dependencies.log" "${labels[@]}"
    case "$HOST_PM" in
        apt-get)
            run_quiet "$(tr_text 'Updating APT package lists' 'APT sąrašų atnaujinimas')" sudo -n apt-get update
            run_quiet "$(tr_text 'Installing dependencies' 'Priklausomybių diegimas')" sudo -n apt-get install -y --no-install-recommends --no-remove "${HOST_PACKAGES[@]}"
            ;;
        pacman)
            run_quiet "$(tr_text 'Installing dependencies' 'Priklausomybių diegimas')" sudo -n pacman -S --needed --noconfirm "${HOST_PACKAGES[@]}"
            ;;
        dnf)
            run_quiet "$(tr_text 'Installing dependencies' 'Priklausomybių diegimas')" sudo -n dnf install -y "${HOST_PACKAGES[@]}"
            ;;
        *) die "$(tr_text 'Automatic installation supports apt-get, pacman, and dnf' 'Automatinis diegimas palaiko apt-get, pacman ir dnf')" ;;
    esac
    progress_stop

}

check_host() {
    [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die "$(tr_text 'Requires a Linux x86_64 host' 'Palaikomas Linux x86_64 šeimininkas')"
    [[ $EUID -ne 0 ]] || die "$(tr_text 'Build as a regular user, not root; the script uses sudo for installation when needed' 'Kompiliuok paprasto naudotojo teisėmis, ne root; diegimui scenarijus pats naudos sudo')"
    HOST_PM=''
    host_package_manager || HOST_PM=''
    collect_host_dependencies
    if (( ${#HOST_MISSING[@]} )); then
        printf "$(tr_text 'Missing:' 'Trūksta:')"; printf ' %s' "${HOST_MISSING[@]}"; printf '\n'
        [[ "$AUTO_INSTALL_DEPS" == yes ]] || die "$(tr_text 'Automatic installation is disabled. Set AUTO_INSTALL_DEPS=yes or see --help' 'Automatinis diegimas išjungtas. Įjunk AUTO_INSTALL_DEPS=yes arba žiūrėk --help')"
        [[ -n "$HOST_PM" ]] || die "$(tr_text 'Unknown host package manager. Dependencies: --help' 'Neatpažinta šeimininko paketų tvarkyklė. Priklausomybės: --help')"
        install_host_dependencies
        hash -r
        collect_host_dependencies
        (( ${#HOST_MISSING[@]} == 0 )) || die "$(tr_text "Still missing after installation: ${HOST_MISSING[*]}" "Po diegimo vis dar trūksta: ${HOST_MISSING[*]}")"
    fi
    if [[ "$DESKTOP_CHOICE" == mate || "$DESKTOP_CHOICE" == lxde || "$DESKTOP_CHOICE" == fluxbox ]]; then
        local meson_major meson_minor meson_version
        meson_version=$(meson --version)
        IFS=. read -r meson_major meson_minor _ <<< "$meson_version"
        [[ "$meson_major" =~ ^[0-9]+$ && "$meson_minor" =~ ^[0-9]+$ ]] || die "$(tr_text 'Failed to determine Meson version' 'Nepavyko nustatyti Meson versijos')"
        (( meson_major > 1 || (meson_major == 1 && meson_minor >= 4) )) || die "$(tr_text "Desktop libraries require Meson >= 1.4; found $meson_version. Update host Meson" "Darbalaukio bibliotekoms reikia Meson >= 1.4; rastas $meson_version. Atnaujink šeimininko Meson")"
    fi
    if [[ "$DESKTOP_CHOICE" == mate ]]; then
        local rust_libdir
        rust_libdir=$(rustc --print target-libdir --target "$RUST_TARGET")
        compgen -G "$rust_libdir/libstd-*.rlib" >/dev/null ||
            die "$(tr_text "MATE's librsvg requires Rust std for $RUST_TARGET; install it with rustup target add $RUST_TARGET" "MATE librsvg reikia Rust std $RUST_TARGET; įdiek su rustup target add $RUST_TARGET")"
    fi
    if [[ "$SHELL_CHOICE" == fish ]]; then
        local rust_version rust_major rust_minor rust_libdir
        rust_version=$(rustc --version); read -r _ rust_version _ <<< "$rust_version"
        IFS=. read -r rust_major rust_minor _ <<< "$rust_version"
        (( rust_major > 1 || (rust_major == 1 && rust_minor >= 85) )) || die "$(tr_text "Fish requires Rust >= 1.85; found $rust_version. Update host Rust tools" "Fish reikia Rust >= 1.85; rastas $rust_version. Atnaujink šeimininko Rust įrankius")"
        rust_libdir=$(rustc --print target-libdir --target "$RUST_TARGET")
        compgen -G "$rust_libdir/libstd-*.rlib" >/dev/null || die "$(tr_text "Missing Rust std for $RUST_TARGET; rustup target add $RUST_TARGET" "Trūksta Rust std $RUST_TARGET; rustup target add $RUST_TARGET")"
    fi
    HOST_CC=$(command -v gcc)
    HOST_CXX=$(command -v g++)
    HOST=$($HOST_CC -dumpmachine)
    require_emulation
}

grub_font_path() {
    local font
    for font in \
        "${BASE:-}/grub-tools/share/grub/unicode.pf2" \
        /usr/share/grub/unicode.pf2 \
        /usr/lib/grub/unicode.pf2 \
        /usr/share/grub2/unicode.pf2 \
        /usr/lib/grub2/unicode.pf2; do
        if [[ -s "$font" ]]; then printf '%s\n' "$font"; return 0; fi
    done
    return 1
}

prepare_grub_font() {
    local font destination="$BASE/grub-tools/share/grub/unicode.pf2"
    font=$(grub_font_path) || die "$(tr_text 'GRUB Unicode font unicode.pf2 is missing; install grub-common' 'Trūksta GRUB unicode.pf2 šrifto; įdiek grub-common')"
    if [[ "$font" != "$destination" ]]; then
        mkdir -p "${destination%/*}"
        install -m0644 "$font" "$destination"
    fi
}

grub_tools() {
    local source target platform target_cc
    case "$BOOT_CHOICE" in
        bios) target=i386; platform=pc ;;
        uefi) target=$EFI_CPU; platform=efi ;;
        *) die "$(tr_text 'GRUB target must be BIOS or UEFI' 'GRUB tikslas turi būti BIOS arba UEFI')" ;;
    esac
    source=$(unpack grub)
    mkdir -p "$BUILD/grub-host" "$BASE/grub-tools"
    target_cc="$HOST_CC"
    if [[ "$BOOT_CHOICE" == uefi && "$TARGET_ARCH" == aarch64 ]]; then
        target_cc="$TOOLS/bin/$TARGET-gcc"
    fi
    # GRUB has separate build and target compilers. BUILD_CC creates the
    # native utilities; TARGET_CC compiles the EFI/BIOS GRUB code. Using only
    # the host compiler for ARM64 EFI hides target macros such as __aarch64__,
    # which breaks GRUB's ARM64 EFI FDT declarations and builds wrong objects.
    # Reconfigure a resumed build if its Makefile was generated with a
    # different target compiler.
    if [[ ! -f "$BUILD/grub-host/Makefile" ]] ||
        ! grep -Fqx "TARGET_CC = $target_cc" "$BUILD/grub-host/Makefile"; then
        rm -rf -- "$BUILD/grub-host"
        mkdir -p "$BUILD/grub-host"
        (
            cd "$BUILD/grub-host"
            # GRUB 2.14 mis-detects --image-base with newer linkers and
            # produces an i386-pc kernel.img at 0x9074 instead of 0x9000.
            # This cache result disables the broken linker option probe.
            # GRUB host-tools configure options (all are intentional):
            #   --disable-werror: keep compiler warnings visible, but do not
            #     fail this build solely because upstream code triggers one.
            #   --disable-grub-mkfont: do not build the font-generation utility;
            #     prepare_grub_font() copies a ready unicode.pf2 into place.
            #   --disable-efiemu: omit GRUB's legacy EFI-emulation runtime;
            #     this does not disable native UEFI boot support.
            #   --disable-device-mapper: omit libdevmapper integration in GRUB
            #     host utilities, avoiding a host-library dependency. This is
            #     separate from GRUB's own lvm module used at boot.
            #   --disable-libzfs: omit host libzfs/libnvpair integration. This
            #     is separate from any GRUB ZFS filesystem module built for the
            #     selected target platform.
            #   --target + target_alias: tell Autoconf/GRUB the same CPU target
            #     (`i386` BIOS or `$EFI_CPU` UEFI); the explicit alias preserves
            #     the target name GRUB uses while canonicalizing configure.
            # Other GRUB features are left to this version's configure defaults
            # and dependency detection; absence of --enable-* does not mean
            # every such feature is necessarily disabled.
            # Optional GRUB configure flags, intentionally OFF (comments only):
            #   --enable-werror: treat compiler warnings as fatal errors.
            #   --enable-grub-mkfont: build the font generator; this recipe uses
            #     a prepared unicode.pf2 instead.
            #   --enable-efiemu: build legacy EFI emulation support; native UEFI
            #     boot does not need this component.
            #   --enable-device-mapper: add host libdevmapper integration.
            #   --enable-libzfs: add host libzfs/libnvpair integration.
            CC="$HOST_CC" CXX="$HOST_CXX" BUILD_CC="$HOST_CC" \
                TARGET_CC="$target_cc" TARGET_CCAS="$target_cc" \
                TARGET_OBJCOPY="$TOOLS/bin/$TARGET-objcopy" \
                TARGET_STRIP="$TOOLS/bin/$TARGET-strip" \
                TARGET_NM="$TOOLS/bin/$TARGET-nm" \
                TARGET_RANLIB="$TOOLS/bin/$TARGET-ranlib" PKG_CONFIG_PATH= \
                ax_cv_check_ldflags___Wl___image_base_0x400000=no \
                "$source/configure" --prefix="$BASE/grub-tools" \
                --with-platform="$platform" --target="$target" \
                --disable-werror --disable-grub-mkfont --disable-efiemu \
                --disable-device-mapper --disable-libzfs "target_alias=$target"
        )
    fi
    make -C "$BUILD/grub-host" -j"$JOBS"
    make -C "$BUILD/grub-host" install
    prepare_grub_font
}

# 3. Atsisiuntimas ir darbo vieta. Atsisiuntimas pirmiausia patikrinamas,
# tik tada išpakuojamas. Nei URL, nei versijos nenuskaitomos iš svetimų komandų.
archive_path() {
    # Oficialus zstd release skiriasi nuo ankstesnio Git archyvo baitų.
    # Skirtingas cache vardas išsaugo seną patikrintą atsisiuntimą.
    if [[ "$1" == zstd ]]; then printf '%s/%s-%s-%s.archive\n' "$CACHE" "$1" "${VERSION[$1]}" "${SHA[$1]:0:12}"
    else printf '%s/%s-%s.archive\n' "$CACHE" "$1" "${VERSION[$1]}"; fi
}

fetch() {
    local name=$1 archive temporary address status
    archive=$(archive_path "$name")
    if [[ -f "$archive" ]]; then
        if printf '%s  %s\n' "${SHA[$name]}" "$archive" | sha256sum --check --status; then
            return 0
        fi
        printf '%s\n' "$(tr_text "Cached $name archive failed SHA-256 and will be downloaded again: $archive" "Talpyklos $name archyvo SHA-256 neteisingas; jis bus atsisiųstas iš naujo: $archive")" >&2
        rm -f -- "$archive"
    fi
    printf "$(tr_text 'Downloading: %s %s\n' 'Atsisiunčiama: %s %s\n')" "$name" "${VERSION[$name]}" >&2
    temporary="$archive.part"
    local -a addresses=("${URL[$name]}")
    # Identical release archive, same mandatory SHA-256 on every source.
    if [[ "$name" == libdrm ]]; then
        addresses+=("https://dri.freedesktop.org/libdrm/libdrm-${VERSION[$name]}.tar.xz")
    fi
    # An interrupted transfer may already be complete; verify before resuming.
    if [[ -f "$temporary" ]] && printf '%s  %s\n' "${SHA[$name]}" "$temporary" | sha256sum --check --status; then
        mv -- "$temporary" "$archive"; return 0
    fi
    local pass destination
    local -a resume_options=()
    for address in "${addresses[@]}"; do
        for pass in resume fresh; do
            resume_options=(); destination="$temporary.full"
            if [[ "$pass" == resume ]]; then resume_options=(--continue-at -); destination=$temporary; fi
            if curl --fail --location --retry 2 --retry-all-errors --retry-delay 1 --retry-max-time 45 \
                --connect-timeout 10 --speed-limit 1024 --speed-time 60 --proto '=https' --proto-redir '=https' \
                "${resume_options[@]}" "$address" -o "$destination"; then
                if printf '%s  %s\n' "${SHA[$name]}" "$destination" | sha256sum --check --status; then
                    mv -- "$destination" "$archive"
                    rm -f -- "$temporary" "$temporary.full"
                    return 0
                fi
                printf '%s\n' "$(tr_text "SHA-256 mismatch for $name at $address; archive rejected" "Nesutampa $name SHA-256 iš $address; archyvas atmestas")" >&2
                rm -f -- "$destination"
                # A corrupt prefix needs one complete transfer from the same URL.
            else
                status=$?
                printf '%s\n' "$(tr_text "Download failed (curl $status): $address; partial file kept" "Atsisiųsti nepavyko (curl $status): $address; dalinis failas išsaugotas")" >&2
                # Range-unsupported servers get a fresh attempt in a separate file,
                # preserving the original partial archive for another mirror.
                [[ "$pass" == resume && "$status" == 33 ]] || break
            fi
        done
    done
    die "$(tr_text "Could not download a verified archive for $name. Check network access and resume with --resume" "Nepavyko atsisiųsti patikrinto $name archyvo. Patikrink tinklą ir tęsk su --resume")"
}

unpack() {
    local name=$1 source="$SOURCES/$1-${VERSION[$1]}"
    local archive
    archive=$(archive_path "$name")
    [[ "$name" != zstd ]] || source+="-${SHA[$name]:0:12}"
    fetch "$name"
    if [[ ! -f "$source/.unpacked" ]]; then
        mkdir -p "$source"
        case "$name" in
            runit) tar -xf "$archive" --strip-components=2 -C "$source" ;;
            kmod)
                # The upstream testsuite contains a fake sysfs symlink named
                # "usb:btusb". NTFS forbids colons in path components, which
                # makes source extraction fail on external test/build disks.
                # This fixture is used only by kmod's test suite (never by the
                # normal cross build), so omit that one unsupported test file.
                tar -xf "$archive" --strip-components=1 \
                    --exclude='*/testsuite/rootfs-pristine/test-loaded/sys/module/btusb/drivers/usb:btusb' \
                    -C "$source" ;;
            systemd)
                # systemd's fuzzing corpus uses colons in two test-journal
                # filenames. They are test data only, and NTFS cannot create
                # these names when the matrix work directory is on an NTFS disk.
                tar -xf "$archive" --strip-components=1 \
                    --exclude='*/test/test-journals/corrupted/id:000000,sig:06,src:000711,time:110015157,execs:33104794,op:MOpt_havoc,rep:2.zst' \
                    --exclude='*/test/test-journals/corrupted/id:000000,src:000031,time:210669947,execs:34191940,op:havoc,rep:32.zst' \
                    -C "$source" ;;
            refind)
                # A previous interrupted extraction may leave a partial tree.
                # Clear it before retrying so unzip never prompts or mixes files.
                rm -rf -- "$source"
                mkdir -p "$source"
                unzip -qo "$archive" -d "$source"
                mv "$source/refind-bin-${VERSION[refind]}/"* "$source/"
                rmdir "$source/refind-bin-${VERSION[refind]}" ;;
            sdboot|sdboot-arm64)
                local payload
                payload=$(ar t "$archive" | awk '/^data\.tar/ {print;exit}')
                case "$payload" in
                    *.xz) ar p "$archive" "$payload" | tar -xJ -C "$source" ;;
                    *.zst) ar p "$archive" "$payload" | zstd -dc | tar -x -C "$source" ;;
                    *) die "$(tr_text 'Unrecognized EFI deb archive' 'Neatpažintas EFI deb archyvas')" ;;
                esac ;;
            *) tar -xf "$archive" --strip-components=1 -C "$source" ;;
        esac
        touch "$source/.unpacked"
    fi
    printf '%s\n' "$source"
}

stage_label() {
    local name=$1 label
    case "$name" in
        01a-binutils) label="$(tr_text 'Building binutils' 'Binutils kompiliavimas')" ;;
        01b-gcc-initial) label="$(tr_text 'Building initial GCC' 'Pradinis GCC kompiliavimas')" ;;
        01c-glibc) label="$(tr_text 'Linux headers and glibc' 'Linux antraštės ir glibc')" ;;
        01d-gcc-final) label="$(tr_text 'Full cross GCC' 'Pilnas kryžminis GCC')" ;;
        02-userland) label="$(tr_text 'System utilities and shell' 'Sistemos programos ir apvalkalas')" ;;
        03-init*) label="$(tr_text 'Init and service system' 'Init ir paslaugų sistema')" ;;
        02d-extras-*) label="$(tr_text 'Extra programs' 'Papildomos programos')" ;;
        02c-network-tools-*) label='Ping / ping6' ;;
        03b-wget-*) label="$(tr_text 'Wget and HTTPS' 'Wget ir HTTPS')" ;;
        03c-openssh-v1-*) label="$(tr_text 'OpenSSH client and server' 'OpenSSH klientas ir serveris')" ;;
        02a-login-su*) label="$(tr_text 'Login and account tools' 'Login ir paskyrų įrankiai')" ;;
        02b-sudo) label='Sudo' ;;
        03-system-bus) label="$(tr_text 'System D-Bus runtime' 'Sistemos D-Bus aplinka')" ;;
        03a-package-manager) label="$(tr_text 'Package manager' 'Paketų tvarkyklė')" ;;
        web-stack-v1) label="$(tr_text 'Nginx and PHP-FPM web stack' 'Nginx ir PHP-FPM žiniatinklio serveris')" ;;
        04-native-gcc) label="$(tr_text 'GCC in the final system' 'GCC galutinėje sistemoje')" ;;
        04b-linux-firmware-v2) label="$(tr_text 'Wi-Fi and hardware firmware' 'Wi-Fi ir aparatinės įrangos firmware')" ;;
        05-kernel*) label="$(tr_text 'Linux kernel' 'Linux branduolys')" ;;
        06-boot-tools-*) label="$(tr_text "Bootloader: $BOOT_CHOICE" "Paleidyklė: $BOOT_CHOICE")" ;;
        06-grub-tools) label='GRUB 2' ;;
        desktop-app-geany-*) label='Geany (native text editor)' ;;
        desktop-app-firefox-*) label='Firefox browser' ;;
        desktop-*) label=${name#desktop-}; label=${label%-v1}; label=${label%-v2} ;;
        *) label=$name ;;
    esac
    printf '%s | %s' "$name" "$label"
}

stage_cache_context() {
    local stage=$1
    # Keep profile-only choices out of binary cache keys where possible:
    # changing init or bootloader should not rebuild unrelated userland.
    printf 'target=%s\n' "$TARGET"
    case "$stage" in
        02-userland)
            printf 'shell=%s\ntools=%s\nfdisk=%s\nping=%s\n' "$SHELL_CHOICE" "$TOOLS_CHOICE" "$PKG_FDISK" "$PKG_PING"
            if needs_busybox; then printf 'busybox-init=%s\n' "$INIT_CHOICE"; fi ;;
        02d-extras-*) printf 'nano=%s\nneofetch=%s\nvim=%s\nfdisk=%s\n' "$PKG_NANO" "$PKG_NEOFETCH" "$PKG_VIM" "$PKG_FDISK" ;;
        02c-network-tools-*) printf 'ping=%s\ntools=%s\n' "$PKG_PING" "$TOOLS_CHOICE" ;;
        02a-login-su*) printf 'tools=%s\ncontrol-center=%s\npower-manager=%s\n' "$TOOLS_CHOICE" "$PKG_MATE_CONTROL_CENTER" "$PKG_MATE_POWER_MANAGER" ;;
        02b-sudo) printf 'sudo=enabled\n' ;;
        03-init*)
            printf 'init=%s\nnetwork=%s\ndesktop=%s\ntools=%s\n' "$INIT_CHOICE" "$NETWORK" "$DESKTOP_CHOICE" "$TOOLS_CHOICE"
            printf 'control-center=%s\npower-manager=%s\n' "$PKG_MATE_CONTROL_CENTER" "$PKG_MATE_POWER_MANAGER" ;;
        03-system-bus) printf 'runtime-bus=system-dbus\n' ;;
        03b-wget-*) printf 'wget=%s\ntools=%s\n' "$PKG_WGET" "$TOOLS_CHOICE" ;;
        03c-openssh-v1-*) printf 'openssh=%s\ntarget=%s\n' "$PKG_OPENSSH" "$TARGET" ;;
        03a-package-manager) printf 'manager=%s\n' "$PACKAGE_MANAGER" ;;
        04-native-gcc) printf 'native-gcc=%s\n' "$WITH_GCC" ;;
        04b-linux-firmware-v2) printf 'network=%s\ndesktop=%s\n' "$NETWORK" "$DESKTOP_CHOICE" ;;
        web-stack-v1) printf 'nginx=%s\nphp=%s\n' "$PKG_NGINX" "$PKG_PHP" ;;
        05-kernel*)
            # BIOS/UEFI/GRUB changes do not alter bzImage. EFISTUB embeds its
            # command line in the kernel, so only that distinction belongs here.
            printf 'network=%s\ndesktop=%s\nefistub-cmdline=%s\n' \
                "$NETWORK" "$DESKTOP_CHOICE" "$([[ "$BOOT_CHOICE" == efistub ]] && printf yes || printf no)" ;;
        desktop-app-firefox-*) printf 'app=firefox-prebuilt\n' ;;
        desktop-*)
            if [[ ${STAGE_CACHE_STABLE_CONTEXT:-no} != yes ]]; then
                # Preserve the historical key for read-through of old caches.
                printf 'desktop=%s\nnetwork=%s\n' "$DESKTOP_CHOICE" "$NETWORK"
            fi
            case "$stage" in
                desktop-elogind-*|desktop-linux-pam-*|desktop-polkit-*|desktop-mate-session-manager-*)
                    printf 'init=%s\n' "$INIT_CHOICE" ;;
            esac ;;
        *) printf 'profile=%s:%s:%s:%s:%s:%s:%s:%s:%s\n' \
            "$SHELL_CHOICE" "$TOOLS_CHOICE" "$INIT_CHOICE" "$PACKAGE_MANAGER" "$WITH_GCC" "$NETWORK" "$DESKTOP_CHOICE" "$PKG_NGINX" "$PKG_PHP" ;;
    esac
}

rootfs_manifest() {
    # Pinned source checksums and the cache key protect contents; this manifest
    # finds newly installed, replaced, and removed paths without hashing every
    # rootfs file before each stage.
    find "$ROOT" -mindepth 1 -printf '%P\t%y\t%m\t%U\t%G\t%s\t%T@\t%l\n' | LC_ALL=C sort -t $'\t' -k1,1
}

stage_cache_recipes() {
    local function_name
    for function_name in "$@"; do declare -f "$function_name"; done
}

stage_cache_packages() {
    local stage=$1 name
    case "$stage" in
        05-kernel*)
            printf '%s\n' linux
            [[ "$NETWORK" != yes ]] || printf '%s\n' wireless-regdb
            ;;
        02-userland)
            # The kernel, init, desktop, and package-manager source versions
            # cannot invalidate the shell/utilities binaries.
            printf '%s\n' libxcrypt ncurses kmod kbd
            if needs_busybox; then printf '%s\n' busybox; fi
            if [[ "$TOOLS_CHOICE" == gnu ]]; then
                printf '%s\n' coreutils grep sed findutils gawk tar gzip procps util-linux inetutils iproute2
            fi
            case "$SHELL_CHOICE" in
                bash) printf '%s\n' bash ;;
                dash) printf '%s\n' bash dash ;;
                zsh) printf '%s\n' bash dash zsh ;;
                fish) printf '%s\n' bash dash fish ;;
                busybox) printf '%s\n' bash ;;
            esac
            ;;
        02d-extras-*)
            [[ "$PKG_NANO" != yes ]] || printf '%s\n' nano
            [[ "$PKG_NEOFETCH" != yes ]] || printf '%s\n' neofetch
            [[ "$PKG_VIM" != yes ]] || printf '%s\n' vim
            ;;
        02c-network-tools-*) [[ "$PKG_PING" != yes ]] || printf '%s\n' inetutils ;;
        02a-login-su*)
            [[ "$TOOLS_CHOICE" != gnu ]] || printf '%s\n' shadow
            [[ "$PKG_MATE_CONTROL_CENTER" != yes && "$PKG_MATE_POWER_MANAGER" != yes ]] || printf '%s\n' linux-pam
            ;;
        02b-sudo) printf '%s\n' sudo ;;
        03-init*)
            case "$INIT_CHOICE" in
                openrc) printf '%s\n' openrc libcap ;;
                systemd) printf '%s\n' systemd libcap ;;
                sysvinit) printf '%s\n' sysvinit ;;
                runit) printf '%s\n' runit ;;
                dinit) printf '%s\n' dinit ;;
                s6) printf '%s\n' skalibs execline s6 s6-rc s6-linux-init ;;
            esac
            if [[ "$NETWORK" == yes && "$DESKTOP_CHOICE" == none && "$INIT_CHOICE" != systemd ]]; then
                printf '%s\n' dhcpcd
            fi
            [[ "$PKG_MATE_CONTROL_CENTER" != yes && "$PKG_MATE_POWER_MANAGER" != yes ]] || printf '%s\n' linux-pam
            ;;
        03-system-bus)
            [[ "$INIT_CHOICE" != systemd ]] || printf '%s\n' expat dbus
            ;;
        03b-wget-*)
            [[ "$PKG_WGET" != yes ]] || printf '%s\n' wget openssl ca-bundle
            ;;
        03c-openssh-v1-*)
            [[ "$PKG_OPENSSH" != yes ]] || printf '%s\n' openssh openssl zlib ca-bundle
            ;;
        03a-package-manager)
            case "$PACKAGE_MANAGER" in
                apt) printf '%s\n' zlib bzip2 xz lz4 xxhash openssl libgpg-error libgcrypt libassuan libksba npth gnupg libmd dpkg db triehash apt ;;
                pacman) printf '%s\n' zlib bzip2 xz zstd openssl libgpg-error libgcrypt libassuan libksba npth gnupg curl libarchive gpgme pacman ;;
            esac
            ;;
        04-native-gcc)
            [[ "$WITH_GCC" != yes ]] || printf '%s\n' binutils gcc gmp mpfr mpc make
            ;;
        04b-linux-firmware-v2*)
            [[ "$NETWORK" != yes && "$DESKTOP_CHOICE" == none ]] || printf '%s\n' linux-firmware
            [[ "$NETWORK" != yes ]] || printf '%s\n' wireless-regdb
            ;;
        web-stack-v1)
            [[ "$PKG_NGINX" != yes ]] || printf '%s\n' nginx pcre2 zlib openssl ca-bundle
            [[ "$PKG_PHP" != yes ]] || printf '%s\n' php libxml2 sqlite
            ;;
        desktop-app-firefox-*) printf '%s\n' firefox ;;
        desktop-*)
            # Desktop components share a large library stack. Keep its ABI
            # inputs in the key, while excluding unrelated init/toolchain
            # programs. The currently selected desktop and optional apps are
            # part of stage_cache_context and these source lists.
            desktop_base_packages
            case "$DESKTOP_CHOICE" in
                mate) mate_packages ;;
                lxde) lxde_packages ;;
                fluxbox) fluxbox_packages ;;
            esac
            case "$stage" in
                desktop-app-geany-*) printf '%s\n' geany ;;
            esac
            ;;
        *) for name in "${!VERSION[@]}"; do printf '%s\n' "$name"; done ;;
    esac
}

stage_cache_recipe_names() {
    local stage=$1 builder=$2
    printf '%s\n' "$builder"
    case "$stage" in
        05-kernel*) printf '%s\n' kernel_make install_wireless_regdb ;;
        02-userland) printf '%s\n' userland build_bash build_fish needs_busybox inetutils_tools autotools meson_package ;;
        02d-extras-*) printf '%s\n' extra_programs vim_tools autotools ;;
        02c-network-tools-*) printf '%s\n' network_tools inetutils_tools autotools ;;
        02a-login-su*) printf '%s\n' login_tools desktop_needs_logind desktop_package desktop_meson autotools ;;
        02b-sudo) printf '%s\n' sudo_tools autotools ;;
        03-init*) printf '%s\n' init_system small_init_tools autotools meson_package desktop_package desktop_meson ;;
        03-system-bus) printf '%s\n' system_bus desktop_package desktop_meson autotools meson_package ;;
        03b-wget-*) printf '%s\n' wget_tools download_tls autotools ;;
        03c-openssh-v1-*) printf '%s\n' openssh_tools download_tls desktop_package autotools ;;
        03a-package-manager) printf '%s\n' package_manager package_libraries patch_dpkg_headers download_tls autotools meson_package ;;
        04-native-gcc) printf '%s\n' native_development autotools ;;
        04b-linux-firmware-v2*) printf '%s\n' desktop_firmware desktop_package desktop_meson ;;
        web-stack-v1) printf '%s\n' web_stack download_tls autotools ;;
        desktop-app-firefox-*) printf '%s\n' firefox_application ;;
        desktop-*) printf '%s\n' desktop_package desktop_meson desktop_host_tools remove_installed_libtool_archives refresh_stale_libtool_metadata desktop_base_packages mate_packages lxde_packages fluxbox_packages ;;
    esac
}

stage_cache_key() {
    local stage=$1 builder=$2 package_inputs function_name
    local cache_functions cross_file_hash sdk_identity
    package_inputs=$(stage_cache_packages "$stage" | tr ' \t' '\n' | while IFS= read -r key; do
        [[ -n "$key" && -n ${VERSION[$key]+x} ]] || continue
        printf '%s\t%s\t%s\n' "$key" "${VERSION[$key]}" "${SHA[$key]:-}"
    done | LC_ALL=C sort -u)
    cache_functions=$(stage_cache_recipe_names "$stage" "$builder" | LC_ALL=C sort -u)
    cross_file_hash=none
    if [[ -f ${CROSS_FILE:-} ]]; then
        # cross.ini embeds the profile rootfs path in sys_root and pkg-config
        # paths. Normalize that location so identical profiles can share the
        # compiled-file cache across --new workspaces.
        cross_file_hash=$(python3 - "$CROSS_FILE" "$ROOT" <<'PY'
import hashlib
import pathlib
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()
root = sys.argv[2].encode()
sys.stdout.write(hashlib.sha256(data.replace(root, b"@DIY_ROOT@")).hexdigest())
PY
)
    fi
    # The SDK directory name is its content/revision key. Its absolute parent
    # path is not a build input and must not split the shared artifact cache.
    sdk_identity=${SDK##*/}
    {
        printf 'cache-schema=3\nstage=%s\nbuilder=%s\n' "$stage" "$builder"
        stage_cache_context "$stage"
        printf 'sdk=%s\ncross-file=%s\n' "${sdk_identity:-none}" "$cross_file_hash"
        printf 'host=%s\nepoch=%s\nCC=%s\nCXX=%s\nAR=%s\nRANLIB=%s\nCFLAGS=%s\nCXXFLAGS=%s\nCPPFLAGS=%s\nLDFLAGS=%s\n' \
            "${HOST:-}" "${SOURCE_DATE_EPOCH:-}" "${CC:-}" "${CXX:-}" "${AR:-}" "${RANLIB:-}" \
            "${CFLAGS:-}" "${CXXFLAGS:-}" "${CPPFLAGS:-}" "${LDFLAGS:-}"
        printf '%s\n' "$package_inputs"
        stage_cache_recipes fetch unpack
        while IFS= read -r function_name; do
            [[ -n "$function_name" ]] || continue
            declare -f "$function_name"
        done <<< "$cache_functions"
        [[ "$stage" != 05-kernel* ]] || printf 'kernel-config=%s\n' "$KERNEL_CONFIG"
        if [[ "$SHELL_CHOICE" == fish && "$stage" == 02-userland ]]; then
            rustc --version 2>/dev/null || :
            cargo --version 2>/dev/null || :
        fi
    } | sha256sum | cut -d' ' -f1
}

# Stable package-cache identity. The legacy key above hashes complete shell
# function bodies and broad desktop source lists, so unrelated edits invalidate
# many artifacts. Desktop stages key their own source only. Stage IDs are
# recipe revisions: bump the affected stage's vN when its recipe or relevant
# dependency ABI changes.
stage_cache_stable_packages() {
    local stage=$1 package
    case "$stage" in
        desktop-app-firefox-*) printf '%s\n' firefox ;;
        desktop-app-geany-*) printf '%s\n' geany ;;
        desktop-*)
            # Stage names have the form desktop-PACKAGE-vN. Key only the
            # package compiled by this stage, not the desktop's source catalog.
            package=${stage#desktop-}
            package=${package%-v[0-9]*}
            [[ -n "$package" ]] && printf '%s\n' "$package"
            ;;
        *) stage_cache_packages "$stage" ;;
    esac
}

stage_cache_key_stable() {
    local stage=$1 builder=$2 package_inputs
    local cross_file_hash=none sdk_identity normalized_cc normalized_cxx normalized_ar normalized_ranlib
    local normalized_cflags normalized_cxxflags normalized_cppflags normalized_ldflags
    package_inputs=$(stage_cache_stable_packages "$stage" | while IFS= read -r key; do
        [[ -n "$key" && -n ${VERSION[$key]+x} ]] || continue
        printf '%s\t%s\t%s\n' "$key" "${VERSION[$key]}" "${SHA[$key]:-}"
    done | LC_ALL=C sort -u)
    if [[ -f ${CROSS_FILE:-} ]]; then
        cross_file_hash=$(python3 - "$CROSS_FILE" "$ROOT" <<'PY'
import hashlib
import pathlib
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()
root = sys.argv[2].encode()
sys.stdout.write(hashlib.sha256(data.replace(root, b"@DIY_ROOT@")).hexdigest())
PY
)
    fi
    sdk_identity=${SDK##*/}
    # Build flags commonly contain the per-profile rootfs path. Normalize it
    # so the same package recipe can share artifacts across --new workspaces.
    normalized_cc=${CC:-}; normalized_cc=${normalized_cc//"$ROOT"/@DIY_ROOT@}
    normalized_cxx=${CXX:-}; normalized_cxx=${normalized_cxx//"$ROOT"/@DIY_ROOT@}
    normalized_ar=${AR:-}; normalized_ar=${normalized_ar//"$ROOT"/@DIY_ROOT@}
    normalized_ranlib=${RANLIB:-}; normalized_ranlib=${normalized_ranlib//"$ROOT"/@DIY_ROOT@}
    normalized_cflags=${CFLAGS:-}; normalized_cflags=${normalized_cflags//"$ROOT"/@DIY_ROOT@}
    normalized_cxxflags=${CXXFLAGS:-}; normalized_cxxflags=${normalized_cxxflags//"$ROOT"/@DIY_ROOT@}
    normalized_cppflags=${CPPFLAGS:-}; normalized_cppflags=${normalized_cppflags//"$ROOT"/@DIY_ROOT@}
    normalized_ldflags=${LDFLAGS:-}; normalized_ldflags=${normalized_ldflags//"$ROOT"/@DIY_ROOT@}
    {
        printf 'cache-schema=5\nstage=%s\nbuilder=%s\nrecipe-stage-id=%s\n' \
            "$stage" "$builder" "$stage"
        STAGE_CACHE_STABLE_CONTEXT=yes stage_cache_context "$stage"
        printf 'sdk=%s\ncross-file=%s\n' "${sdk_identity:-none}" "$cross_file_hash"
        printf 'host=%s\nepoch=%s\nCC=%s\nCXX=%s\nAR=%s\nRANLIB=%s\nCFLAGS=%s\nCXXFLAGS=%s\nCPPFLAGS=%s\nLDFLAGS=%s\n' \
            "${HOST:-}" "${SOURCE_DATE_EPOCH:-}" "$normalized_cc" "$normalized_cxx" "$normalized_ar" "$normalized_ranlib" \
            "$normalized_cflags" "$normalized_cxxflags" "$normalized_cppflags" "$normalized_ldflags"
        printf '%s\n' "$package_inputs"
        [[ "$stage" != 05-kernel* ]] || printf 'kernel-config=%s\n' "$KERNEL_CONFIG"
        if [[ "$SHELL_CHOICE" == fish && "$stage" == 02-userland ]]; then
            rustc --version 2>/dev/null || :
            cargo --version 2>/dev/null || :
        fi
    } | sha256sum | cut -d' ' -f1
}

stage_cache_apply() {
    local cache_dir=$1 path root_real parent_rel parent_real
    [[ -n ${ROOT:-} && "$ROOT" == /* && "$ROOT" != / && -d "$ROOT" && ! -L "$ROOT" ]] || return 1
    root_real=$(realpath -e -- "$ROOT") || return 1
    # A prior process may have been interrupted between preserving and
    # replacing a cache directory. Restore its last complete copy first.
    if [[ ! -e "$cache_dir" && ! -L "$cache_dir" && -d "$cache_dir.old" && ! -L "$cache_dir.old" ]]; then
        mv -- "$cache_dir.old" "$cache_dir" || return 1
    fi
    [[ -s "$cache_dir/payload.tar.gz" && -f "$cache_dir/removed.list" && -f "$cache_dir/SHA256SUMS" ]] || return 1
    (cd "$cache_dir" && sha256sum --check --status SHA256SUMS) || return 1
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        [[ "$path" != /* && "$path" != .. && "$path" != ../* &&
           "$path" != */.. && "$path" != */../* ]] || return 1
        if [[ "$path" == */* ]]; then parent_rel=${path%/*}; else parent_rel=.; fi
        parent_real=$(realpath -m -- "$root_real/$parent_rel") || return 1
        [[ "$parent_real" == "$root_real" || "$parent_real" == "$root_real/"* ]] || return 1
        rm -rf -- "$root_real/$path"
    done < "$cache_dir/removed.list"
    # Preserve permission bits from the trusted, SHA-256-checked package
    # artifact. In particular, Xorg.wrap requires its SUID bit; GNU tar's
    # default extraction mode strips SUID/SGID for non-root builders.
    tar -xzf "$cache_dir/payload.tar.gz" --no-same-owner --same-permissions -C "$root_real"
}

stage_cache_save() {
    local cache_dir=$1 before=$2 temporary backup path
    [[ -n ${ROOT:-} && "$ROOT" == /* && "$ROOT" != / && -d "$ROOT" && ! -L "$ROOT" &&
       -n "$cache_dir" && "$cache_dir" == /* && "$cache_dir" != / && -f "$before" ]] || return 1
    temporary="$cache_dir.tmp.$$"
    backup="$cache_dir.old"
    rm -rf -- "$temporary"
    mkdir -p "$temporary"
    rootfs_manifest > "$temporary/after.manifest"
    awk -F '\t' 'NR==FNR { old[$1]=$0; next } !($1 in old) || old[$1]!=$0 { print $1 }' \
        "$before" "$temporary/after.manifest" > "$temporary/changed.list"
    awk -F '\t' 'NR==FNR { new[$1]=1; next } !($1 in new) { print $1 }' \
        "$temporary/after.manifest" "$before" > "$temporary/removed.list"
    : > "$temporary/changed.nul"
    while IFS= read -r path; do [[ -z "$path" ]] || printf '%s\0' "$path" >> "$temporary/changed.nul"; done < "$temporary/changed.list"
    if [[ -s "$temporary/changed.nul" ]]; then
        tar -C "$ROOT" --no-recursion --null -T "$temporary/changed.nul" -czf "$temporary/payload.tar.gz"
    else
        tar -czf "$temporary/payload.tar.gz" --files-from /dev/null
    fi
    (cd "$temporary" && sha256sum payload.tar.gz removed.list > SHA256SUMS)
    rm -f "$temporary/after.manifest" "$temporary/changed.list" "$temporary/changed.nul"
    # Preserve the last complete cache until the new directory is in place.
    # stage_cache_apply restores the backup if a process is interrupted here.
    rm -rf -- "$backup"
    if [[ -e "$cache_dir" || -L "$cache_dir" ]]; then
        mv -- "$cache_dir" "$backup"
    fi
    if ! mv -- "$temporary" "$cache_dir"; then
        [[ ! -e "$backup" && ! -L "$backup" ]] || mv -- "$backup" "$cache_dir"
        return 1
    fi
    rm -rf -- "$backup"
}

step() {
    local name=$1 label builder cache_key cache_dir before cache_lock_fd legacy_cache_key legacy_lock_fd cache_hit
    builder=$2; shift
    label=$(stage_label "$name")
    if [[ -f "$STAMPS/$name" ]]; then
        if [[ ${UI_ACTIVE:-no} == yes ]]; then
            progress_begin "$(tr_text "$label (already complete)" "$label (jau baigta)")" yes
            UI_DONE=$((UI_DONE+1)); progress_finish done
        else say "$(tr_text "$name: already complete" "$name: jau baigta")"; fi
        return
    fi
    # Cache installed target files between profiles. Toolchain stages already
    # have their own shared SDK cache; bootloader stages also create files
    # outside rootfs and therefore stay profile-local.
    if [[ -n ${ARTIFACT_CACHE:-} && "$name" != 01* && "$name" != 06-boot-tools-* ]]; then
        cache_key=$(stage_cache_key_stable "$name" "$builder")
        cache_dir="$ARTIFACT_CACHE/$cache_key"
        exec {cache_lock_fd}>"$ARTIFACT_CACHE/$cache_key.lock"
        flock -x "$cache_lock_fd"
        cache_hit=''
        if stage_cache_apply "$cache_dir"; then
            cache_hit=stable
        else
            # Read through the pre-stable cache format once. This keeps
            # artifacts produced by earlier script versions reusable when
            # their original detailed recipe hash still matches.
            legacy_cache_key=$(stage_cache_key "$name" "$builder")
            if [[ "$legacy_cache_key" != "$cache_key" ]]; then
                exec {legacy_lock_fd}>"$ARTIFACT_CACHE/$legacy_cache_key.lock"
                flock -s "$legacy_lock_fd"
                if stage_cache_apply "$ARTIFACT_CACHE/$legacy_cache_key"; then
                    cache_hit=legacy
                fi
                flock -u "$legacy_lock_fd"
                exec {legacy_lock_fd}>&-
            fi
        fi
        if [[ -n "$cache_hit" ]]; then
            if [[ "$name" == 05-kernel* && -s "$ROOT/boot/bzImage" ]]; then
                install -m0644 "$ROOT/boot/bzImage" "$IMAGES/bzImage"
            fi
            touch "$STAMPS/$name"
            if [[ ${UI_ACTIVE:-no} == yes ]]; then
                progress_begin "$label (cached:$cache_hit)" yes
                UI_DONE=$((UI_DONE+1)); progress_finish done
            else say "$name: reused $cache_hit compiled package cache"; fi
            flock -u "$cache_lock_fd"
            exec {cache_lock_fd}>&-
            return 0
        fi
        before=$(mktemp "$BASE/.rootfs-before.XXXXXX")
        rootfs_manifest > "$before"
    fi
    if [[ ${UI_ACTIVE:-no} == yes ]]; then
        run_quiet "$label" "$@"
    else
        say "$name"
        "$@"
    fi
    if [[ -n ${before:-} ]]; then
        stage_cache_save "$cache_dir" "$before"
        rm -f -- "$before"
    fi
    if [[ -n ${cache_lock_fd:-} ]]; then
        flock -u "$cache_lock_fd"
        exec {cache_lock_fd}>&-
    fi
    # Nenaudoti „if ! funkcija“: jis išjungtų errexit.
    touch "$STAMPS/$name"        # Žyma sukuriama TIK po sėkmingo etapo.
}

# Sesijos nustatymai skaitomi kaip duomenys: nenaudojamas source ar eval.
# Žyma lieka ir po SIGKILL / elektros dingimo; ji pašalinama tik baigus.
session_pointer() {
    local directory
    directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
    # A copied builder may live on read-only media; state belongs in writable work.
    [[ -w "$directory" ]] || directory=$WORK_DIR
    printf '%s/.diy-linux-pending' "$directory"
}

# Užrakto failo trinti negalima: flock užraktas priklauso procesui, ne vardui.
build_lock_busy() {
    local lock=$1 owners=''
    if command -v lslocks >/dev/null; then
        owners=$(lslocks -n -r -u -o PID,COMMAND,PATH 2>/dev/null | awk -v path="$lock" '$3 == path {print "PID=" $1 "  command=" $2}') || :
    fi
    printf "$(tr_text '\nLock: %s\n' '\nUžraktas: %s\n')" "$lock" >&2
    [[ -z "$owners" ]] || printf '%s\n' "$owners" >&2
    printf "$(tr_text 'Close the previous session: chroot - exit, build / packaging - Ctrl+C. Resume builds with --resume.\nIf the terminal is closed, inspect processes: lslocks -o PID,COMMAND,PATH --notruncate\n' 'Užbaik ankstesnę sesiją: chroot — exit, kūrimas / pakavimas — Ctrl+C. Kūrimą tęsk su --resume.\nJei terminalas uždarytas, procesus patikrink: lslocks -o PID,COMMAND,PATH --notruncate\n')" >&2
    die "$(tr_text 'Build lock is occupied. Deleting its file does not release the lock' 'Kūrimo užraktas užimtas. Užrakto failo trynimas problemos neišsprendžia')"
}

session_choose() {
    local mode=$1 pointer selected answer name value
    pointer=$(session_pointer)
    RESUME_BASE='' FRESH_SUFFIX='' SDK_SUFFIX='' SESSION_LOCK_BASE=''
    if [[ -f "$pointer" && "$mode" != --new ]]; then
        IFS= read -r selected < "$pointer" || selected=''
        if [[ -f "$selected/build.session" && ! -f "$selected/build.complete" ]]; then
            [[ ! -L "$selected/build.session" ]] || die "$(tr_text 'Build session file must not be a symbolic link' 'Kūrimo sesijos failas negali būti simbolinė nuoroda')"
            chmod 0600 -- "$selected/build.session" || die "$(tr_text 'Could not protect the build session file' 'Nepavyko apsaugoti kūrimo sesijos failo')"
            # Neleisti pradėti antro kūrimo, kol pirmasis vis dar dirba.
            if [[ "$mode" != --fresh ]]; then
                exec 8> "$selected/.build-lock"
                flock -n 8 || build_lock_busy "$selected/.build-lock"
                SESSION_LOCK_BASE=$selected
            fi
            if [[ "$mode" != --fresh && "$mode" != --resume ]]; then
                [[ -t 0 ]] || die "$(tr_text 'An unfinished build exists. Choose --resume or --fresh' 'Rastas nebaigtas kūrimas. Pasirink --resume arba --fresh')"
                tui_ready
                if ! tui --title "$(tr_text 'Unfinished build' 'Nebaigtas kūrimas')" --cancel-label "$(tr_text 'Exit' 'Išeiti')" --menu \
                    "$(tr_text "Unfinished build found: $selected" "Rastas nebaigtas kūrimas: $selected")" 15 80 3 \
                    resume "$(tr_text 'Resume - completed stages are preserved' 'Tęsti — baigti etapai išsaugomi')" fresh "$(tr_text 'Start over - previous files are preserved' 'Pradėti iš naujo — ankstesni failai lieka')"; then exit 0; fi
                case "$TUI_VALUE" in resume) mode=--resume ;; fresh) mode=--fresh ;; esac
            fi
            if [[ "$mode" == --resume ]]; then
                DESKTOP_CHOICE=none
                TARGET_ARCH=x86_64 # Ankstesni profiliai iki architektūrų meniu.
                while IFS='=' read -r name value; do
                    case "$name" in
                        JOBS)
                            # Explicit JOBS=... on --resume is an intentional override;
                            # otherwise retain the value saved with the unfinished build.
                            [[ -z "$JOBS_WAS_EXPLICIT" ]] || continue
                            printf -v JOBS '%s' "$value" ;;
                        DESKTOP_CHOICE|TARGET_ARCH|SHELL_CHOICE|TOOLS_CHOICE|INIT_CHOICE|PACKAGE_MANAGER|WITH_GCC|BOOT_CHOICE|NETWORK|AUTOLOGIN|DESKTOP_AUTOSTART|KEEP_ROOTFS_TAR|SYSTEM_NAME|OS_NAME|WORK_DIR|ROOT_PASSWORD_HASH|USER_NAME|USER_PASSWORD_HASH|AUTO_INSTALL_DEPS|SDK_SUFFIX|PKG_NANO|PKG_WGET|PKG_OPENSSH|PKG_PING|PKG_NEOFETCH|PKG_VIM|PKG_FDISK|PKG_GEANY|PKG_FIREFOX|PKG_PLUMA|PKG_ENGRAMPA|PKG_CAJA|PKG_EOM|PKG_MATE_CONTROL_CENTER|PKG_MATE_POWER_MANAGER|PKG_NGINX|PKG_PHP)
                            printf -v "$name" '%s' "$value" ;;
                    esac
                done < "$selected/build.session"
                RESUME_BASE=$selected
                say "$(tr_text "Resuming previous build: $selected" "Tęsiamas ankstesnis kūrimas: $selected")"
                return 0
            fi
            exec 8>&-
            SESSION_LOCK_BASE=''
        elif [[ "$mode" == --resume ]]; then
            die "$(tr_text 'No unfinished build to resume' 'Nėra nebaigto kūrimo, kurį būtų galima tęsti')"
        fi
    elif [[ "$mode" == --resume ]]; then
        die "$(tr_text 'No saved unfinished build session' 'Nėra išsaugotos nebaigto kūrimo sesijos')"
    fi
    if [[ "$mode" == --new ]]; then
        FRESH_SUFFIX="-new-$(date +%s)-$$"
    fi
    if [[ "$mode" == --fresh ]]; then
        FRESH_SUFFIX="-new-$(date +%s)-$$"
        SDK_SUFFIX=$FRESH_SUFFIX
    fi
    if [[ "$mode" == --build || ( "$mode" == --new && ${DIY_NONINTERACTIVE_NEW:-no} == yes ) ]]; then
        [[ "$mode" != --new ]] || say "Using environment settings for the new profile."
    else
        menu
    fi
}

session_save() {
    local name pointer temporary
    # Tęsiant tas pats užraktas jau įgytas; jo neatidaryti antrą kartą.
    if [[ ${SESSION_LOCK_BASE:-} != "$BASE" ]]; then
        exec 8> "$BASE/.build-lock"
        flock -n 8 || build_lock_busy "$BASE/.build-lock"
        SESSION_LOCK_BASE=$BASE
    fi
    # Slaptažodžio maiša saugoma tik savininkui prieinamame faile.
    temporary="$BASE/build.session.tmp.$$"
    (umask 077
        for name in DESKTOP_CHOICE TARGET_ARCH SHELL_CHOICE TOOLS_CHOICE INIT_CHOICE PACKAGE_MANAGER WITH_GCC BOOT_CHOICE NETWORK AUTOLOGIN DESKTOP_AUTOSTART KEEP_ROOTFS_TAR SYSTEM_NAME OS_NAME WORK_DIR JOBS ROOT_PASSWORD_HASH USER_NAME USER_PASSWORD_HASH AUTO_INSTALL_DEPS SDK_SUFFIX PKG_NANO PKG_WGET PKG_OPENSSH PKG_PING PKG_NEOFETCH PKG_VIM PKG_FDISK PKG_GEANY PKG_FIREFOX PKG_PLUMA PKG_ENGRAMPA PKG_CAJA PKG_EOM PKG_MATE_CONTROL_CENTER PKG_MATE_POWER_MANAGER PKG_NGINX PKG_PHP; do
            [[ ${!name} != *$'\n'* ]] || die "$(tr_text "Invalid setting value: $name" "Netinkama nustatymo reikšmė: $name")"
            printf '%s=%s\n' "$name" "${!name}"
        done > "$temporary"
    )
    mv -f -- "$temporary" "$BASE/build.session"
    chmod 0600 -- "$BASE/build.session"
    rm -f -- "$BASE/build.complete"
    pointer=$(session_pointer)
    (umask 077; printf '%s\n' "$BASE" > "$pointer.tmp.$$")
    mv -f -- "$pointer.tmp.$$" "$pointer"
}

session_complete() {
    touch "$BASE/build.complete"
    rm -f -- "$WORK_DIR/.diy-linux-retry"
    local pointer selected
    pointer=$(session_pointer)
    if [[ -f "$pointer" ]]; then
        IFS= read -r selected < "$pointer" || selected=''
        [[ "$selected" != "$BASE" ]] || rm -f -- "$pointer"
    fi
}

valid_work_dir_path() {
    [[ "$1" =~ ^[A-Za-z0-9._/+_-]+$ ]]
}

workspace() {
    valid_work_dir_path "$WORK_DIR" || die "$(tr_text 'Working directory contains characters unsafe for the generated SDK environment script' 'Darbo kataloge yra simbolių, nesaugių generuojamam SDK aplinkos scenarijui')"
    mkdir -p -- "$WORK_DIR"
    WORK_DIR=$(cd "$WORK_DIR" && pwd -P)
    valid_work_dir_path "$WORK_DIR" || die "$(tr_text 'Working directory contains characters unsafe for the generated SDK environment script' 'Darbo kataloge yra simbolių, nesaugių generuojamam SDK aplinkos scenarijui')"
    [[ "$WORK_DIR" != / && "$WORK_DIR" != /usr && "$WORK_DIR" != /etc && "$WORK_DIR" != /bin && "$WORK_DIR" != /sbin ]] || die "$(tr_text 'Invalid working directory' 'Netinkamas darbo katalogas')"
    # JOBS ir slaptažodis neįtraukiami: sumažinus JOBS galima tęsti tą patį build.
    local recipe_id profile
    recipe_id=$({ sha256sum "${BASH_SOURCE[0]}"; printf "%s\n" "$PKG_NANO:$PKG_WGET:$PKG_OPENSSH:$PKG_PING:$PKG_NEOFETCH:$PKG_VIM:$PKG_FDISK:$PKG_GEANY:$PKG_FIREFOX:$PKG_PLUMA:$PKG_ENGRAMPA:$PKG_CAJA:$PKG_EOM:$PKG_MATE_CONTROL_CENTER:$PKG_MATE_POWER_MANAGER:$PKG_NGINX:$PKG_PHP:$DESKTOP_CHOICE:$AUTOLOGIN:$DESKTOP_AUTOSTART:$OS_NAME"; } | sha256sum | cut -c1-12)
    profile="$TARGET_ARCH-$SHELL_CHOICE-$TOOLS_CHOICE-$INIT_CHOICE-pkg-$PACKAGE_MANAGER-gcc-$WITH_GCC-$BOOT_CHOICE-net-$NETWORK-$recipe_id"
    BASE=${RESUME_BASE:-"$WORK_DIR/$profile${FRESH_SUFFIX:-}"}
    CACHE="$WORK_DIR/downloads"
    ARTIFACT_CACHE="$WORK_DIR/artifacts"
    ROOT="$BASE/rootfs"
    TOOLS="$BASE/cross-tools"
    SOURCES="$BASE/sources"
    BUILD="$BASE/build"
    STAMPS="$BASE/stamps"
    IMAGES="$BASE/images"
    architecture
    mkdir -p "$CACHE" "$ARTIFACT_CACHE" "$ROOT/usr"/{bin,sbin,lib,include,share} "$ROOT"/{etc,boot,dev,proc,sys,run,tmp,root,var/lib,var/log,var/tmp} \
             "$TOOLS" "$SOURCES" "$BUILD" "$STAMPS" "$IMAGES"
    chmod 1777 "$ROOT/tmp" "$ROOT/var/tmp"
    chmod 0700 "$ROOT/root"
    # Merged /usr: vienas bibliotekų kelias, mažiau dviprasmių lib/lib64 kelių.
    ln -snf usr/bin "$ROOT/bin"
    ln -snf usr/sbin "$ROOT/sbin"
    ln -snf usr/lib "$ROOT/lib"
    ln -snf usr/lib "$ROOT/lib64"
    ln -snf lib "$ROOT/usr/lib64"
    export PATH="$TOOLS/bin:$PATH" LC_ALL=C
    export CONFIG_SITE=/dev/null
    export SOURCE_DATE_EPOCH=1791583200
    printf "$(tr_text 'Workspace: %s\n' 'Darbo vieta: %s\n')" "$BASE"
    printf "$(tr_text 'Compiled artifact cache: %s\n' 'Sukompiliuotų programų artefaktų talpykla: %s\n')" "$ARTIFACT_CACHE"
}

# Bendras toolchain turi atskirą sysroot. Galutinės sistemos apvalkalas, init,
# paketų tvarkyklė ir UI pakeitimai nepriverčia iš naujo kompiliuoti GCC.
toolchain_inputs() {
    local name identity_url
    # Increment only when an effective toolchain build option, patch, or build
    # step changes the resulting compiler/sysroot. Comments and formatting do
    # not invalidate a compatible SDK.
    printf 'SDK-schema=2\nTOOLCHAIN_RECIPE_REV=1\nTARGET=%s\nHOST=%s\n' "$TARGET" "$HOST"
    printf '%s\n' \
        'binutils:--disable-nls --disable-multilib --disable-werror' \
        'gcc-initial:--with-newlib --without-headers --disable-nls --disable-shared --disable-multilib --disable-threads --disable-libatomic --disable-libgomp --disable-libquadmath --disable-libssp --disable-libstdcxx --disable-bootstrap --enable-languages=c,c++' \
        'glibc:--enable-kernel=5.10 --disable-nscd libc_cv_slibdir=/usr/lib' \
        'gcc-final:--disable-nls --disable-multilib --disable-bootstrap --disable-libsanitizer --disable-libquadmath --disable-libgomp --enable-languages=c,c++'
    "$HOST_CC" --version; "$HOST_CXX" --version
    for name in binutils gcc glibc glibc-fixes linux gmp mpfr mpc; do
        identity_url=${URL[$name]}
        # Tik tas pats SHA patikrintas patch: naujas transporto URL nekeičia ABI.
        if [[ "$name" == glibc-fixes && "${SHA[$name]}" == cd3245887c9c2564ef18b8e9ed4046093a575fc91bce00fd82eb931102e4a30e ]]; then
            identity_url='https://www.linuxfromscratch.org/patches/lfs/development/glibc-2.44-upstream_fixes-3.patch'
        fi
        printf '%s %s %s %s\n' "$name" "${VERSION[$name]}" "$identity_url" "${SHA[$name]}"
    done
}

toolchain_sdk_compatible() {
    local candidate=$1 inputs=$2 ld_version stage_name
    [[ -f "$candidate/READY" && -x "$candidate/tools/bin/$TARGET-gcc" &&
       -x "$candidate/tools/bin/$TARGET-g++" && -x "$candidate/tools/bin/$TARGET-ld" &&
       -f "$candidate/sysroot/usr/include/stdio.h" &&
       -e "$candidate/sysroot/usr/lib/${ELF_LOADER##*/}" ]] || return 1
    for stage_name in 01a-binutils 01b-gcc-initial 01c-glibc 01d-gcc-final; do
        [[ -f "$candidate/stamps/$stage_name" ]] || return 1
    done
    grep -Fxq "target=$TARGET" "$candidate/READY" || return 1
    grep -Fxq "gcc=${VERSION[gcc]}" "$candidate/READY" || return 1
    grep -Fxq "glibc=${VERSION[glibc]}" "$candidate/READY" || return 1
    [[ $("$candidate/tools/bin/$TARGET-gcc" -dumpmachine 2>/dev/null) == "$TARGET" ]] || return 1
    [[ $("$candidate/tools/bin/$TARGET-gcc" -dumpfullversion 2>/dev/null) == "${VERSION[gcc]}" ]] || return 1
    ld_version=$("$candidate/tools/bin/$TARGET-ld" --version 2>/dev/null | sed -n '1p')
    [[ "$ld_version" == *"GNU Binutils) ${VERSION[binutils]}"* ]] || return 1
    # New SDKs carry their full semantic inputs. Legacy SDKs are accepted only
    # after checking their completed stages and installed target tool versions.
    [[ ! -f "$candidate/toolchain.inputs" ||
       "$(cat "$candidate/toolchain.inputs")" == "$inputs" ]]
}

toolchain_workspace() {
    SYSTEM_BASE=$BASE SYSTEM_ROOT=$ROOT SYSTEM_TOOLS=$TOOLS
    SYSTEM_SOURCES=$SOURCES SYSTEM_BUILD=$BUILD SYSTEM_STAMPS=$STAMPS
    local key name saved_sdk saved_sdk_real current_toolchain_inputs incomplete_sdk='' candidate
    current_toolchain_inputs=$(toolchain_inputs)
    key=$(printf '%s\n' "$current_toolchain_inputs" | sha256sum | cut -c1-20)
    SDK="$WORK_DIR/toolchains/$key${SDK_SUFFIX:-}"
    # A resumed profile must continue with the exact SDK it already used.
    # Otherwise even a comment-only edit to a bootstrap function could select
    # a fresh SDK and needlessly rebuild binutils, GCC, and glibc.
    if [[ -n ${RESUME_BASE:-} && -f "$SYSTEM_BASE/toolchain-path" ]]; then
        IFS= read -r saved_sdk < "$SYSTEM_BASE/toolchain-path" || saved_sdk=''
        if [[ "$saved_sdk" == "$WORK_DIR/toolchains/"* && -d "$saved_sdk" ]]; then
            saved_sdk_real=$(realpath -e -- "$saved_sdk") || saved_sdk_real=''
            [[ "$saved_sdk_real" == "$saved_sdk" ]] ||
                die "$(tr_text 'Saved toolchain path is invalid; refusing to switch SDK while resuming.' 'Išsaugotas toolchain kelias netinkamas; tęsiant SDK nebus pakeistas.')"
            if [[ -f "$saved_sdk/READY" && -x "$saved_sdk/tools/bin/$TARGET-gcc" &&
                  -x "$saved_sdk/tools/bin/$TARGET-g++" &&
                  -f "$saved_sdk/sysroot/usr/include/stdio.h" &&
                  -e "$saved_sdk/sysroot/usr/lib/${ELF_LOADER##*/}" ]]; then
                grep -Fxq "target=$TARGET" "$saved_sdk/READY" &&
                    grep -Fxq "gcc=${VERSION[gcc]}" "$saved_sdk/READY" &&
                    grep -Fxq "glibc=${VERSION[glibc]}" "$saved_sdk/READY" ||
                    die "$(tr_text 'Saved toolchain does not match this profile.' 'Išsaugotas toolchain neatitinka profilio.')"
                SDK=$saved_sdk
            elif [[ -f "$saved_sdk/toolchain.inputs" ]] &&
                 [[ "$(cat "$saved_sdk/toolchain.inputs")" == "$current_toolchain_inputs" ]]; then
                # Keep an interrupted SDK as a fallback, but prefer another
                # complete compatible SDK below so a new profile does not
                # repeat bootstrap work needlessly.
                incomplete_sdk=$saved_sdk
            fi
        fi
    fi
    if [[ -z ${SDK_SUFFIX:-} ]]; then
        # Reuse any finished SDK with matching target ABI and tool versions;
        # profile-only changes (init, desktop, bootloader, OS name) must not
        # trigger a second cross-toolchain build. Exact-input matches are
        # preferred; validated legacy SDKs remain usable as a migration path.
        for candidate in "$WORK_DIR"/toolchains/*; do
            [[ -d "$candidate" ]] || continue
            if toolchain_sdk_compatible "$candidate" "$current_toolchain_inputs" &&
               { [[ -z ${SDK_SUFFIX:-} ]] && [[ "$candidate" == "$SDK" || ! -f "$SDK/READY" ]]; }; then
                SDK=$candidate
                break
            fi
        done
        if [[ ! -f "$SDK/READY" && -n "$incomplete_sdk" ]]; then
            SDK=$incomplete_sdk
        fi
    fi
    BASE=$SDK ROOT="$SDK/sysroot" TOOLS="$SDK/tools"
    SOURCES="$SDK/sources" BUILD="$SDK/build" STAMPS="$SDK/stamps"
    mkdir -p "$ROOT/usr"/{bin,sbin,lib,include,share} "$ROOT"/{etc,var,run,tmp} "$TOOLS" "$SOURCES" "$BUILD" "$STAMPS"
    [[ -f "$SDK/READY" || -f "$SDK/toolchain.inputs" ]] ||
        printf '%s\n' "$current_toolchain_inputs" > "$SDK/toolchain.inputs"
    # Save the exact SDK as soon as a full system build starts using it. This
    # lets --resume continue an interrupted GCC bootstrap too, before READY.
    if [[ -n ${SYSTEM_BASE:-} ]]; then
        local toolchain_path_tmp="$SYSTEM_BASE/toolchain-path.tmp.$$"
        (umask 077; printf '%s\n' "$SDK" > "$toolchain_path_tmp")
        mv -f -- "$toolchain_path_tmp" "$SYSTEM_BASE/toolchain-path"
    fi
    exec 9> "$SDK/.lock"
    # Nelaukti tyliai su sustingusia „Paruošimas“ juosta.
    flock -n -x 9 || build_lock_busy "$SDK/.lock"
    ln -snf usr/bin "$ROOT/bin"; ln -snf usr/sbin "$ROOT/sbin"
    ln -snf usr/lib "$ROOT/lib"; ln -snf usr/lib "$ROOT/lib64"; ln -snf lib "$ROOT/usr/lib64"
    export PATH="$TOOLS/bin:$PATH"
    printf "$(tr_text 'Saved / reused toolchain: %s\n' 'Išsaugomas / naudojamas toolchain: %s\n')" "$SDK"
}

# Tas pats užfiksuotas SDK receptas ir užraktas, bet be sistemos kūrimo.
# Etapų žymos SDK kataloge leidžia tęsti pakartojus --toolchain.
build_toolchain_only() {
    architecture || die "$VALIDATION_ERROR"
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "$(tr_text 'JOBS must be a positive integer' 'JOBS turi būti teigiamas sveikasis skaičius')"
    # Šie pasirinkimai nereikalingi SDK ir neturi diegti ISO / Rust priklausomybių.
    local DESKTOP_CHOICE=none BOOT_CHOICE=none INIT_CHOICE=openrc SHELL_CHOICE=bash PACKAGE_MANAGER=none
    check_host
    valid_work_dir_path "$WORK_DIR" || die "$(tr_text 'Working directory contains characters unsafe for the generated SDK environment script' 'Darbo kataloge yra simbolių, nesaugių generuojamam SDK aplinkos scenarijui')"
    mkdir -p -- "$WORK_DIR"
    WORK_DIR=$(cd "$WORK_DIR" && pwd -P)
    valid_work_dir_path "$WORK_DIR" || die "$(tr_text 'Working directory contains characters unsafe for the generated SDK environment script' 'Darbo kataloge yra simbolių, nesaugių generuojamam SDK aplinkos scenarijui')"
    [[ "$WORK_DIR" != / && "$WORK_DIR" != /usr && "$WORK_DIR" != /etc &&
       "$WORK_DIR" != /bin && "$WORK_DIR" != /sbin ]] || die "$(tr_text 'Invalid working directory' 'Netinkamas darbo katalogas')"
    CACHE="$WORK_DIR/downloads"; mkdir -p "$CACHE"
    RETRY_KIND=toolchain
    rm -f -- "$WORK_DIR/.diy-linux-retry"
    # toolchain_workspace išsaugo profilio kintamuosius; šiame režime profilio nėra.
    BASE='' ROOT='' TOOLS='' SOURCES='' BUILD='' STAMPS=''
    export LC_ALL=C CONFIG_SITE=/dev/null SOURCE_DATE_EPOCH=1791583200
    toolchain_workspace
    progress_start 4 "$SDK/build.log" "$(stage_label 01a-binutils)" "$(stage_label 01b-gcc-initial)" \
        "$(stage_label 01c-glibc)" "$(stage_label 01d-gcc-final)"
    step '01a-binutils' bootstrap_binutils
    local requested_jobs=$JOBS
    JOBS=1
    [[ -f "$STAMPS/01b-gcc-initial" ]] || check_build_memory
    step '01b-gcc-initial' bootstrap_gcc_initial
    step '01c-glibc' bootstrap_glibc
    [[ -f "$STAMPS/01d-gcc-final" ]] || check_build_memory
    step '01d-gcc-final' bootstrap_gcc_final
    JOBS=$requested_jobs
    [[ -x "$TOOLS/bin/$TARGET-gcc" && -x "$TOOLS/bin/$TARGET-g++" &&
       -f "$ROOT/usr/include/stdio.h" && -e "$ROOT/usr/lib/${ELF_LOADER##*/}" ]] || die "$(tr_text 'Toolchain is not complete yet' 'Toolchain dar nebaigtas')"
    printf 'target=%s\ngcc=%s\nglibc=%s\nbinutils=%s\ninputs_sha256=%s\n' \
        "$TARGET" "${VERSION[gcc]}" "${VERSION[glibc]}" "${VERSION[binutils]}" \
        "$(printf '%s\n' "$(toolchain_inputs)" | sha256sum | cut -d' ' -f1)" > "$SDK/READY"
    cat > "$SDK/sdk-env.sh" <<SDK_ENV
# source "$SDK/sdk-env.sh" — SDK aplinka, ne galutinės sistemos rootfs.
export DIY_SDK="$SDK" DIY_ROOT="$ROOT"
export PATH="$TOOLS/bin:\$PATH"
export CROSS_COMPILE="$TARGET-"
export CC="$TARGET-gcc" CXX="$TARGET-g++" AR="$TARGET-ar" RANLIB="$TARGET-ranlib" STRIP="$TARGET-strip"
export PKG_CONFIG_SYSROOT_DIR="$ROOT"
export PKG_CONFIG_LIBDIR="$ROOT/usr/lib/pkgconfig:$ROOT/usr/share/pkgconfig"
export PKG_CONFIG_PATH=""
SDK_ENV
    progress_stop
    flock -u 9; exec 9>&-
    rm -f -- "$WORK_DIR/.diy-linux-retry"
    printf "$(tr_text '\nToolchain ready: %s\nEnvironment: source "%s/sdk-env.sh"\n' '\nToolchain paruoštas: %s\nAplinka: source "%s/sdk-env.sh"\n')" "$SDK" "$SDK"
}

system_toolchain() {
    [[ -x "$TOOLS/bin/$TARGET-gcc" && -x "$TOOLS/bin/$TARGET-g++" && -f "$ROOT/usr/include/stdio.h" ]] || die "$(tr_text 'Toolchain is not complete yet' 'Toolchain dar nebaigtas')"
    printf 'target=%s\ngcc=%s\nglibc=%s\nbinutils=%s\ninputs_sha256=%s\n' \
        "$TARGET" "${VERSION[gcc]}" "${VERSION[glibc]}" "${VERSION[binutils]}" \
        "$(printf '%s\n' "$(toolchain_inputs)" | sha256sum | cut -d' ' -f1)" > "$SDK/READY"
    BASE=$SYSTEM_BASE ROOT=$SYSTEM_ROOT TOOLS=$SYSTEM_TOOLS
    SOURCES=$SYSTEM_SOURCES BUILD=$SYSTEM_BUILD STAMPS=$SYSTEM_STAMPS
    if [[ ! -f "$STAMPS/sysroot-seeded" ]]; then
        cp -a "$SDK/sysroot/." "$ROOT/"
        touch "$STAMPS/sysroot-seeded"
    fi
    # GCC numatytasis sysroot yra SDK/sysroot. Profilio wrappers aiškiai
    # parenka savo rootfs, kad nesumaišytų dviejų kuriamų sistemų bibliotekų.
    mkdir -p "$TOOLS/bin"
    local executable wrapper compiler
    for executable in "$SDK/tools/bin/"*; do
        [[ -e "$executable" ]] || continue
        ln -snf "$executable" "$TOOLS/bin/${executable##*/}"
    done
    ln -snf "$SDK/tools/$TARGET" "$TOOLS/$TARGET"
    for compiler in gcc g++; do
        wrapper="$TOOLS/bin/$TARGET-$compiler"
        [[ ! -L "$wrapper" ]] || unlink "$wrapper"
        cat > "$wrapper" <<WRAPPER
#!/usr/bin/env bash
exec "$SDK/tools/bin/$TARGET-$compiler" --sysroot="$ROOT" "\$@"
WRAPPER
        chmod 0755 "$wrapper"
    done
    export PATH="$TOOLS/bin:$PATH"
    cat > "$BASE/sdk-env.sh" <<SDK_ENV
# source "$BASE/sdk-env.sh" — kryžminis kūrimas šeimininke.
export DIY_ROOT="$ROOT" DIY_SDK="$SDK"
export PATH="$TOOLS/bin:\$PATH"
export CROSS_COMPILE="$TARGET-"
export CC="$TARGET-gcc" CXX="$TARGET-g++" AR="$TARGET-ar" RANLIB="$TARGET-ranlib" STRIP="$TARGET-strip"
export CFLAGS="-O2 -pipe -isystem $SDK/sysroot/usr/include"
export CXXFLAGS="-O2 -pipe -isystem $SDK/sysroot/usr/include"
export PKG_CONFIG_SYSROOT_DIR="$ROOT"
export PKG_CONFIG_LIBDIR="$ROOT/usr/lib/pkgconfig:$ROOT/usr/share/pkgconfig"
export PKG_CONFIG_PATH=""
# configure --host=$TARGET --prefix=/usr; make; make DESTDIR="\$DIY_ROOT" install
SDK_ENV
    printf '%s\n' "$SDK" > "$BASE/toolchain-path"
    flock -u 9
    exec 9>&-
}

save_system() {
    local name
    # Paprastas key=value failas, nenaudojamas source ar eval.
    : > "$BASE/system.settings"
    for name in DESKTOP_CHOICE TARGET_ARCH SHELL_CHOICE TOOLS_CHOICE INIT_CHOICE PACKAGE_MANAGER WITH_GCC BOOT_CHOICE NETWORK AUTOLOGIN DESKTOP_AUTOSTART KEEP_ROOTFS_TAR SYSTEM_NAME OS_NAME USER_NAME PKG_NANO PKG_WGET PKG_OPENSSH PKG_PING PKG_NEOFETCH PKG_VIM PKG_FDISK PKG_GEANY PKG_FIREFOX PKG_PLUMA PKG_ENGRAMPA PKG_CAJA PKG_EOM PKG_MATE_CONTROL_CENTER PKG_MATE_POWER_MANAGER PKG_NGINX PKG_PHP; do
        printf '%s=%s\n' "$name" "${!name}" >> "$BASE/system.settings"
    done
    printf '%s\n' "$BASE" > "$WORK_DIR/latest-system"
}

load_system() {
    local selected=${1:-} key value program option
    if [[ -z "$selected" ]]; then
        [[ -f "$WORK_DIR/latest-system" ]] || die "$(tr_text 'Specify a system directory: --enter /path/profile or --repack /path/profile' 'Nurodyk sistemos katalogą: --enter /kelias/profilis arba --repack /kelias/profilis')"
        IFS= read -r selected < "$WORK_DIR/latest-system" || selected=''
    fi
    [[ -d "$selected" ]] || die "$(tr_text "System directory does not exist: $selected" "Nėra sistemos katalogo: $selected")"
    selected=$(cd "$selected" && pwd -P)
    [[ ${selected##*/} != rootfs ]] || selected=${selected%/rootfs}
    BASE=$selected ROOT="$selected/rootfs" TOOLS="$selected/cross-tools"
    BUILD="$selected/build" STAMPS="$selected/stamps" IMAGES="$selected/images"
    DESKTOP_CHOICE=none
    OS_NAME='DIY Linux' # Senesni system.settings neturėjo OS pavadinimo.
    TARGET_ARCH=x86_64 # Senesni system.settings neturėjo architektūros.
    [[ ! -L "$ROOT" && -d "$ROOT" ]] || die "$(tr_text 'Rootfs must be an actual directory of this profile' 'Rootfs turi būti tikras šio profilio katalogas')"
    [[ -f "$BASE/system.settings" && -x "$ROOT/usr/bin/bash" ]] || die "$(tr_text 'The directory has no prepared system and system.settings' 'Nurodytame kataloge nėra paruoštos sistemos ir system.settings')"
    # Senesniuose system.settings pasirinkimų dar nėra: nustatyti pagal esamus failus.
    for program in nano wget ping neofetch vim fdisk geany firefox pluma engrampa; do
        option="PKG_${program^^}"
        printf -v "$option" no
        if [[ -x "$ROOT/usr/bin/$program" || -x "$ROOT/usr/sbin/$program" ]]; then
            printf -v "$option" yes
        fi
    done
    PKG_OPENSSH=no; [[ ! -x "$ROOT/usr/bin/ssh" ]] || PKG_OPENSSH=yes
    PKG_NGINX=no; [[ ! -x "$ROOT/usr/sbin/nginx" ]] || PKG_NGINX=yes
    PKG_PHP=no; [[ ! -x "$ROOT/usr/sbin/php-fpm" ]] || PKG_PHP=yes
        PKG_CAJA=no; [[ ! -x "$ROOT/usr/bin/caja" ]] || PKG_CAJA=yes
    PKG_EOM=no; [[ ! -x "$ROOT/usr/bin/eom" ]] || PKG_EOM=yes
    while IFS='=' read -r key value; do
        case "$key" in
            DESKTOP_AUTOSTART) DESKTOP_AUTOSTART=$value; DESKTOP_AUTOSTART_WAS_SET=x ;;
            DESKTOP_CHOICE|TARGET_ARCH|SHELL_CHOICE|TOOLS_CHOICE|INIT_CHOICE|PACKAGE_MANAGER|WITH_GCC|BOOT_CHOICE|NETWORK|AUTOLOGIN|KEEP_ROOTFS_TAR|SYSTEM_NAME|OS_NAME|USER_NAME|PKG_NANO|PKG_WGET|PKG_OPENSSH|PKG_PING|PKG_NEOFETCH|PKG_VIM|PKG_FDISK|PKG_GEANY|PKG_FIREFOX|PKG_PLUMA|PKG_ENGRAMPA|PKG_CAJA|PKG_EOM|PKG_MATE_CONTROL_CENTER|PKG_MATE_POWER_MANAGER|PKG_NGINX|PKG_PHP)
                printf -v "$key" '%s' "$value" ;;
        esac
    done < "$BASE/system.settings"
    validate || die "$VALIDATION_ERROR"
    [[ -f "$BASE/toolchain-path" ]] || die "$(tr_text 'No saved toolchain reference' 'Nėra išsaugoto toolchain nuorodos')"
    IFS= read -r SDK < "$BASE/toolchain-path"
    export PATH="$TOOLS/bin:$PATH"
    STRIP="$TARGET-strip"
}

# Ieškome tik paruoštus profilius šiame darbo kataloge, ne toolchain ar sources.
list_systems() {
    SYSTEM_PATHS=() SYSTEM_LABELS=()
    # Skaitymo komandos, paleistos kitu cwd, gali rasti profilius prie scenarijaus.
    if [[ ! -d "$WORK_DIR" && "$WORK_DIR" == "$DEFAULT_WORK_DIR" && -z "$WORK_DIR_FROM_ENV" ]]; then
        local script_work
        script_work="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/diy-linux-work"
        [[ ! -d "$script_work" ]] || WORK_DIR=$script_work
    fi
    local directory key value name os_name shell init boot architecture_label desktop_label
    while IFS= read -r -d '' directory; do
        [[ ! -L "$directory/rootfs" && -d "$directory/rootfs" ]] || continue
        [[ -f "$directory/system.settings" && -f "$directory/toolchain-path" &&
           -x "$directory/rootfs/usr/bin/bash" && -x "$directory/rootfs/init" &&
           -s "$directory/images/bzImage" && -s "$directory/images/initramfs.cpio.zst" ]] || continue
        name=${directory##*/} os_name='DIY Linux' shell='?' init='?' boot='?' architecture_label=x86_64 desktop_label=none
        while IFS='=' read -r key value; do
            case "$key" in SYSTEM_NAME) name=$value ;; OS_NAME) os_name=$value ;; SHELL_CHOICE) shell=$value ;;
                INIT_CHOICE) init=$value ;; BOOT_CHOICE) boot=$value ;; TARGET_ARCH) architecture_label=$value ;; DESKTOP_CHOICE) desktop_label=$value ;; esac
        done < "$directory/system.settings"
        SYSTEM_PATHS+=("$directory")
        SYSTEM_LABELS+=("$os_name ($name) | $architecture_label / $shell / $init / $boot / desktop=$desktop_label | ID: ${directory##*-}")
    done < <(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
}

select_system() {
    local requested=${1:-} title=${2:-"$(tr_text 'Select a system' 'Pasirink sistemą')"} index default=1 pointer='' count
    local -a entries=()
    if [[ -n "$requested" ]]; then SELECTED_SYSTEM=$requested; return 0; fi
    list_systems
    count=${#SYSTEM_PATHS[@]}
    if (( count == 0 )); then
        if [[ -t 0 && -t 1 ]]; then
            tui --title "$(tr_text 'No prepared systems' 'Paruoštų sistemų nėra')" --msgbox \
                "$(tr_text "No prepared systems were found in:\n$WORK_DIR\n\nChoose Build from the main menu first, or change the working directory." "Darbo kataloge paruoštų sistemų nerasta:\n$WORK_DIR\n\nPirmiausia pagrindiniame meniu pasirink Kurti arba pakeisk darbo katalogą.")" 12 76 || :
            return 1
        fi
        die "$(tr_text "No prepared systems in working directory: $WORK_DIR. You can specify a profile directory in the command." "Darbo kataloge nėra paruoštų sistemų: $WORK_DIR. Gali nurodyti profilio katalogą komandoje.")"
    fi
    if (( count == 1 )); then SELECTED_SYSTEM=${SYSTEM_PATHS[0]}; return 0; fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        printf "$(tr_text 'Available systems:\n' 'Rastos sistemos:\n')" >&2
        printf '  %s\n' "${SYSTEM_PATHS[@]}" >&2
        die "$(tr_text 'Selection requires a terminal, or specify a profile directory in the command' 'Pasirinkimui reikia terminalo arba nurodyk profilio katalogą komandoje')"
    fi
    tui_ready
    if [[ -f "$WORK_DIR/last-used-system" ]]; then
        IFS= read -r pointer < "$WORK_DIR/last-used-system" || :
    elif [[ -f "$WORK_DIR/latest-system" ]]; then
        IFS= read -r pointer < "$WORK_DIR/latest-system" || :
    fi
    for ((index=0; index<count; index++)); do
        [[ ${SYSTEM_PATHS[index]} != "$pointer" ]] || default=$((index+1))
        entries+=("$((index+1))" "${SYSTEM_LABELS[index]}" "${SYSTEM_PATHS[index]}")
    done
    if tui --title "$title" --default-item "$default" --item-help --menu \
        "$(tr_text 'Select a prepared rootfs. Esc cancels. Each line contains the full profile name.' 'Pasirink paruoštą rootfs. Esc atšaukia. Pilnas profilio vardas pateiktas eilutėje.')" \
        22 80 12 "${entries[@]}"; then
        for ((index=0; index<count; index++)); do
            if [[ "$TUI_VALUE" == "$((index+1))" ]]; then
                SELECTED_SYSTEM=${SYSTEM_PATHS[index]}
                return 0
            fi
        done
        die "$(tr_text 'Invalid system selection' 'Netinkamas sistemos pasirinkimas')" 
    fi
    return 1
}

image_menu() {
    select_system '' "$(tr_text 'Which system should be packaged?' 'Kurią sistemą supakuoti?')" || return 0
    load_system "$SELECTED_SYSTEM"
    local -a entries=()
    case "$BOOT_CHOICE" in
        none) entries=(auto "$(tr_text 'Rootfs / initramfs archives (no bootloader selected)' 'Rootfs / initramfs archyvai (paleidyklė nepasirinkta)')") ;;
        lilo) entries=(img "$(tr_text 'LILO BIOS disk image (IMG only)' 'LILO BIOS disko atvaizdas (tik IMG)')") ;;
        *) entries=(iso "$(tr_text 'ISO boot image' 'ISO paleidimo atvaizdas')" img "$(tr_text 'IMG boot image' 'IMG paleidimo atvaizdas')" auto "$(tr_text 'All normal images for this profile' 'Visi įprasti šio profilio atvaizdai')") ;;
    esac
    if tui --title "$(tr_text "Image: $SYSTEM_NAME" "Atvaizdas: $SYSTEM_NAME")" --menu \
        "$(tr_text 'Uses the existing rootfs and selected bootloader; no programs are compiled.' 'Naudojamas esamas rootfs ir pasirinkta paleidyklė; programos nekompiliuojamos.')" \
        15 80 5 "${entries[@]}"; then
        repack_system "$BASE" "$TUI_VALUE"
    fi
}

enter_system() {
    select_system "${1:-}" "$(tr_text 'Which system should be entered (chroot)?' 'Į kurią sistemą prisijungti (chroot)?')" || return 0
    load_system "$SELECTED_SYSTEM"
    require_emulation
    exec 8> "$BASE/.build-lock"
    flock -n 8 || build_lock_busy "$BASE/.build-lock"
    if [[ -d "$WORK_DIR" ]]; then printf '%s\n' "$BASE" > "$WORK_DIR/last-used-system"; fi
    local tool chroot_status=0 caller_uid=${SUDO_UID:-$(id -u)} caller_gid=${SUDO_GID:-$(id -g)}
    local metadata_helper="$BASE/.enter-restore-metadata.py"
    for tool in sudo unshare mount chroot hostname python3; do command -v "$tool" >/dev/null || die "$(tr_text "Entering requires $tool" "Prisijungimui reikia $tool")"; done
    # chown clears SUID/SGID bits and security.capability. Save that metadata
    # so the rootfs remains bootable and privileged tools retain their modes.
    cat > "$metadata_helper" <<'PY'
import base64, json, os, stat, sys

action, root, state = sys.argv[1:]
root = os.path.realpath(root)
if action == "save":
    root_device = os.stat(root).st_dev
    entries = []
    for directory, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [name for name in dirnames
                       if not os.path.islink(os.path.join(directory, name))
                       and os.stat(os.path.join(directory, name), follow_symlinks=False).st_dev == root_device]
        for name in dirnames + filenames:
            path = os.path.join(directory, name)
            try:
                st = os.lstat(path)
                if st.st_uid != 0 or not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode)):
                    continue
                mode = stat.S_IMODE(st.st_mode)
                capability = b""
                if stat.S_ISREG(st.st_mode):
                    try:
                        capability = os.getxattr(path, "security.capability", follow_symlinks=False)
                    except OSError:
                        pass
                if mode & 0o6000 or capability:
                    entries.append([os.path.relpath(path, root), mode,
                                    base64.b64encode(capability).decode("ascii")])
            except OSError:
                continue
    with open(state, "w", encoding="utf-8") as stream:
        json.dump(entries, stream)
elif action == "restore":
    with open(state, encoding="utf-8") as stream:
        entries = json.load(stream)
    for relative, mode, encoded_capability in entries:
        path = os.path.join(root, relative)
        if os.path.commonpath((root, os.path.realpath(path))) != root:
            continue
        try:
            st = os.lstat(path)
            if not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode)):
                continue
            os.chown(path, 0, 0, follow_symlinks=False)
            os.chmod(path, mode, follow_symlinks=False)
            capability = base64.b64decode(encoded_capability)
            if capability and stat.S_ISREG(st.st_mode):
                os.setxattr(path, "security.capability", capability, follow_symlinks=False)
        except OSError as error:
            print(f"warning: could not restore privileged metadata for {relative}: {error}", file=sys.stderr)
PY
    chmod 0600 "$metadata_helper"
    say "$(tr_text "Entering $ROOT; return with: exit" "Prisijungimas į $ROOT; grįžimas: exit")"
    printf "$(tr_text 'Changes installed in this rootfs persist on disk. Create an image separately after leaving.\n' 'Diegimas šiame rootfs išlieka diske. Išėjus atvaizdą gali sukurti atskirai.\n')"
    printf "$(tr_text 'Chroot uses the host kernel and uptime. Test system boot using ISO / IMG.\n' 'Chroot naudoja šeimininko branduolį ir uptime. Sistemos boot tikrink paleidęs ISO / IMG.\n')"
    # Privati mount namespace: /proc, /sys, /dev ir DNS montavimai nelieka
    # šeimininke. sudo naudojamas tik chroot sesijai; į host /usr nediegiama.
    if sudo unshare --mount --uts --fork --propagation private bash -Eeuo pipefail -c '
        root=$1; terminal=$2; prompt=$3; caller_uid=$4; caller_gid=$5; target_user=$6; metadata_helper=$7
        # UTS namespace atskiras: host vardas nesikeičia.
        hostname "$(cat "$root/etc/hostname")"
        mkdir -p "$root"/{proc,sys,dev,run,etc}
        mount -t proc proc "$root/proc"
        mount --rbind /sys "$root/sys"; mount --make-rslave "$root/sys"
        mount --rbind /dev "$root/dev"; mount --make-rslave "$root/dev"
        mount -t tmpfs tmpfs "$root/run"
        backup=$(mktemp -d "$root/run/diy-enter.XXXXXX")
        original=no
        if [[ -e "$root/etc/resolv.conf" || -L "$root/etc/resolv.conf" ]]; then
            mv "$root/etc/resolv.conf" "$backup/resolv.conf"; original=yes
        fi
        restore_dns() {
            [[ ! -e "$root/etc/resolv.conf" && ! -L "$root/etc/resolv.conf" ]] || unlink "$root/etc/resolv.conf"
            [[ "$original" != yes ]] || mv "$backup/resolv.conf" "$root/etc/resolv.conf"
        }
        restore_enter_state() {
            restore_dns
            if ! python3 "$metadata_helper" save "$root" "$backup/privileged.json"; then
                printf "%s\\n" "warning: could not save privileged file metadata; leaving rootfs ownership unchanged" >&2
                return 0
            fi
            # chroot runs as root, but the build tree belongs to the invoking
            # host user. Restore host ownership so --resume can edit it later.
            if [[ -d "$root/home/$target_user" ]]; then
                find "$root/home/$target_user" -xdev -uid 0 -exec chown -h 1000:1000 {} + 2>/dev/null || :
            fi
            find "$root" -xdev -uid 0 -exec chown -h "$caller_uid:$caller_gid" {} + 2>/dev/null || :
            python3 "$metadata_helper" restore "$root" "$backup/privileged.json" || :
        }
        trap restore_enter_state EXIT
        cp -L /etc/resolv.conf "$root/etc/resolv.conf"
        chroot "$root" /usr/bin/env -i HOME=/root USER=root LOGNAME=root \
            TERM="$terminal" PATH=/usr/bin:/usr/sbin:/bin:/sbin "PS1=$prompt" DIY_CHROOT=1 /bin/bash --login -i
    ' _ "$ROOT" "${TERM:-linux}" '\u@\h:\w\$ ' "$caller_uid" "$caller_gid" "$USER_NAME" "$metadata_helper"; then :; else chroot_status=$?; fi
    rm -f -- "$metadata_helper"
    [[ "$chroot_status" == 0 ]] || printf "$(tr_text 'Chroot exit status: %s\n' 'Chroot komandos grįžimo kodas: %s\n')" "$chroot_status"
    printf "$(tr_text '\nChroot session ended. Changes saved: %s\n' '\nChroot sesija baigta. Pakeitimai išsaugoti: %s\n')" "$ROOT"
    printf 'ISO: bash "%s" --iso "%s"\n' "${BASH_SOURCE[0]}" "$BASE"
    printf 'IMG: bash "%s" --img "%s"\n' "${BASH_SOURCE[0]}" "$BASE"
    printf "$(tr_text 'All profile images: bash "%s" --repack "%s"\n' 'Visi profilio atvaizdai: bash "%s" --repack "%s"\n')" "${BASH_SOURCE[0]}" "$BASE"
}

upgrade_rootfs_devpts() {
    local boot_script="$ROOT/etc/diy/boot" tty_gid
    [[ -f "$boot_script" ]] || return 0
    tty_gid=$(awk -F: '$1 == "tty" { print $3; exit }' "$ROOT/etc/group" 2>/dev/null || :)
    [[ "$tty_gid" =~ ^[0-9]+$ ]] || tty_gid=5

    if ! grep -Fq 'mkdir -p /dev/pts' "$boot_script"; then
        if grep -q '^mount -a$' "$boot_script"; then
            sed -i '/^mount -a$/i mkdir -p /dev/pts' "$boot_script"
        else
            sed -i '/^hostname -F \/etc\/hostname/a mkdir -p /dev/pts' "$boot_script"
        fi
    fi
    if ! grep -Fq 'mount -t devpts devpts /dev/pts' "$boot_script"; then
        if grep -q '^mount -a$' "$boot_script"; then
            sed -i "/^mount -a\$/a mount -t devpts devpts /dev/pts -o gid=$tty_gid,mode=0620,ptmxmode=0666,nosuid,noexec 2>/dev/null || :" "$boot_script"
        else
            cat >> "$boot_script" <<DEVPTS_BOOT
mount -t devpts devpts /dev/pts -o gid=$tty_gid,mode=0620,ptmxmode=0666,nosuid,noexec 2>/dev/null || :
DEVPTS_BOOT
        fi
    fi
    if ! grep -Fq 'ln -snf pts/ptmx /dev/ptmx' "$boot_script"; then
        sed -i '/mount -t devpts devpts \/dev\/pts/a [ ! -e /dev/pts/ptmx ] || ln -snf pts/ptmx /dev/ptmx' "$boot_script"
    fi
    chmod 0755 "$boot_script"
}

repack_system() {
    local format=${2:-auto} command=--repack
    case "$format" in auto) ;; iso) command=--iso ;; img) command=--img ;; *) die "$(tr_text 'Format: iso, img, or auto' 'Formatas: iso, img arba auto')" ;; esac
    select_system "${1:-}" "$(tr_text 'Which system image should be created?' 'Kurios sistemos atvaizdą kurti?')" || return 0
    load_system "$SELECTED_SYSTEM"
    [[ "$BOOT_CHOICE" != lilo || "$format" != iso ]] || die "$(tr_text 'LILO creates a raw BIOS IMG only; choose img.' 'LILO kuria tik BIOS IMG atvaizdą; pasirink img.')"
    [[ "$format" != iso || "$BOOT_CHOICE" != none ]] || die "$(tr_text 'This profile has no bootloader; use --repack for rootfs / initramfs archives.' 'Šis profilis neturi paleidyklės; rootfs / initramfs archyvams naudok --repack.')"
    [[ "$format" != img || "$BOOT_CHOICE" != none ]] || die "$(tr_text 'IMG requires a bootloader; use --repack for this profile.' 'IMG reikia paleidyklės; šiam profiliui naudok --repack.')" 
    # fakeroot packages root-owned files. No actual sudo is needed here; any
    # read-only ELF files are simply left unstripped during an image refresh.
    SOURCES="$BASE/sources"
    upgrade_rootfs_devpts
    local tool
        for tool in fakeroot cpio gzip zstd mksquashfs readelf "$STRIP"; do command -v "$tool" >/dev/null || die "$(tr_text "Packaging requires $tool" "Pakavimui reikia $tool")"; done
    if [[ "$BOOT_CHOICE" == bios || "$BOOT_CHOICE" == uefi ]]; then
        [[ -x "$BASE/grub-tools/bin/grub-mkrescue" ]] || die "$(tr_text 'Missing GRUB tools for this profile' 'Trūksta šio profilio GRUB įrankių')"
    fi
    exec 8> "$BASE/.build-lock"
    flock -n 8 || build_lock_busy "$BASE/.build-lock"
    IMAGE_FORMAT=$format
    REPACKING=yes             # Nešalinti naudotojo vėliau įdiegtų kūrimo failų.
    progress_start 1 "$BASE/repack.log" "$(tr_text 'Packaging images after software installation' 'Atvaizdų pakavimas po programų diegimo')"
    run_quiet "$(tr_text 'Packaging images after software installation' 'Atvaizdų pakavimas po programų diegimo')" verify_and_pack
    progress_stop
    print_qemu_command
    case "$format" in
        iso) printf "$(tr_text '\nISO created: %s/%s.iso\n' '\nISO sukurtas: %s/%s.iso\n')" "$IMAGES" "$SYSTEM_NAME" ;;
        img) printf "$(tr_text '\nIMG created: %s/diy-linux.img\n' '\nIMG sukurtas: %s/diy-linux.img\n')" "$IMAGES" ;;
        auto) printf "$(tr_text '\nImages refreshed: %s\n' '\nAtnaujinti atvaizdai: %s\n')" "$IMAGES" ;;
    esac
}


# 4. Kryžminis kompiliatorius. Jis veikia šeimininke, bet kuria failus ROOT.
# Tai nėra galutinis GCC sistemoje; šis etapas reikalingas VISIEMS variantams.
# Toolchain configure parinktys:
#   --target nurodo CPU, kuriai kuriami kryžminiai įrankiai.
#   --with-sysroot nurodo tikslinės sistemos antraščių ir bibliotekų šaknį.
#   --with-headers nurodo Linux API antraštes glibc kūrimui.
#   --with-newlib --without-headers leidžia GCC bootstrap kompiliuoti dar be glibc.
#   --enable-languages=c,c++ kuria tik C ir C++ kompiliatorius.
#   --disable-bootstrap praleidžia papildomas GCC savęs kompiliavimo pakopas.
#   --disable-multilib praleidžia alternatyvias ABI/bibliotekų architektūras.
#   --disable-nls nekuria įrankių vertimų katalogų.
#   --disable-shared pirmame GCC etape palieka statinę bootstrap grandį.
#   --disable-threads ir --disable-lib* praleidžia papildomas runtime bibliotekas,
#   kurios bootstrap etape dar neturi veikiančios tikslinės C/C++ bibliotekos.
#   --enable-kernel=5.10 nustato seniausią Linux ABI, kurį glibc palaikys.
#   --disable-nscd nekuria pasirenkamo vardų/UID spartinančio demono.
#   --disable-werror neleidžia įspėjimams nutraukti toolchain kompiliavimo.
bootstrap_binutils() {
    local source
    local -a binutils_flags=(
        --prefix="$TOOLS"       # kur binutils įrankius (šeimininko toolchain katalogą)
        --target="$TARGET"      # nurodo kuriam tiksliniam Linux tripletui juos kurti
        --with-sysroot="$ROOT"  # pateikia tikslinės sistemos antraščių/bibliotekų šaknį
        --disable-nls            # nekuria binutils vertimų katalogų
        --disable-multilib       # nekuria papildomų ABI bibliotekų variantų
        --disable-werror         # neleidžia įspėjimams nutraukti kompiliavimo
    )
    source=$(unpack binutils)
    mkdir -p "$BUILD/binutils-cross"
    (cd "$BUILD/binutils-cross"
     CC="$HOST_CC" CXX="$HOST_CXX" "$source/configure" "${binutils_flags[@]}"
     make -j"$JOBS"; make install)

}

bootstrap_gcc_initial() {
    local gcc_source dependency source
    local -a gcc_initial_flags=(
        --prefix="$TOOLS"                      # diegia kryžminį GCC įrankius į toolchain katalogą
        --target="$TARGET"                     # kuria GCC tiksliniam architektūros tripletui
        --with-sysroot="$ROOT"                 # tikslinių antraščių ir bibliotekų vieta
        --with-glibc-version="${VERSION[glibc]}" # nurodo glibc versiją, su kuria bus susieta ABI
        --with-newlib                          # leidžia bootstrap etapui veikti be glibc
        --without-headers                      # pirmame etape dar nėra tikslinių libc antraščių
        --disable-nls                          # nekuria kompiliatoriaus vertimų
        --disable-shared                       # bootstrap įrankius susieja statiškai
        --disable-multilib                     # nekuria papildomų ABI bibliotekų
        --disable-threads                      # išjungia dar neįmanomas tikslines gijas
        --disable-libatomic                    # praleidžia atominės operacijos runtime
        --disable-libgomp                      # praleidžia OpenMP runtime
        --disable-libquadmath                  # praleidžia quad-precision matematikos runtime
        --disable-libssp                       # praleidžia stack-protector runtime
        --disable-libstdcxx                    # dar nekuria C++ standartinės bibliotekos
        --disable-bootstrap                    # nekartoja GCC savęs kompiliavimo etapų
        --enable-languages=c,c++               # bootstrap GCC kuria tik C ir C++ kompiliatorius
    )
    gcc_source=$(unpack gcc)
    for dependency in gmp mpfr mpc; do
        source=$(unpack "$dependency")
        [[ -d "$gcc_source/$dependency" ]] || cp -a "$source" "$gcc_source/$dependency"
    done
    if [[ "$TARGET_ARCH" == x86_64 ]]; then
        sed -i '/m64=/s/lib64/lib/' "$gcc_source/gcc/config/i386/t-linux64"
    elif [[ "$TARGET_ARCH" == aarch64 ]]; then
        sed -i 's@lib64@lib@g' "$gcc_source/gcc/config/aarch64/t-aarch64-linux"
    fi
    mkdir -p "$BUILD/gcc-initial"
    (cd "$BUILD/gcc-initial"
     CC="$HOST_CC" CXX="$HOST_CXX" "$gcc_source/configure" "${gcc_initial_flags[@]}"
     make -j"$JOBS" all-gcc all-target-libgcc
     make install-gcc install-target-libgcc)

}

bootstrap_glibc() {
    local source
    local -a glibc_flags=(
        --prefix=/usr                      # tikslinėje sistemoje diegia į /usr
        --host="$TARGET"                  # nurodo tikslinę sistemos architektūrą
        --build="$HOST"                   # nurodo kompiliavimo kompiuterio architektūrą
        --with-headers="$ROOT/usr/include" # naudoja jau įdiegtas Linux API antraštes
        --enable-kernel=5.10               # palaiko Linux branduolio ABI nuo 5.10
        --disable-nscd                     # nekuria vardų ir UID užklausų spartinančio demono
        # --enable-nscd # Įjungti NSS užklausų spartinimo demoną.
        # --enable-kernel=6.1 # Reikalauti naujesnio branduolio ABI ir atsisakyti senesnių branduolių.
        # --enable-obsolete-rpc # Pridėti pasenusią RPC sąsają, jei senoms programoms jos reikia.
    )
    source=$(unpack linux)
    make -C "$source" ARCH="$KERNEL_ARCH" headers_install INSTALL_HDR_PATH="$ROOT/usr"
    source=$(unpack glibc)
    if [[ ! -f "$source/.diy-fixes" ]]; then
        fetch glibc-fixes
        patch -d "$source" -p1 < "$CACHE/glibc-fixes-${VERSION[glibc-fixes]}.archive"
        touch "$source/.diy-fixes"
    fi
    mkdir -p "$BUILD/glibc"
    (cd "$BUILD/glibc"
     printf 'rootsbindir=/usr/sbin\n' > configparms
     CC="$TARGET-gcc" AR="$TARGET-ar" RANLIB="$TARGET-ranlib" \
     "$source/configure" "${glibc_flags[@]}" \
         libc_cv_slibdir=/usr/lib libc_cv_forced_unwind=yes
     make -j"$JOBS"; make DESTDIR="$ROOT" install)

}

bootstrap_gcc_final() {
    local gcc_source
    local -a gcc_final_flags=(
        --prefix="$TOOLS"                      # diegia galutinį kryžminį GCC į toolchain katalogą
        --target="$TARGET"                     # kuria GCC tiksliniam architektūros tripletui
        --with-sysroot="$ROOT"                 # susieja kompiliatorių su kuriamos sistemos bibliotekomis
        --disable-nls                          # nekuria vertimų katalogų
        --disable-multilib                     # kuria tik pasirinktą ABI
        --disable-bootstrap                    # praleidžia papildomą GCC savęs perkompiliavimą
        --disable-libsanitizer                 # nekuria nepasirinkto sanitizer runtime
        --disable-libquadmath                  # nekuria quad-precision matematikos runtime
        --disable-libgomp                      # nekuria OpenMP runtime
        --enable-languages=c,c++               # įtraukia C ir C++ kompiliatorius
    )
    gcc_source=$(unpack gcc)
    cat "$gcc_source/gcc/limitx.h" "$gcc_source/gcc/glimits.h" "$gcc_source/gcc/limity.h" \
        > "$("$TARGET-gcc" -print-file-name=include)/limits.h"
    mkdir -p "$BUILD/gcc-final"
    (cd "$BUILD/gcc-final"
     CC="$HOST_CC" CXX="$HOST_CXX" "$gcc_source/configure" "${gcc_final_flags[@]}"
     make -j"$JOBS"; make install)
    install -m0755 "$("$TARGET-gcc" -print-file-name=libgcc_s.so.1)" "$ROOT/usr/lib/libgcc_s.so.1"
    install -m0755 "$("$TARGET-g++" -print-file-name=libstdc++.so.6)" "$ROOT/usr/lib/libstdc++.so.6"
    printf 'int main(void){return 0;}\n' > "$BUILD/check.c"
    "$TARGET-gcc" "$BUILD/check.c" -o "$BUILD/check"
    readelf -l "$BUILD/check" | grep -Fq "$ELF_LOADER" || die "$(tr_text 'Invalid ELF loader' 'Netinkamas ELF loader')"
    [[ -e "$ROOT/usr/lib/${ELF_LOADER##*/}" ]] || die "$(tr_text 'Missing target glibc loader' 'Trūksta tikslinės glibc loader')"
}

require_emulation() {
    [[ -z "$EMULATOR" ]] || {
        local registration="/proc/sys/fs/binfmt_misc/$EMULATOR"
        [[ -r "$registration" ]] && grep -qx enabled "$registration" &&
            grep -Eq '^flags:.*F' "$registration" || die "$(tr_text "$TARGET_ARCH chroot and executable build checks require active $EMULATOR binfmt with the F flag. Debian/Ubuntu: sudo apt install qemu-user qemu-user-binfmt; sudo update-binfmts --enable $EMULATOR" "$TARGET_ARCH chroot ir vykdomoms build patikroms reikia aktyvaus $EMULATOR binfmt su F vėliava. Debian/Ubuntu: sudo apt install qemu-user qemu-user-binfmt; sudo update-binfmts --enable $EMULATOR")"
    }
}

cross_environment() {
    require_emulation
    export QEMU_LD_PREFIX="$ROOT"
    export CC="$TARGET-gcc" CXX="$TARGET-g++" AR="$TARGET-ar" RANLIB="$TARGET-ranlib"
    export STRIP="$TARGET-strip" CFLAGS='-O2 -pipe' CXXFLAGS='-O2 -pipe'
    export PKG_CONFIG_SYSROOT_DIR="$ROOT"
    export PKG_CONFIG_LIBDIR="$ROOT/usr/lib/pkgconfig:$ROOT/usr/share/pkgconfig"
    export PKG_CONFIG_PATH=
    CROSS_FILE="$BASE/cross.ini"
    cat > "$CROSS_FILE" <<CROSS
[binaries]
c = '$TARGET-gcc'
cpp = '$TARGET-g++'
ar = '$TARGET-ar'
strip = '$TARGET-strip'
pkg-config = '$(command -v pkg-config)'
[host_machine]
system = 'linux'
cpu_family = '$CPU_FAMILY'
cpu = '$TARGET_ARCH'
endian = 'little'
[properties]
sys_root = '$ROOT'
needs_exe_wrapper = true
pkg_config_libdir = ['$ROOT/usr/lib/pkgconfig', '$ROOT/usr/share/pkgconfig']
CROSS
}

# Installed libtool archives contain final /usr/lib paths in dependency_libs.
# In a DESTDIR cross build these escape the target rootfs and may add build-path
# RPATHs. Shared-library consumers use .so / pkg-config instead. Keep .la files
# inside build directories, where libtool still needs its own intermediate data.
remove_installed_libtool_archives() {
    [[ -n "$ROOT" && $(readlink -m -- "$ROOT") != / ]] || die "$(tr_text 'Refusing libtool cleanup outside a target rootfs' 'Atsisakoma valyti libtool failus už kuriamos rootfs ribų')"
    [[ -d "$ROOT/usr/lib" ]] || return 0
    find "$ROOT/usr/lib" -type f -name '*.la' -delete
}

# A resumed build can retain convenience-library metadata (e.g. libarchive_fe.la)
# referring to installed archives removed above. Drop only those stale targets:
# make relinks them from existing objects using the current shared libraries.
refresh_stale_libtool_metadata() {
    local directory=$1 file dependencies dependency
    local -a entries=()
    while IFS= read -r -d '' file; do
        dependencies=$(sed -n "s/^dependency_libs='\(.*\)'$/\1/p" "$file")
        read -r -a entries <<< "$dependencies"
        for dependency in "${entries[@]}"; do
            case "$dependency" in
                /usr/lib/*.la|/lib/*.la|/usr/lib64/*.la|/lib64/*.la|\
                "$ROOT"/usr/lib/*.la|"$ROOT"/lib/*.la|"$ROOT"/usr/lib64/*.la|"$ROOT"/lib64/*.la)
                    rm -f -- "$file"
                    break ;;
            esac
        done
    done < <(find "$directory" -type f -name '*.la' -print0)
}

# Užrašyti realiai paketui perduodamas kompiliavimo parinktis į kūrimo žurnalą.
# Tai apima aplinkos C/C++ vėliavėles, bendrus diegimo kelius ir konkretaus
# paketo configure/Meson parinktis. Taip galima atsekti, kodėl funkcija įjungta.
log_package_build_flags() {
    local name=$1 build_system=$2; shift 2
    printf '\n--- Build flags: %s (%s) ---\n' "$name" "$build_system"
    printf 'CC=%q\nCXX=%q\n' "${CC:-}" "${CXX:-}"
    printf 'CFLAGS=%q\nCXXFLAGS=%q\nCPPFLAGS=%q\nLDFLAGS=%q\n' \
        "${CFLAGS:-}" "${CXXFLAGS:-}" "${CPPFLAGS:-}" "${LDFLAGS:-}"
    printf 'Package-specific options:'
    if (($#)); then printf ' %q' "$@"; else printf ' (none)'; fi
    printf '\n--- End build flags: %s ---\n' "$name"
}

# Bendros kompiliatoriaus vėliavėlės:
#   -O2 optimizuoja vykdymo greitį, neįjungiant agresyvių -O3 transformacijų.
#   -pipe naudoja vamzdžius tarp kompiliavimo žingsnių, bet nekeičia ABI.
#   -isystem <sysroot>/usr/include nurodo tikslinės sistemos antraštes.
#   CPPFLAGS/LDFLAGS papildomai nurodo tikslines antraštes/bibliotekas ir
#   rpath-link; pastarasis padeda linker'iui rasti priklausomybes kūrimo metu.
#   -march=native sąmoningai nenaudojama: rezultatai turi veikti kituose CPU.
#
# GNU configure standartinės vėliavėlės:
#   --build = kompiliavimą vykdanti šeimininko architektūra.
#   --host = architektūra, kurioje veiks sukompiliuota programa.
#   --prefix=/usr, --libdir=/usr/lib, --sysconfdir=/etc,
#   --localstatedir=/var = tikslinės sistemos diegimo vietos.
# Paketų papildomos vėliavėlės pateikiamos recepto iškvietime ir užregistruojamos.
# Nestandartiniai paketai žemiau turi atskirus receptus bei jų paaiškinimus.
autotools() {
    local name=$1 source jobs=$JOBS; shift
    source=$(unpack "$name")
    # lxsession 0.5.7 has generated Vala C files that are moved from the
    # shared build directory by independent recursive Make targets. Parallel
    # make races those `main.c` moves and fails with "cannot stat main.c".
    # Serialize this one upstream package; other recipes keep the configured
    # JOBS value.
    [[ "$name" != lxsession ]] || jobs=1
    # Before configure also covers archives left by a failed previous attempt.
    remove_installed_libtool_archives
    mkdir -p "$BUILD/$name"
    log_package_build_flags "$name" autotools \
        --build="$HOST" --host="$TARGET" --prefix=/usr --libdir=/usr/lib \
        --sysconfdir=/etc --localstatedir=/var "$@"
    (cd "$BUILD/$name"
     xorg_cv_malloc0_returns_null=no "$source/configure" --build="$HOST" --host="$TARGET" --prefix=/usr \
         --libdir=/usr/lib --sysconfdir=/etc --localstatedir=/var "$@"
     refresh_stale_libtool_metadata "$BUILD/$name"
     make -j"$jobs"; make DESTDIR="$ROOT" install)
    remove_installed_libtool_archives
}

meson_package() {
    local name=$1 source; shift
    source=$(unpack "$name")
    # Meson bendros parinktys:
    #   --cross-file = tikslinio kompiliatoriaus/sysroot aprašas.
    #   --prefix ir katalogai = diegimo vietos tikslinėje sistemoje.
    #   --buildtype=release = optimizuotas leidimo kūrinys.
    #   --wrap-mode=nodownload = neparsisiųsti nepatikrintų subprojektų.
    #   -Dauto_features=disabled = nepridėti pasirenkamų funkcijų automatiškai;
    #   būtinos funkcijos aiškiai įjungiamos tik konkretaus paketo recepte.
    # Nenaudojamos / nepriklausomos pasirenkamos funkcijos paliekamos išjungtos.
    log_package_build_flags "$name" meson \
        --cross-file="$CROSS_FILE" --prefix=/usr --libdir=lib --sbindir=sbin \
        --sysconfdir=/etc --localstatedir=/var --buildtype=release \
        --wrap-mode=nodownload -Dauto_features=disabled "$@"
    if [[ ! -f "$BUILD/$name/build.ninja" ]]; then
        meson setup "$BUILD/$name" "$source" --cross-file="$CROSS_FILE" \
            --prefix=/usr --libdir=lib --sbindir=sbin --sysconfdir=/etc --localstatedir=/var \
            --buildtype=release --wrap-mode=nodownload -Dauto_features=disabled "$@"
    fi
    ninja -C "$BUILD/$name" -j"$JOBS"
    DESTDIR="$ROOT" meson install -C "$BUILD/$name" --no-rebuild
}

# BEGIN DESKTOP RECIPES
desktop_base_packages() {
    printf '%s\n' 'zlib libffi pcre2 expat glib libpng freetype fontconfig util-macros xorgproto libXau libXdmcp xcb-proto libxcb xtrans libX11 libXext libXrender libXft libXfixes libXi libXrandr libXcursor libXinerama libXcomposite libXdamage libXtst libXres libXpresent libXxf86vm libICE libSM libfontenc libXfont2 libxkbfile font-util font-misc-misc libxcvt libpciaccess libdrm libxshmfence elfutils libmd pixman dbus eudev libevdev mtdev xkbcomp xkeyboard-config'
    printf '%s\n' 'libglvnd mesa libepoxy xorg-server xf86-input-evdev libXt libXmu libXpm libXaw xauth xinit xterm cairo harfbuzz fribidi pango libxml2 shared-mime-info gdk-pixbuf at-spi2-core gtk desktop-file-utils hicolor-icon-theme adwaita-icon-theme dejavu-fonts libwnck libtool alsa-lib alsa-utils libcap libsndfile pulseaudio sound-mixer'
    if [[ ${PKG_FIREFOX:-no} == yes ]]; then printf '%s\n' bubblewrap; fi
    # MATE session components and Firefox query UPower over the system bus.
    # Install its daemon even when the optional MATE power-settings UI is off.
    if [[ "$DESKTOP_CHOICE" == mate || ${PKG_FIREFOX:-no} == yes ]]; then
        printf '%s\n' 'libusb libgudev'
    fi
    if [[ "$NETWORK" == yes ]]; then
        printf '%s\n' 'wireless-regdb libnl iw wpa_supplicant libndp NetworkManager libsecret libnma network-manager-applet'
    fi
    [[ ${PKG_MATE_POWER_MANAGER:-no} != yes ]] || printf '%s\n' libsecret
}

install_wireless_regdb() {
    local source
    source=$(unpack wireless-regdb)
    install -Dm0644 "$source/regulatory.db" "$ROOT/lib/firmware/regulatory.db"
    install -m0644 "$source/regulatory.db.p7s" "$ROOT/lib/firmware/regulatory.db.p7s"
    install -Dm0644 "$source/wens.x509.pem" "$ROOT/usr/share/wireless-regdb/wens.x509.pem"
}

mate_packages() {
    # librsvg installs GTK's SVG pixbuf loader, needed by Adwaita icons used
    # by Caja and the MATE panel. Without it these applications log missing
    # check-symbolic.svg resources and display blank icons.
    printf '%s\n' 'librsvg dconf dbus-glib sqlite libpsl libsoup libtool libogg libvorbis libcanberra libnotify mate-common mate-icon-theme iso-codes mate-desktop mate-menus marco duktape'
    # Build elogind before mate-session-manager. Without its pkg-config module,
    # MATE silently enables its ConsoleKit fallback and repeatedly queries a
    # service that these images do not provide.
    if [[ "$INIT_CHOICE" != systemd ]]; then
        # GNU login builds PAM in the earlier login-tools stage; lightweight
        # tool profiles need it added here for elogind's PAM integration.
        [[ "$TOOLS_CHOICE" == gnu ]] || printf '%s\n' linux-pam
        printf '%s\n' elogind
    fi
    printf '%s\n' polkit
    # UPower links to polkit-gobject-1; keep it after polkit in the build order.
    printf '%s\n' upower
    printf '%s\n' 'mate-session-manager libxklavier libmatekbd mate-settings-daemon libmateweather mate-panel mate-notification-daemon'
    if [[ ${PKG_CAJA:-no} == yes ]]; then
        printf '%s\n' caja
    else
        # Caja is optional. When it is disabled, PCManFM draws the desktop
        # background so MATE does not start with a black root window.
        printf '%s\n' 'libfm-extra menu-cache libfm pcmanfm'
    fi
    if [[ ${PKG_PLUMA:-no} == yes ]]; then printf '%s\n' gtksourceview4 gobject-introspection libpeas pluma; fi
    if [[ ${PKG_ENGRAMPA:-no} == yes ]]; then printf '%s\n' engrampa; fi
    if [[ ${PKG_EOM:-no} == yes ]]; then printf '%s\n' gobject-introspection libpeas libexif eom; fi
    if [[ ${PKG_MATE_CONTROL_CENTER:-no} == yes || ${PKG_MATE_POWER_MANAGER:-no} == yes ]]; then
        printf '%s\n' linux-pam
    fi
    if [[ ${PKG_MATE_CONTROL_CENTER:-no} == yes ]]; then
        printf '%s\n' mate-polkit libXScrnSaver libgtop libatasmart e2fsprogs libblockdev udisks mate-control-center
    fi
    if [[ ${PKG_MATE_POWER_MANAGER:-no} == yes ]]; then
        [[ ${PKG_MATE_CONTROL_CENTER:-no} == yes ]] || printf '%s\n' mate-polkit
        printf '%s\n' mate-power-manager
    fi
}
fluxbox_packages() {
    # LXPanel supplies an app menu, task list, clock and system tray;
    # PCManFM draws the wallpaper for this standalone Fluxbox session.
    printf '%s\n' 'libfm-extra menu-cache libfm pcmanfm keybinder lxmenu-data lxde-icon-theme lxpanel fluxbox'
    if [[ ${PKG_FIREFOX:-no} == yes ]]; then
        printf '%s\n' duktape
        if [[ "$INIT_CHOICE" != systemd ]]; then
            [[ "$TOOLS_CHOICE" == gnu ]] || printf '%s\n' linux-pam
            printf '%s\n' elogind
        fi
        printf '%s\n' polkit upower
    fi
}

lxde_packages() {
    # LXPanel and PCManFM are the GTK3 desktop shell; Fluxbox supplies LXDE's
    # window manager. libfm-extra is bootstrapped first to break the upstream
    # libfm <-> menu-cache build dependency cycle.
    # LXDE does not start PolicyKit, UPower, or mate-polkit in this profile.
    # Omitting these packages avoids D-Bus rules for a missing polkitd user.
    printf '%s\n' 'dbus-glib duktape libfm-extra menu-cache libfm keybinder lxmenu-data lxde-icon-theme lxpanel lxsession pcmanfm lxappearance lxrandr lxde-common fluxbox'
}

desktop_prepare_gi_cross_tools() {
    local wrapper="$BUILD/desktop-host/target-exec"
    local ldd_wrapper="${wrapper%/*}/target-ldd"
    mkdir -p "${wrapper%/*}"
    cat > "$wrapper" <<EOF
#!/bin/sh
loader='$ROOT/usr/lib/${ELF_LOADER##*/}'
library_path='$ROOT/usr/lib:$ROOT/lib'
unset LD_LIBRARY_PATH PYTHONPATH
exec "\$loader" --library-path "\$library_path" "\$@"
EOF
    chmod 0755 "$wrapper"
    cat > "$ldd_wrapper" <<EOF
#!/bin/sh
loader='$ROOT/usr/lib/${ELF_LOADER##*/}'
library_path='$ROOT/usr/lib:$ROOT/lib'
exec "\$loader" --library-path "\$library_path" --list "\$1"
EOF
    chmod 0755 "$ldd_wrapper"
    # Meson obtains tool paths from the target pkg-config file
    # (which are rooted below $ROOT), bypassing PATH. These temporary shims
    # dispatch those build-only tools to their native host implementations.
    # They are removed once all target GIR/typelib files have been generated.
    for tool in g-ir-scanner g-ir-compiler g-ir-generate; do
        command -v "$tool" >/dev/null || die "MATE introspection requires host tool: $tool"
        if [[ "$tool" == g-ir-scanner ]]; then
            # g-ir-scanner normally exports target/build library paths as
            # LD_LIBRARY_PATH while compiling its temporary dumper. That
            # makes host tools such as /usr/bin/env load the target glibc.
            # Keep those paths in a private variable; target dumper execution
            # is handled separately by GI_CROSS_LAUNCHER.
            printf '#!/bin/sh\nunset LD_LIBRARY_PATH PYTHONPATH\nexec /usr/bin/g-ir-scanner --lib-dirs-envvar=GI_CROSS_LIBRARY_PATH --use-ldd-wrapper=%s "$@"\n' \
                "$ldd_wrapper" > "$ROOT/usr/bin/$tool"
        else
            printf '#!/bin/sh\nunset LD_LIBRARY_PATH PYTHONPATH\nexec /usr/bin/%s "$@"\n' \
                "$tool" > "$ROOT/usr/bin/$tool"
        fi
        chmod 0755 "$ROOT/usr/bin/$tool"
    done
    python3 - "$CROSS_FILE" "$wrapper" <<'PY'
from pathlib import Path
import re
import sys

cross_file, wrapper = map(Path, sys.argv[1:])
text = cross_file.read_text()
text = re.sub(r"(?m)^\s*exe_wrapper\s*=.*\n?", "", text)
marker = "[binaries]"
if marker not in text:
    raise SystemExit("MATE cross file has no [binaries] section")
text = text.replace(marker, f"{marker}\nexe_wrapper = ['{wrapper}']", 1)
cross_file.write_text(text)
PY
    export GI_CROSS_LAUNCHER="$wrapper"
}

desktop_needs_logind() {
    [[ ${DESKTOP_CHOICE:-none} == mate ||
       ${PKG_MATE_CONTROL_CENTER:-no} == yes ||
       ${PKG_MATE_POWER_MANAGER:-no} == yes ]]
}

build_librsvg() {
    local rust_key=${RUST_TARGET//-/_}
    local -x CARGO_HOME="$WORK_DIR/cargo-cache" CARGO_BUILD_JOBS="$JOBS"
    # librsvg's in-tree uninstalled pkg-config file points at the build root,
    # while Meson emits the shared library in its rsvg/ subdirectory. Cargo's
    # pixbufloader-svg crate links this library before installation, so provide
    # its actual build-time directory explicitly.
    local -x RUSTFLAGS="-C link-arg=--sysroot=$ROOT -C link-arg=-L$BUILD/librsvg/rsvg"
    export "CARGO_TARGET_${rust_key^^}_LINKER=$CC" "CC_${rust_key}=$CC" \
        "AR_${rust_key}=$AR" "CXX_${rust_key}=$CXX"
    desktop_meson librsvg -Dintrospection=disabled -Dpixbuf=enabled \
        -Dpixbuf-loader=enabled -Ddocs=disabled -Dvala=disabled -Dtests=false
    unset "CARGO_TARGET_${rust_key^^}_LINKER" "CC_${rust_key}" "AR_${rust_key}" "CXX_${rust_key}"
}

# Grafikos receptai: eksperimentinis x86_64 Xorg + Mesa variantas.
# Jokių šeimininko bibliotekų nekopijuojama į rootfs.
desktop_meson() {
    local name=$1 source ninja_status ninja_log; shift
    # GCC adds sysroot/usr/local/include to its default include search path.
    # Several Meson projects treat the absent directory as a fatal warning.
    mkdir -p "$ROOT/usr/local/include"
    source=$(unpack "$name")
    # Darbalaukio Meson paketams papildomai išjungiami upstream Werror
    # įspėjimų pavertimai į klaidas. Tik konkrečiai reikalingi komponentai
    # įjungiami per "$@"; kitos automatinės pasirenkamos funkcijos išjungtos.
    log_package_build_flags "$name" meson-desktop \
        --cross-file="$CROSS_FILE" --prefix=/usr --libdir=lib --sbindir=sbin \
        --sysconfdir=/etc --localstatedir=/var --buildtype=release \
        --wrap-mode=nodownload -Dauto_features=disabled -Dwerror=false "$@"
    if [[ ! -f "$BUILD/$name/build.ninja" ]]; then
        meson setup "$BUILD/$name" "$source" --cross-file="$CROSS_FILE" \
            --prefix=/usr --libdir=lib --sbindir=sbin --sysconfdir=/etc --localstatedir=/var \
            --buildtype=release --wrap-mode=nodownload -Dauto_features=disabled -Dwerror=false "$@"
    else
        meson configure "$BUILD/$name" "$@"
    fi
    if [[ "$name" == librsvg ]]; then
        # A stale/incomplete Cargo target tree can make Cargo report a missing
        # .d dep-info file even though the crate sources are present. Retry
        # this specific transient failure once from a clean, profile-local
        # Rust target directory; preserve all other build outputs and errors.
        ninja_log="$BUILD/librsvg/ninja-build.log"
        if ninja -C "$BUILD/$name" -j"$JOBS" >"$ninja_log" 2>&1; then
            cat "$ninja_log"
        else
            ninja_status=$?
            cat "$ninja_log"
            if grep -Fq 'could not parse/generate dep info at:' "$ninja_log" &&
               grep -Fq 'No such file or directory (os error 2)' "$ninja_log"; then
                printf '%s\n' 'Retrying librsvg Cargo build after removing its incomplete target cache.'
                rm -rf -- "$BUILD/librsvg/target"
                ninja -C "$BUILD/$name" -j"$JOBS"
            else
                return "$ninja_status"
            fi
        fi
    else
        ninja -C "$BUILD/$name" -j"$JOBS"
    fi
    DESTDIR="$ROOT" meson install -C "$BUILD/$name" --no-rebuild
}

# Pagalbinės tikslinės x86_64 programos vykdomos per jų glibc įkėliklį;
# taip generuojami ištekliai nesumaišant šeimininko ir rootfs bibliotekų.
desktop_host_tools() {
    local tool
    mkdir -p "$BUILD/desktop-host/bin"
    for tool in xmllint glib-compile-resources glib-compile-schemas gio-querymodules gdk-pixbuf-csource gdk-pixbuf-query-loaders gtk-update-icon-cache update-mime-database dbus-binding-tool g-ir-compiler g-ir-generate; do
        [[ -x "$ROOT/usr/bin/$tool" ]] || continue
        printf '#!/bin/sh\nexec "%s" --library-path "%s/usr/lib" "%s/usr/bin/%s" "$@"\n' \
            "$ROOT/usr/lib/${ELF_LOADER##*/}" "$ROOT" "$ROOT" "$tool" > "$BUILD/desktop-host/bin/$tool"
        chmod +x "$BUILD/desktop-host/bin/$tool"
    done
    for tool in glib-genmarshal glib-mkenums gdbus-codegen g-ir-scanner; do
        [[ -x "$ROOT/usr/bin/$tool" ]] || continue
        printf '#!/bin/sh\nunset UNINSTALLED_GLIB_SRCDIR\nexec python3 "%s/usr/bin/%s" "$@"\n' \
            "$ROOT" "$tool" > "$BUILD/desktop-host/bin/$tool"
        chmod +x "$BUILD/desktop-host/bin/$tool"
    done
    export PATH="$BUILD/desktop-host/bin:$PATH"
}

# Dažnos paketų parinktys žemiau:
#   --enable-shared: kurti bendrąją .so biblioteką.
#   --disable-static: nekurti statinės .a bibliotekos. Tai NEĮJUNGIA statinio
#     susiejimo; jis tik išjungia statinės bibliotekos kūrimą.
#   --disable-nls: neįtraukti programos vertimų katalogų.
#   --disable-doc(s), --disable-gtk-doc, -Ddocs=disabled, -Dman=false:
#     praleisti programos dokumentaciją, API HTML ar man puslapius.
#   --disable-tests, -Dtests=false, -Dbuild-tests=false: nestatyti testų.
#   -Dinstalled_tests=false: neįdiegti testų duomenų į galutinę sistemą.
#   --disable-introspection, -Dintrospection=false, -Dgir=false:
#     neprigeneruoti GObject GIR/typelib metaduomenų.
#   -Dvapi=false ir -Dvala=disabled: neprigeneruoti Vala sąsajų.
#   --without-X/-DX=disabled|false išjungia konkrečią pasirenkamą funkciją
#     arba priklausomybę; --with-X/--enable-X ją įjungia ar parenka backendą.
#   -Dauto_features=disabled Meson projekte išjungia features, paliktus kaip auto;
#     recepte aiškiai įjungti privalomi komponentai lieka įjungti.
#   -Dwerror=false palieka įspėjimus matomus, bet neleidžia jų laikyti klaidomis.
# Neaktyvios parinktys: žemiau pateikiami tik pavyzdžiai. Jos lieka komentaruose,
# į masyvus ir kompiliavimo komandas nepatenka. Prieš įjungiant tikrinti būtent
# naudojamos upstream versijos ./configure --help arba meson configure sąrašą;
# projektai gali pašalinti ar pervadinti parinktį tarp versijų.
#   -Dsystemd=false/disabled praleidžia systemd integraciją kituose init profiliuose.
# Pastaba: kai kurie upstream projektai pagal nutylėjimą automatiškai aptinka
# funkcijas. Jei jų reikia atsisakyti, aiškų disable jungiklį palik aktyvų.
desktop_package() {
    local name=$1 source
    case "$name" in
        zlib)
            source=$(unpack zlib)
            (cd "$source"; CHOST="$TARGET" ./configure --prefix=/usr --libdir=/usr/lib
             make -j"$JOBS"; make DESTDIR="$ROOT" install) ;;
        libffi)
            local -a libffi_flags=(
                --disable-static             # Omit static .a archives; retain shared libraries.
                --disable-multi-os-directory # Do not add GCC's multilib directory suffix.
            )
            autotools libffi "${libffi_flags[@]}" ;;
        pcre2)
            local -a pcre2_flags=(
                --enable-unicode # Enable UTF and Unicode-property pattern matching.
                --enable-jit     # Enable runtime-generated code to speed up matching.
                --disable-static # Omit static .a archives; retain shared libraries.
            )
            autotools pcre2 "${pcre2_flags[@]}" ;;
        expat)
            local -a expat_flags=(
                --without-xmlwf    # Do not build the standalone XML validation tool.
                --without-examples # Omit example programs.
                --without-tests    # Omit Expat's test suite.
                --without-docbook  # Omit DocBook documentation generation.
                --disable-static   # Omit static .a archives; retain shared library.
            )
            autotools expat "${expat_flags[@]}" ;;
        glib)
            local -a glib_flags=(
                -Dtests=false             # Do not build GLib's test programs.
                -Dinstalled_tests=false   # Do not install tests for downstream runs.
                -Dintrospection=disabled  # Do not generate/install GObject introspection data.
                -Dlibmount=disabled       # Omit optional libmount integration.
                -Dselinux=disabled        # Omit SELinux support.
                -Dman-pages=disabled      # Do not generate or install manual pages.
                -Dsysprof=disabled        # Omit Sysprof profiling integration.
            )
            desktop_meson glib "${glib_flags[@]}" ;;
        libpng)
            local -a libpng_flags=(
                --disable-static # Omit static .a archives; retain shared libpng.
            )
            autotools libpng "${libpng_flags[@]}" ;;
        # FreeType keeps PNG support; it does not build HarfBuzz, BZip2 or
        # Brotli integrations and does not emit static archives.
        freetype) autotools freetype --with-harfbuzz=no --with-bzip2=no --with-brotli=no --with-png=yes --disable-static ;;
        libmd) autotools libmd --disable-static ;;
        fontconfig) autotools fontconfig --disable-docs --disable-static --with-cache-dir=/var/cache/fontconfig ;;
        # D-Bus uses no systemd/user-session integration; disable optional
        # modular tests, XML/Doxygen/Ducktype docs, and X11 daemon autolaunch.
        dbus) desktop_meson dbus -Dsystemd=disabled -Duser_session=false -Dmodular_tests=disabled -Dxml_docs=disabled -Ddoxygen_docs=disabled -Dducktype_docs=disabled -Dx11_autolaunch=disabled ;;
        util-macros|xorgproto|libXau|libXdmcp|libX11|libXext|libXrender|libXfixes|libXi|libXrandr|libXcursor|libXinerama|libXcomposite|libXdamage|libXtst|libXres|libXpresent|libXxf86vm|libICE|libSM|xtrans|libfontenc|libXfont2|libxkbfile|font-util|bdftopcf|xkbcomp|xf86-input-evdev|xinit|xauth|libXt|libXmu|libXpm|libXaw)
            autotools "$name" --disable-static --disable-specs --disable-docs --disable-devel-docs --without-xmlto --without-fop ;;
        font-misc-misc)
            autotools font-misc-misc --with-fontrootdir=/usr/share/fonts/X11
            mkfontdir "$ROOT/usr/share/fonts/X11/misc" ;;
        libXft) autotools libXft --disable-static ;;
        fluxbox)
            # Fluxbox 1.3.7 predates modern GCC's C++17 default; keep this
            # legacy upstream release in C++14 mode and use only the Xft/X11
            # dependencies already built by the desktop base recipe.
            source=$(unpack fluxbox)
            sed -i 's/text_prop\.value > 0/text_prop.value != nullptr/' "$source/util/fluxbox-remote.cc"
            ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes \
                CXXFLAGS="${CXXFLAGS:-} -std=gnu++14" \
                autotools fluxbox --disable-nls --enable-xft ;;
        # The common LXDE policy omits static archives and GTK API docs.
        menu-cache) autotools menu-cache --disable-static --disable-gtk-doc ;;
        libfm-extra)
            source=$(unpack libfm)
            mkdir -p "$BUILD/libfm-extra"
            (cd "$BUILD/libfm-extra"
             xorg_cv_malloc0_returns_null=no "$source/configure" --build="$HOST" --host="$TARGET" \
                 --prefix=/usr --libdir=/usr/lib --sysconfdir=/etc --localstatedir=/var \
                 --with-extra-only=yes --disable-static --disable-gtk-doc
             refresh_stale_libtool_metadata "$BUILD/libfm-extra"
             make -j"$JOBS"; make DESTDIR="$ROOT" install) ;;
        libfm)
            CPPFLAGS="${CPPFLAGS:-} -I$BUILD/libfm/src -I$BUILD/libfm/src/base -I$BUILD/libfm/src/gtk" \
                autotools libfm --with-extra-only=no --with-gtk=3 --disable-static --disable-gtk-doc ;;
        # LXDE GTK support libraries use the common shared-only, no-GTK-doc policy.
        keybinder) autotools keybinder --disable-static --disable-gtk-doc ;;
        lxmenu-data|lxde-common)
            autotools "$name" --disable-static --disable-gtk-doc ;;
        lxde-icon-theme)
            source=$(unpack lxde-icon-theme)
            # The upstream install-data-hook copies this source asset using a
            # build-directory-relative path; make it work with our out-of-tree build.
            sed -i 's|cp -raf --no-preserve=ownership nuoveXT2 |cp -raf --no-preserve=ownership $(srcdir)/nuoveXT2 |' "$source/Makefile.in"
            autotools lxde-icon-theme --disable-static --disable-gtk-doc ;;
        lxpanel)
            # Out-of-tree builds need the generated UI destination prepared.
            mkdir -p "$BUILD/lxpanel/data/ui"
            CPPFLAGS="${CPPFLAGS:-} -I$BUILD/lxpanel/src" \
                autotools lxpanel --enable-gtk3 --with-plugins=all,-netstat,-weather --disable-static --disable-gtk-doc ;;
        lxsession)
            source=$(unpack lxsession)
            # These optional Vala utilities in 0.5.7 reference an unavailable
            # lxsession helper library when cross-linked. Keep the session and
            # logout programs; mate-polkit supplies the authentication agent.
            sed -i \
                -e '/^[[:space:]]*lxpolkit\/lxpolkit \\/d' \
                -e '/^[[:space:]]*lxsession-db\/lxsession-db \\/d' \
                -e '/^[[:space:]]*lxsession-edit\/lxsession-edit \\/d' \
                -e '/^[[:space:]]*lxsession-default-apps\/lxsession-default-apps \\/d' \
                -e '/^[[:space:]]*lxclipboard\/lxclipboard \\/d' \
                "$source/Makefile.am" "$source/Makefile.in"
            python3 - "$source/Makefile.in" <<'PY_LXSESSION_MAKEFILE'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
start = s.index('@USE_GTK_TRUE@am__EXEEXT_2 =')
end = s.index('\n', s.index('$(am__EXEEXT_1)', start))
s = s[:start] + '@USE_GTK_TRUE@am__EXEEXT_2 = lxsession-logout/lxsession-logout$(EXEEXT) $(am__EXEEXT_1)' + s[end:]
p.write_text(s)
PY_LXSESSION_MAKEFILE
            rm -rf "$BUILD/lxsession"
            autotools lxsession --enable-gtk3 --disable-static --disable-gtk-doc ;;
        pcmanfm) autotools pcmanfm --with-gtk=3 --disable-static --disable-gtk-doc ;;
        lxappearance) autotools lxappearance --enable-gtk3 --disable-static --disable-gtk-doc ;;
        lxrandr) autotools lxrandr --enable-gtk3 --disable-static --disable-gtk-doc ;;
        xcb-proto) autotools xcb-proto ;;
        # XCB runtime library only; omit .a archives and developer documentation.
        libxcb) autotools libxcb --disable-static --disable-devel-docs ;;
        pixman) desktop_meson pixman -Dtests=disabled -Dgtk=disabled ;;
        # PCI device access does not need optional zlib compression.
        libpciaccess) desktop_meson libpciaccess -Dzlib=disabled ;;
        libxcvt) desktop_meson libxcvt ;;
        libdrm) desktop_meson libdrm -Dintel=enabled -Dradeon=enabled -Damdgpu=enabled \
            -Dnouveau=enabled -Dvmwgfx=enabled -Dfreedreno=disabled -Dvc4=disabled \
            -Detnaviv=disabled -Dtests=false -Dman-pages=disabled ;;
        libxshmfence) autotools libxshmfence --disable-static ;;
        elfutils)
            # GCC 15+ reports several upstream const-correctness warnings in
            # elfutils 0.193. Keep -Werror for the package, except this warning
            # class; the inputs are read-only and the diagnostics are benign.
            CFLAGS="${CFLAGS:-} -Wno-error=discarded-qualifiers" \
                autotools elfutils --disable-debuginfod --disable-nls --disable-libdw --disable-libasm ;;
        # Mesa 26.2 makes Intel iris/crocus require its LLVM based CLC
        # compiler. This minimal cross toolchain has no native mesa_clc tools,
        # and building LLVM here would add a much larger dependency chain.
        # Keep acceleration for AMD, Nouveau and virtual GPUs plus softpipe.
        mesa)
            local -a mesa_flags=(
                -Dplatforms=x11 # Kurti tik X11 langų sistemos backendą.
                -Degl-native-platform=x11 # EGL numatytoji platforma yra X11.
                -Dgallium-drivers=radeonsi,nouveau,svga,virgl,softpipe # AMD/Nouveau/VMware/virtio ir CPU fallback tvarkyklės.
                -Dvulkan-drivers=[] # Nenaudojami Vulkan tvarkyklių komponentai.
                -Dglx=dri # GLX susiejamas su Mesa DRI tvarkyklėmis.
                -Degl=enabled # Įtraukti EGL API (Xorg GL klientams).
                -Dgbm=enabled # Įtraukti GBM buferių valdymą.
                -Dglvnd=enabled # Naudoti bendrą GLVND dispatch biblioteką.
                -Dllvm=disabled # Išjungti LLVM; šiame recepte nėra LLVM CLC grandinės.
                -Dgallium-va=disabled # Išjungti VA-API Gallium video kodavimą/dekodavimą.
                -Dbuild-tests=false # Nekurti Mesa testų.
                -Dhtml-docs=disabled # Neįtraukti HTML dokumentacijos.
                # -Dvulkan-drivers=amd,intel # Pridėti Vulkan tvarkykles; reikia papildomų priklausomybių.
                # -Dllvm=enabled # Įjungti LLVM paremtus tvarkyklių komponentus.
                # -Dgallium-va=enabled # Įtraukti VA-API vaizdo spartinimą.
                # -Dbuild-tests=true # Kurti Mesa testų programas.
                # -Dhtml-docs=enabled # Kurti Mesa HTML dokumentaciją.
            )
            desktop_meson mesa "${mesa_flags[@]}" ;;
        # udev's 80-drivers.rules invokes the kmod builtin for device modaliases.
        # Disabling kmod leaves modular Ethernet/Wi-Fi drivers unloaded at boot.
        eudev)
            # A completed image may have had development headers stripped.
            # Rebuild eudev against the retained SDK headers in that case.
            local host_pkg_config kmod_source
            host_pkg_config=$(command -v pkg-config) || die "$(tr_text 'eudev requires host pkg-config' 'eudev reikia šeimininko pkg-config')"
            kmod_source=$(unpack kmod)
            (export CPPFLAGS="${CPPFLAGS:-} -I$SDK/sysroot/usr/include -I$kmod_source/libkmod"
             export PKG_CONFIG="$host_pkg_config"
             autotools eudev --disable-static --disable-introspection --disable-manpages \
                 --disable-selinux --enable-kmod --disable-blkid --enable-hwdb=no \
                 --with-rootprefix=/usr --with-rootrundir=/run) ;;
        # Input libraries are runtime-only; libevdev also omits tests/manuals.
        mtdev) autotools mtdev --disable-static ;;
        libevdev) desktop_meson libevdev -Dtests=disabled -Ddocumentation=disabled ;;
        xkeyboard-config) desktop_meson xkeyboard-config ;;
        xorg-server)
            local -a xorg_flags=(
                -Dxorg=true # Kurti pagrindinį Xorg serverį.
                -Dxvfb=true # Įtraukti virtualų X serverį be fizinio ekrano.
                -Dxnest=false # Neįtraukti įdėtinio X serverio Xnest.
                -Dxephyr=false # Neįtraukti kūrėjams skirto Xephyr serverio.
                -Dpciaccess=true # Aptikti PCI grafikos įrenginius per libpciaccess.
                -Dsha1=libmd # SHA-1 funkcijai naudoti jau įtrauktą libmd.
                -Dglamor=true # Įjungti 2D glamor spartinimą per GL.
                -Dglx=true # Įjungti GLX OpenGL sąsają X11 klientams.
                -Ddri1=false # Išjungti pasenusį DRI1 protokolą.
                -Ddri2=true # Palikti DRI2 suderinamumui.
                -Ddri3=true # Įjungti DRI3 tiesioginį atvaizdavimą.
                -Dudev=true # Įrenginius aptikti per udev.
                -Dudev_kms=true # KMS ekrano valdymą susieti su udev įrenginiais.
                -Dsystemd_logind=false # Xorg sesijų nevaldyti per systemd-logind.
                -Dsuid_wrapper=true # Paleisti Xorg be root setuid serverio wrapperio.
                -Dsecure-rpc=false # Išjungti X11 Secure RPC palaikymą.
                -Dxkb_dir=/usr/share/X11/xkb # Klaviatūrų taisyklių duomenų vieta.
                -Dxkb_output_dir=/var/lib/xkb # Sugeneruotų XKB duomenų vieta.
                -Dxkb_bin_dir=/usr/bin # XKB kompiliatoriaus programų vieta.
                # -Dxwayland=true # Kurti Xwayland serverį; reikia Wayland bibliotekų.
                # -Dxephyr=true # Įtraukti įdėtinį X serverį testavimui.
                # -Dxnest=true # Įtraukti kitą įdėtinio X serverio variantą.
                # -Ddri1=true # Įtraukti pasenusį DRI1 palaikymą.
                # -Dsystemd_logind=true # Naudoti systemd-logind vietoj elogind/kitų sesijų valdymo.
            )
            desktop_meson xorg-server "${xorg_flags[@]}" ;;
        # Cairo enables PNG, font and Xlib/XCB rendering dependencies; tests off.
        cairo) desktop_meson cairo -Dzlib=enabled -Dglib=enabled -Dtests=disabled -Dfontconfig=enabled -Dfreetype=enabled -Dxlib=enabled -Dxcb=enabled -Dpng=enabled ;;
        harfbuzz) desktop_meson harfbuzz -Dglib=enabled -Dfreetype=enabled -Dgobject=disabled \
            -Dicu=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled ;;
        # FriBidi runtime only: omit docs and tests.
        fribidi) desktop_meson fribidi -Ddocs=false -Dtests=false ;;
        pango) desktop_meson pango -Dfontconfig=enabled -Dfreetype=enabled -Dcairo=enabled -Dintrospection=disabled -Ddocumentation=false -Dbuild-testsuite=false -Dbuild-examples=false ;;
        gdk-pixbuf) desktop_meson gdk-pixbuf -Dpng=enabled -Djpeg=disabled -Dtiff=disabled -Dgif=enabled -Dbuiltin_loaders=png,gif -Dintrospection=disabled -Dman=false -Dtests=false -Dinstalled_tests=false ;;
        at-spi2-core) desktop_meson at-spi2-core -Dx11=enabled -Dintrospection=disabled -Dgtk2_atk_adaptor=false -Duse_systemd=false -Ddbus_daemon=/usr/bin/dbus-daemon ;;
        libepoxy) desktop_meson libepoxy -Dglx=yes -Degl=yes -Dx11=true -Dtests=false ;;
        # Mesa uses the GLVND dispatch ABI for GLX/EGL clients.
        libglvnd) desktop_meson libglvnd -Dx11=enabled -Dglx=enabled -Degl=true \
            -Dhgl=false -Dgles1=false -Dgles2=false -Dheaders=true ;;
        # Color-management runtime library only; no static archive.
        lcms2) autotools lcms2 --disable-static ;;
        libgusb) desktop_meson libgusb -Ddocs=false -Dtests=false -Dvapi=false ;;
        colord) desktop_meson colord -Ddaemon=false -Dsession_example=false \
            -Dbash_completion=false -Dudev_rules=false -Dsystemd=false \
            -Dargyllcms_sensor=false -Dsane=false -Dtests=false \
            -Dinstalled_tests=false -Dman=false -Ddocs=false -Dvapi=false \
            -Dintrospection=false ;;
        libei) desktop_meson libei -Dlibei=enabled -Dlibeis=enabled \
            -Dliboeffis=disabled -Dtests=disabled -Ddocumentation=[] ;;
        gtk)
            # GTK3 options: build the Xorg desktop used by MATE/LXDE, without
            # pulling in Wayland or developer/test/documentation components.
            local -a gtk_flags=(
                -Dx11_backend=true       # įjungia GTK X11/Xorg langų sistemą
                -Dwayland_backend=false # nekuria GTK Wayland langų sistemos
                -Dintrospection=false  # nekuria GObject introspection metaduomenų
                -Ddemos=false           # neįdiegia GTK demonstracinių programų
                -Dexamples=false        # neįdiegia GTK pavyzdinių programų
                -Dtests=false           # nekuria GTK testų
                -Dinstalled_tests=false # neįdiegia testų į galutinę sistemą
                -Dman=false             # nekuria GTK man dokumentacijos
                -Dprint_backends=file   # palieka spausdinimą į failą, be CUPS priklausomybės
                -Dxinerama=yes          # įjungia kelių ekranų Xinerama palaikymą
                # -Dwayland_backend=true # Pridėti Wayland GTK backendą (reikia Wayland stack).
                # -Dintrospection=true # Generuoti GIR metaduomenis kalbų sąsajoms.
                # -Ddemos=true -Dexamples=true # Įdiegti demonstracijas ir pavyzdines programas.
                # -Dtests=true -Dinstalled_tests=true # Kurti ir įdiegti GTK testus.
                # -Dman=true # Kurti GTK man puslapius.
            )
            desktop_meson gtk "${gtk_flags[@]}" ;;
        # libxml2 stays a C runtime library; omit Python bindings and optional
        # LZMA/iconv integrations that would add dependencies.
        libxml2) autotools libxml2 --without-python --without-lzma --without-iconv --disable-static ;;
        # Use the shipped MIME database: no host database regeneration,
        # translation build, or test suite.
        shared-mime-info) desktop_meson shared-mime-info -Dbuild-tests=false -Dupdate-mimedb=false -Dbuild-translations=false ;;
        desktop-file-utils) desktop_meson desktop-file-utils ;;
        hicolor-icon-theme) desktop_meson hicolor-icon-theme ;;
        adwaita-icon-theme) autotools adwaita-icon-theme ;;
        dejavu-fonts)
            source=$(unpack dejavu-fonts)
            mkdir -p "$ROOT/usr/share/fonts/dejavu"
            install -m0644 "$source/ttf/"*.ttf "$ROOT/usr/share/fonts/dejavu/" ;;
        libdisplay-info) desktop_meson libdisplay-info ;;
        # libwnck omits startup notification integration, GIR and GTK docs.
        libwnck) desktop_meson libwnck -Dstartup_notification=disabled -Dintrospection=disabled -Dgtk_doc=false ;;
        # bash-completion only adds interactive shell completions; the target
        # system does not build/install bash-completion, so keep this optional
        # dconf feature disabled for reproducible cross builds.
        # dconf omits shell completion, GTK/man docs and Vala bindings.
        dconf) desktop_meson dconf -Dbash_completion=false -Dgtk_doc=false -Dman=false -Dvapi=false ;;
        dbus-glib)
            # dbus-glib 0.112 uses `bool` as a local variable name. Newer GCC
            # defaults to C23, where bool is a keyword, so rename that local.
            source=$(unpack dbus-glib)
            sed -i \
                -e 's/dbus_bool_t bool;/dbus_bool_t dbus_boolean_value;/' \
                -e 's/get_basic (iter, \&bool);/get_basic (iter, \&dbus_boolean_value);/' \
                -e 's/set_boolean (value, bool);/set_boolean (value, dbus_boolean_value);/' \
                "$source/dbus/dbus-gvalue.c"
            autotools dbus-glib --disable-static --disable-gtk-doc ;;
        # SQLite keeps FTS5 full-text search and R*Tree spatial indexing;
        # legacy SONAME preserves expected ABI naming; no static archive.
        sqlite) autotools sqlite --disable-static --enable-fts5 --enable-rtree --soname=legacy ;;
        # libsoup requires libpsl for public-suffix cookie checks. Keep its
        # built-in suffix data, while disabling optional runtime IDNA support.
        libpsl) autotools libpsl --disable-static --disable-runtime --disable-man --disable-gtk-doc ;;
        libsoup) desktop_meson libsoup -Dgtk_doc=false -Dintrospection=disabled -Dvapi=disabled -Dtests=false -Dinstalled_tests=false -Dsysprof=disabled -Dtls_check=false -Dgnome=false -Dbrotli=disabled ;;
        # ALSA runtime library only; do not build static archive or Python bindings.
        alsa-lib) autotools alsa-lib --disable-static --disable-python ;;
        alsa-utils)
            # ALSA Utils' auto-detection can choose ncurses.pc (whose libs are
            # ncursesw) but still probe narrow -lpanel. Select ncursesw so it
            # correctly probes panelw/menuw/formw, and link against target libs.
            # Its topology Makefile also forgets to use the -latopology flag
            # that configure discovers, so add it when the target library exists.
            (export CPPFLAGS="${CPPFLAGS:-} -I$ROOT/usr/include"
             export LDFLAGS="${LDFLAGS:-} -L$ROOT/usr/lib -Wl,-rpath-link,$ROOT/usr/lib"
             source=$(unpack alsa-utils)
             remove_installed_libtool_archives
             mkdir -p "$BUILD/alsa-utils"
             (cd "$BUILD/alsa-utils"
              "$source/configure" --build="$HOST" --host="$TARGET" --prefix=/usr \
                  --libdir=/usr/lib --sysconfdir=/etc --localstatedir=/var \
                  --with-curses=ncursesw --disable-static --disable-nls \
                  --disable-alsaconf --disable-bat --disable-alsaloop --disable-alsatest
              refresh_stale_libtool_metadata "$BUILD/alsa-utils"
              if [[ -e "$ROOT/usr/lib/libatopology.so" ]]; then
                  sed -i 's|^ALSA_TOPOLOGY_LIBS =.*$|ALSA_TOPOLOGY_LIBS = -latopology|' \
                      topology/Makefile
              fi
              make -j"$JOBS"
              make DESTDIR="$ROOT" install)
             remove_installed_libtool_archives) ;;
        libcap)
            source=$(unpack libcap)
            make -C "$source/libcap" -j"$JOBS" CROSS_COMPILE="$TARGET-" BUILD_CC="$HOST_CC" \
                CC="$CC" AR="$AR" lib=lib prefix=/usr SHARED=yes GOLANG=no
            make -C "$source/libcap" CROSS_COMPILE="$TARGET-" BUILD_CC="$HOST_CC" \
                CC="$CC" AR="$AR" lib=lib prefix=/usr SHARED=yes GOLANG=no DESTDIR="$ROOT" install ;;
        libsndfile)
            # PulseAudio links libsndfile for its sndfile module and playback
            # helpers. Build the shared target library; optional codecs,
            # utilities, examples, and tests are not needed in this image.
            source=$(unpack libsndfile)
            local -a libsndfile_cmake_flags=(
                -DCMAKE_SYSTEM_NAME=Linux              # nurodo kryžminio kompiliavimo OS
                -DCMAKE_SYSTEM_PROCESSOR="$TARGET_ARCH" # nustato tikslinę procesoriaus architektūrą
                -DCMAKE_C_COMPILER="$CC"               # naudoja projekto kryžminį C kompiliatorių
                -DCMAKE_SYSROOT="$ROOT"                 # ieško tikslinės sistemos antraščių ir bibliotekų
                -DCMAKE_FIND_ROOT_PATH="$ROOT"         # nustato tikslinės sistemos paieškos šaknį
                -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER # build metu įrankius ima iš šeimininko
                -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY  # bibliotekas ima tik iš tikslinio rootfs
                -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY  # antraštes ima tik iš tikslinio rootfs
                -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY  # CMake paketus ima tik iš tikslinio rootfs
                -DCMAKE_INSTALL_PREFIX=/usr               # diegia programos failus į /usr
                -DCMAKE_INSTALL_LIBDIR=lib                 # bibliotekas diegia į /usr/lib
                -DCMAKE_BUILD_TYPE=Release                # įjungia optimizuotą leidimo kompiliavimą
                -DBUILD_SHARED_LIBS=ON                    # kuria dalijamąją libsndfile biblioteką
                -DBUILD_PROGRAMS=OFF                      # nekuria papildomų komandų eilutės programų
                -DBUILD_EXAMPLES=OFF                      # nekuria demonstracinių pavyzdžių
                -DBUILD_TESTING=OFF                       # nekuria ir nevykdo testų
                -DENABLE_EXTERNAL_LIBS=OFF                # neprideda pasirenkamų išorinių kodekų
                -DENABLE_MPEG=OFF                         # išjungia MPEG kodekų palaikymą
                -DENABLE_CPACK=OFF                        # nekuria CPack diegimo archyvų
                -DENABLE_PACKAGE_CONFIG=OFF                # negeneruoja CMake paketo konfigūracijos failų
                -DINSTALL_PKGCONFIG_MODULE=ON              # įdiegia pkg-config metaduomenis PulseAudio
                -DINSTALL_MANPAGES=OFF                     # neįdiegia man puslapių
                # -DBUILD_PROGRAMS=ON # kurti papildomus libsndfile CLI įrankius.
                # -DBUILD_EXAMPLES=ON # kurti demonstracines programas.
                # -DBUILD_TESTING=ON # kurti libsndfile testų rinkinį.
                # -DENABLE_MPEG=ON # įjungti MPEG palaikymą su reikalingomis priklausomybėmis.
                # -DINSTALL_MANPAGES=ON # įdiegti man puslapius.
            )
            cmake -S "$source" -B "$BUILD/libsndfile" -G Ninja "${libsndfile_cmake_flags[@]}"
            cmake --build "$BUILD/libsndfile" --parallel "$JOBS"
            DESTDIR="$ROOT" cmake --install "$BUILD/libsndfile" ;;
        pulseaudio)
            # Firefox's Linux build uses PulseAudio for browser audio. Keep the
            # server per-user (started by the MATE session), with ALSA and
            # udev device detection; omit systemd, optional Bluetooth/docs, and
            # external TDB/GDBM storage. PulseAudio's built-in simple database
            # keeps device/stream restore without another library dependency.
            local -a pulseaudio_flags=(
                -Ddaemon=true       # kuria PulseAudio garso serverį
                -Dclient=true       # kuria klientų biblioteką ir įrankius
                -Dalsa=enabled      # įjungia ALSA garso įrenginių išvestį/įvestį
                -Dudev=enabled      # leidžia aptikti garso įrenginius per udev
                -Dsystemd=disabled  # nenaudoja systemd integracijos, kad tiktų kiti init
                -Dbluez5=disabled   # neįtraukia Bluetooth garso modulio
                -Ddatabase=simple   # naudoja vidinę paprastą nustatymų duomenų bazę
                -Ddoxygen=false     # nekuria Doxygen dokumentacijos
                -Dman=false         # nekuria man puslapių
                -Dtests=false       # nekuria PulseAudio testų
                # -Dbluez5=enabled # įjungti Bluetooth garso palaikymą (reikia BlueZ bibliotekų).
                # -Dsystemd=enabled # pridėti systemd integraciją; netinka kitoms init sistemoms.
                # -Dtests=true # kurti PulseAudio testų rinkinį.
                # -Dman=true # generuoti PulseAudio man puslapius.
            )
            meson_package pulseaudio "${pulseaudio_flags[@]}" ;;
        sound-mixer)
            # Small native GTK window over ALSA's simple mixer API: a real GUI
            # control without pulling in the much larger gtkmm/pavucontrol stack.
            cat > "$BUILD/diy-sound-mixer.c" <<'SOUND_MIXER_C'
#include <gtk/gtk.h>
#include <alsa/asoundlib.h>
#include <glob.h>
#include <string.h>

static snd_mixer_t *mixer;
static snd_mixer_elem_t *control;
static long volume_min, volume_max;
static GtkWidget *volume_scale, *mute_button, *window;
static GtkStatusIcon *status_icon;
static gboolean updating, tray_mode;

static void tray_activated(GtkStatusIcon *icon, gpointer unused) {
    (void)icon; (void)unused;
    if (gtk_widget_get_visible(window)) gtk_widget_hide(window);
    else { gtk_widget_show_all(window); gtk_window_present(GTK_WINDOW(window)); }
}

static gboolean tray_delete_window(GtkWidget *widget, GdkEvent *event, gpointer unused) {
    (void)event; (void)unused;
    gtk_widget_hide(widget);
    return TRUE;
}

static long current_volume(void) {
    long left = 0, right = 0;
    snd_mixer_selem_get_playback_volume(control, SND_MIXER_SCHN_FRONT_LEFT, &left);
    if (snd_mixer_selem_has_playback_channel(control, SND_MIXER_SCHN_FRONT_RIGHT))
        snd_mixer_selem_get_playback_volume(control, SND_MIXER_SCHN_FRONT_RIGHT, &right);
    else right = left;
    return (left + right) / 2;
}

static void volume_changed(GtkRange *range, gpointer unused) {
    (void)unused;
    if (updating) return;
    long value = volume_min + (long)((gtk_range_get_value(range) / 100.0) * (volume_max-volume_min));
    snd_mixer_selem_set_playback_volume_all(control, value);
}

static void mute_changed(GtkToggleButton *button, gpointer unused) {
    (void)unused;
    if (!updating && snd_mixer_selem_has_playback_switch(control))
        snd_mixer_selem_set_playback_switch_all(control, !gtk_toggle_button_get_active(button));
}

static gboolean refresh_controls(gpointer unused) {
    (void)unused;
    if (!control) return G_SOURCE_CONTINUE;
    updating = TRUE;
    gtk_range_set_value(GTK_RANGE(volume_scale),
        100.0 * (current_volume()-volume_min) / (volume_max-volume_min));
    if (snd_mixer_selem_has_playback_switch(control)) {
        int enabled = 1;
        snd_mixer_selem_get_playback_switch(control, SND_MIXER_SCHN_FRONT_LEFT, &enabled);
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(mute_button), !enabled);
    } else gtk_widget_set_sensitive(mute_button, FALSE);
    updating = FALSE;
    return G_SOURCE_CONTINUE;
}

int main(int argc, char **argv) {
    tray_mode = argc > 1 && !strcmp(argv[1], "--tray");
    /* Do not probe ALSA on headless/QEMU boots that expose no sound device.
     * Apart from noisy alsa-lib diagnostics, a tray mixer without a card is
     * misleading. Running the mixer manually still shows its helpful error. */
    if (tray_mode) {
        glob_t sound_nodes = {0};
        int found_sound_device = glob("/dev/snd/controlC*", 0, NULL, &sound_nodes) == 0;
        globfree(&sound_nodes);
        if (!found_sound_device) return 0;
    }
    gtk_init(&argc, &argv);
    if (tray_mode) {
        status_icon=gtk_status_icon_new_from_icon_name("audio-volume-high");
        gtk_status_icon_set_tooltip_text(status_icon, "Sound Mixer");
        gtk_status_icon_set_visible(status_icon, TRUE);
        g_signal_connect(status_icon, "activate", G_CALLBACK(tray_activated), NULL);
    }
    int err = snd_mixer_open(&mixer, 0);
    if (err >= 0) err = snd_mixer_attach(mixer, "default");
    if (err >= 0) err = snd_mixer_selem_register(mixer, NULL, NULL);
    if (err >= 0) err = snd_mixer_load(mixer);
    if (err < 0) {
        if (tray_mode) {
            gtk_status_icon_set_tooltip_text(status_icon, "Sound Mixer (audio device unavailable)");
            window=gtk_window_new(GTK_WINDOW_TOPLEVEL);
            gtk_window_set_title(GTK_WINDOW(window), "Sound Mixer");
            gtk_window_set_default_size(GTK_WINDOW(window), 360, 100);
            GtkWidget *label=gtk_label_new("No ALSA sound mixer is available. Check /dev/snd and the audio driver.");
            gtk_container_set_border_width(GTK_CONTAINER(window), 16);
            gtk_container_add(GTK_CONTAINER(window), label);
            g_signal_connect(window, "delete-event", G_CALLBACK(tray_delete_window), NULL);
            gtk_main();
        } else {
            GtkWidget *dialog = gtk_message_dialog_new(NULL, GTK_DIALOG_MODAL, GTK_MESSAGE_ERROR,
                GTK_BUTTONS_CLOSE, "No ALSA sound mixer is available: %s", snd_strerror(err));
            gtk_dialog_run(GTK_DIALOG(dialog)); gtk_widget_destroy(dialog);
        }
        if (mixer) snd_mixer_close(mixer);
        return tray_mode ? 0 : 1;
    }
    for (snd_mixer_elem_t *item=snd_mixer_first_elem(mixer); item; item=snd_mixer_elem_next(item)) {
        if (!snd_mixer_selem_is_active(item) || !snd_mixer_selem_has_playback_volume(item)) continue;
        if (!g_ascii_strcasecmp(snd_mixer_selem_get_name(item), "Master")) { control=item; break; }
        if (!control || !g_ascii_strcasecmp(snd_mixer_selem_get_name(item), "PCM")) control=item;
    }
    if (!control || snd_mixer_selem_get_playback_volume_range(control, &volume_min, &volume_max) < 0 || volume_max <= volume_min) {
        if (tray_mode) {
            gtk_status_icon_set_tooltip_text(status_icon, "Sound Mixer (no adjustable control)");
            window=gtk_window_new(GTK_WINDOW_TOPLEVEL);
            gtk_window_set_title(GTK_WINDOW(window), "Sound Mixer");
            gtk_window_set_default_size(GTK_WINDOW(window), 360, 100);
            GtkWidget *label=gtk_label_new("No adjustable ALSA playback control was found. Try alsamixer in a terminal.");
            gtk_container_set_border_width(GTK_CONTAINER(window), 16);
            gtk_container_add(GTK_CONTAINER(window), label);
            g_signal_connect(window, "delete-event", G_CALLBACK(tray_delete_window), NULL);
            gtk_main();
            snd_mixer_close(mixer); return 0;
        }
        GtkWidget *dialog = gtk_message_dialog_new(NULL, GTK_DIALOG_MODAL, GTK_MESSAGE_ERROR,
            GTK_BUTTONS_CLOSE, "No adjustable ALSA playback control was found. Try `alsamixer` in a terminal.");
        gtk_dialog_run(GTK_DIALOG(dialog)); gtk_widget_destroy(dialog);
        snd_mixer_close(mixer); return 1;
    }
    window=gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(window), "Sound Mixer");
    gtk_window_set_default_size(GTK_WINDOW(window), 360, 130);
    gtk_container_set_border_width(GTK_CONTAINER(window), 16);
    GtkWidget *box=gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    GtkWidget *label=gtk_label_new(snd_mixer_selem_get_name(control));
    volume_scale=gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 100, 1);
    gtk_scale_set_draw_value(GTK_SCALE(volume_scale), TRUE);
    mute_button=gtk_check_button_new_with_label("Mute");
    gtk_box_pack_start(GTK_BOX(box), label, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), volume_scale, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(box), mute_button, FALSE, FALSE, 0);
    gtk_container_add(GTK_CONTAINER(window), box);
    g_signal_connect(volume_scale, "value-changed", G_CALLBACK(volume_changed), NULL);
    g_signal_connect(mute_button, "toggled", G_CALLBACK(mute_changed), NULL);
    if (tray_mode) {
        g_signal_connect(window, "delete-event", G_CALLBACK(tray_delete_window), NULL);
        gtk_widget_hide(window);
    } else {
        g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
        gtk_widget_show_all(window);
    }
    refresh_controls(NULL); g_timeout_add_seconds(2, refresh_controls, NULL);
    gtk_main();
    snd_mixer_close(mixer);
    return 0;
}
SOUND_MIXER_C
            local -a mixer_cflags=() mixer_libs=()
            read -r -a mixer_cflags <<<"$(pkg-config --cflags gtk+-3.0 alsa)"
            read -r -a mixer_libs <<<"$(pkg-config --libs gtk+-3.0 alsa)"
            "$CC" -O2 -Wall -Wextra "${mixer_cflags[@]}" "$BUILD/diy-sound-mixer.c" \
                -o "$ROOT/usr/bin/diy-sound-mixer" "${mixer_libs[@]}"
            mkdir -p "$ROOT/usr/share/applications"
            cat > "$ROOT/usr/share/applications/diy-sound-mixer.desktop" <<'SOUND_MIXER_DESKTOP'
[Desktop Entry]
Type=Application
Name=Sound Mixer
Name[lt]=Garso maišytuvas
Comment=Adjust the sound card volume and mute state
Comment[lt]=Keisti garso plokštės garsumą ir nutildymą
Exec=/usr/bin/diy-sound-mixer
Icon=audio-volume-high
Terminal=false
Categories=AudioVideo;Audio;Settings;
SOUND_MIXER_DESKTOP
            ;;
        linux-firmware)
            # Download the signed-off upstream snapshot, but copy only the
            # firmware families needed by the selected desktop/network profile.
            # The upstream archive changes its top-level layout over time, so
            # select matching members from its actual listing instead of making
            # tar fail when an optional vendor directory is absent.
            fetch linux-firmware
            local firmware_archive firmware_listing firmware_members
            firmware_archive=$(archive_path linux-firmware)
            mkdir -p "$ROOT/lib/firmware"
            firmware_listing="$BUILD/linux-firmware-members.list"
            firmware_members="$BUILD/linux-firmware-selected.list"
            tar -tJf "$firmware_archive" > "$firmware_listing" ||
                die "$(tr_text 'Could not list linux-firmware archive' 'Nepavyko perskaityti linux-firmware archyvo turinio')"
            awk -v need_wifi="$NETWORK" -v need_desktop="$DESKTOP_CHOICE" '
                /^linux-firmware-[^/]+\// {
                    path=$0
                    sub(/^[^/]+\//, "", path)
                    if (need_wifi == "yes" && (path ~ /^(ath3k|ath6k|ath9k_htc|ath10k|ath11k|ath12k|brcm|iwlwifi|mediatek|mrvl|qca|ralink|rtl_nic|rtlwifi|rtw88|rtw89|rtw|ti-connectivity)\// ||
                        path ~ /^intel\/iwlwifi\//)) {
                        print; wifi++
                    } else if (need_desktop != "none" && path ~ /^(amdgpu|i915|nvidia|radeon|cirrus|amd|sof)\//) {
                        print
                    } else if (need_desktop != "none" && path ~ /^intel\/(sof|sof-tplg)\//) {
                        print
                    } else if (need_desktop != "none" && (path ~ /^intel\/(avs|catpt)\// ||
                               path ~ /^intel\/(ibt-[^/]+|dsp_fw[^/]*|fw_sst[^/]*)$/)) {
                        print
                    } else if (need_wifi == "yes" && path ~ /^iwlwifi-[^/]+\.(ucode|pnvm)$/) {
                        print; wifi++
                    } else if (need_wifi == "yes" && path ~ /^(ath3k[^/]*\.fw|ar[0-9][^/]*\.fw|htc_[^/]*\.fw|rt[^/]*\.(bin|fw))$/) {
                        print; wifi++
                    } else if ((need_wifi == "yes" && path ~ /^regulatory\.db(\.p7s)?$/) || path ~ /^(WHENCE|LICENCE[^/]*)$/) {
                        print
                    }
                }
                END { if (need_wifi == "yes" && !wifi) exit 1 }
            ' "$firmware_listing" > "$firmware_members" ||
                die "$(tr_text 'No supported Wi-Fi or graphics firmware files were found in linux-firmware' 'linux-firmware archyve nerasta palaikomų Wi-Fi ar grafikos firmware failų')"
            tar -xJf "$firmware_archive" -C "$ROOT/lib/firmware" --strip-components=1 \
                --no-recursion --verbatim-files-from --files-from="$firmware_members" ||
                die "$(tr_text 'Could not extract selected firmware from linux-firmware' 'Nepavyko išskleisti pasirinktos linux-firmware dalies')"
            # linux-firmware moved Intel blobs into intel/iwlwifi/, but the
            # in-tree iwlwifi driver still requests iwlwifi-*.ucode from the
            # firmware root. Provide the legacy paths expected by request_firmware().
            if [[ -d "$ROOT/lib/firmware/intel/iwlwifi" ]]; then
                local iwl_blob iwl_name
                for iwl_blob in "$ROOT"/lib/firmware/intel/iwlwifi/iwlwifi-*.ucode \
                    "$ROOT"/lib/firmware/intel/iwlwifi/iwlwifi-*.pnvm; do
                    [[ -f "$iwl_blob" ]] || continue
                    iwl_name=${iwl_blob##*/}
                    ln -sfn "intel/iwlwifi/$iwl_name" "$ROOT/lib/firmware/$iwl_name"
                done
            fi
            find "$ROOT/lib/firmware" -type d -empty -delete
            ;;
        wireless-regdb)
            install_wireless_regdb
            ;;
        libnl) autotools libnl --disable-static --disable-cli --disable-debug --disable-pthreads --disable-doc ;;
        iw)
            source=$(unpack iw)
            make -C "$source" -j"$JOBS" CC="$CC" PKG_CONFIG="$(command -v pkg-config)" PREFIX=/usr SBINDIR=/usr/sbin
            make -C "$source" DESTDIR="$ROOT" PREFIX=/usr SBINDIR=/usr/sbin install ;;
        libmnl) autotools libmnl --disable-static ;;
        libnftnl) autotools libnftnl --disable-static ;;
        # WISPr is only used by a subset of captive portals and forces a hard
        libndp)
            source=$(unpack libndp)
            (cd "$source"; NOCONFIGURE=1 ./autogen.sh)
            autotools libndp --disable-static ;;
        NetworkManager)
            # Minimal OpenRC build: internal DHCP, WPA supplicant, no systemd,
            # polkit, modem, VPN, firewall, docs or optional CLI dependencies.
            # nmcli needs readline; nmtui needs newt/slang. The desktop uses
            # network-manager-applet, so omit both terminal frontends.
            local -a networkmanager_flags=(
                -Dsystemdsystemunitdir=no # nediegia systemd paslaugų failų
                -Dsystemdsystemgeneratordir=no # nediegia systemd generatoriaus
                -Ddbus_conf_dir=/usr/share/dbus-1/system.d # nurodo D-Bus sistemos taisyklių vietą
                -Dudev_dir=/usr/lib/udev # nurodo udev taisyklių katalogą
                -Dsession_tracking=no # išjungia systemd/ConsoleKit sesijų sekimą
                -Dsession_tracking_consolekit=false # išjungia ConsoleKit sesijų sekimo backendą
                -Dsystemd_journal=false # nerašo į systemd žurnalą
                -Dconfig_logging_backend_default=syslog # pagal nutylėjimą registruoja per syslog
                -Dpolkit=false # nenaudoja polkit autorizavimo priklausomybės
                -Dconfig_auth_polkit_default=false # numatytajai konfigūracijai neparenka polkit
                -Dcrypto=null # nenaudoja papildomo paslapčių saugojimo kriptografijos backend'o
                -Dwifi=true # įjungia Wi-Fi valdymą
                -Diwd=false # nenaudoja iwd Wi-Fi backend'o
                -Dconfig_wifi_backend_default=wpa_supplicant # parenka wpa_supplicant Wi-Fi backendą
                -Dconfig_dhcp_default=internal # naudoja vidinį DHCP klientą
                -Dlibpsl=false # išjungia pasirenkamą viešųjų domenų biblioteką
                -Dconcheck=false # išjungia automatinį interneto ryšio tikrinimą
                -Dppp=false # išjungia PPP modemų palaikymą
                -Dmodem_manager=false # išjungia ModemManager integraciją
                -Dteamdctl=false # išjungia teamd tinklo komandų biblioteką
                -Dovs=false # išjungia Open vSwitch palaikymą
                -Dclat=false # išjungia CLAT IPv4/IPv6 vertimo modulį
                -Dnbft=false # išjungia NVMe-oF Boot Firmware Table palaikymą
                -Dnm_cloud_setup=false # nekuria debesijos tinklo parengimo įrankio
                -Dfirewalld_zone=false # išjungia firewalld zonų integraciją
                -Dnmcli=false # nekuria nmcli terminalo įrankio
                -Dnmtui=false # nekuria nmtui tekstinio meniu
                -Dlibaudit=no # išjungia Linux audit bibliotekos integraciją
                -Dselinux=false # išjungia SELinux integraciją
                -Ddocs=false # nekuria dokumentacijos
                -Dman=false # nekuria man puslapių
                -Dtests=no # nekuria testų
                -Dintrospection=false # nekuria GObject introspection metaduomenų
                -Dvapi=false # nekuria Vala API metaduomenų
                # -Dnmcli=true # Kurti terminalo NetworkManager valdymo komandą.
                # -Dnmtui=true # Kurti tekstinį valdymo meniu (reikia newt/slang).
                # -Dpolkit=true # Įjungti polkit autorizavimo integraciją.
                # -Diwd=true # Leisti alternatyvų iwd Wi-Fi backendą.
                # -Dmodem_manager=true # Pridėti mobiliųjų modemų valdymą.
                # -Dconcheck=true # Pridėti interneto/captive portal pasiekiamumo tikrinimą.
                # -Dlibpsl=true # Pridėti viešųjų domenų sąrašų biblioteką.
                # -Dselinux=true # Įjungti SELinux politikų integraciją.
            )
            meson_package NetworkManager "${networkmanager_flags[@]}" ;;
        libsecret)
            meson_package libsecret -Dcrypto=disabled -Dmanpage=false -Dvapi=false \
                -Dgtk_doc=false -Dintrospection=false -Dbash_completion=disabled ;;
        libnma)
            meson_package libnma -Dlibnma_gtk4=false -Dgcr=false -Diso_codes=false \
                -Dmobile_broadband_provider_info=false -Dintrospection=false \
                -Dvapi=false -Dgtk_doc=false ;;
        network-manager-applet)
            meson_package network-manager-applet -Dappindicator=no -Dwwan=false \
                -Dselinux=false -Dteam=false -Dld_gc=false ;;
        bubblewrap)
            # Bubblewrap >= 0.12 removed setuid mode; it uses unprivileged user namespaces.
            meson_package bubblewrap -Dselinux=disabled \
                -Dman=disabled -Dbash_completion=disabled -Dzsh_completion=disabled -Dtests=false ;;
        wpa_supplicant)
            # This profile may omit wget, so build the shared TLS library here
            # before compiling the Wi-Fi supplicant against OpenSSL.
            download_tls
            source=$(unpack wpa_supplicant)
            cat > "$source/wpa_supplicant/.config" <<'WPA_CONFIG'
CONFIG_DRIVER_NL80211=y
CONFIG_CTRL_IFACE=y
CONFIG_CTRL_IFACE_UNIX=y
CONFIG_CTRL_IFACE_DBUS_NEW=y
CONFIG_DBUS=y
CONFIG_LIBNL32=y
CONFIG_TLS=openssl
CONFIG_EAPOL=y
CONFIG_IEEE8021X_EAPOL=y
CONFIG_SAE=y
CONFIG_OWE=y
CONFIG_WPS=y
CONFIG_DEBUG_SYSLOG=y
WPA_CONFIG
            make -C "$source/wpa_supplicant" clean
            make -C "$source/wpa_supplicant" -j"$JOBS" CC="$CC" BINDIR=/usr/sbin LIBDIR=/usr/lib
            install -Dm0755 "$source/wpa_supplicant/wpa_supplicant" "$ROOT/usr/sbin/wpa_supplicant"
            install -Dm0755 "$source/wpa_supplicant/wpa_cli" "$ROOT/usr/sbin/wpa_cli"
            install -Dm0755 "$source/wpa_supplicant/wpa_passphrase" "$ROOT/usr/sbin/wpa_passphrase"
            # NetworkManager launches the supplicant through the system D-Bus API.
            mkdir -p "$ROOT/usr/share/dbus-1/system-services" "$ROOT/etc/dbus-1/system.d"
            cat > "$ROOT/usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service" <<'WPA_DBUS_SERVICE'
[D-BUS Service]
Name=fi.w1.wpa_supplicant1
Exec=/usr/sbin/wpa_supplicant -u
User=root
SystemdService=wpa_supplicant.service
WPA_DBUS_SERVICE
            cat > "$ROOT/etc/dbus-1/system.d/wpa_supplicant.conf" <<'WPA_DBUS_POLICY'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="root">
    <allow own="fi.w1.wpa_supplicant1"/>
  </policy>
  <policy context="default">
    <allow send_destination="fi.w1.wpa_supplicant1"/>
    <allow receive_sender="fi.w1.wpa_supplicant1"/>
  </policy>
</busconfig>
WPA_DBUS_POLICY
            ;;
        # libcanberra loads sound modules through libltdl at runtime.
        libtool) autotools libtool --enable-ltdl-install --disable-static ;;
        libogg) autotools libogg --disable-static ;;
        libvorbis) autotools libvorbis --disable-static ;;
        libcanberra) autotools libcanberra --disable-static --enable-alsa --disable-oss --disable-pulse --disable-gstreamer --disable-udev --disable-gtk --enable-gtk3 --disable-tdb --disable-gtk-doc ;;
        libnotify) desktop_meson libnotify -Dgtk_doc=false -Dintrospection=disabled -Dtests=false -Dman=false -Ddocbook_docs=disabled ;;
        duktape)
            source=$(unpack duktape)
            make -C "$source" -f Makefile.sharedlibrary -j"$JOBS" CC="$CC" \
                CFLAGS="${CFLAGS:-} -fPIC" INSTALL_PREFIX=/usr LIBDIR=/lib \
                DESTDIR="$ROOT" install ;;
        polkit)
            local session_tracking=logind
            [[ "$INIT_CHOICE" == systemd ]] || session_tracking=elogind
            desktop_meson polkit -Dsession_tracking="$session_tracking" -Dauthfw=shadow \
                -Dintrospection=false -Dgtk_doc=false -Dman=false -Dtests=false \
                -Dsystemdsystemunitdir=/usr/lib/systemd/system -Dos_type=lfs \
                -Dprivileged_group=sudo ;;
        linux-pam)
            desktop_meson linux-pam -Ddocs=disabled -Daudit=disabled -Deconf=disabled \
                -Dlogind=disabled -Delogind=disabled -Dpwaccess=disabled \
                -Dselinux=disabled -Dnis=disabled -Dexamples=false \
                -Dpam_userdb=disabled -Dpam_unix=enabled -Dpam_lastlog=disabled \
                -Dopenssl=disabled -Dxtests=false ;;
        elogind)
            # Re-extract to undo source edits left by an interrupted earlier
            # build recipe before applying the current compatibility fix.
            rm -rf "$SOURCES/elogind-${VERSION[elogind]}"
            source=$(unpack elogind)
            # logind still uses user-record/userdb internally with these
            # features off. Build the shared NSS record helpers too, but keep
            # the external NSS module itself disabled.
            sed -i "s/if get_option('nss-elogind') != false/if true/" \
                "$source/src/shared/meson.build"
            desktop_meson elogind -Dmode=release -Dtests=false -Dman=disabled \
                -Dpam=enabled -Dpolkit=disabled -Dacl=disabled -Daudit=disabled \
                -Dselinux=disabled -Dnss-elogind=false -Duserdb=false \
                -Dvarlink=false -Dsysvinit-path=/etc/init.d -Dsysvrcnd-path=/etc/rc.d ;;
        mate-polkit) autotools mate-polkit --disable-static --disable-gtk-doc ;;
        libXScrnSaver) autotools libXScrnSaver --disable-static --disable-docs ;;
        libgtop) autotools libgtop --disable-static --disable-introspection --disable-gtk-doc ;;
        librsvg) build_librsvg ;;
        libatasmart) autotools libatasmart --disable-static --disable-gtk-doc ;;
        e2fsprogs)
            source=$(unpack e2fsprogs)
            mkdir -p "$BUILD/e2fsprogs"
            ( cd "$BUILD/e2fsprogs"
              "$source/configure" --build="$HOST" --host="$TARGET" --prefix=/usr \
                  --libdir=/usr/lib --sysconfdir=/etc --enable-elf-shlibs \
                  --disable-nls --disable-uuidd --disable-fsck --disable-e2initrd-helper
              make -j"$JOBS"
              make DESTDIR="$ROOT" install-libs
              make -C lib/ext2fs DESTDIR="$ROOT" install
              make -C lib/e2p DESTDIR="$ROOT" install ) ;;
        libblockdev) autotools libblockdev --disable-static --disable-tests \
            --enable-introspection=no --with-python3=no --with-gtk-doc=no --with-tools=no \
            --with-loop --with-swap --with-part --with-fs --without-btrfs --without-crypto \
            --without-dm --without-lvm --without-lvm_dbus --without-mdraid \
            --without-mpath --without-nvdimm --without-nvme \
            --without-smart --without-smartmontools ;;
        udisks)
            source=$(unpack udisks)
            blockdev_source=$(unpack libblockdev)
            install -d "$ROOT/usr/include/blockdev"
            for header in crypto mdraid nvme; do
                install -m0644 "$blockdev_source/src/lib/plugin_apis/$header.h" \
                    "$ROOT/usr/include/blockdev/$header.h"
            done
            python3 - "$source/configure" "$source/src/udisksdaemon.c" "$source/data/Makefile.in" <<'PY'
from pathlib import Path
import sys

configure, daemon, data_makefile = map(Path, sys.argv[1:])
text = configure.read_text()
# Repair a literal escaped newline left by an earlier interrupted recipe run.
text = text.replace(r"\n  fi", "\n  fi")
for feature in ("MDRAID", "CRYPTO", "NVMe"):
    marker = f"support requested but header or library not found"
    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if marker in line and f"BLOCKDEV {feature}" in line:
            lines[i] = "    : # optional libblockdev plugin omitted in this profile\n"
    text = "".join(lines)
configure.write_text(text)

# The policy file is already English XML; msgfmt's optional ITS rules are not
# available on all build hosts, so copy the untranslated template directly.
text = data_makefile.read_text()
text = text.replace(
    "$(AM_V_GEN) $(MSGFMT) --xml --template $< -d $(top_srcdir)/po -o $@",
    "cp $< $@",
)
data_makefile.write_text(text)

text = daemon.read_text()
old = """  BDPluginSpec mdraid_plugin = {BD_PLUGIN_MDRAID, NULL};
  BDPluginSpec fs_plugin = {BD_PLUGIN_FS, NULL};
  BDPluginSpec crypto_plugin = {BD_PLUGIN_CRYPTO, NULL};
  BDPluginSpec nvme_plugin = {BD_PLUGIN_NVME, NULL};

  /* The core daemon needs the part, swap, loop, mdraid, fs and crypto plugins.
     Additional plugins are required by various modules, but they make sure
     plugins are loaded themselves. */
  BDPluginSpec *plugins[] = {&part_plugin, &swap_plugin, &loop_plugin, &mdraid_plugin,
                             &fs_plugin, &crypto_plugin, &nvme_plugin, NULL};"""
new = """  BDPluginSpec fs_plugin = {BD_PLUGIN_FS, NULL};

  /* This profile includes the core partition, swap, loop, and filesystem plugins. */
  BDPluginSpec *plugins[] = {&part_plugin, &swap_plugin, &loop_plugin, &fs_plugin, NULL};"""
if old in text:
    daemon.write_text(text.replace(old, new, 1))
elif new not in text:
    raise SystemExit("Could not patch UDisks libblockdev plugin set")
PY
            autotools udisks --disable-static --disable-man --disable-gtk-doc \
                --enable-introspection=no --disable-dependency-tracking \
                --disable-btrfs --disable-lvm2 --disable-iscsi --disable-lsm \
                --with-systemdsystemunitdir=/usr/lib/systemd/system ;;
        libusb) autotools libusb --disable-static --disable-udev ;;
        libgudev) desktop_meson libgudev -Dintrospection=disabled -Dtests=disabled ;;
        upower)
            source=$(unpack upower)
            cat > "$source/policy/meson.build" <<'UPower_POLICY'
if polkit.found()
  configure_file(
    input: 'org.freedesktop.upower.policy.in',
    output: 'org.freedesktop.upower.policy',
    copy: true,
    install: true,
    install_dir: join_paths(datadir, 'polkit-1', 'actions'),
  )
endif
UPower_POLICY
            desktop_meson upower -Dman=false -Dgtk-doc=false -Dintrospection=disabled \
                -Dos_backend=linux -Didevice=disabled -Dpolkit=enabled \
                -Dsystemdsystemunitdir=/usr/lib/systemd/system -Dzshcompletiondir=no ;;
        libsecret) desktop_meson libsecret -Dcrypto=disabled -Dmanpage=false -Dvapi=false \
            -Dgtk_doc=false -Dintrospection=disabled -Dtests=false ;;
        mate-control-center)
            source=$(unpack mate-control-center)
            python3 - "$source/configure.ac" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
start = text.find('AS_IF([test "x$enable_appindicator" = xyes],')
end = text.find('\nhave_systemd=no', start)
if start >= 0 and end > start:
    text = text[:start] + 'APPINDICATOR_CFLAGS=""\nAPPINDICATOR_LIBS=""\n' + text[end:]
elif 'APPINDICATOR_CFLAGS=""' not in text:
    raise SystemExit('Could not disable optional MATE appindicator dependency')
path.write_text(text)
PY
            ( cd "$source"; autoconf )
            ac_cv_func_XScreenSaverQueryInfo=no \
            ac_cv_lib_Xss_XScreenSaverQueryInfo=no \
            ac_cv_lib_Xext_XScreenSaverQueryInfo=no \
            autotools mate-control-center --disable-static \
                --disable-gtk-doc --without-accountsservice --disable-systemd \
                ;;
        mate-power-manager)
            source=$(unpack mate-power-manager)
            # This distro provides systemd or elogind, never ConsoleKit.
            # Skip MATE's obsolete ConsoleKit D-Bus probe unconditionally.
            python3 - "$source/src/egg-console-kit.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
needle = '\tconsole->priv->session_id = NULL;\n'
replacement = needle + '\n\t/* DIY Linux uses systemd or elogind; ConsoleKit is not installed. */\n\tgoto out;\n'
if 'DIY Linux uses systemd or elogind' not in text:
    if needle not in text:
        raise SystemExit('Could not locate MATE ConsoleKit initialization')
    text = text.replace(needle, replacement, 1)
path.write_text(text)
PY
            # Bus/polkit denials for optional power actions must not terminate
            # the power daemon. Report them as warnings and keep other controls.
            python3 - "$source/src" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
for path in src.glob('*.c'):
    text = path.read_text()
    text = text.replace('g_error ("Error in dbus - %s", error->message);',
                        'g_warning ("Power-management D-Bus request denied: %s", error->message);')
    text = text.replace('g_error ("Error connecting to dbus - %s", error->message);',
                        'g_warning ("Power-management D-Bus connection failed: %s", error->message);')
    path.write_text(text)
PY
            python3 - "$source/policy/Makefile.in" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    '$(AM_V_GEN) $(MSGFMT) --xml --template $< -d $(top_srcdir)/po -o $@',
    'cp $< $@',
)
path.write_text(text)
PY
            autotools mate-power-manager --disable-static \
                --disable-gtk-doc --without-keyring --with-libsecret ;;
        iso-codes) desktop_meson iso-codes ;;
        libmateweather) autotools libmateweather --disable-static --disable-introspection --disable-gtk-doc ;;
        mate-common)
            source=$(unpack mate-common)
            mkdir -p "$BUILD/mate-common"
            (cd "$BUILD/mate-common"; "$source/configure" --prefix=/usr --sysconfdir=/etc; make -j"$JOBS"; make DESTDIR="$ROOT" install) ;;
        # Icon-naming-utils only generates compatibility aliases; all MATE
        # icon assets are still installed without those host-side symlinks.
        mate-icon-theme) autotools mate-icon-theme --disable-icon-cache-update --disable-icon-mapping ;;
        mate-desktop) autotools mate-desktop --disable-static --disable-introspection --disable-startup-notification --disable-gtk-doc ;;
        mate-menus) autotools mate-menus --disable-static --disable-introspection --disable-gtk-doc ;;
        marco) autotools marco --disable-static --disable-introspection --disable-startup-notification --disable-gtk-doc ;;
        mate-session-manager)
            source=$(unpack mate-session-manager)
            # MATE otherwise falls back to ConsoleKit when it is built without
            # systemd, repeatedly querying a service that this distro does not
            # run. elogind provides the compatible logind API for every
            # non-systemd init profile.
            # MATE's LOGIND_RUNNING() only checks /run/systemd/seats/. That
            # directory can appear after the session starts, so a fast login
            # may incorrectly select ConsoleKit and emit D-Bus permission
            # errors. In elogind builds, select the compatible logind path
            # unconditionally; elogind is a required service for this profile.
            if [[ "$INIT_CHOICE" != systemd ]]; then
                python3 - "$source/mate-session/gsm-systemd.h" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
needle = '#define LOGIND_RUNNING() (access("/run/systemd/seats/", F_OK) >= 0)'
replacement = '''#ifdef HAVE_ELOGIND
#define LOGIND_RUNNING() (1)
#else
#define LOGIND_RUNNING() (access("/run/systemd/seats/", F_OK) >= 0)
#endif'''
if replacement not in text:
    if needle not in text:
        raise SystemExit('Could not locate MATE logind runtime check')
    path.write_text(text.replace(needle, replacement, 1))
PY
            fi
            if [[ "$INIT_CHOICE" == systemd ]]; then
                autotools mate-session-manager --disable-static --disable-introspection --disable-gtk-doc
            else
                autotools mate-session-manager --disable-static --disable-introspection --disable-gtk-doc --with-elogind
            fi ;;
        libxklavier) autotools libxklavier --disable-static --disable-introspection --disable-gtk-doc \
            --with-xkb-base=/usr/share/X11/xkb --with-xkb-bin-base=/usr/bin \
            --with-xkb-default-ruleset=evdev ;;
        libmatekbd) autotools libmatekbd --disable-static --disable-introspection --disable-gtk-doc ;;
        mate-settings-daemon)
            # GNU gettext's host installation may not ship PolicyKit's ITS
            # rules. polkit installs them into the target rootfs, so direct
            # msgfmt to that data directory while generating the policy XML.
            (export GETTEXTDATADIR="$ROOT/usr/share/gettext"
             autotools mate-settings-daemon --disable-static --disable-introspection --disable-gtk-doc --disable-smartcard-support) ;;
        lz4)
            source=$(unpack lz4)
            make -C "$source" -j"$JOBS" CC="$CC" AR="$AR" RANLIB="$RANLIB"
            make -C "$source" CC="$CC" AR="$AR" RANLIB="$RANLIB" PREFIX=/usr DESTDIR="$ROOT" install ;;
        # GMP 6.3.0 compiler probes use old-style void f() declarations.
        # GCC 16 defaults to C23, where these mean "no parameters" and the
        # probes reject a working compiler. Keep this package in GNU C17 mode.
        gmp)
            local -a gmp_flags=(
                --enable-shared     # Kurti bendrąją .so biblioteką.
                --disable-static    # Nekurti statinio .a archyvo.
                --disable-cxx       # Praleisti neprivalomą C++ wrapper.
                # --enable-static # Papildomai kurti .a bibliotekas.
                # --enable-cxx    # Kurti GMP C++ wrapper sąsają.
                # --disable-shared # Vietoj .so kurti tik statines bibliotekas.
            )
            CFLAGS="${CFLAGS:-} -std=gnu17" autotools gmp "${gmp_flags[@]}" ;;
        nettle)
            local -a nettle_flags=(
                --enable-shared         # Kurti bendrąją .so biblioteką.
                --disable-static        # Nekurti statinio .a archyvo.
                --disable-documentation # Neįtraukti dokumentacijos.
                # --enable-static # Papildomai kurti .a bibliotekas.
                # --disable-shared # Kurti tik statines bibliotekas.
                # --enable-documentation # Kurti Nettle dokumentaciją.
            )
            autotools nettle "${nettle_flags[@]}" ;;
        gnutls)
            local -a gnutls_flags=(
                --enable-shared             # Kurti bendrąją TLS .so biblioteką.
                --disable-static            # Nekurti statinio .a archyvo.
                --disable-doc               # Praleisti dokumentaciją.
                --disable-tests             # Nestatyti testų.
                --disable-tools             # Praleisti papildomas GnuTLS CLI programas.
                --disable-cxx              # Neįtraukti C++ bindings.
                --disable-nls               # Praleisti vertimų katalogus.
                --disable-libdane           # Išjungti DNSSEC/DANE integraciją.
                --with-included-libtasn1    # Naudoti archyve esantį libtasn1 šaltinį.
                --with-included-unistring   # Naudoti archyve esantį libunistring šaltinį.
                --without-p11-kit           # Nenaudoti PKCS#11 p11-kit integracijos.
                --without-tpm               # Nenaudoti TPM palaikymo.
                --without-zlib              # Nepridėti zlib priklausomybės.
                # --enable-tools # Įtraukti papildomas GnuTLS komandų eilutės programas.
                # --enable-tests # Kurti GnuTLS testų rinkinį.
                # --enable-libdane # Įtraukti DNSSEC/DANE tikrinimą.
                # --with-p11-kit # Įtraukti PKCS#11 raktų saugyklos palaikymą.
                # --with-tpm # Įtraukti TPM kriptografijos palaikymą.
                # --with-zlib # Įtraukti zlib suspaudimą.
            )
            autotools gnutls "${gnutls_flags[@]}" ;;
        mate-panel)
            local -a mate_panel_flags=(
                --disable-static         # Nekurti statinės .a bibliotekos.
                --disable-introspection  # Negeneruoti GIR/typelib metaduomenų.
                --disable-gtk-doc        # Negeneruoti GTK API dokumentacijos.
                # --enable-introspection # Generuoti GIR/typelib sąsają programavimo įrankiams.
                # --enable-gtk-doc # Kurti GTK API dokumentaciją.
            )
            autotools mate-panel "${mate_panel_flags[@]}" ;;
        caja)
            local -a caja_flags=(
                --disable-static         # Nekurti statinės .a bibliotekos.
                --disable-introspection  # Negeneruoti GIR/typelib metaduomenų.
                --disable-gtk-doc        # Negeneruoti GTK API dokumentacijos.
                --disable-exif           # Išjungti paveikslų EXIF metaduomenų palaikymą.
                --disable-gvfs           # Išjungti GVFS nuotolinių/virtualių FS integraciją.
                # --enable-exif # Įtraukti nuotraukų EXIF metaduomenų skaitymą.
                # --enable-gvfs # Įtraukti GVFS virtualių ir nuotolinių vietų palaikymą.
                # --enable-introspection # Generuoti Caja GIR/typelib metaduomenis.
            )
            # Caja 1.28 connects the X11 middle-click handler to its wrapper
            # FMDesktopIconView, but the signal belongs to CajaIconContainer.
            # Connect the actual signal owner to avoid a GLib critical at run time.
            source=$(unpack caja)
            python3 - "$source/src/file-manager/fm-desktop-icon-view.c" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = 'g_signal_connect_object (desktop_icon_view, "middle_click",'
new = 'g_signal_connect_object (icon_container, "middle_click",'
if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit('Could not find Caja middle_click signal connection')
path.write_text(text)
PY
            autotools caja "${caja_flags[@]}" ;;
        mate-notification-daemon)
            local -a notification_flags=(
                --disable-static         # Nekurti statinės .a bibliotekos.
                --disable-introspection  # Negeneruoti GIR/typelib metaduomenų.
                --disable-gtk-doc        # Negeneruoti GTK API dokumentacijos.
                # --enable-introspection # Generuoti D-Bus/GTK introspection sąsają.
                # --enable-gtk-doc # Kurti GTK API dokumentaciją.
            )
            autotools mate-notification-daemon "${notification_flags[@]}" ;;
        gtksourceview4)
            local -a gtksourceview_flags=(
                -Dgtk_doc=false # Praleisti GTK API dokumentaciją.
                -Dvapi=false    # Negeneruoti Vala sąsajos.
                -Dgir=false     # Negeneruoti GObject introspection metaduomenų.
            )
            desktop_meson gtksourceview4 "${gtksourceview_flags[@]}" ;;
        gobject-introspection)
            source=$(unpack gobject-introspection)
            # Build the scanner when MATE's optional Pluma/EOM apps need
            # runtime typelibs; otherwise retain the lean C-library-only build.
            python3 - "$source/meson.build" "$(python3 -c 'import os, sysconfig; print(os.path.dirname(sysconfig.get_path("include")))')" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
python_include_root = sys.argv[2]
text = path.read_text()
old_check = "# python headers\ncc.check_header('Python.h', dependencies: [python.dependency()], required: true)"
new_check = "# python headers\nif get_option('build_introspection_data')\n  cc.check_header('Python.h', dependencies: [python.dependency()], args: ['-I" + python_include_root + "'], required: true)\nendif"
if old_check in text:
    text = text.replace(old_check, new_check, 1)
else:
    old_patched_check = "  cc.check_header('Python.h', dependencies: [python.dependency()], required: true)"
    patched_check = "  cc.check_header('Python.h', dependencies: [python.dependency()], args: ['-I" + python_include_root + "'], required: true)"
    if old_patched_check in text:
        text = text.replace(old_patched_check, patched_check, 1)
    elif patched_check not in text:
        raise SystemExit('Python.h check pattern was not found')
    new_check = "# python headers\nif get_option('build_introspection_data')\n" + patched_check + "\nendif"
    if new_check not in text and patched_check not in text:
        raise SystemExit('Python.h include path patch did not apply')
if new_check not in text:
    raise SystemExit('Python.h check pattern was not found')
old_subdir = "subdir('giscanner')"
new_subdir = "if get_option('build_introspection_data')\n  subdir('giscanner')\nendif"
if old_subdir in text:
    text = text.replace(old_subdir, new_subdir, 1)
elif new_subdir not in text:
    raise SystemExit('giscanner subdirectory pattern was not found')
path.write_text(text)
PY
            local gi_data=false
            local python_include_root
            [[ "$DESKTOP_CHOICE" != mate || ${PKG_EOM:-no} != yes ]] || gi_data=true
            python_include_root=$(python3 -c 'import os, sysconfig; print(os.path.dirname(sysconfig.get_path("include")))')
            desktop_meson gobject-introspection -Dbuild_introspection_data="$gi_data" \
                -Ddoctool=disabled -Dgtk_doc=false -Dcairo=disabled \
                "-Dc_args=-I$python_include_root"
            if [[ "$gi_data" == true ]]; then
                # GLib and GObject GIR files are deliberately not part of
                # gobject-introspection's normal install set. Downstream
                # libpeas/EOM need them to generate their own introspection
                # data, and EOM needs the typelibs at runtime as well.
                ninja -C "$BUILD/gobject-introspection" -j"$JOBS" \
                    gir/GModule-2.0.typelib gir/Gio-2.0.typelib \
                    gir/GLib-2.0.typelib gir/GObject-2.0.typelib
                local typelib
                for typelib in GLib-2.0 GObject-2.0 GModule-2.0 Gio-2.0; do
                    install -Dm0644 "$BUILD/gobject-introspection/gir/$typelib.gir" \
                        "$ROOT/usr/share/gir-1.0/$typelib.gir"
                    install -Dm0644 "$BUILD/gobject-introspection/gir/$typelib.typelib" \
                        "$ROOT/usr/lib/girepository-1.0/$typelib.typelib"
                done
            fi ;;
        libpeas)
            source=$(unpack libpeas)
            # libpeas 1.36 probes gobject-introspection unconditionally even
            # when its introspection option is disabled; make the probe match
            # that option so a lean cross build does not need a host scanner.
            sed -i "s/introspection_dep = dependency('gobject-introspection-1.0', version: introspection_req)/introspection_dep = dependency('gobject-introspection-1.0', version: introspection_req, required: get_option('introspection'))/" "$source/meson.build"
            grep -Fq "introspection_dep = dependency('gobject-introspection-1.0', version: introspection_req, required: get_option('introspection'))" "$source/meson.build" || die 'Could not make libpeas introspection optional'
            # EOM's core viewer works without language-plugin introspection;
            # building that optional GIR requires executing target-linked
            # helper binaries during this cross build. Keep C plugin support.
            desktop_meson libpeas -Dgtk_doc=false -Dvapi=false -Dintrospection=false -Dpython3=false -Dlua51=false ;;
        pluma) autotools pluma --disable-static --disable-introspection --disable-gtk-doc --disable-spell ;;
        engrampa) autotools engrampa --disable-static --disable-introspection --disable-gtk-doc --disable-packagekit --disable-caja-actions ;;
        libexif) autotools libexif --disable-static ;;
        # EOM 1.28.1 moved its release archive to GitHub and switched from
        # Autotools to Meson. Its former MATE mirror URL returns HTTP 404.
        eom) desktop_meson eom -Dintrospection=disabled ;;
        xterm) autotools xterm --disable-setuid --disable-setgid --disable-luit --disable-imake --with-app-defaults=/etc/X11/app-defaults ;;
        *) die "$(tr_text "No graphics recipe yet: $name" "Dar nėra grafikos recepto: $name")" ;;
    esac
}

# Nginx and PHP-FPM are system services, independent of any graphical desktop.
# Optional libraries are built from the same pinned source manifest as the
# desktop recipes, then all server programs are cross-compiled for TARGET.
web_stack() {
    [[ "$PKG_NGINX" == yes || "$PKG_PHP" == yes ]] || return 0
    local name source nginx_runner
    for name in zlib pcre2; do
        case "$name" in
            zlib) [[ -e "$ROOT/usr/lib/libz.so" ]] || desktop_package zlib ;;
            pcre2) [[ -e "$ROOT/usr/lib/libpcre2-8.so" ]] || desktop_package pcre2 ;;
        esac
    done
    if [[ "$PKG_PHP" == yes ]]; then
        [[ -e "$ROOT/usr/lib/libxml2.so" ]] || desktop_package libxml2
        [[ -e "$ROOT/usr/lib/libsqlite3.so" ]] || desktop_package sqlite
    fi
    # Nginx TLS and PHP's OpenSSL extension use the target OpenSSL libraries.
    download_tls
    if [[ "$PKG_NGINX" == yes ]]; then
        source=$(unpack nginx)
        # Nginx's Makefile keeps source prerequisites relative (src/core, etc.).
        # With --builddir that Makefile must still run from the source tree;
        # the external build directory is only the object/output directory.
        # Remove a failed partial tree so an old --builddir Makefile cannot be
        # reused after changing this recipe.
        rm -rf -- "$BUILD/nginx" "$source/objs"
        # Nginx configure compiles and runs small target probes (endianness,
        # sizeof and optional APIs). Run them against the target libc, through
        # qemu-user for a foreign CPU or the target loader for native x86_64.
        # This prevents failed host execution from silently guessing big-endian
        # or failing sizeof checks against the host's libc.
        nginx_runner="$BUILD/nginx-target-runner"
        if [[ -n "$EMULATOR" ]]; then
            cat > "$nginx_runner" <<EOF
#!/bin/sh
exec "$EMULATOR" -L "$ROOT" "\$@"
EOF
        else
            cat > "$nginx_runner" <<EOF
#!/bin/sh
exec "$ROOT$ELF_LOADER" --library-path "$ROOT/usr/lib:$ROOT/lib:$ROOT/lib64" "\$@"
EOF
        fi
        chmod 0755 "$nginx_runner"
        # Route every configure-time execution probe through the target runner.
        # Nginx's sizeof and byte-order probes invoke NGX_AUTOTEST directly.
        sed -i 's|/bin/sh -c \$NGX_AUTOTEST|"$NGX_TARGET_RUNNER" "$NGX_AUTOTEST"|g' "$source/auto/feature"
        sed -i 's|`\$NGX_AUTOTEST`|`"$NGX_TARGET_RUNNER" "$NGX_AUTOTEST"`|g' "$source/auto/types/sizeof"
        sed -i 's|if \$NGX_AUTOTEST |if "$NGX_TARGET_RUNNER" "$NGX_AUTOTEST" |g' "$source/auto/endianness"
        grep -Fq '"$NGX_TARGET_RUNNER" "$NGX_AUTOTEST"' "$source/auto/feature" ||
            die 'Could not install Nginx target feature-test runner'
        grep -Fq '"$NGX_TARGET_RUNNER" "$NGX_AUTOTEST"' "$source/auto/types/sizeof" ||
            die 'Could not install Nginx target sizeof runner'
        grep -Fq '"$NGX_TARGET_RUNNER" "$NGX_AUTOTEST"' "$source/auto/endianness" ||
            die 'Could not install Nginx target endianness runner'
        (cd "$source"
         NGX_TARGET_RUNNER="$nginx_runner" ./configure --crossbuild="Linux::$TARGET_ARCH" \
             --prefix=/usr --sbin-path=/usr/sbin/nginx \
             --modules-path=/usr/lib/nginx/modules --conf-path=/etc/nginx/nginx.conf \
             --pid-path=/run/nginx.pid --lock-path=/run/lock/nginx.lock \
             --error-log-path=/var/log/nginx/error.log --http-log-path=/var/log/nginx/access.log \
             --http-client-body-temp-path=/var/lib/nginx/client_temp \
             --http-proxy-temp-path=/var/lib/nginx/proxy_temp \
             --http-fastcgi-temp-path=/var/lib/nginx/fastcgi_temp \
             --user=nginx --group=nginx --with-cc="$CC" \
             --with-cc-opt="-I$ROOT/usr/include -I$SDK/sysroot/usr/include" \
             --with-ld-opt="-L$ROOT/usr/lib -Wl,-rpath-link,$ROOT/usr/lib" \
             --with-http_ssl_module --with-http_v2_module --with-http_gzip_static_module \
             --with-http_stub_status_module --with-pcre --with-pcre-jit
         make -j"$JOBS"
         make DESTDIR="$ROOT" install)
    fi
    if [[ "$PKG_PHP" == yes ]]; then
        source=$(unpack php)
        mkdir -p "$BUILD/php"
        (cd "$BUILD/php"
         export CPPFLAGS="${CPPFLAGS:-} -I$ROOT/usr/include -I$SDK/sysroot/usr/include"
         export LDFLAGS="${LDFLAGS:-} -L$ROOT/usr/lib -Wl,-rpath-link,$ROOT/usr/lib"
         "$source/configure" --build="$HOST" --host="$TARGET" --prefix=/usr \
             --sysconfdir=/etc --localstatedir=/var --with-config-file-path=/etc \
             --with-config-file-scan-dir=/etc/php.d --disable-all --enable-cli --enable-pdo \
             --disable-cgi --disable-phpdbg --enable-fpm --with-fpm-user=nginx \
             --with-fpm-group=nginx --with-openssl --with-zlib --with-libxml \
             --with-sqlite3="$ROOT/usr" --with-pdo-sqlite="$ROOT/usr" --without-pear
         make -j"$JOBS"
         # PHP's makefiles use INSTALL_ROOT rather than GNU DESTDIR. Pass both
         # variables defensively: INSTALL_ROOT prefixes PHP's absolute paths,
         # while DESTDIR protects any subordinate install rule that honors
         # the GNU convention. Never let PHP's libtool install touch host /usr.
         make INSTALL_ROOT="$ROOT" DESTDIR="$ROOT" install
         install -Dm0644 "$source/php.ini-production" "$ROOT/etc/php.ini")
    fi
}

desktop_firmware() {
    # Console-only network profiles do not pass through desktop_base_packages,
    # but the kernel's signed-regdb configuration needs its database and key
    # certificate before kernel configuration starts.
    if [[ "$NETWORK" == yes && "$DESKTOP_CHOICE" == none ]]; then
        desktop_package wireless-regdb
    fi
    [[ "$NETWORK" == yes || "$DESKTOP_CHOICE" != none ]] || return 0
    desktop_package linux-firmware
}

graphical_desktop() {
    [[ "$DESKTOP_CHOICE" == mate || "$DESKTOP_CHOICE" == lxde || "$DESKTOP_CHOICE" == fluxbox ]] || return 0
    local -x PATH="$PATH" LDFLAGS="${LDFLAGS:-}" PYTHONPATH="${PYTHONPATH:-}" ACLOCAL_PATH="${ACLOCAL_PATH:-}"
    local -x xorg_cv_malloc0_returns_null=no
    export LDFLAGS="${LDFLAGS:-} -Wl,-rpath-link,$ROOT/usr/lib"
    local archive name python_dir mate_needs_gi=no
    if [[ "$DESKTOP_CHOICE" == mate ]] &&
       printf '%s\n' "$(mate_packages)" | grep -qx gobject-introspection; then
        mate_needs_gi=yes
    fi
    for archive in libdl.a libpthread.a librt.a libutil.a; do
        [[ ! -f "$SDK/sysroot/usr/lib/$archive" ]] || cp "$SDK/sysroot/usr/lib/$archive" "$ROOT/usr/lib/"
    done
    desktop_host_tools
    for name in $(desktop_base_packages); do
        local stage="desktop-$name-v1"
        case "$name" in
            eudev) stage=desktop-eudev-v2 ;;
            gobject-introspection) stage=desktop-gobject-introspection-v4 ;;
            sound-mixer) stage=desktop-sound-mixer-v2 ;;
        esac
        step "$stage" desktop_package "$name"
        remove_installed_libtool_archives
        desktop_host_tools
        if [[ "$name" == xcb-proto ]]; then
            python_dir=$(find "$ROOT/usr/lib" -type d -name site-packages -print -quit)
            export PYTHONPATH="$python_dir${PYTHONPATH:+:$PYTHONPATH}"
        fi
        export ACLOCAL_PATH="$ROOT/usr/share/aclocal"
    done
    [[ "$mate_needs_gi" != yes ]] || desktop_prepare_gi_cross_tools
    local -a desktop_app_packages=()
    case "$DESKTOP_CHOICE" in
        mate) read -r -a desktop_app_packages <<< "$(mate_packages | tr '\n' ' ')" ;;
        lxde) read -r -a desktop_app_packages <<< "$(lxde_packages | tr '\n' ' ')" ;;
        fluxbox) read -r -a desktop_app_packages <<< "$(fluxbox_packages | tr '\n' ' ')" ;;
    esac
    for name in "${desktop_app_packages[@]}"; do
        local stage="desktop-$name-v1"
        [[ "$name" != gobject-introspection ]] || stage=desktop-gobject-introspection-v4
        [[ "$name" != mate-session-manager ]] || stage=desktop-mate-session-manager-v4
        [[ "$name" != mate-settings-daemon ]] || stage=desktop-mate-settings-daemon-v3
        [[ "$name" != mate-power-manager ]] || stage=desktop-mate-power-manager-v2
        [[ "$name" != caja ]] || stage=desktop-caja-v2
        # Avoid reusing libxklavier artifacts that embed the build-root XKB path.
        [[ "$name" != libxklavier ]] || stage=desktop-libxklavier-v2
        step "$stage" desktop_package "$name"
        find "$ROOT/usr/lib" -name '*.la' -type f -delete
        desktop_host_tools
    done
}

configure_desktop_init_services() {
    local unit_dir="$ROOT/etc/systemd/system"
    local needs_desktop_auth=no
    local upower_enabled=no
    [[ ${DESKTOP_CHOICE:-none} != mate && \
       ${PKG_MATE_CONTROL_CENTER:-no} != yes && \
       ${PKG_MATE_POWER_MANAGER:-no} != yes ]] || needs_desktop_auth=yes
    [[ ${DESKTOP_CHOICE:-none} != mate && ${PKG_FIREFOX:-no} != yes ]] || upower_enabled=yes
    mkdir -p "$ROOT/usr/libexec"
    cat > "$ROOT/usr/libexec/diy-mount-devpts" <<'DEVPTS'
#!/bin/sh
# XTerm and other terminals need Unix98 PTYs available before X starts.
mkdir -p /dev/pts || exit 1
if ! grep -q ' /dev/pts devpts ' /proc/mounts; then
    tty_gid=$(sed -n 's/^tty:[^:]*:\([0-9][0-9]*\):.*/\1/p' /etc/group | sed -n '1p')
    case "$tty_gid" in ''|*[!0-9]*) tty_gid=5 ;; esac
    mount -t devpts devpts /dev/pts -o gid="$tty_gid",mode=0620,ptmxmode=0666,nosuid,noexec || exit 1
fi
if [ -e /dev/pts/ptmx ]; then
    ln -snf pts/ptmx /dev/ptmx || exit 1
fi
DEVPTS
    chmod 0755 "$ROOT/usr/libexec/diy-mount-devpts"
    cat > "$ROOT/usr/libexec/diy-desktop-cache" <<'CACHE'
#!/bin/sh
mkdir -p /run/dbus /tmp/.X11-unix /tmp/.ICE-unix
chmod 1777 /tmp/.X11-unix /tmp/.ICE-unix
/usr/bin/dbus-uuidgen --ensure=/etc/machine-id
# These caches are image-wide and do not need a forced rebuild on every boot.
# The first pass runs in the background; later boots only do the cheap setup above.
cache_stamp=/var/cache/diy-desktop-cache.complete
[ -e "$cache_stamp" ] && exit 0
mkdir -p /var/cache
failed=no
if [ -d /usr/share/glib-2.0/schemas ] && [ ! -s /usr/share/glib-2.0/schemas/gschemas.compiled ]; then
    /usr/bin/glib-compile-schemas /usr/share/glib-2.0/schemas || failed=yes
fi
if [ -x /usr/bin/gdk-pixbuf-query-loaders ] && [ ! -s /usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache ]; then
    /usr/bin/gdk-pixbuf-query-loaders --update-cache || failed=yes
fi
if [ -x /usr/bin/gtk-query-immodules-3.0 ] && [ ! -s /usr/lib/gtk-3.0/3.0.0/immodules.cache ]; then
    /usr/bin/gtk-query-immodules-3.0 --update-cache || failed=yes
fi
if [ -d /usr/share/mime ] && [ ! -s /usr/share/mime/mime.cache ]; then
    /usr/bin/update-mime-database /usr/share/mime || failed=yes
fi
if [ -d /usr/share/applications ] && [ ! -s /usr/share/applications/mimeinfo.cache ]; then
    /usr/bin/update-desktop-database /usr/share/applications || failed=yes
fi
if ! find /var/cache/fontconfig -type f -name '*.cache-*' -print -quit 2>/dev/null | grep -q .; then
    /usr/bin/fc-cache -s || failed=yes
fi
[ "$failed" = yes ] || : > "$cache_stamp"
CACHE
    chmod 0755 "$ROOT/usr/libexec/diy-desktop-cache"
    case "$INIT_CHOICE" in
        openrc)
            cat > "$ROOT/etc/init.d/diy-udev" <<'UDEV'
#!/sbin/openrc-run
command=/usr/sbin/udevd
command_args="--daemon"
pidfile=/run/udev/udevd.pid
depend() { need devfs; before diy-dbus; }
start() {
    ebegin "Detecting graphics, input and network devices"
    /usr/libexec/diy-mount-devpts || return 1
    mkdir -p /run/udev
    /usr/sbin/udevd --daemon || return 1
    /usr/bin/udevadm trigger --type=subsystems --action=add
    /usr/bin/udevadm trigger --type=devices --action=add
    /usr/bin/udevadm settle --timeout=15
    command -v modprobe >/dev/null 2>&1 && modprobe mt7921e || :
    eend $?
}
stop() { /usr/bin/udevadm control --exit; }
UDEV
            cat > "$ROOT/etc/init.d/diy-dbus" <<'DBUS'
#!/sbin/openrc-run
supervisor=supervise-daemon
command=/usr/bin/dbus-daemon
command_args_foreground="--system --nofork --nopidfile"
pidfile=/run/diy-dbus.pid
depend() { need localmount; after diy-udev; }
start_pre() {
    checkpath --directory --mode 0755 /run/dbus
    checkpath --directory --mode 1777 /tmp/.X11-unix /tmp/.ICE-unix
    /usr/libexec/diy-desktop-cache >/var/log/diy-desktop-cache.log 2>&1 </dev/null &
}
DBUS
            cat > "$ROOT/etc/init.d/diy-alsa" <<'ALSA'
#!/sbin/openrc-run
description="Restore ALSA mixer levels"
depend() { need localmount; after modules; }
start() {
    ebegin "Restoring ALSA mixer levels"
    /usr/sbin/alsactl restore 2>/dev/null || /usr/sbin/alsactl init 2>/dev/null || :
    eend 0
}
ALSA
            chmod 0755 "$ROOT/etc/init.d/diy-udev" "$ROOT/etc/init.d/diy-dbus" "$ROOT/etc/init.d/diy-alsa"
            ln -snf /etc/init.d/diy-udev "$ROOT/etc/runlevels/boot/diy-udev"
            ln -snf /etc/init.d/diy-dbus "$ROOT/etc/runlevels/default/diy-dbus"
            ln -snf /etc/init.d/diy-alsa "$ROOT/etc/runlevels/default/diy-alsa"
            if desktop_needs_logind && [[ "$INIT_CHOICE" != systemd ]]; then
                cat > "$ROOT/etc/init.d/elogind" <<'ELOGIND_SERVICE'
#!/sbin/openrc-run
description="Login/session tracking daemon for desktop authorization"
command=/usr/libexec/elogind
command_background=yes
pidfile=/run/elogind.pid
depend() { need diy-dbus diy-udev; }
ELOGIND_SERVICE
                chmod 0755 "$ROOT/etc/init.d/elogind"
                ln -snf /etc/init.d/elogind "$ROOT/etc/runlevels/default/elogind"
            fi
            if [[ "$needs_desktop_auth" == yes ]]; then
                cat > "$ROOT/etc/init.d/polkit" <<'POLKIT_SERVICE'
#!/sbin/openrc-run
description="PolicyKit authorization service"
command=/usr/lib/polkit-1/polkitd
command_args="--no-debug --log-level=notice"
command_background=yes
pidfile=/run/polkitd.pid
depend() { need diy-dbus elogind; }
start_pre() { mkdir -p /run/polkit-1 /var/lib/polkit-1; }
POLKIT_SERVICE
                chmod 0755 "$ROOT/etc/init.d/polkit"
                ln -snf /etc/init.d/polkit "$ROOT/etc/runlevels/default/polkit"
                if [[ ${PKG_MATE_CONTROL_CENTER:-no} == yes ]]; then
                    cat > "$ROOT/etc/init.d/udisks2" <<'UDISKS_SERVICE'
#!/sbin/openrc-run
description="UDisks storage management service"
command=/usr/libexec/udisks2/udisksd
command_background=yes
pidfile=/run/udisks2/udisksd.pid
depend() { need diy-dbus elogind polkit; }
start_pre() { mkdir -p /run/udisks2; }
UDISKS_SERVICE
                    chmod 0755 "$ROOT/etc/init.d/udisks2"
                    ln -snf /etc/init.d/udisks2 "$ROOT/etc/runlevels/default/udisks2"
                fi
            fi
            if [[ "$upower_enabled" == yes ]]; then
                cat > "$ROOT/etc/init.d/upower" <<'UPOWER_SERVICE'
#!/sbin/openrc-run
description="UPower system power and battery service"
command=/usr/libexec/upowerd
command_background=yes
pidfile=/run/upowerd.pid
depend() { need diy-dbus; }
start_pre() { mkdir -p /run/upower; }
UPOWER_SERVICE
                chmod 0755 "$ROOT/etc/init.d/upower"
                ln -snf /etc/init.d/upower "$ROOT/etc/runlevels/default/upower"
            fi
            if [[ "$NETWORK" == yes ]]; then
                cat > "$ROOT/etc/init.d/wpa_supplicant" <<'WPA_SUPPLICANT_SERVICE'
#!/sbin/openrc-run
description="WPA supplicant D-Bus service for NetworkManager"
supervisor=supervise-daemon
command=/usr/sbin/wpa_supplicant
command_args_foreground="-u -s"
pidfile=/run/wpa_supplicant.pid
depend() { need diy-dbus; after diy-udev; }
WPA_SUPPLICANT_SERVICE
                chmod 0755 "$ROOT/etc/init.d/wpa_supplicant"
                ln -snf /etc/init.d/wpa_supplicant "$ROOT/etc/runlevels/default/wpa_supplicant"
                cat > "$ROOT/etc/init.d/NetworkManager" <<'NETWORKMANAGER_SERVICE'
#!/sbin/openrc-run
description="NetworkManager (Ethernet and Wi-Fi)"
supervisor=supervise-daemon
command=/usr/sbin/NetworkManager
command_args_foreground="--no-daemon"
pidfile=/run/NetworkManager/NetworkManager.pid
depend() { need diy-dbus wpa_supplicant; after bootmisc; provide net; }
start_pre() {
    checkpath --directory --mode 0755 /run/NetworkManager
    /usr/sbin/rfkill unblock wlan 2>/dev/null || :
}
NETWORKMANAGER_SERVICE
                chmod 0755 "$ROOT/etc/init.d/NetworkManager"
                ln -snf /etc/init.d/NetworkManager "$ROOT/etc/runlevels/default/NetworkManager"
            fi
            ;;
        systemd)
            mkdir -p "$unit_dir" "$unit_dir/sysinit.target.wants" \
                "$unit_dir/multi-user.target.wants" "$unit_dir/sockets.target.wants"
            # Desktop profiles include eudev and use it instead of systemd-udevd.
            # Console-only profiles have no eudev package, so keep systemd's own
            # device manager and do not mask its units.
            if [[ -x "$ROOT/usr/sbin/udevd" ]]; then
                cat > "$unit_dir/diy-udev.service" <<'UNIT'
[Unit]
Description=DIY Linux device manager (eudev)
DefaultDependencies=no
After=systemd-sysusers.service
Before=sysinit.target

[Service]
Type=simple
ExecStartPre=/usr/bin/mkdir -p /run/udev
ExecStartPre=/usr/libexec/diy-mount-devpts
ExecStart=/usr/sbin/udevd
ExecStartPost=-/usr/bin/udevadm trigger --type=subsystems --action=add
ExecStartPost=-/usr/bin/udevadm trigger --type=devices --action=add
ExecStartPost=-/usr/bin/udevadm settle --timeout=10
TimeoutStartSec=20

[Install]
WantedBy=sysinit.target
UNIT
                local udev_unit
                for udev_unit in systemd-udevd.service systemd-udev-trigger.service \
                    systemd-udev-load-credentials.service systemd-udev-settle.service \
                    systemd-udevd-kernel.socket systemd-udevd-varlink.socket systemd-udevd-control.socket; do
                    ln -snf /dev/null "$unit_dir/$udev_unit"
                done
                ln -snf ../diy-udev.service "$unit_dir/sysinit.target.wants/diy-udev.service"
            fi
            cat > "$unit_dir/dbus.service" <<'UNIT'
[Unit]
Description=DIY Linux system D-Bus
After=local-fs.target
RequiresMountsFor=/run/dbus

[Service]
Type=simple
ExecStartPre=/usr/bin/mkdir -p /run/dbus
ExecStartPre=/usr/bin/dbus-uuidgen --ensure=/etc/machine-id
ExecStart=/usr/bin/dbus-daemon --system --nofork --nopidfile
ExecStartPost=/usr/bin/sh -c 'i=0; until /usr/bin/dbus-send --system --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames >/dev/null 2>&1; do i=$((i+1)); [ "$i" -lt 15 ] || exit 1; sleep 1; done'
ExecStartPost=-/usr/bin/sh -c '/usr/libexec/diy-desktop-cache >/var/log/diy-desktop-cache.log 2>&1 </dev/null &'
Restart=on-failure
TimeoutStartSec=25

[Install]
WantedBy=multi-user.target
UNIT
            cat > "$unit_dir/diy-alsa.service" <<'UNIT'
[Unit]
Description=Restore ALSA mixer levels
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/sh -c '/usr/sbin/alsactl restore 2>/dev/null || /usr/sbin/alsactl init 2>/dev/null || :'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
            rm -f "$unit_dir/dbus.socket" "$unit_dir/sockets.target.wants/dbus.socket"
            ln -snf ../dbus.service "$unit_dir/multi-user.target.wants/dbus.service"
            ln -snf ../diy-alsa.service "$unit_dir/multi-user.target.wants/diy-alsa.service"
            # systemd uses logind for local sessions even on console-only systems.
            ln -snf /usr/lib/systemd/system/systemd-logind.service "$unit_dir/multi-user.target.wants/systemd-logind.service"
            if [[ "$needs_desktop_auth" == yes ]]; then
                ln -snf /usr/lib/systemd/system/polkit.service "$unit_dir/multi-user.target.wants/polkit.service"
            fi
            if [[ ${PKG_MATE_CONTROL_CENTER:-no} == yes ]]; then
                ln -snf /usr/lib/systemd/system/udisks2.service "$unit_dir/multi-user.target.wants/udisks2.service"
            fi
            if [[ "$upower_enabled" == yes ]]; then
                ln -snf /usr/lib/systemd/system/upower.service "$unit_dir/multi-user.target.wants/upower.service"
            fi
            if [[ "$DESKTOP_CHOICE" == mate ]]; then
                # These desktop profiles are started manually from tty1; do not
                # wait for a serial getty that QEMU's VGA command does not use.
                ln -snf /dev/null "$unit_dir/serial-getty@ttyS0.service"
            fi
            if [[ "$NETWORK" == yes ]]; then
                cat > "$unit_dir/wpa_supplicant.service" <<'UNIT'
[Unit]
Description=WPA supplicant D-Bus service for NetworkManager
After=dbus.service diy-udev.service
Requires=dbus.service diy-udev.service

[Service]
Type=dbus
BusName=fi.w1.wpa_supplicant1
ExecStart=/usr/sbin/wpa_supplicant -u -s
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
                ln -snf ../wpa_supplicant.service "$unit_dir/multi-user.target.wants/wpa_supplicant.service"
                cat > "$unit_dir/NetworkManager.service" <<'UNIT'
[Unit]
Description=NetworkManager (Ethernet and Wi-Fi)
After=dbus.service diy-udev.service wpa_supplicant.service
Requires=dbus.service diy-udev.service wpa_supplicant.service

[Service]
Type=simple
ExecStartPre=/usr/bin/mkdir -p /run/NetworkManager
ExecStartPre=-/usr/sbin/rfkill unblock wlan
ExecStart=/usr/sbin/NetworkManager --no-daemon
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
                ln -snf ../NetworkManager.service "$unit_dir/multi-user.target.wants/NetworkManager.service"
            fi
            ;;
        *)
            # SysVinit, BusyBox init, runit, dinit and s6 all start through
            # /etc/diy/boot in this image; keep their desktop services in one
            # small POSIX-shell startup helper.
            cat > "$ROOT/usr/libexec/diy-desktop-boot" <<'BOOT'
#!/bin/sh
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
mkdir -p /run/udev /run/dbus /run/NetworkManager /tmp/.X11-unix /tmp/.ICE-unix
/usr/libexec/diy-mount-devpts || exit 1
/usr/sbin/udevd --daemon || exit 1
/usr/bin/udevadm trigger --type=subsystems --action=add
/usr/bin/udevadm trigger --type=devices --action=add
/usr/bin/udevadm settle --timeout=15
modprobe mt7921e 2>/dev/null || :
/usr/libexec/diy-desktop-cache >/var/log/diy-desktop-cache.log 2>&1 </dev/null &
/usr/bin/dbus-daemon --system --fork --nopidfile
/usr/sbin/alsactl restore 2>/dev/null || /usr/sbin/alsactl init 2>/dev/null || :
BOOT
            if desktop_needs_logind && [[ "$INIT_CHOICE" != systemd && "$INIT_CHOICE" != dinit ]]; then
                cat >> "$ROOT/usr/libexec/diy-desktop-boot" <<'BOOT_ELOGIND'
/usr/libexec/elogind --daemon
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    /usr/bin/dbus-send --system --dest=org.freedesktop.DBus / org.freedesktop.DBus.NameHasOwner string:org.freedesktop.login1 >/dev/null 2>&1 && break
    sleep 1
done
BOOT_ELOGIND
            fi
            if [[ "$needs_desktop_auth" == yes && "$INIT_CHOICE" != systemd && "$INIT_CHOICE" != dinit ]]; then
                cat >> "$ROOT/usr/libexec/diy-desktop-boot" <<'BOOT_POLKIT'
/usr/lib/polkit-1/polkitd --no-debug --log-level=notice >>/var/log/polkitd.log 2>&1 &
BOOT_POLKIT
                cat >> "$ROOT/usr/libexec/diy-desktop-boot" <<'BOOT_POLKIT_WAIT'
sleep 1
BOOT_POLKIT_WAIT
                if [[ ${PKG_MATE_CONTROL_CENTER:-no} == yes ]]; then
                    cat >> "$ROOT/usr/libexec/diy-desktop-boot" <<'BOOT_UDISKS'
mkdir -p /run/udisks2
/usr/libexec/udisks2/udisksd >>/var/log/udisks2.log 2>&1 &
BOOT_UDISKS
                fi
            fi
            if [[ "$upower_enabled" == yes && "$INIT_CHOICE" != systemd && "$INIT_CHOICE" != dinit ]]; then
                cat >> "$ROOT/usr/libexec/diy-desktop-boot" <<'BOOT_UPOWER'
mkdir -p /run/upower
/usr/libexec/upowerd >>/var/log/upowerd.log 2>&1 &
BOOT_UPOWER
            fi
            if [[ "$NETWORK" == yes ]]; then
                cat >> "$ROOT/usr/libexec/diy-desktop-boot" <<'BOOT_NETWORK'
/usr/sbin/rfkill unblock wlan 2>/dev/null || :
/usr/sbin/wpa_supplicant -u -B -s >>/var/log/wpa_supplicant.log 2>&1
sleep 1
/usr/sbin/NetworkManager --no-daemon >>/var/log/NetworkManager.log 2>&1 &
BOOT_NETWORK
            fi
            chmod 0755 "$ROOT/usr/libexec/diy-desktop-boot"
            printf '\n/usr/libexec/diy-desktop-boot\n' >> "$ROOT/etc/diy/boot"
            ;;
    esac
}

configure_graphical_runtime_accounts_locale() {
    # D-Bus system services and UTF-8 desktop sessions need these account and
    # locale records even when the selected desktop has no MATE components.
    grep -q '^messagebus:' "$ROOT/etc/passwd" ||
        printf 'messagebus:x:81:81:D-Bus:/var/lib/dbus:/bin/false\n' >> "$ROOT/etc/passwd"
    grep -q '^messagebus:' "$ROOT/etc/group" || printf 'messagebus:x:81:\n' >> "$ROOT/etc/group"
    ensure_dbus_launch_helper_mode
    # Compile GSettings schemas before a graphical login can race the
    # background cache job. MATE settings daemons otherwise receive NULL
    # string-vector settings and emit GLib g_strv_length criticals.
    if [[ ${DESKTOP_CHOICE:-none} == mate && -d "$ROOT/usr/share/glib-2.0/schemas" ]]; then
        [[ ! -x "$ROOT/usr/bin/glib-compile-schemas" ]] ||
            "$ROOT/usr/lib/${ELF_LOADER##*/}" --library-path "$ROOT/usr/lib" \
                "$ROOT/usr/bin/glib-compile-schemas" "$ROOT/usr/share/glib-2.0/schemas"
    fi
    local source
    source=$(unpack glibc)
    mkdir -p "$ROOT/usr/lib/locale"
    LC_ALL=C I18NPATH="$source/localedata" "$ROOT/usr/lib/${ELF_LOADER##*/}" \
        --library-path "$ROOT/usr/lib" "$ROOT/usr/bin/localedef" --no-archive \
        -i C -f "$source/localedata/charmaps/UTF-8" "$ROOT/usr/lib/locale/C.UTF-8"
}

ensure_dbus_launch_helper_mode() {
    local helper="$ROOT/usr/libexec/dbus-daemon-launch-helper"
    # D-Bus system activation requires root:messagebus mode 4750. fakeroot
    # applies the root owner and messagebus group when the image is packed.
    [[ ! -x "$helper" ]] || chmod 4750 "$helper"
}

configure_timezone() {
    local zoneinfo=/usr/share/zoneinfo
    [[ -r "$zoneinfo/Europe/Vilnius" ]] ||
        die "$(tr_text 'Host tzdata is missing Europe/Vilnius' 'Šeimininko tzdata pakete nėra Europe/Vilnius laiko juostos')"
    mkdir -p "$ROOT/usr/share/zoneinfo" "$ROOT/etc"
    cp -a "$zoneinfo/." "$ROOT/usr/share/zoneinfo/"
    printf '%s\n' 'Europe/Vilnius' > "$ROOT/etc/timezone"
    ln -sfn /usr/share/zoneinfo/Europe/Vilnius "$ROOT/etc/localtime"
}

normalize_lxpanel_tray_order() {
    local panel=$1 mode=${2:-0644} temporary
    [[ -f "$panel" ]] || return 0
    temporary=$(mktemp "${panel}.tray.XXXXXX") || return 1
    if ! awk '
        function braces(s, t, opens, closes) {
            t = s; opens = gsub(/[{]/, "", t)
            t = s; closes = gsub(/[}]/, "", t)
            return opens - closes
        }
        function save_plugin() {
            if (block ~ /type[[:space:]]*=[[:space:]]*tray/) { tray_block = block; return }
            # Keep only the terminal launcher that this profile installs.
            # Stock LXPanel profiles often refer to optional programs that
            # are deliberately absent from the image (for example Firefox).
            if (block ~ /type[[:space:]]*=[[:space:]]*launchbar/) {
                if (block ~ /id[[:space:]]*=[[:space:]]*xterm\.desktop/) launchbar_block = block
                return
            }
            # netstatus only opens an interface-properties dialog; it does not
            # manage Wi-Fi. NetworkManager nm-applet supplies the real menu
            # in this system tray, so discard the misleading netstatus icon.
            if (block ~ /type[[:space:]]*=[[:space:]]*netstatus/) return
            plugins[++plugin_count] = block
            if (!clock_index && block ~ /type[[:space:]]*=[[:space:]]*dclock/) clock_index = plugin_count
        }
        /^[[:space:]]*Plugin[[:space:]]*[{]/ {
            in_plugin = 1; block = $0 ORS; depth = braces($0)
            if (depth == 0) { save_plugin(); in_plugin = 0; block = "" }
            next
        }
        in_plugin {
            block = block $0 ORS; depth += braces($0)
            if (depth == 0) { save_plugin(); in_plugin = 0; block = "" }
            next
        }
        { print }
        END {
            if (block != "") save_plugin()
            if (tray_block == "") tray_block = "Plugin {\n    type=tray\n}\n\n"
            if (!clock_index) clock_index = plugin_count + 1
            for (i = 1; i <= plugin_count + 1; i++) {
                if (i == clock_index) {
                    printf "%s", tray_block
                }
                if (i <= plugin_count) printf "%s", plugins[i]
            }
            if (launchbar_block != "") printf "%s", launchbar_block
        }
    ' "$panel" > "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    chmod "$mode" "$temporary" && mv -f -- "$temporary" "$panel"
}

configure_pcmanfm_wallpaper() {
    local profile=${1:-LXDE} config
    [[ -n ${wallpaper_default_path:-} && -s "$ROOT$wallpaper_default_path" ]] || return 0
    config="$ROOT/etc/skel/.config/pcmanfm/$profile/desktop-items-0.conf"
    mkdir -p "${config%/*}" "$ROOT/etc/xdg/pcmanfm/$profile" \
        "$ROOT/home/$USER_NAME/.config/pcmanfm/$profile"
    {
        printf '[*]\nwallpaper=%s\n' "$wallpaper_default_path"
        cat <<'PCMANFM_WALLPAPER'
wallpaper_mode=stretch
desktop_bg=#101820
desktop_fg=#f5f7fa
desktop_shadow=#000000
show_wm_menu=1
sort=mtime;ascending;
PCMANFM_WALLPAPER
    } > "$config"
    install -m0644 "$config" "$ROOT/etc/xdg/pcmanfm/$profile/desktop-items-0.conf"
    install -m0600 "$config" "$ROOT/home/$USER_NAME/.config/pcmanfm/$profile/desktop-items-0.conf"
}

configure_fluxbox_menu() {
    local menu_file
    for menu_file in "$ROOT/usr/share/fluxbox/menu" "$ROOT/etc/skel/.fluxbox/menu" \
        "$ROOT/home/$USER_NAME/.fluxbox/menu"; do
        mkdir -p "${menu_file%/*}"
        {
            printf '[begin] (%s)\n' "$OS_NAME"
            printf '[exec] (Terminal — XTerm) {xterm}\n'
            [[ "$NETWORK" != yes ]] || printf '[exec] (Network settings) {nm-connection-editor}\n'
            printf '[exec] (Sound mixer) {xterm -e alsamixer}\n'
            [[ "$PKG_FIREFOX" != yes ]] || printf '[exec] (Firefox) {firefox}\n'
            printf '[separator]\n[config] (Fluxbox settings)\n[commanddialog] (Run command)\n[reconfig] (Reload menu)\n[restart] (Restart Fluxbox)\n[exit] (Log out)\n[end]\n'
        } > "$menu_file"
        chmod 0644 "$menu_file"
    done
}

configure_desktop() {
    [[ "$DESKTOP_CHOICE" != none ]] || return 0
    local desktop_session_name needs_desktop_auth=no
    [[ ${DESKTOP_CHOICE:-none} != mate && \
       ${PKG_MATE_CONTROL_CENTER:-no} != yes && \
       ${PKG_MATE_POWER_MANAGER:-no} != yes ]] || needs_desktop_auth=yes
    case "$DESKTOP_CHOICE" in mate) desktop_session_name=MATE ;; lxde) desktop_session_name=LXDE ;; esac
    if [[ "$DESKTOP_CHOICE" == mate ]]; then
        # Keep MATE's session defaults consistent with this minimal image:
        # no dock provider or gnome-keyring package is built, and the upstream
        # GTK/Macro defaults name the absent Menta theme. Atlanta and Adwaita
        # are included. Disable Marco compositing so MATE remains responsive
        # on systems without working 3D acceleration; Xorg glamor still handles
        # 2D acceleration independently.
        local mate_schema="$ROOT/usr/share/glib-2.0/schemas"
        if [[ -f "$mate_schema/org.mate.session.gschema.xml" ]]; then
            if [[ ${PKG_CAJA:-no} == yes ]]; then
                sed -i "/<key name=\"required-components-list\" type=\"as\">/,/<\\/key>/s|<default>.*</default>|<default>[ 'windowmanager', 'panel', 'filemanager' ]</default>|" \
                    "$mate_schema/org.mate.session.gschema.xml"
            else
                sed -i "/<key name=\"required-components-list\" type=\"as\">/,/<\\/key>/s|<default>.*</default>|<default>[ 'windowmanager', 'panel' ]</default>|" \
                    "$mate_schema/org.mate.session.gschema.xml"
            fi
            sed -i "s|<default>\[ 'keyring', 'smproxy' \]</default>|<default>[ 'smproxy' ]</default>|" \
                "$mate_schema/org.mate.session.gschema.xml"
        fi
        if [[ -f "$mate_schema/org.mate.interface.gschema.xml" ]]; then
            sed -i "s|<default>'Menta'</default>|<default>'Adwaita'</default>|" \
                "$mate_schema/org.mate.interface.gschema.xml"
        fi
        if [[ -f "$mate_schema/org.mate.marco.gschema.xml" ]]; then
            sed -i \
                -e "s|<default>'Menta'</default>|<default>'Atlanta'</default>|" \
                -e '/<key name="compositing-manager" type="b">/,/<\/key>/s|<default>true</default>|<default>false</default>|' \
                "$mate_schema/org.mate.marco.gschema.xml"
        fi
    fi
    if [[ -x "$ROOT/usr/bin/xterm" ]]; then
        mkdir -p "$ROOT/usr/share/applications"
        # xterm's compiled default XLFD may not be discoverable unless Xorg
        # has the bitmap-font directory in its server font path. Set the same
        # installed fixed font explicitly in the app-defaults file as well.
        if [[ -f "$ROOT/etc/X11/app-defaults/XTerm" ]]; then
            cat >> "$ROOT/etc/X11/app-defaults/XTerm" <<'XTERM_FIXED_FONT'

! Use the bundled X11 bitmap font explicitly; this avoids a missing-font
! failure when the X server was started without its default font path.
*VT100.font: -misc-fixed-medium-r-semicondensed--13-120-75-75-c-60-iso10646-1
XTERM_FIXED_FONT
        fi
        mkdir -p "$ROOT/usr/share/applications"
        cat > "$ROOT/usr/share/applications/xterm.desktop" <<'XTERM_DESKTOP'
[Desktop Entry]
Name=XTerm
GenericName=Terminal Emulator
Comment=Start an X terminal emulator
Exec=xterm
Icon=utilities-terminal
Terminal=false
Type=Application
Categories=System;TerminalEmulator;
StartupNotify=false
XTERM_DESKTOP
    fi
    mkdir -p "$ROOT/etc/X11/xorg.conf.d" "$ROOT/etc/gtk-3.0" \
        "$ROOT/etc/init.d" "$ROOT/etc/runlevels/default" "$ROOT/etc/runlevels/boot" "$ROOT/usr/libexec" \
        "$ROOT/etc/xdg/autostart" "$ROOT/usr/share/applications" \
        "$ROOT/var/lib/dbus" "$ROOT/var/lib/xkb" "$ROOT/var/lib/alsa" "$ROOT/var/log" "$ROOT/etc/skel"
    local script_dir wallpaper_dir wallpaper_source wallpaper_file wallpaper_default_path='' wallpaper_index
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    wallpaper_dir="$script_dir/img"
    if [[ -d "$wallpaper_dir" ]]; then
        mkdir -p "$ROOT/usr/share/backgrounds" "$ROOT/usr/share/lxde/wallpapers"
        for wallpaper_source in "$wallpaper_dir"/*; do
            [[ -f "$wallpaper_source" ]] || continue
            case "$wallpaper_source" in
                *.png|*.PNG|*.jpg|*.JPG|*.jpeg|*.JPEG)
                    install -Dm0644 "$wallpaper_source" "$ROOT/usr/share/backgrounds/${wallpaper_source##*/}"
                    install -Dm0644 "$wallpaper_source" "$ROOT/usr/share/lxde/wallpapers/${wallpaper_source##*/}" ;;
                *) continue ;;
            esac
        done
        if [[ -s "$ROOT/usr/share/backgrounds/grg-engineering-wallpaper.png" ]]; then
            ln -sfn grg-engineering-wallpaper.png "$ROOT/usr/share/backgrounds/grg-engineering.png"
        fi
        for wallpaper_index in 1 2 3; do
            wallpaper_file="$ROOT/usr/share/backgrounds/grg-engineering-wallpaper-light-$wallpaper_index.jpg"
            [[ ! -s "$wallpaper_file" ]] ||
                ln -sfn "grg-engineering-wallpaper-light-$wallpaper_index.jpg" \
                    "$ROOT/usr/share/backgrounds/grg-engineering-light-$wallpaper_index.jpg"
        done
        # GTK's pixbuf JPEG loader is intentionally not built in this minimal
        # profile. Prefer PNG wallpapers so PCManFM can decode the default.
        if [[ -s "$ROOT/usr/share/backgrounds/grg-engineering-wallpaper-light-1.png" ]]; then
            wallpaper_default_path=/usr/share/backgrounds/grg-engineering-wallpaper-light-1.png
        elif [[ -s "$ROOT/usr/share/backgrounds/grg-engineering-wallpaper.png" ]]; then
            wallpaper_default_path=/usr/share/backgrounds/grg-engineering-wallpaper.png
        elif [[ -s "$ROOT/usr/share/backgrounds/grg-engineering-light-1.jpg" ]]; then
            wallpaper_default_path=/usr/share/backgrounds/grg-engineering-light-1.jpg
        elif [[ -s "$ROOT/usr/share/backgrounds/grg-engineering.png" ]]; then
            wallpaper_default_path=/usr/share/backgrounds/grg-engineering.png
        else
            for wallpaper_file in "$ROOT/usr/share/backgrounds"/*; do
                [[ -f "$wallpaper_file" ]] || continue
                case "$wallpaper_file" in
                    *.png|*.PNG|*.jpg|*.JPG|*.jpeg|*.JPEG)
                        wallpaper_default_path="/usr/share/backgrounds/${wallpaper_file##*/}"
                        break ;;
                esac
            done
        fi
        if [[ "$DESKTOP_CHOICE" == lxde && -n "$wallpaper_default_path" ]]; then
            wallpaper_default_path="/usr/share/lxde/wallpapers/${wallpaper_default_path##*/}"
        fi
    fi
    # ALSA kernel drivers are usable by the desktop user's audio group.
    grep -q '^audio:' "$ROOT/etc/group" || printf 'audio:x:29:\n' >> "$ROOT/etc/group"
    awk -F: -v OFS=: -v name="$USER_NAME" '$1=="audio" {n=split($4,a,","); found=0; for(i=1;i<=n;i++) if(a[i]==name) found=1; if(!found) $4=$4 ($4=="" ? "" : ",") name} {print}' \
        "$ROOT/etc/group" > "$ROOT/etc/group.tmp"
    mv "$ROOT/etc/group.tmp" "$ROOT/etc/group"
    # Xorg veikia su ribotu SUID wrapper: tik vietinėje konsolėje prisijungę naudotojai.
    printf 'allowed_users=console\nneeds_root_rights=yes\n' > "$ROOT/etc/X11/Xwrapper.config"
    cat > "$ROOT/etc/X11/xorg.conf.d/10-diy-modesetting.conf" <<'XORG'
Section "Device"
    Identifier "DIY KMS"
    Driver "modesetting"
    Option "AccelMethod" "glamor"
EndSection
Section "InputClass"
    Identifier "DIY evdev keyboard"
    MatchIsKeyboard "on"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
    Option "XkbLayout" "us,lt"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection
Section "InputClass"
    Identifier "DIY evdev pointer"
    MatchIsPointer "on"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
EndSection
XORG
    cat > "$ROOT/etc/X11/xorg.conf.d/20-diy-fonts.conf" <<'XORG_FONTS'
Section "Files"
    FontPath "/usr/share/fonts/X11/misc"
EndSection
XORG_FONTS
    if [[ "$DESKTOP_CHOICE" == fluxbox ]]; then
        mkdir -p "$ROOT/etc/skel/.fluxbox" "$ROOT/home/$USER_NAME/.fluxbox" "$ROOT/usr/libexec"
        configure_pcmanfm_wallpaper
        local fluxbox_panel="$ROOT/etc/xdg/lxpanel/default/panels/panel"
        [[ -f "$fluxbox_panel" ]] || die "LXPanel default configuration is missing for Fluxbox"
        sed -i 's/lxterminal\.desktop/xterm.desktop/g' "$fluxbox_panel"
        if ! grep -q 'id=xterm\.desktop' "$fluxbox_panel"; then
            cat >> "$fluxbox_panel" <<'FLUXBOX_XTERM_LAUNCHER'

Plugin {
    type=launchbar
    Config {
        Button {
            id=xterm.desktop
        }
    }
}
FLUXBOX_XTERM_LAUNCHER
        fi
        normalize_lxpanel_tray_order "$fluxbox_panel" 0644 ||
            die "Could not configure the Fluxbox panel system tray"
        cat > "$ROOT/etc/skel/.fluxbox/init" <<'FLUXBOX_INIT'
session.screen0.toolbar.visible: false
session.screen0.toolbar.placement: BottomCenter
session.screen0.toolbar.widthPercent: 100
session.screen0.workspaces: 4
session.screen0.focusModel: ClickToFocus
session.screen0.focusNewWindows: true
session.screen0.windowPlacement: RowSmartPlacement
session.screen0.antialias: true
FLUXBOX_INIT
        configure_fluxbox_menu
        cat > "$ROOT/etc/skel/.fluxbox/keys" <<'FLUXBOX_KEYS'
Mod1 F1 :Exec xterm
Mod1 F4 :Close
Mod1 F5 :Reconfigure
Mod1 F6 :Restart
Mod1 F9 :Workspace 1
Mod1 F10 :Workspace 2
Mod1 F11 :Workspace 3
Mod1 F12 :Workspace 4
FLUXBOX_KEYS
        cat > "$ROOT/usr/bin/startfluxbox" <<'STARTFLUXBOX'
#!/bin/sh
[ -z "${DIY_CHROOT:-}" ] || { echo 'Start Fluxbox after booting the system, not inside chroot.' >&2; exit 1; }
[ -z "${DISPLAY:-}" ] || { echo 'A graphical session is already running.' >&2; exit 1; }
case "$(tty 2>/dev/null || :)" in /dev/tty[1-6]) ;; *) echo 'Log in on tty1-tty6 and run startfluxbox.' >&2; exit 1 ;; esac
XDG_RUNTIME_DIR=$(mktemp -d "/tmp/diy-fluxbox-$(id -u).XXXXXXXX")
export XDG_RUNTIME_DIR
trap 'rm -rf -- "$XDG_RUNTIME_DIR"' EXIT HUP INT TERM
startx /usr/libexec/diy-fluxbox-session -- /usr/bin/X -keeptty -nolisten tcp
STARTFLUXBOX
        cat > "$ROOT/usr/libexec/diy-fluxbox-session" <<'FLUXBOX_SESSION'
#!/bin/sh
export XDG_CURRENT_DESKTOP=FLUXBOX XDG_SESSION_DESKTOP=fluxbox XDG_SESSION_TYPE=x11
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-run-session -- sh -c '
wallpaper_config="${XDG_CONFIG_HOME:-$HOME/.config}/pcmanfm/LXDE/desktop-items-0.conf"
wallpaper_default="@DIY_WALLPAPER_DEFAULT@"
wallpaper_marker="${XDG_CONFIG_HOME:-$HOME/.config}/diy-wallpaper-defaulted"
if [ -n "$wallpaper_default" ] && [ -f "$wallpaper_default" ] &&
   ! grep -Fqx "$wallpaper_default" "$wallpaper_marker" 2>/dev/null; then
    if grep -q "^wallpaper=" "$wallpaper_config"; then
        sed -i "s|^wallpaper=.*|wallpaper=$wallpaper_default|" "$wallpaper_config"
    else
        printf "wallpaper=%s\n" "$wallpaper_default" >> "$wallpaper_config"
    fi
fi
if command -v pulseaudio >/dev/null 2>&1; then
    pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || :
fi
if command -v nm-applet >/dev/null 2>&1; then
    nm-applet --sm-disable >/dev/null 2>&1 &
fi
if command -v pcmanfm >/dev/null 2>&1; then
    pcmanfm --desktop --profile LXDE >/dev/null 2>&1 &
fi
if command -v lxpanel >/dev/null 2>&1; then
    lxpanel --profile default >/dev/null 2>&1 &
fi
exec fluxbox -log "$HOME/.fluxbox/log"
'
FLUXBOX_SESSION
        sed -i "s|@DIY_WALLPAPER_DEFAULT@|$wallpaper_default_path|g" "$ROOT/usr/libexec/diy-fluxbox-session"
        chmod 0755 "$ROOT/usr/bin/startfluxbox" "$ROOT/usr/libexec/diy-fluxbox-session"
        cp -a "$ROOT/etc/skel/.fluxbox/." "$ROOT/home/$USER_NAME/.fluxbox/"
        if [[ "$NETWORK" == yes ]]; then
            mkdir -p "$ROOT/etc/NetworkManager/conf.d" "$ROOT/var/lib/NetworkManager" "$ROOT/run/NetworkManager"
            cat > "$ROOT/etc/NetworkManager/NetworkManager.conf" <<'NETWORKMANAGER_CONFIG'
[main]
plugins=keyfile
auth-polkit=false
dhcp=internal

[device]
wifi.backend=wpa_supplicant
NETWORKMANAGER_CONFIG
            cat > "$ROOT/etc/xdg/autostart/nm-applet.desktop" <<'NM_APPLET_AUTOSTART'
[Desktop Entry]
Type=Application
Name=NetworkManager Applet
Exec=nm-applet --sm-disable
Icon=network-wireless
Terminal=false
OnlyShowIn=Fluxbox;
NM_APPLET_AUTOSTART
        fi
        configure_graphical_runtime_accounts_locale
        configure_desktop_init_services
        return 0
    fi
    if [[ "$DESKTOP_CHOICE" == lxde ]]; then
        # LXDE uses Fluxbox as its window manager; replace Fluxbox's upstream
        # sample menu, which advertises IRC, GNOME, and other absent programs.
        configure_fluxbox_menu
        configure_pcmanfm_wallpaper
        mkdir -p "$ROOT/etc/skel/.config/lxsession/LXDE" \
            "$ROOT/home/$USER_NAME/.config/lxsession/LXDE" \
            "$ROOT/etc/xdg/lxsession/LXDE" "$ROOT/usr/libexec"
        local lxde_network_gui=no
        cat > "$ROOT/etc/skel/.config/lxsession/LXDE/desktop.conf" <<LXDE_SESSION_CONF
[Session]
window_manager=fluxbox
panel/command=lxpanel
panel/session=LXDE
file_manager/command=pcmanfm
file_manager/session=LXDE
desktop_manager/command=filemanager
terminal_manager/command=xterm
network_gui/command=$lxde_network_gui
polkit/command=
clipboard/command=
xsettings_manager/command=build-in
LXDE_SESSION_CONF
        cp "$ROOT/etc/skel/.config/lxsession/LXDE/desktop.conf" \
            "$ROOT/home/$USER_NAME/.config/lxsession/LXDE/desktop.conf"
        cp "$ROOT/etc/skel/.config/lxsession/LXDE/desktop.conf" \
            "$ROOT/etc/xdg/lxsession/LXDE/desktop.conf"
        local lxde_panel="$ROOT/etc/xdg/lxpanel/LXDE/panels/panel"
        [[ -f "$lxde_panel" ]] || die "$(tr_text 'LXDE panel default configuration was not installed' 'Neįdiegta numatytoji LXDE skydelio konfigūracija')"
        if ! grep -Eq 'type[[:space:]]*=[[:space:]]*tray' "$lxde_panel"; then
            cat >> "$lxde_panel" <<'LXDE_TRAY_PLUGIN'

Plugin {
    type=tray
}
LXDE_TRAY_PLUGIN
        fi
        normalize_lxpanel_tray_order "$lxde_panel" 0644 ||
            die "$(tr_text 'Could not place the LXDE system tray before the clock and remove the legacy network-properties icon' 'Nepavyko perkelti LXDE dėklo prieš laikrodį ir pašalinti senos tinklo savybių piktogramos')"
        # LXPanel's stock profiles still point at lxterminal even though this
        # image intentionally ships only xterm. Keep every selectable profile
        # consistent, not just the active LXDE panel.
        while IFS= read -r panel_file; do
            sed -i 's/lxterminal\.desktop/xterm.desktop/g' "$panel_file"
        done < <(find "$ROOT/etc/xdg/lxpanel" -type f -path '*/panels/*' -print)
        if ! grep -q 'id=xterm\.desktop' "$lxde_panel"; then
            cat >> "$lxde_panel" <<'LXDE_XTERM_LAUNCHER'

Plugin {
    type=launchbar
    Config {
        Button {
            id=xterm.desktop
        }
    }
}
LXDE_XTERM_LAUNCHER
        fi
        cat > "$ROOT/usr/bin/startlxde" <<'STARTLXDE'
#!/bin/sh
[ -z "${DIY_CHROOT:-}" ] || { echo 'Start LXDE after booting the system, not inside chroot.' >&2; exit 1; }
[ -z "${DISPLAY:-}" ] || { echo 'A graphical session is already running.' >&2; exit 1; }
case "$(tty 2>/dev/null || :)" in /dev/tty[1-6]) ;; *) echo 'Log in on tty1-tty6 and run startlxde.' >&2; exit 1 ;; esac
cd "$HOME" 2>/dev/null || cd / || exit 1
XDG_RUNTIME_DIR=$(mktemp -d "/tmp/diy-lxde-$(id -u).XXXXXXXX")
export XDG_RUNTIME_DIR
trap 'rm -rf -- "$XDG_RUNTIME_DIR"' EXIT HUP INT TERM
startx /usr/libexec/diy-lxde-session -- /usr/bin/X -keeptty -nolisten tcp
STARTLXDE
        cat > "$ROOT/usr/libexec/diy-lxde-session" <<'LXDE_SESSION'
#!/bin/sh
cd "$HOME" 2>/dev/null || cd / || exit 1
export XDG_CURRENT_DESKTOP=LXDE XDG_SESSION_DESKTOP=lxde XDG_SESSION_TYPE=x11
lxde_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/lxsession/LXDE"
lxde_config="$lxde_config_dir/desktop.conf"
mkdir -p "$lxde_config_dir"
if [ ! -f "$lxde_config" ]; then
    cp /etc/xdg/lxsession/LXDE/desktop.conf "$lxde_config" 2>/dev/null || :
fi
set_lxde_option() {
    key=$1 value=$2
    if grep -q "^$key=" "$lxde_config"; then
        sed -i "s|^$key=.*|$key=$value|" "$lxde_config"
    else
        printf '%s=%s\n' "$key" "$value" >> "$lxde_config"
    fi
}
set_lxde_option terminal_manager/command xterm
set_lxde_option desktop_manager/command filemanager
set_lxde_option network_gui/command no
lxde_autostart="$lxde_config_dir/autostart"
if [ -f "$lxde_autostart" ]; then
    sed -i '\|^@nm-applet --sm-disable$|d' "$lxde_autostart"
fi
wallpaper_config="${XDG_CONFIG_HOME:-$HOME/.config}/pcmanfm/LXDE/desktop-items-0.conf"
if [ ! -f "$wallpaper_config" ]; then
    mkdir -p "${wallpaper_config%/*}"
    cp /etc/xdg/pcmanfm/LXDE/desktop-items-0.conf "$wallpaper_config" 2>/dev/null || :
fi
wallpaper_default="@DIY_WALLPAPER_DEFAULT@"
if [ -n "$wallpaper_default" ] && [ -f "$wallpaper_default" ] && [ -f "$wallpaper_config" ] &&
   grep -Eq '^wallpaper=/usr/share/backgrounds/grg-engineering[^/]*\.(jpg|jpeg)$' "$wallpaper_config"; then
    sed -i "s|^wallpaper=.*|wallpaper=$wallpaper_default|" "$wallpaper_config"
fi
lxpanel_dir="${XDG_CONFIG_HOME:-$HOME/.config}/lxpanel/LXDE/panels"
lxpanel_config="$lxpanel_dir/panel"
mkdir -p "$lxpanel_dir"
if [ ! -f "$lxpanel_config" ]; then
    cp /etc/xdg/lxpanel/LXDE/panels/panel "$lxpanel_config" 2>/dev/null || :
fi
if [ -f "$lxpanel_config" ]; then
    sed -i 's/lxterminal\.desktop/xterm.desktop/g' "$lxpanel_config"
    if command -v xterm >/dev/null 2>&1 && ! grep -q 'id=xterm\.desktop' "$lxpanel_config"; then
        cat >> "$lxpanel_config" <<'XTERM_LAUNCHER'

Plugin {
    type=launchbar
    Config {
        Button {
            id=xterm.desktop
        }
    }
}
XTERM_LAUNCHER
    fi
    if command -v nm-applet >/dev/null 2>&1 && ! grep -Eq 'type[[:space:]]*=[[:space:]]*tray' "$lxpanel_config"; then
        cat >> "$lxpanel_config" <<'TRAY_PLUGIN'

Plugin {
    type=tray
}
TRAY_PLUGIN
    fi
    /usr/libexec/diy-lxpanel-tray-order "$lxpanel_config" 0600 || :
fi
if command -v pulseaudio >/dev/null 2>&1; then
    pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 || :
fi
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-run-session -- sh -c '
exec lxsession -s LXDE -e LXDE
'
LXDE_SESSION
        chmod 0755 "$ROOT/usr/bin/startlxde" "$ROOT/usr/libexec/diy-lxde-session"
        cat > "$ROOT/usr/libexec/diy-lxpanel-tray-order" <<'LXDE_TRAY_ORDER'
#!/bin/sh
panel=$1
mode=${2:-0600}
[ -f "$panel" ] || exit 0
temporary=$(mktemp "${panel}.tray.XXXXXX") || exit 1
if ! awk '
    function braces(s, t, opens, closes) {
        t = s; opens = gsub(/[{]/, "", t)
        t = s; closes = gsub(/[}]/, "", t)
        return opens - closes
    }
    function save_plugin() {
        if (block ~ /type[[:space:]]*=[[:space:]]*tray/) { tray_block = block; return }
        # The inherited LXDE panel can contain launchers for programs that
        # this minimal image intentionally does not install. Keep one known
        # launcher whose desktop file is created and verified by the build.
        if (block ~ /type[[:space:]]*=[[:space:]]*launchbar/) {
            if (!launchbar_block) launchbar_block = "Plugin {\n    type=launchbar\n    Config {\n        Button {\n            id=xterm.desktop\n        }\n    }\n}\n\n"
            return
        }
        # Remove the legacy interface-properties icon. nm-applet is the Wi-Fi
        # connection menu and is hosted by the tray plugin retained below.
        if (block ~ /type[[:space:]]*=[[:space:]]*netstatus/) return
        plugins[++plugin_count] = block
        if (!clock_index && block ~ /type[[:space:]]*=[[:space:]]*dclock/) clock_index = plugin_count
    }
    /^[[:space:]]*Plugin[[:space:]]*[{]/ {
        in_plugin = 1; block = $0 ORS; depth = braces($0)
        if (depth == 0) { save_plugin(); in_plugin = 0; block = "" }
        next
    }
    in_plugin {
        block = block $0 ORS; depth += braces($0)
        if (depth == 0) { save_plugin(); in_plugin = 0; block = "" }
        next
    }
    { print }
    END {
        if (block != "") save_plugin()
        if (tray_block == "") tray_block = "Plugin {\n    type=tray\n}\n\n"
        if (!clock_index) clock_index = plugin_count + 1
        for (i = 1; i <= plugin_count + 1; i++) {
            if (i == clock_index) {
                printf "%s", tray_block
                if (launchbar_block != "") printf "%s", launchbar_block
            }
            if (i <= plugin_count) printf "%s", plugins[i]
        }
    }
' "$panel" > "$temporary"; then
    rm -f -- "$temporary"
    exit 1
fi
chmod "$mode" "$temporary" && mv -f -- "$temporary" "$panel"
LXDE_TRAY_ORDER
        chmod 0755 "$ROOT/usr/libexec/diy-lxpanel-tray-order"
    fi
    if [[ "$DESKTOP_CHOICE" == mate ]]; then
        if [[ ${PKG_CAJA:-no} != yes ]]; then
            configure_pcmanfm_wallpaper MATE
        fi
        cat > "$ROOT/usr/bin/startmate" <<'STARTMATE'
#!/bin/sh
[ -z "${DIY_CHROOT:-}" ] || { echo 'Start MATE after booting the system, not inside chroot.' >&2; exit 1; }
[ -z "${DISPLAY:-}" ] || { echo 'A graphical session is already running.' >&2; exit 1; }
case "$(tty 2>/dev/null || :)" in /dev/tty[1-6]) ;; *) echo 'Log in on tty1-tty6 and run startmate.' >&2; exit 1 ;; esac
cd "$HOME" 2>/dev/null || cd /
uid=$(id -u)
runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$uid}
if [ -d "$runtime_dir" ] && [ -w "$runtime_dir" ]; then
    export XDG_RUNTIME_DIR=$runtime_dir
else
    XDG_RUNTIME_DIR=$(mktemp -d "/tmp/diy-mate-$uid.XXXXXXXX") || exit 1
    export XDG_RUNTIME_DIR
    trap 'rm -rf -- "$XDG_RUNTIME_DIR"' EXIT HUP INT TERM
fi
if [ "@DIY_MATE_NEEDS_ELOGIND@" = yes ]; then
    ready=no
    attempt=0
    while [ "$attempt" -lt 15 ]; do
        if /usr/bin/dbus-send --system --print-reply --dest=org.freedesktop.DBus / \
             org.freedesktop.DBus.NameHasOwner string:org.freedesktop.login1 2>/dev/null | grep -q 'boolean true'; then
            ready=yes
            break
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    [ "$ready" = yes ] || { echo 'elogind is not ready; MATE session was not started.' >&2; exit 1; }
fi
startx /usr/libexec/diy-mate-session -- /usr/bin/X -keeptty -nolisten tcp
STARTMATE
        cat > "$ROOT/usr/libexec/diy-mate-session" <<'SESSION'
#!/bin/sh
export XDG_CURRENT_DESKTOP=MATE XDG_SESSION_DESKTOP=mate XDG_SESSION_TYPE=x11
if command -v pulseaudio >/dev/null 2>&1; then
    pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1 ||
        echo 'Warning: PulseAudio did not start; check /dev/snd and the audio group.' >&2
fi
unset DBUS_SESSION_BUS_ADDRESS
dbus-run-session -- sh -c '
if [ -d /usr/share/glib-2.0/schemas ] &&
   [ ! -s /usr/share/glib-2.0/schemas/gschemas.compiled ]; then
    /usr/bin/glib-compile-schemas /usr/share/glib-2.0/schemas ||
        echo "Warning: could not compile GSettings schemas" >&2
fi
wallpaper_marker="${XDG_CONFIG_HOME:-$HOME/.config}/diy-wallpaper-defaulted"
wallpaper_default="@DIY_WALLPAPER_DEFAULT@"
if command -v gsettings >/dev/null 2>&1; then
    # On systems without a DRM render node (for example, older GPUs or
    # software-only Xorg), Marco compositor falls back to CPU rendering.
    # Disable compositing in that case so MATE starts and responds faster.
    render_node_found=no
    for render_node in /dev/dri/renderD*; do
        if [ -e "$render_node" ]; then
            render_node_found=yes
            break
        fi
    done
    if [ "$render_node_found" = no ]; then
        gsettings set org.mate.Marco.general compositing-manager false >/dev/null 2>&1 || :
    fi
    if [ -n "$wallpaper_default" ] && [ -f "$wallpaper_default" ]; then
        wallpaper_current=$(gsettings get org.mate.background picture-filename 2>/dev/null || :)
        wallpaper_update=no
        case "$wallpaper_current" in *grg-engineering.png*) wallpaper_update=yes ;; esac
        if [ ! -e "$wallpaper_marker" ] || [ "$wallpaper_update" = yes ]; then
            if gsettings set org.mate.background picture-filename "$wallpaper_default" &&
               gsettings set org.mate.background picture-options zoom; then
                mkdir -p "${wallpaper_marker%/*}"
                : > "$wallpaper_marker"
            fi
        fi
    fi
    gsettings set org.mate.panel.menubar icon-name diy-linux-logo >/dev/null 2>&1 || :
    # Create the panel profile before mate-session launches its autostart
    # entries. On a fresh user profile, waiting for asynchronous first-run
    # layout discovery can leave the wallpaper visible without a
    # panel for a long time, especially under runit in QEMU.
    panel_layout_marker="${XDG_CONFIG_HOME:-$HOME/.config}/diy-mate-panel-layout-ready"
    if [ ! -e "$panel_layout_marker" ] && command -v mate-panel >/dev/null 2>&1; then
        panel_ids=$(gsettings get org.mate.panel.general toplevel-id-list 2>/dev/null || printf "[]")
        if [ "$panel_ids" = "[]" ]; then
            mate-panel --reset --layout=default >/dev/null 2>&1 || :
        fi
        mkdir -p "${panel_layout_marker%/*}"
        : > "$panel_layout_marker"
    fi
fi
if ! command -v caja >/dev/null 2>&1 && command -v pcmanfm >/dev/null 2>&1; then
    pcmanfm --desktop --profile MATE >/dev/null 2>&1 &
fi
exec mate-session
'
status=$?
pulseaudio --kill >/dev/null 2>&1 || :
exit "$status"
SESSION
        sed -i "s|@DIY_WALLPAPER_DEFAULT@|$wallpaper_default_path|g" "$ROOT/usr/libexec/diy-mate-session"
        if [[ "$INIT_CHOICE" == systemd ]]; then
            sed -i 's|@DIY_MATE_NEEDS_ELOGIND@|no|g' "$ROOT/usr/bin/startmate"
        else
            sed -i 's|@DIY_MATE_NEEDS_ELOGIND@|yes|g' "$ROOT/usr/bin/startmate"
        fi
        chmod 0755 "$ROOT/usr/bin/startmate" "$ROOT/usr/libexec/diy-mate-session"
    fi
    printf '[Settings]\ngtk-theme-name=Adwaita\ngtk-icon-theme-name=Adwaita\ngtk-font-name=DejaVu Sans 10\n' > "$ROOT/etc/gtk-3.0/settings.ini"
    mkdir -p "$ROOT/usr/share/icons/hicolor/scalable/apps"
    cat > "$ROOT/usr/share/icons/hicolor/scalable/apps/diy-linux-logo.svg" <<'DIY_LOGO'
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
  <rect x="2" y="2" width="60" height="60" rx="15" fill="#17324f"/>
  <path d="M32 10 51 21v22L32 54 13 43V21z" fill="#39b8d8"/>
  <path d="M32 17 45 24.5v15L32 47 19 39.5v-15z" fill="#f5fbff"/>
  <path d="M26 27h12v4H26zm0 7h12v4H26z" fill="#17324f"/>
  <circle cx="32" cy="21" r="2.5" fill="#f4bd50"/>
</svg>
DIY_LOGO
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache --force "$ROOT/usr/share/icons/hicolor" >/dev/null 2>&1 || :
    fi
    if [[ "$DESKTOP_CHOICE" != lxde ]]; then
    cat > "$ROOT/etc/xdg/autostart/nm-applet.desktop" <<NM_APPLET_AUTOSTART
[Desktop Entry]
Type=Application
Name=NetworkManager Applet
Comment=Manage wired and wireless network connections
Exec=nm-applet
Icon=network-wireless
Terminal=false
X-MATE-Autostart-enabled=true
X-MATE-Autostart-Phase=Application
OnlyShowIn=$desktop_session_name;
NM_APPLET_AUTOSTART
    fi
    if [[ "$DESKTOP_CHOICE" == lxde && "$NETWORK" == yes ]]; then
        # Launch exactly once through XDG autostart, after LXSession has
        # started LXPanel and its XEmbed tray host.
        cat > "$ROOT/etc/xdg/autostart/nm-applet.desktop" <<'LXDE_NM_APPLET_AUTOSTART'
[Desktop Entry]
Type=Application
Name=NetworkManager Applet
Comment=Manage wired and wireless network connections
Exec=nm-applet --sm-disable
Icon=network-wireless
Terminal=false
OnlyShowIn=LXDE;
LXDE_NM_APPLET_AUTOSTART
    fi
    local sound_applet_desktop=$desktop_session_name
    cat > "$ROOT/etc/xdg/autostart/diy-volume-applet.desktop" <<VOLUME_APPLET_AUTOSTART
[Desktop Entry]
Type=Application
Name=DIY Volume Control
Name[lt]=DIY garsumo valdiklis
Comment=Show a sound icon in the desktop notification area
Comment[lt]=Rodyti garso piktogramą darbalaukio pranešimų srityje
Exec=/usr/bin/diy-sound-mixer --tray
Icon=audio-volume-high
Terminal=false
OnlyShowIn=$sound_applet_desktop;
X-MATE-Autostart-enabled=true
X-MATE-Autostart-Phase=Application
VOLUME_APPLET_AUTOSTART
    cat > "$ROOT/usr/share/applications/diy-network-settings.desktop" <<'NETWORK_APP'
[Desktop Entry]
Type=Application
Name=Network Connections
Comment=Connect to Wi-Fi and manage network connections
Exec=nm-connection-editor
Icon=network-wireless
Terminal=false
Categories=Settings;Network;
NETWORK_APP
    if [[ "$NETWORK" == yes ]]; then
        # NetworkManager is the only DHCP and Wi-Fi manager on desktop profiles.
        if [[ "$INIT_CHOICE" == openrc ]]; then rm -f "$ROOT/etc/runlevels/default/dhcpcd"; fi
        rm -f "$ROOT/etc/runlevels/default/connmand" "$ROOT/etc/init.d/connmand"
        rm -f "$ROOT/etc/xdg/autostart/diy-connman-gtk.desktop"
        rm -f "$ROOT/usr/bin/connman-gtk" "$ROOT/usr/sbin/connmand" \
            "$ROOT/usr/bin/connmanctl" "$ROOT/etc/connman/main.conf"
        mkdir -p "$ROOT/etc/NetworkManager/conf.d" "$ROOT/var/lib/NetworkManager" \
            "$ROOT/run/NetworkManager"
        cat > "$ROOT/etc/NetworkManager/NetworkManager.conf" <<'NETWORKMANAGER_CONFIG'
# This single-user DIY image has no polkit daemon; allow the logged-in desktop
# user to connect to Ethernet and Wi-Fi from nm-applet.
[main]
plugins=keyfile
auth-polkit=false
dhcp=internal

[device]
wifi.backend=wpa_supplicant
NETWORKMANAGER_CONFIG
    else
        rm -f "$ROOT/etc/xdg/autostart/nm-applet.desktop"
        rm -f "$ROOT/usr/share/applications/diy-network-settings.desktop"
    fi
    configure_desktop_init_services
    if [[ "$needs_desktop_auth" == yes ]]; then
        local polkit_uid
        if ! grep -q '^polkitd:' "$ROOT/etc/passwd"; then
            for polkit_uid in {900..999}; do
                if ! awk -F: -v id="$polkit_uid" \
                    'FNR==NR { if ($3 == id) used=1; next } $3 == id { used=1 } END { exit used ? 0 : 1 }' \
                    "$ROOT/etc/passwd" "$ROOT/etc/group"; then break; fi
                polkit_uid=''
            done
            [[ -n "$polkit_uid" ]] || die "$(tr_text 'No free system UID is available for polkitd' 'polkitd paskyrai nėra laisvo sistemos UID')"
            grep -q '^polkitd:' "$ROOT/etc/group" || printf 'polkitd:x:%s:\n' "$polkit_uid" >> "$ROOT/etc/group"
            printf 'polkitd:x:%s:%s:PolicyKit daemon:/var/lib/polkit-1:/bin/false\n' \
                "$polkit_uid" "$polkit_uid" >> "$ROOT/etc/passwd"
            grep -q '^polkitd:' "$ROOT/etc/shadow" || printf 'polkitd:!:::::::\n' >> "$ROOT/etc/shadow"
        fi
        install -d -m0755 "$ROOT/var/lib/polkit-1" "$ROOT/etc/polkit-1/rules.d"
        if [[ ${PKG_MATE_POWER_MANAGER:-no} == yes ]]; then
            cat > "$ROOT/etc/polkit-1/rules.d/10-diy-power-manager.rules" <<'POLKIT_POWER_RULE'
polkit.addRule(function(action, subject) {
    var allowed = [
        "org.freedesktop.login1.power-off",
        "org.freedesktop.login1.power-off-multiple-sessions",
        "org.freedesktop.login1.power-off-ignore-inhibit",
        "org.freedesktop.login1.reboot",
        "org.freedesktop.login1.reboot-multiple-sessions",
        "org.freedesktop.login1.reboot-ignore-inhibit",
        "org.freedesktop.login1.suspend",
        "org.freedesktop.login1.suspend-multiple-sessions",
        "org.freedesktop.login1.suspend-ignore-inhibit",
        "org.freedesktop.login1.hibernate",
        "org.freedesktop.login1.hibernate-multiple-sessions",
        "org.freedesktop.login1.hibernate-ignore-inhibit"
    ];
    if (subject.isInGroup("sudo") && allowed.indexOf(action.id) >= 0)
        return polkit.Result.YES;
});
POLKIT_POWER_RULE
            chmod 0644 "$ROOT/etc/polkit-1/rules.d/10-diy-power-manager.rules"
        fi
    fi
    if [[ ${PKG_MATE_CONTROL_CENTER:-no} == yes || ${PKG_MATE_POWER_MANAGER:-no} == yes ]]; then
        cat > "$ROOT/etc/xdg/autostart/polkit-mate-authentication-agent-1.desktop" <<'POLKIT_AGENT'
[Desktop Entry]
Type=Application
Name=MATE PolicyKit Authentication Agent
Exec=/usr/libexec/polkit-mate-authentication-agent-1
OnlyShowIn=MATE;
NoDisplay=true
X-MATE-Autostart-enabled=true
POLKIT_AGENT
    fi
    if [[ ${PKG_MATE_POWER_MANAGER:-no} == yes ]]; then
        cat > "$ROOT/etc/xdg/autostart/mate-power-manager.desktop" <<'MATE_POWER_AUTOSTART'
[Desktop Entry]
Type=Application
Name=MATE Power Manager
Comment=Manage battery and power settings
Exec=mate-power-manager
OnlyShowIn=MATE;
X-MATE-Autostart-enabled=true
MATE_POWER_AUTOSTART
    fi
    configure_graphical_runtime_accounts_locale
}

# END DESKTOP RECIPES

# 5. Programos. GNU ir BusyBox įrankiai nėra painiojami su apvalkalu.
build_bash() {
    local source number patch_file
            source=$(unpack bash)
            if [[ ! -f "$source/.diy-patches" ]]; then
                # Oficialūs GNU pataisų failai yra -p0 context diff formato.
                while read -r number checksum; do
                    [[ -n "$number" ]] || continue
                    patch_file="$CACHE/bash53-$number.patch"
                    if [[ ! -f "$patch_file" ]]; then
                        curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' \
                            "https://ftp.gnu.org/gnu/bash/bash-5.3-patches/bash53-$number" -o "$patch_file.part"
                        printf '%s  %s\n' "$checksum" "$patch_file.part" | sha256sum --check --status
                        mv -- "$patch_file.part" "$patch_file"
                    fi
                    printf '%s  %s\n' "$checksum" "$patch_file" | sha256sum --check --status
                    # Žyma kiekvienai pataisai leidžia tęsti nutrūkusį pataisymą.
                    if [[ ! -f "$source/.patch-$number" ]]; then
                        patch -d "$source" -p0 < "$patch_file"
                        touch "$source/.patch-$number"
                    fi
                done <<'BASH_PATCHES'
001 1f608434364af86b9b45c8b0ea3fb3b165fb830d27697e6cdfc7ac17dee3287f
002 e385548a00130765ec7938a56fbdca52447ab41fabc95a25f19ade527e282001
003 f245d9c7dc3f5a20d84b53d249334747940936f09dc97e1dcb89fc3ab37d60ed
004 9591d245045529f32f0812f94180b9d9ce9023f5a765c039b852e5dfc99747d0
005 cca1ef52dbbf433bc98e33269b64b2c814028efe2538be1e2c9a377da90bc99d
006 29119addefed8eff91ae37fd51822c31780ee30d4a28376e96002706c995ff10
007 c0976bbfffa1453c7cfdd62058f206a318568ff2d690f5d4fa048793fa3eb299
008 097cd723cbfb8907674ac32214063a3fd85282657ec5b4e544d2c0f719653fb4
009 eee30fe78a4b0cb2fe20e010e00308899cfc613e0774ebb3c8557a1552f24f8c
010 cf76f1cce2ea300c18bff9f002d21f280cc931acd17c28518110b93fe6e72569
011 0298df8f5ea2a31d3be43ed7d269c5b3c7c342dd5b570bea7f64d66dcbbe7531
012 d71379b39bebaedaf123414414e77fb458a0a43b9ad3116594c6df7ca6754573
013 042f9cda967e24bf4211944697441e93d06ff42b4b998629a98a1b249279f200
014 bd4360b401d38507e358783dcad8536a99c6789f0d3a5bd0cfb8c4a34144696c
015 55b79ceee2fc27f6767eed697e939a7eb2fe2a28c01556bd75f18d581014f46e
016 9ea29b266b7d24cb34d0ff3f1c4631e4d527bfe2d1ef15d17cdb924bf31ef767
017 443b927b45c1558ca72052410f8b8f6e5152b617ed707061a2781d4375b0d1c3
018 ae715d76c50341d7d7095e9a8d2eeed1ca9546152c2ac7289206f90cf30ac697
019 a25c581e4d0057dea3833918438a930e2e86ee4c6dc17fe15267b7f04cbc4e3d
020 df217ed3a9122aa2286d9b67bbe348661b6a9db262b580c29150dae55d532896
BASH_PATCHES
                touch "$source/.diy-patches"
            fi
            autotools bash --disable-nls --without-bash-malloc
}

# Fish nėra POSIX shell. Jis skirtas prisijungimui, /bin/sh lieka dash.
build_fish() {
    local source rust_target=$RUST_TARGET rust_key=${RUST_TARGET//-/_}
    source=$(unpack fish)
    export CARGO_HOME="$WORK_DIR/cargo-cache" CARGO_BUILD_JOBS="$JOBS"
    export "CARGO_TARGET_${rust_key^^}_LINKER=$CC" "CC_${rust_key}=$CC" \
        "AR_${rust_key}=$AR" "CXX_${rust_key}=$CXX"
    export RUSTFLAGS="-C link-arg=--sysroot=$ROOT"
    # Cargo.lock užfiksuoja crates sumas ir Git revizijas. Tik šiam pasirinkimui
    # Cargo atsisiunčia Rust priklausomybes; kompiliatorius į rootfs nepatenka.
    cmake -S "$source" -B "$BUILD/fish" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR="$TARGET_ARCH" \
        -DCMAKE_C_COMPILER="$CC" -DCMAKE_SYSROOT="$ROOT" \
        -DCMAKE_FIND_ROOT_PATH="$ROOT" -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_SYSCONFDIR=/etc \
        -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release \
        -DRust_COMPILER="$(command -v rustc)" -DRust_CARGO="$(command -v cargo)" \
        -DRust_CARGO_TARGET="$rust_target" '-DCARGO_FLAGS=--locked' \
        -DFISH_USE_SYSTEM_PCRE2=OFF -DWITH_MESSAGE_LOCALIZATION=OFF \
        -DSPHINX_EXECUTABLE=SPHINX_EXECUTABLE-NOTFOUND
    cmake --build "$BUILD/fish" --parallel "$JOBS"
    DESTDIR="$ROOT" cmake --install "$BUILD/fish"
}

# GNU util-linux login priklauso nuo PAM ir su --without-pam nesukuriamas.
# Shadow suteikia login/passwd ir paskyrų valdymą be BusyBox ar PAM.
login_tools() {
    [[ "$TOOLS_CHOICE" == gnu ]] || return 0
    local source compatibility pam_option=--without-libpam
    if desktop_needs_logind; then
        # Login must notify logind/elogind about the user session so Polkit can
        # authorize mount and power operations from the MATE desktop.
        desktop_package linux-pam
        pam_option=--with-libpam
    fi
    source=$(unpack shadow)
    # Be nscd šiame leidime stub deklaracija turi netinkamą argumento tipą.
    sed -i 's/nscd_flush_cache(MAYBE_UNUSED int _1)/nscd_flush_cache(MAYBE_UNUSED const char *service)/' "$source/lib/nscd.h"
    # Glibc tušti suderinamumo archyvai (-ldl ir kt.) pašalinti iš mažo rootfs.
    # Linkeriui pateikti tik juos, ne visą SDK bibliotekų kelią.
    mkdir -p "$BUILD/shadow-compat"
    for compatibility in libdl.a libpthread.a librt.a libutil.a; do
        [[ ! -f "$SDK/sysroot/usr/lib/$compatibility" ]] || cp "$SDK/sysroot/usr/lib/$compatibility" "$BUILD/shadow-compat/"
    done
    # Pakavimo metu pašalinti rootfs headers lieka bendrame SDK.
    (export CPPFLAGS="${CPPFLAGS:-} -I$SDK/sysroot/usr/include"
     export LDFLAGS="${LDFLAGS:-} -L$BUILD/shadow-compat"
     autotools shadow "$pam_option" --without-audit --without-selinux \
         --without-acl --without-attr --without-btrfs --without-libbsd \
         --without-nscd --without-sssd --disable-logind --disable-subordinate-ids \
         --without-fcaps --with-su --without-bcrypt --with-yescrypt)
    [[ -x "$ROOT/usr/bin/login" && -x "$ROOT/usr/bin/passwd" && -x "$ROOT/usr/bin/su" ]] || die "$(tr_text 'Shadow did not install login / passwd / su' 'Shadow neįdiegė login / passwd / su')"
    install -Dm0644 "$SOURCES/shadow-${VERSION[shadow]}/etc/login.defs" "$ROOT/etc/login.defs"
    sed -i -e 's/^ENCRYPT_METHOD.*/ENCRYPT_METHOD YESCRYPT/' \
        -e 's/^#*ENV_PATH[[:space:]].*/ENV_PATH PATH=\/usr\/bin:\/bin/' \
        -e 's/^#*ENV_SUPATH[[:space:]].*/ENV_SUPATH PATH=\/usr\/sbin:\/usr\/bin:\/sbin:\/bin/' "$ROOT/etc/login.defs"
}

user_password_prompt() {
    local password confirmation required=${1:-no} prompt
    if [[ "$required" == yes ]]; then prompt="$(tr_text "Password for $USER_NAME: " "$USER_NAME slaptažodis: ")"
    else prompt="$(tr_text "Password for $USER_NAME (Enter keeps the existing password): " "$USER_NAME slaptažodis (Enter nekeičia esamo slaptažodžio): ")"; fi
    while :; do
        read -r -s -p "$prompt" password || exit 130
        printf '\n'
        [[ "$required" == yes && -z "$password" && "$USER_PASSWORD_HASH" == '!' ]] || break
        printf "$(tr_text 'A user password is required for the initial login.\n' 'Pradiniam prisijungimui reikia vartotojo slaptažodžio.\n')"
    done
    if [[ -n "$password" ]]; then
        read -r -s -p "$(tr_text 'Repeat password: ' 'Pakartok slaptažodį: ')" confirmation; printf '\n'
        [[ "$password" == "$confirmation" ]] || die "$(tr_text 'Passwords do not match' 'Slaptažodžiai nesutampa')"
        USER_PASSWORD_HASH=$(printf '%s\n' "$password" | openssl passwd -6 -stdin)
    fi
    unset password confirmation
}

system_password_prompt() {
    local password confirmation
    while :; do
        read -r -s -p "$(tr_text "Password for root and $USER_NAME: " "Root ir $USER_NAME slaptažodis: ")" password || exit 130
        printf '\n'
        if [[ -z "$password" ]]; then
            [[ "$ROOT_PASSWORD_HASH" != '!' && "$USER_PASSWORD_HASH" == "$ROOT_PASSWORD_HASH" ]] && break
            printf '%s\n' "$(tr_text 'A shared password is required for the initial login.' 'Pradiniam prisijungimui reikia bendro slaptažodžio.')"
            continue
        fi
        read -r -s -p "$(tr_text 'Repeat password: ' 'Pakartok slaptažodį: ')" confirmation || exit 130
        printf '\n'
        [[ "$password" == "$confirmation" ]] || { printf '%s\n' "$(tr_text 'Passwords do not match; try again.' 'Slaptažodžiai nesutampa; bandyk dar kartą.')"; continue; }
        ROOT_PASSWORD_HASH=$(printf '%s\n' "$password" | openssl passwd -6 -stdin)
        USER_PASSWORD_HASH=$ROOT_PASSWORD_HASH
        break
    done
    unset password confirmation
}

sudo_tools() {
    local source compatibility
    if [[ -x "$ROOT/usr/bin/sudo" && -f "$BASE/sudo-version" ]] && grep -Fxq "${VERSION[sudo]}" "$BASE/sudo-version"; then return 0; fi
    source=$(unpack sudo)
    mkdir -p "$BUILD/sudo" "$BUILD/sudo-compat"
    for compatibility in libdl.a libpthread.a librt.a libutil.a; do
        [[ ! -f "$SDK/sysroot/usr/lib/$compatibility" ]] || cp "$SDK/sysroot/usr/lib/$compatibility" "$BUILD/sudo-compat/"
    done
    (cd "$BUILD/sudo"
     export CPPFLAGS="${CPPFLAGS:-} -I$SDK/sysroot/usr/include"
     export LDFLAGS="${LDFLAGS:-} -L$BUILD/sudo-compat"
     "$source/configure" --build="$HOST" --host="$TARGET" --prefix=/usr \
         --libdir=/usr/lib --libexecdir=/usr/libexec --sysconfdir=/etc --localstatedir=/var \
         --without-pam --without-selinux --without-apparmor --without-ldap \
         --disable-openssl --disable-zlib --disable-log-server --disable-nls \
         --with-env-editor --with-secure-path=/usr/sbin:/usr/bin:/sbin:/bin
     make -j"$JOBS"
     # Tikras root savininkas nustatomas archyvuose per fakeroot.
     make INSTALL_OWNER= DESTDIR="$ROOT" install)
    chmod 4755 "$ROOT/usr/bin/sudo"
    printf '%s\n' "${VERSION[sudo]}" > "$BASE/sudo-version"
}

configure_user() {
    local shell existing sudo_gid=1001 desktop_start_command system_group system_gid
    case "$SHELL_CHOICE" in busybox) shell=/bin/ash ;; *) shell=/bin/$SHELL_CHOICE ;; esac
    existing=$(awk -F: -v name="$USER_NAME" '$1==name {print $3}' "$ROOT/etc/passwd")
    [[ -z "$existing" || "$existing" == 1000 ]] || die "$(tr_text "User $USER_NAME already has a different UID" "Vartotojas $USER_NAME jau turi kitą UID")"
    awk -F: -v name="$USER_NAME" '$3==1000 && $1!=name {exit 1}' "$ROOT/etc/passwd" || die "$(tr_text 'UID 1000 is already used by another user' 'UID 1000 jau užimtas kito vartotojo')"
    [[ -n "$existing" ]] || printf '%s:x:1000:1000:%s:/home/%s:%s\n' "$USER_NAME" "$USER_NAME" "$USER_NAME" "$shell" >> "$ROOT/etc/passwd"
    if ! grep -q "^$USER_NAME:" "$ROOT/etc/group"; then
        awk -F: '$3==1000 {exit 1}' "$ROOT/etc/group" || die "$(tr_text 'GID 1000 is already in use' 'GID 1000 jau užimtas')"
        printf '%s:x:1000:\n' "$USER_NAME" >> "$ROOT/etc/group"
    fi
    # udev rules use these standard groups for device nodes. Creating them
    # avoids boot warnings and makes device permissions resolve consistently.
    for system_group in 'dialout:20' 'kmem:9' 'input:24' 'video:27' \
        'sgx:994' 'lp:7' 'disk:6' 'cdrom:11' 'tape:26' 'kvm:36'; do
        IFS=: read -r system_group system_gid <<< "$system_group"
        if ! grep -q "^${system_group}:" "$ROOT/etc/group"; then
            while awk -F: -v gid="$system_gid" '$3==gid {found=1} END {exit !found}' "$ROOT/etc/group"; do
                system_gid=$((system_gid + 1))
            done
            printf '%s:x:%s:\n' "$system_group" "$system_gid" >> "$ROOT/etc/group"
        fi
    done
    if ! grep -q '^sudo:' "$ROOT/etc/group"; then
        while awk -F: -v gid="$sudo_gid" '$3==gid {found=1} END {exit !found}' "$ROOT/etc/group"; do
            sudo_gid=$((sudo_gid+1))
            (( sudo_gid < 60000 )) || die "$(tr_text 'No free GID for the sudo group' 'Nėra laisvo GID sudo grupei')"
        done
        printf 'sudo:x:%s:%s\n' "$sudo_gid" "$USER_NAME" >> "$ROOT/etc/group"
    else
        awk -F: -v OFS=: -v name="$USER_NAME" '$1=="sudo" {n=split($4,a,","); found=0; for(i=1;i<=n;i++) if(a[i]==name) found=1; if(!found) $4=$4 ($4=="" ? "" : ",") name} {print}' "$ROOT/etc/group" > "$ROOT/etc/group.tmp"
        mv "$ROOT/etc/group.tmp" "$ROOT/etc/group"
    fi
    if [[ "$DESKTOP_CHOICE" != none ]]; then
        grep -q '^audio:' "$ROOT/etc/group" || printf 'audio:x:29:\n' >> "$ROOT/etc/group"
        awk -F: -v OFS=: -v name="$USER_NAME" '$1=="audio" {n=split($4,a,","); found=0; for(i=1;i<=n;i++) if(a[i]==name) found=1; if(!found) $4=$4 ($4=="" ? "" : ",") name} {print}' \
            "$ROOT/etc/group" > "$ROOT/etc/group.tmp"
        mv "$ROOT/etc/group.tmp" "$ROOT/etc/group"
    fi
    if ! grep -q "^$USER_NAME:" "$ROOT/etc/shadow"; then
        printf '%s:%s:%s:0:99999:7:::\n' "$USER_NAME" "$USER_PASSWORD_HASH" "$(( SOURCE_DATE_EPOCH / 86400 ))" >> "$ROOT/etc/shadow"
    elif [[ "$USER_PASSWORD_HASH" != '!' ]]; then
        awk -F: -v OFS=: -v name="$USER_NAME" -v hash="$USER_PASSWORD_HASH" '$1==name {$2=hash} {print}' "$ROOT/etc/shadow" > "$ROOT/etc/shadow.tmp"
        chmod 0600 "$ROOT/etc/shadow.tmp"; mv "$ROOT/etc/shadow.tmp" "$ROOT/etc/shadow"
    fi
    chmod 0600 "$ROOT/etc/shadow"
    if desktop_needs_logind; then
        install -d -m0755 "$ROOT/etc/pam.d"
        local pam_logind_module=pam_systemd.so
        [[ "$INIT_CHOICE" == systemd ]] || pam_logind_module=pam_elogind.so
        cat > "$ROOT/etc/pam.d/login" <<PAM_LOGIN
auth       required     pam_unix.so
account    required     pam_unix.so
password   required     pam_unix.so
session    required     pam_unix.so
session    required     $pam_logind_module
PAM_LOGIN
        cat > "$ROOT/etc/pam.d/su" <<'PAM_SU'
auth       sufficient   pam_rootok.so
auth       required     pam_unix.so
account    required     pam_unix.so
password   required     pam_unix.so
session    required     pam_unix.so
PAM_SU
        cat > "$ROOT/etc/pam.d/other" <<'PAM_OTHER'
auth       required     pam_unix.so
account    required     pam_unix.so
password   required     pam_unix.so
session    required     pam_unix.so
PAM_OTHER
    else
        # Linux-PAM's upstream login service file includes system-auth, but
        # this minimal distribution does not generate that vendor-specific
        # stack.  Write a self-contained stack so LXDE/Fluxbox users can log
        # in on every supported init system.
        install -d -m0755 "$ROOT/etc/pam.d"
        cat > "$ROOT/etc/pam.d/login" <<'PAM_LOGIN_MINIMAL'
auth       required     pam_unix.so
account    required     pam_unix.so
password   required     pam_unix.so
session    required     pam_unix.so
PAM_LOGIN_MINIMAL
        cat > "$ROOT/etc/pam.d/su" <<'PAM_SU_MINIMAL'
auth       sufficient   pam_rootok.so
auth       required     pam_unix.so
account    required     pam_unix.so
password   required     pam_unix.so
session    required     pam_unix.so
PAM_SU_MINIMAL
        cat > "$ROOT/etc/pam.d/other" <<'PAM_OTHER_MINIMAL'
auth       required     pam_unix.so
account    required     pam_unix.so
password   required     pam_unix.so
session    required     pam_unix.so
PAM_OTHER_MINIMAL
    fi
    [[ ! -L "$ROOT/home" && ! -L "$ROOT/home/$USER_NAME" ]] || die "$(tr_text 'User home must not be a symbolic link' 'Vartotojo home neturi būti simbolinė nuoroda')"
    configure_prompt
    mkdir -p "$ROOT/home/$USER_NAME"
    chmod 0700 "$ROOT/home/$USER_NAME"
    [[ -f "$ROOT/home/$USER_NAME/.profile" ]] || printf '[ -r /etc/profile ] && . /etc/profile\n' > "$ROOT/home/$USER_NAME/.profile"
    [[ -f "$ROOT/home/$USER_NAME/.bashrc" ]] || install -m0644 "$ROOT/etc/skel/.bashrc" "$ROOT/home/$USER_NAME/.bashrc"
    [[ -f "$ROOT/home/$USER_NAME/.bash_profile" ]] || cat > "$ROOT/home/$USER_NAME/.bash_profile" <<'BASH_PROFILE'
[ -r "$HOME/.profile" ] && . "$HOME/.profile"
[ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
BASH_PROFILE
    grep -Fq '. "$HOME/.profile"' "$ROOT/home/$USER_NAME/.bash_profile" ||
        printf '\n[ -r "$HOME/.profile" ] && . "$HOME/.profile"\n' >> "$ROOT/home/$USER_NAME/.bash_profile"
    if [[ "$DESKTOP_AUTOSTART" == yes ]]; then
        desktop_start_command=startmate
        case "$DESKTOP_CHOICE" in lxde) desktop_start_command=startlxde ;; fluxbox) desktop_start_command=startfluxbox ;; esac
        cat > "$ROOT/usr/libexec/diy-desktop-autostart" <<'DESKTOP_AUTOSTART_HELPER'
#!/bin/sh
tty_name=$(tty 2>/dev/null) || exit 0
[ "$tty_name" = /dev/tty1 ] || exit 0
uid=$(id -u) || exit 0
marker="/tmp/diy-desktop-autostart-$uid"
# The marker prevents a logout from immediately relaunching the desktop.
# /tmp is cleared on reboot, so the desktop starts automatically next boot.
if ( set -C; : > "$marker" ) 2>/dev/null; then
    DESKTOP_START_COMMAND_PLACEHOLDER
    status=$?
    # If the desktop failed to start, permit a retry at the next login.
    [ "$status" -eq 0 ] || rm -f -- "$marker"
    exit "$status"
fi
exit 0
DESKTOP_AUTOSTART_HELPER
        sed -i "s/DESKTOP_START_COMMAND_PLACEHOLDER/$desktop_start_command/" \
            "$ROOT/usr/libexec/diy-desktop-autostart"
        chmod 0755 "$ROOT/usr/libexec/diy-desktop-autostart"
        if [[ "$SHELL_CHOICE" == zsh ]]; then
            [[ -f "$ROOT/home/$USER_NAME/.zprofile" ]] || : > "$ROOT/home/$USER_NAME/.zprofile"
            grep -Fq '. "$HOME/.profile"' "$ROOT/home/$USER_NAME/.zprofile" ||
                printf '\n[ -r "$HOME/.profile" ] && . "$HOME/.profile"\n' >> "$ROOT/home/$USER_NAME/.zprofile"
        elif [[ "$SHELL_CHOICE" == fish ]]; then
            mkdir -p "$ROOT/home/$USER_NAME/.config/fish"
            if ! grep -Fq '/usr/libexec/diy-desktop-autostart' "$ROOT/home/$USER_NAME/.config/fish/config.fish" 2>/dev/null; then
                cat >> "$ROOT/home/$USER_NAME/.config/fish/config.fish" <<'FISH_AUTOSTART'
if status is-login
    /usr/libexec/diy-desktop-autostart
end
FISH_AUTOSTART
            fi
        fi
        if [[ "$SHELL_CHOICE" != fish ]]; then
            grep -Fq '/usr/libexec/diy-desktop-autostart' "$ROOT/home/$USER_NAME/.profile" ||
                printf '\nif [ -x /usr/libexec/diy-desktop-autostart ]; then\n    /usr/libexec/diy-desktop-autostart\nfi\n' >> "$ROOT/home/$USER_NAME/.profile"
        fi
    fi
    cat > "$ROOT/etc/sudoers.tmp" <<'SUDOERS'
Defaults env_reset
Defaults secure_path="/usr/sbin:/usr/bin:/sbin:/bin"
root ALL=(ALL:ALL) ALL
%sudo ALL=(ALL:ALL) ALL
SUDOERS
    local sudoers_validator
    sudoers_validator=$(command -v visudo) || sudoers_validator=/usr/sbin/visudo
    [[ -x "$sudoers_validator" ]] || die "$(tr_text 'Missing host visudo; install sudo on the build host' 'Trūksta šeimininko visudo; kūrimo kompiuteryje įdiek sudo')"
    "$sudoers_validator" -cf "$ROOT/etc/sudoers.tmp" || die "$(tr_text 'Generated sudoers file failed validation' 'Sugeneruotas sudoers failas nepraėjo patikros')"
    chmod 0440 "$ROOT/etc/sudoers.tmp"
    mv -f "$ROOT/etc/sudoers.tmp" "$ROOT/etc/sudoers"
}

add_user() {
    local requested=${1:-user}
    load_system "${2:-}"
    USER_NAME=$requested
    validate || die "$VALIDATION_ERROR"
    check_host
    if [[ -t 0 && "$USER_PASSWORD_HASH" == '!' ]]; then user_password_prompt yes; fi
    SOURCES="$BASE/sources" CACHE="$WORK_DIR/downloads"
    exec 8> "$BASE/.build-lock"
    flock -n 8 || build_lock_busy "$BASE/.build-lock"
    cross_environment
    progress_start 3 "$BASE/add-user.log" "$(tr_text 'Sudo tools' 'Sudo įrankiai')" \
        "$(tr_text 'User and sudoers' 'Vartotojas ir sudoers')" "$(tr_text 'Packaging images' 'Atvaizdų pakavimas')"
    run_quiet "$(tr_text 'Sudo tools' 'Sudo įrankiai')" sudo_tools
    run_quiet "$(tr_text 'User and sudoers' 'Vartotojas ir sudoers')" configure_user
    save_system
    REPACKING=yes
    run_quiet "$(tr_text 'Packaging images' 'Atvaizdų pakavimas')" verify_and_pack
    progress_stop
    print_qemu_command
    printf "$(tr_text '\nUser %s created with sudo access. ISO: %s/%s.iso\n' '\nVartotojas %s sukurtas su sudo teisėmis. ISO: %s/%s.iso\n')" "$USER_NAME" "$IMAGES" "$SYSTEM_NAME"
    [[ "$USER_PASSWORD_HASH" != '!' ]] || printf "$(tr_text 'If the account is still locked: log in as root and run passwd %s.\n' 'Jei paskyra dar užrakinta: prisijunk kaip root ir vykdyk passwd %s.\n')" "$USER_NAME"
}

repair_login() {
    load_system "${1:-}"
    check_host
    SOURCES="$BASE/sources" CACHE="$WORK_DIR/downloads"
    mkdir -p "$CACHE" "$SOURCES"
    exec 8> "$BASE/.build-lock"
    flock -n 8 || build_lock_busy "$BASE/.build-lock"
    cross_environment
    progress_start 2 "$BASE/repair-login.log" "$(tr_text 'Login and account tools' 'Login ir paskyrų įrankiai')" \
        "$(tr_text 'Packaging images' 'Atvaizdų pakavimas')"
    run_quiet "$(tr_text 'Login and account tools' 'Login ir paskyrų įrankiai')" login_tools
    REPACKING=yes
    run_quiet "$(tr_text 'Packaging images' 'Atvaizdų pakavimas')" verify_and_pack
    progress_stop
    print_qemu_command
    printf "$(tr_text '\nLogin repair installed. New ISO: %s/%s.iso\n' '\nPrisijungimo pataisa įdiegta. Naujas ISO: %s/%s.iso\n')" "$IMAGES" "$SYSTEM_NAME"
}

# HTTPS bibliotekos ir patikimi CA sertifikatai reikalingi ir be paketų tvarkyklės.
download_tls() {
    local source archive
    # Minimalus rootfs po pakavimo nebeturi glibc suderinamumo .a failų.
    mkdir -p "$BUILD/tls-compat"
    for archive in libdl.a libpthread.a librt.a libutil.a; do
        install -m0644 "$SDK/sysroot/usr/lib/$archive" "$BUILD/tls-compat/"
    done
    if [[ ! -f "$ROOT/usr/include/openssl/ssl.h" || ! -f "$ROOT/usr/lib/libssl.so" ]]; then
        source=$(unpack openssl)
        (cd "$source"
         export CPPFLAGS="${CPPFLAGS:-} -I$SDK/sysroot/usr/include"
         export LDFLAGS="${LDFLAGS:-} -L$BUILD/tls-compat"
         ./Configure "$OPENSSL_ARCH" --prefix=/usr --libdir=lib --openssldir=/etc/ssl shared no-tests
         make -j"$JOBS"; make DESTDIR="$ROOT" install_sw)
    fi
    fetch ca-bundle
    install -Dm0644 "$CACHE/ca-bundle-${VERSION[ca-bundle]}.archive" "$ROOT/etc/ssl/cert.pem"
    ln -snf cert.pem "$ROOT/etc/ssl/ca-certificates.crt"
}

wget_tools() {
    [[ "$PKG_WGET" == yes ]] || { rm -f "$ROOT/usr/bin/wget"; return 0; }
    download_tls
    # OpenSSL 4 pašalino SSLv3 metodą ir jo seną NO_SSL3 makrokomandą.
    (export CPPFLAGS="${CPPFLAGS:-} -I$SDK/sysroot/usr/include -DOPENSSL_NO_SSL3_METHOD"
     autotools wget --with-ssl=openssl --without-libpsl --without-included-regex \
         --disable-nls --without-zlib)
    [[ -x "$ROOT/usr/bin/wget" ]] || die "$(tr_text 'Missing wget' 'Trūksta wget')"
    # Naudojamas tas pats CA rinkinys kaip curl; TLS patikra paliekama įjungta.
    printf 'ca_certificate = /etc/ssl/cert.pem\n' > "$ROOT/etc/wgetrc"
}

# OpenSSH client and server. The server is started by the selected init system.
openssh_tools() {
    [[ "$PKG_OPENSSH" == yes ]] || {
        rm -f "$ROOT/usr/bin/ssh" "$ROOT/usr/bin/scp" "$ROOT/usr/bin/sftp" \
            "$ROOT/usr/bin/ssh-add" "$ROOT/usr/bin/ssh-agent" "$ROOT/usr/bin/ssh-keygen" \
            "$ROOT/usr/bin/ssh-keyscan" "$ROOT/usr/bin/ssh-copy-id" "$ROOT/usr/sbin/sshd"
        return 0
    }
    download_tls
    [[ -e "$ROOT/usr/lib/libz.so" ]] || desktop_package zlib
    (
        export CPPFLAGS="${CPPFLAGS:-} -I$ROOT/usr/include -I$SDK/sysroot/usr/include"
        export LDFLAGS="${LDFLAGS:-} -L$ROOT/usr/lib -Wl,-rpath-link,$ROOT/usr/lib"
        autotools openssh --sysconfdir=/etc/ssh --with-privsep-user=sshd \
            --with-ssl-dir="$ROOT/usr" --with-zlib="$ROOT/usr" \
            --without-pam --without-kerberos5 --without-selinux --without-libedit \
            --without-xauth --with-privsep-path=/var/empty
    )
    [[ -x "$ROOT/usr/bin/ssh" && -x "$ROOT/usr/bin/scp" && -x "$ROOT/usr/bin/sftp" && -x "$ROOT/usr/sbin/sshd" ]] ||
        die "$(tr_text 'OpenSSH build did not install its client and sshd server' 'OpenSSH kūrimas neįdiegė kliento įrankių ir sshd serverio')"
}

extra_programs() {
    local source
    if [[ "$PKG_NANO" == yes ]]; then
        (export CPPFLAGS="${CPPFLAGS:-} -I$SDK/sysroot/usr/include"
         autotools nano --disable-nls --disable-libmagic --enable-utf8)
    else rm -f "$ROOT/usr/bin/nano"; fi
    if [[ "$PKG_NEOFETCH" == yes ]]; then
        source=$(unpack neofetch)
        install -m0755 "$source/neofetch" "$ROOT/usr/bin/neofetch"
        install -Dm0644 "$source/LICENSE.md" "$ROOT/usr/share/licenses/neofetch/LICENSE.md"
    else rm -f "$ROOT/usr/bin/neofetch"; fi
    if [[ "$PKG_VIM" == yes ]]; then vim_tools
    else rm -f "$ROOT/usr/bin/vim"; fi
    if [[ "$PKG_FDISK" == no ]]; then
        rm -f "$ROOT/usr/bin/fdisk" "$ROOT/usr/sbin/fdisk"
    fi
}

geany_application() {
    local source
    [[ "$PKG_GEANY" == yes ]] || { rm -f "$ROOT/usr/bin/geany"; return 0; }
    source=$(unpack geany)
    (export CPPFLAGS="${CPPFLAGS:-} -I$ROOT/usr/include -I$SDK/sysroot/usr/include"
     autotools geany --disable-vte --disable-nls)
    [[ -x "$ROOT/usr/bin/geany" ]] || die "$(tr_text 'Geany build did not install its executable' 'Geany kūrimas neįdiegė programos failo')"
    install -Dm0644 "$source/geany.desktop.in" "$ROOT/usr/share/applications/geany.desktop"
}

firefox_application() {
    local archive
    [[ "$PKG_FIREFOX" == yes ]] || { rm -rf "$ROOT/opt/firefox"; rm -f "$ROOT/usr/bin/firefox" "$ROOT/usr/bin/diy-firefox-sandbox"; return 0; }
    archive=$(archive_path firefox)
    [[ -f "$archive" ]] || fetch firefox
    mkdir -p "$ROOT/opt/firefox"
    tar -xJf "$archive" --strip-components=1 -C "$ROOT/opt/firefox"
    [[ -x "$ROOT/opt/firefox/firefox" ]] || die "$(tr_text 'Mozilla archive did not contain the Firefox executable' 'Mozilla archyve nerastas Firefox programos failas')"
    [[ -x "$ROOT/usr/bin/bwrap" ]] || die "$(tr_text 'Firefox isolation requires bubblewrap' 'Firefox izoliavimui reikia bubblewrap')"
    mkdir -p "$ROOT/opt/firefox/distribution"
    cat > "$ROOT/opt/firefox/distribution/policies.json" <<'FIREFOX_POLICIES'
{
  "policies": {
    "DNSOverHTTPS": {
      "Enabled": true,
      "ProviderURL": "https://dns.google/dns-query",
      "Locked": false,
      "Fallback": true
    }
  }
}
FIREFOX_POLICIES
    cat > "$ROOT/usr/bin/diy-firefox-sandbox" <<'FIREFOX_SANDBOX'
#!/usr/bin/bash
# Firefox sees a private home and only the user's Downloads directory.
set -euo pipefail
if (( EUID == 0 )); then
    printf '%s\n' 'Refusing to start sandboxed Firefox as root.' >&2
    exit 1
fi
user=$(id -un)
uid=$(id -u)
gid=$(id -g)
home=${HOME:?HOME is not set}
private_home="$home/.local/share/diy-linux/firefox/home"
downloads="$home/Downloads/Firefox"
mkdir -p "$private_home/Downloads" "$downloads"
    chmod 700 "$home/.local/share/diy-linux" "$home/.local/share/diy-linux/firefox" "$private_home"

# System files are read-only. Firefox settings/cookies persist in private_home.
args=(
    --die-with-parent --new-session
    --unshare-user --uid "$uid" --gid "$gid"
    --unshare-pid --unshare-ipc --unshare-uts
    --clearenv
    --ro-bind /usr /usr
    --ro-bind /etc /etc
    --ro-bind /opt/firefox /opt/firefox
    --symlink usr/bin /bin
    --symlink usr/sbin /sbin
    --symlink usr/lib /lib
    --symlink usr/lib /lib64
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --dir /tmp/.X11-unix
    --ro-bind-try /tmp/.X11-unix /tmp/.X11-unix
    --dir /run
    --dir /home
    --dir "/home/$user"
    --bind "$private_home" "/home/$user"
    --bind "$downloads" "/home/$user/Downloads"
    --setenv HOME "/home/$user"
    --setenv USER "$user"
    --setenv LOGNAME "$user"
    --setenv PATH /usr/bin:/bin
    --setenv DISPLAY "${DISPLAY:-}"
    --setenv LANG "${LANG:-C.UTF-8}"
    --setenv GDK_BACKEND x11
    --setenv MOZ_ENABLE_WAYLAND 0
    --chdir "/home/$user"
)
if [[ -n ${XDG_RUNTIME_DIR:-} && -S "$XDG_RUNTIME_DIR/pulse/native" ]]; then
    # Expose only this session's PulseAudio socket inside Firefox's sandbox.
    args+=(--dir /run/user --dir "/run/user/$uid"
           --ro-bind "$XDG_RUNTIME_DIR/pulse" "/run/user/$uid/pulse"
           --setenv XDG_RUNTIME_DIR "/run/user/$uid"
           --setenv PULSE_SERVER "unix:/run/user/$uid/pulse/native")
    pulse_cookie="$home/.config/pulse/cookie"
    if [[ -f "$pulse_cookie" ]]; then
        mkdir -p "$private_home/.config/pulse"
        args+=(--ro-bind "$pulse_cookie" "/home/$user/.config/pulse/cookie")
    fi
fi
xauthority=${XAUTHORITY:-$home/.Xauthority}
if [[ -n ${LC_ALL:-} ]]; then args+=(--setenv LC_ALL "$LC_ALL"); fi
if [[ -f "$xauthority" ]]; then
    args+=(--ro-bind "$xauthority" /run/diy-firefox.Xauthority
           --setenv XAUTHORITY /run/diy-firefox.Xauthority)
fi
exec /usr/bin/bwrap "${args[@]}" -- /usr/bin/dbus-run-session -- /opt/firefox/firefox "$@"
FIREFOX_SANDBOX
    chmod 0755 "$ROOT/usr/bin/diy-firefox-sandbox"
    cat > "$ROOT/usr/bin/firefox" <<'FIREFOX_LAUNCHER'
#!/bin/sh
exec /usr/bin/diy-firefox-sandbox "$@"
FIREFOX_LAUNCHER
    chmod 0755 "$ROOT/usr/bin/firefox"
    install -Dm0644 "$ROOT/opt/firefox/browser/chrome/icons/default/default128.png" "$ROOT/usr/share/icons/hicolor/128x128/apps/firefox.png"
    cat > "$ROOT/usr/share/applications/firefox.desktop" <<'FIREFOX_DESKTOP'
[Desktop Entry]
Name=Firefox
Comment=Browse the web in a filesystem sandbox
Exec=/usr/bin/firefox %u
Icon=firefox
Terminal=false
Type=Application
Categories=Network;WebBrowser;
FIREFOX_DESKTOP
}

desktop_applications() {
    [[ "$DESKTOP_CHOICE" == mate || "$DESKTOP_CHOICE" == lxde || "$DESKTOP_CHOICE" == fluxbox ]] || return 0
    [[ "$DESKTOP_CHOICE" == mate ]] && step "desktop-app-geany-$PKG_GEANY" geany_application
    step "desktop-app-firefox-$PKG_FIREFOX" firefox_application
}

vim_tools() {
    local source
    source=$(unpack vim)
    # Vim configure vykdo kelias target patikras; x86_64/glibc atsakymai pateikiami aiškiai.
    (cd "$source"
     export CPPFLAGS="${CPPFLAGS:-} -I$ROOT/usr/include -I$BUILD/ncurses/include -I$SOURCES/ncurses-${VERSION[ncurses]}/include -I$SDK/sysroot/usr/include"
     vim_cv_toupper_broken=no vim_cv_terminfo=yes vim_cv_tgetent=zero \
     vim_cv_tty_group=tty vim_cv_tty_mode=0620 vim_cv_getcwd_broken=no \
     vim_cv_stat_ignores_slash=no vim_cv_memmove_handles_overlap=yes \
     ./configure --build="$HOST" --host="$TARGET" --prefix=/usr \
         --with-tlib=ncursesw --enable-gui=no --without-x --disable-nls \
         --disable-acl --disable-gpm --disable-selinux --disable-canberra \
         --disable-python3interp --disable-pythoninterp --disable-perlinterp \
         --disable-rubyinterp --disable-luainterp --disable-tclinterp \
         --with-features=normal
     make -j"$JOBS"
     make DESTDIR="$ROOT" install)
    [[ -x "$ROOT/usr/bin/vim" ]] || die "$(tr_text 'Missing Vim' 'Trūksta Vim')"
}

inetutils_tools() {
    local -a ping_options=(--disable-ping --disable-ping6)
    [[ "$PKG_PING" != yes ]] || ping_options=(--enable-ping --enable-ping6)
    (export CPPFLAGS="${CPPFLAGS:-} -I$SDK/sysroot/usr/include"
     autotools inetutils --disable-servers --disable-ifconfig "${ping_options[@]}" \
         --disable-traceroute --disable-ftp --disable-telnet --disable-rlogin \
         --disable-rcp --disable-rexec --disable-tftp)
}

network_tools() {
    [[ "$PKG_PING" == yes ]] || { rm -f "$ROOT/usr/bin/ping" "$ROOT/usr/bin/ping6"; return 0; }
    # GNU userland jau įtraukia hostname ir pasirinktą ping; BusyBox variantui
    # papildomas GNU ping kompiliuojamas tik šiame etape.
    [[ -f "$ROOT/usr/bin/ping" && -f "$ROOT/usr/bin/ping6" ]] || inetutils_tools
    [[ -f "$ROOT/usr/bin/ping" && -f "$ROOT/usr/bin/ping6" ]] || die "$(tr_text 'Missing ping / ping6' 'Trūksta ping / ping6')"
    # Raw ICMP socket reikia teisių; inetutils po socket sukūrimo jas sumažina.
    # Archyve fakeroot priskiria root savininką, todėl ping veikia paprastam vartotojui.
    chmod 4755 "$ROOT/usr/bin/ping" "$ROOT/usr/bin/ping6"
    # getprotobyname() skaito šį failą; GNU ping be jo neatpažįsta ICMP.
    if [[ ! -s "$ROOT/etc/protocols" ]]; then
        cat > "$ROOT/etc/protocols" <<'PROTOCOLS'
ip 0 IP
icmp 1 ICMP
igmp 2 IGMP
tcp 6 TCP
udp 17 UDP
ipv6 41 IPv6
ipv6-route 43 IPv6-Route
ipv6-frag 44 IPv6-Frag
ipv6-icmp 58 IPv6-ICMP
ipv6-nonxt 59 IPv6-NoNxt
ipv6-opts 60 IPv6-Opts
sctp 132 SCTP
PROTOCOLS
        chmod 0644 "$ROOT/etc/protocols"
    fi
}

userland() {
    local source number patch_file fdisk_option
    fdisk_option=--disable-fdisk
    [[ "$PKG_FDISK" != yes ]] || fdisk_option=--enable-fdisk
    autotools libxcrypt --disable-werror
    # ncurses otherwise installs target executables with host `install -s`,
    # which invokes the host-architecture strip and fails for cross builds.
    # Final image packing strips target ELF files with the cross-toolchain.
    autotools ncurses --with-shared --enable-widec --without-debug --without-ada \
        --without-cxx-binding --enable-pc-files --with-pkg-config-libdir=/usr/lib/pkgconfig \
        --with-build-cc="$HOST_CC" --disable-stripping
    ln -snf libncursesw.so "$ROOT/usr/lib/libncurses.so"
    ln -snf ncursesw.pc "$ROOT/usr/lib/pkgconfig/ncurses.pc"
    if needs_busybox; then
        source=$(unpack busybox)
        if [[ ! -f "$source/.config" ]]; then
            make -C "$source" defconfig
            # Kompiliuojama dinamiškai prieš mūsų glibc, ne prieš šeimininko libc.
            sed -i 's/^CONFIG_STATIC=y/# CONFIG_STATIC is not set/' "$source/.config"
        fi
        # BusyBox tc naudoja pašalintą CBQ ABI iš senų Linux antraščių.
        # Taikoma ir jau esančiai .config, kad --resume sutaisytų nutrūkusį build.
        # GNU įrankių variante tc pateikia iproute2; BusyBox variante jo neįtraukiame.
        sed -i -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
            -e 's/^CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/' "$source/.config"
        local applet enabled
        for applet in FDISK PING PING6 WGET; do
            case "$applet" in PING|PING6) enabled=$PKG_PING ;; FDISK) enabled=$PKG_FDISK ;; WGET) enabled=no ;; esac
            if [[ "$enabled" == yes ]]; then
                sed -i "s/^# CONFIG_${applet} is not set/CONFIG_${applet}=y/" "$source/.config"
            else
                sed -i "s/^CONFIG_${applet}=y/# CONFIG_${applet} is not set/" "$source/.config"
            fi
        done
        if [[ "$TOOLS_CHOICE" == busybox && ( "$INIT_CHOICE" == busybox || "$INIT_CHOICE" == openrc ) ]]; then
            # Both minimal init setups need a local console getty. OpenRC's
            # BusyBox profile cannot depend on util-linux's separate agetty.
            for applet in GETTY LOGIN; do
                sed -i -E \
                    -e "s/^# CONFIG_${applet} is not set/CONFIG_${applet}=y/" \
                    -e "s/^CONFIG_${applet}=.*/CONFIG_${applet}=y/" "$source/.config"
            done
        fi
        make -C "$source" -j"$JOBS" CROSS_COMPILE="$TARGET-" CONFIG_EXTRA_LDLIBS=crypt
        if [[ "$TOOLS_CHOICE" == busybox ]]; then
            make -C "$source" CROSS_COMPILE="$TARGET-" CONFIG_PREFIX="$ROOT" install
        else
            install -m0755 "$source/busybox" "$ROOT/usr/bin/busybox"
        fi
    fi
    if [[ "$TOOLS_CHOICE" == gnu ]]; then
        autotools coreutils --disable-nls --without-gmp --disable-single-binary
        autotools grep --disable-nls --disable-perl-regexp
        autotools sed --disable-nls
        autotools findutils --disable-nls
        autotools gawk --disable-nls --without-readline
        autotools tar --disable-nls
        autotools gzip
        autotools procps --disable-nls --disable-kill --without-systemd
        # Host ncurses*-config gali pridėti -ltinfo, kurio target neturi.
        # Išjungti host pagalbinius scenarijus; pkg-config jau izoliuotas rootfs.
        autotools util-linux NCURSESW6_CONFIG=/bin/false NCURSESW5_CONFIG=/bin/false \
            NCURSES6_CONFIG=/bin/false NCURSES5_CONFIG=/bin/false --without-python --without-systemd --without-libcap-ng \
            --disable-makeinstall-chown --disable-makeinstall-setuid --without-pam "$fdisk_option"
        inetutils_tools          # hostname būtinas nepriklausomai nuo ping varnelės.
    fi
    case "$SHELL_CHOICE" in
        bash)
            build_bash
            ln -snf bash "$ROOT/usr/bin/sh"
            ;;
        dash) autotools dash; ln -snf dash "$ROOT/usr/bin/sh" ;;
        zsh|fish)
            autotools dash; ln -snf dash "$ROOT/usr/bin/sh"
            if [[ "$SHELL_CHOICE" == zsh ]]; then
                autotools zsh --enable-etcdir=/etc/zsh --with-term-lib=ncursesw --disable-pcre
            else build_fish; fi
            ;;
        busybox)
            ln -snf busybox "$ROOT/usr/bin/ash"
            ln -snf busybox "$ROOT/usr/bin/sh"
            ;;
    esac
    if [[ "$SHELL_CHOICE" != bash ]]; then
        build_bash              # Neofetch (ir makepkg) reikia Bash; /bin/sh nekeičia.
    fi
    # kmod naudojamas abiem init variantams; GNU komandos papildomos iproute2.
    meson_package kmod -Dmanpages=false -Dbashcompletiondir=no -Dfishcompletiondir=no \
        -Dzshcompletiondir=no -Dzlib=disabled -Dxz=disabled -Dzstd=disabled -Dopenssl=disabled
    # OpenRC's keymaps and save-keymaps services call loadkeys and dumpkeys.
    # Include their upstream implementation in every system profile.
    autotools kbd --disable-nls --disable-vlock
    if [[ "$TOOLS_CHOICE" == gnu ]]; then
        source=$(unpack iproute2)
        (cd "$source"
         make -j"$JOBS" CC="$CC" HOSTCC="$HOST_CC" AR="$AR" \
             KERNEL_INCLUDE="$ROOT/usr/include" SBINDIR=/usr/sbin
         make CC="$CC" DESTDIR="$ROOT" SBINDIR=/usr/sbin install)
    fi
}

# 6. Init. OpenRC ir systemd kompiliuojami tiesiogiai su Meson/Ninja.
# Mažos init sistemos kompiliuojamos prieš išsaugotą SDK, be PAM / host bibliotekų.
small_init_tools() {
    local source name command
    case "$INIT_CHOICE" in
        sysvinit)
            source=$(unpack sysvinit)
            make -C "$source/src" -j"$JOBS" CC="$CC" ROOT="$ROOT" \
                CPPFLAGS="-I$SDK/sysroot/usr/include" WITH_SELINUX=no DISTRO=DIY \
                base_bindir=/usr/bin base_sbindir=/usr/sbin
            make -C "$source/src" CC="$CC" ROOT="$ROOT" \
                CPPFLAGS="-I$SDK/sysroot/usr/include" WITH_SELINUX=no DISTRO=DIY \
                base_bindir=/usr/bin base_sbindir=/usr/sbin install
            ;;
        runit)
            source=$(unpack runit)
            # Senoji build sistema naudoja conf-cc / conf-ld, ne aplinkos CC.
            printf '%s -O2 -std=gnu89 -I%s/sysroot/usr/include\n' "$CC" "$SDK" > "$source/src/conf-cc"
            printf '%s\n' "$CC" > "$source/src/conf-ld"
            sed -i 's/ -static$//' "$source/src/Makefile"
            (cd "$source"; sh package/compile)
            for command in "$source/command/"*; do
                case ${command##*/} in runit|runit-init) install -m0755 "$command" "$ROOT/usr/sbin/" ;;
                    *) install -m0755 "$command" "$ROOT/usr/bin/" ;;
                esac
            done
            ;;
        dinit)
            source=$(unpack dinit)
            # Dinit has a small code generator that must run on the host. Keep
            # its CPP/LDFLAGS free of target sysroot paths; the Dinit binaries
            # themselves still use the cross compiler and target libraries.
            (cd "$source"
             make -j"$JOBS" CXX="$CXX" CXX_FOR_BUILD="$HOST_CXX" \
                 CXXFLAGS='-std=c++11 -Os -Wall -fno-rtti -fno-plt' \
                 CPPFLAGS="-I$ROOT/usr/include -I$SDK/sysroot/usr/include" \
                 LDFLAGS="-L$ROOT/usr/lib -Wl,-rpath-link,$ROOT/usr/lib" \
                 CPPFLAGS_FOR_BUILD= CXXFLAGS_FOR_BUILD='-O2' LDFLAGS_FOR_BUILD= \
                 BINDIR=/usr/bin SBINDIR=/usr/sbin MANDIR=/usr/share/man \
                 SYSCONTROLSOCKET=/run/dinitctl BUILD_SHUTDOWN=yes SHUTDOWN_PREFIX=dinit-
             make DESTDIR="$ROOT" BINDIR=/usr/bin SBINDIR=/usr/sbin MANDIR=/usr/share/man \
                 SYSCONTROLSOCKET=/run/dinitctl BUILD_SHUTDOWN=yes SHUTDOWN_PREFIX=dinit- install)
            ;;
        s6)
            # Full s6 stack: supervision, dependency-aware service management,
            # and the upstream Linux PID 1 / shutdown framework.
            for name in skalibs execline s6 s6-rc s6-linux-init; do
                source=$(unpack "$name")
                local -a skarnet_configure_args
                skarnet_configure_args=(
                    --host="$TARGET" --prefix=/usr --libdir=/usr/lib --includedir=/usr/include
                    --with-include="$ROOT/usr/include" --with-lib="$ROOT/usr/lib"
                    --disable-shared --enable-static
                )
                if [[ "$name" == skalibs ]]; then
                    skarnet_configure_args+=(
                        --with-sysdep-devurandom=yes
                        --with-sysdep-posixspawnearlyreturn=no
                        --with-sysdep-procselfexe=/proc/self/exe
                        --with-sysdep-selectinfinite=yes
                    )
                else
                    skarnet_configure_args+=(--with-sysdeps="$ROOT/usr/lib/skalibs/sysdeps")
                fi
                (
                    cd "$source"
                    CC="$CC" AR="$AR" RANLIB="$RANLIB" \
                    CPPFLAGS="-I$ROOT/usr/include -I$SDK/sysroot/usr/include" \
                    ./configure "${skarnet_configure_args[@]}"
                    make -j"$JOBS"
                    make DESTDIR="$ROOT" install
                )
            done
            ;;
    esac
}

# Bendras boot / shutdown runit, s6 ir SysVinit. /init jau sumontavo proc/sys/dev.
configure_small_init() {
    local port directory tty1_getty
    tty1_getty='/sbin/agetty tty1 38400 linux'
    [[ "$AUTOLOGIN" != yes ]] || tty1_getty="/sbin/agetty --autologin $USER_NAME tty1 38400 linux"
    mkdir -p "$ROOT/etc/diy" "$ROOT/usr/libexec"
    cat > "$ROOT/etc/diy/boot" <<'BOOT'
#!/bin/sh
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
cd / || exit 1
hostname -F /etc/hostname
mkdir -p /dev/pts
mount -a
# mount -a cannot mount devpts unless its mountpoint exists. Unix98 PTYs
# are required by xterm, terminal emulators, ssh, and other pseudo terminals.
if ! grep -q ' /dev/pts devpts ' /proc/mounts; then
    mount -t devpts devpts /dev/pts -o gid=5,mode=0620,ptmxmode=0666,nosuid,noexec 2>/dev/null || :
fi
ip link set lo up
ip addr replace 127.0.0.1/8 dev lo
mkdir -p /run/lock /run/dhcpcd
: > /run/utmp
BOOT
    # DHCP logs on the same tty as getty can hide the login prompt. SysVinit
    # starts its boot script before respawn services, so daemonize quietly here
    # and keep diagnostics in the system log instead of inittab's console.
    if [[ ( "$INIT_CHOICE" == sysvinit || "$INIT_CHOICE" == busybox ) &&
          "$NETWORK" == yes && "$DESKTOP_CHOICE" == none ]]; then
        cat >> "$ROOT/etc/diy/boot" <<'SYSV_DHCP'
/usr/sbin/dhcpcd --background --quiet >>/var/log/dhcpcd.log 2>&1
SYSV_DHCP
    fi
    cat > "$ROOT/etc/diy/shutdown" <<'SHUTDOWN'
#!/bin/sh
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
sync
umount -a -r 2>/dev/null || :
exec /usr/libexec/diy-powerctl "${1:-poweroff}"
SHUTDOWN
    # Syscall wrapper yra tik target rootfs; niekada nevykdomas šeimininke.
    if [[ "$INIT_CHOICE" != s6 ]]; then cat > "$BUILD/diy-powerctl.c" <<'POWER'
#include <unistd.h>
#include <sys/reboot.h>
#include <string.h>
#include <stdio.h>
int main(int argc,char **argv) {
    if (geteuid()!=0) { fputs("Reikia root teisių\n",stderr); return 1; }
    sync();
    if (reboot(argc>1 && !strcmp(argv[1],"reboot") ? RB_AUTOBOOT : RB_POWER_OFF)<0) { perror("reboot"); return 1; }
    return 0;
}
POWER
    "$CC" -O2 -I"$SDK/sysroot/usr/include" "$BUILD/diy-powerctl.c" -o "$ROOT/usr/libexec/diy-powerctl"
    fi
    # util-linux login writes to /var/run/utmp, while boot initializes
    # /run/utmp. Keep the traditional path pointed at the same runtime dir.
    if [[ -d "$ROOT/var/run" && ! -L "$ROOT/var/run" ]]; then
        if find "$ROOT/var/run" -mindepth 1 -print -quit | grep -q .; then
            cp -a "$ROOT/var/run/." "$ROOT/run/"
        fi
        rmdir "$ROOT/var/run"
    fi
    ln -snf ../run "$ROOT/var/run"
    chmod 0755 "$ROOT/etc/diy/boot" "$ROOT/etc/diy/shutdown"
    if [[ "$INIT_CHOICE" == sysvinit ]]; then
        cat > "$ROOT/etc/inittab" <<'SYSV'
id:3:initdefault:
si::sysinit:/etc/diy/boot
ca::ctrlaltdel:/sbin/shutdown -r now
l0:0:wait:/etc/diy/shutdown poweroff
l6:6:wait:/etc/diy/shutdown reboot
c1:2345:respawn:/sbin/agetty tty1 38400 linux
s0:2345:respawn:/sbin/agetty -L @SERIAL_TTY@ 115200 vt100
SYSV
        sed -i "s/@SERIAL_TTY@/$SERIAL_TTY/g" "$ROOT/etc/inittab"
        if [[ "$AUTOLOGIN" == yes ]]; then
            sed -i "s|^c1:2345:respawn:.*|c1:2345:respawn:$tty1_getty|" "$ROOT/etc/inittab"
        fi
        return
    fi
    if [[ "$INIT_CHOICE" == dinit ]]; then
        mkdir -p "$ROOT/etc/dinit.d" "$ROOT/etc/dinit"
        # Dinit owns the session/power daemons so failures are visible and
        # services restart cleanly. The shared boot helper starts D-Bus first.
        if desktop_needs_logind; then
            cat > "$ROOT/etc/dinit.d/elogind" <<'DINIT_ELOGIND'
type = process
command = /usr/libexec/elogind
restart = true
depends-on: diy-boot
DINIT_ELOGIND
        fi
        if [[ "$needs_desktop_auth" == yes ]]; then
            cat > "$ROOT/etc/dinit.d/polkit" <<'DINIT_POLKIT'
type = process
command = /usr/lib/polkit-1/polkitd --no-debug --log-level=notice
restart = true
depends-on: elogind
DINIT_POLKIT
        fi
        if [[ "$upower_enabled" == yes ]]; then
            cat > "$ROOT/etc/dinit.d/upower" <<'DINIT_UPOWER'
type = process
command = /usr/libexec/upowerd
restart = true
depends-on: diy-boot
DINIT_UPOWER
        fi
        if [[ ${PKG_MATE_CONTROL_CENTER:-no} == yes ]]; then
            cat > "$ROOT/etc/dinit.d/udisks2" <<'DINIT_UDISKS'
type = process
command = /usr/libexec/udisks2/udisksd
restart = true
depends-on: elogind
depends-on: polkit
DINIT_UDISKS
        fi
        cat > "$ROOT/etc/dinit.d/boot" <<'DINIT_BOOT'
# Dinit starts this service by default as PID 1.
type = internal
depends-on: diy-boot
depends-ms: tty1
depends-ms: ttyS0
DINIT_BOOT
        if desktop_needs_logind; then
            printf 'depends-on: elogind\n' >> "$ROOT/etc/dinit.d/boot"
        fi
        if [[ "$needs_desktop_auth" == yes ]]; then
            printf 'depends-on: polkit\n' >> "$ROOT/etc/dinit.d/boot"
        fi
        if [[ "$upower_enabled" == yes ]]; then
            printf 'depends-on: upower\n' >> "$ROOT/etc/dinit.d/boot"
        fi
        if [[ ${PKG_MATE_CONTROL_CENTER:-no} == yes ]]; then
            printf 'depends-on: udisks2\n' >> "$ROOT/etc/dinit.d/boot"
        fi
        cat > "$ROOT/etc/dinit.d/diy-boot" <<'DINIT_BOOT_SETUP'
type = scripted
command = /etc/diy/boot
restart = false
DINIT_BOOT_SETUP
        printf 'type = process\ncommand = %s\nrestart = true\ndepends-on: diy-boot\n' "$tty1_getty" > "$ROOT/etc/dinit.d/tty1"
        if desktop_needs_logind; then
            printf 'depends-on: elogind\n' >> "$ROOT/etc/dinit.d/tty1"
        fi
        cat > "$ROOT/etc/dinit.d/ttyS0" <<'DINIT_TTYS0'
type = process
command = /sbin/agetty -L ttyS0 115200 vt100
restart = true
depends-on: diy-boot
DINIT_TTYS0
        if [[ "$NETWORK" == yes && "$DESKTOP_CHOICE" == none ]]; then
            cat > "$ROOT/etc/dinit.d/dhcpcd" <<'DINIT_DHCP'
type = process
command = /usr/sbin/dhcpcd --nobackground
restart = true
depends-on: diy-boot
DINIT_DHCP
            printf 'depends-on: dhcpcd\n' >> "$ROOT/etc/dinit.d/boot"
        fi
        cat > "$ROOT/etc/dinit/shutdown-hook" <<'DINIT_SHUTDOWN'
#!/bin/sh
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
sync
umount -a -r 2>/dev/null || :
exit 0
DINIT_SHUTDOWN
        chmod 0755 "$ROOT/etc/dinit/shutdown-hook"
        ln -snf dinit-reboot "$ROOT/usr/sbin/reboot"
        ln -snf dinit-poweroff "$ROOT/usr/sbin/poweroff"
        ln -snf dinit-halt "$ROOT/usr/sbin/halt"
        return
    fi
    # BusyBox init uses the common shutdown script and power syscall helper,
    # but its inittab is generated by configure_system below.
    [[ "$INIT_CHOICE" != busybox ]] || return 0
    if [[ "$INIT_CHOICE" == s6 ]]; then
        local skel="$ROOT/etc/s6-linux-init/skel" source_dir="$ROOT/etc/s6-rc/source"
        mkdir -p "$skel" "$source_dir/default/contents.d" \
            "$source_dir/boot-setup/dependencies.d" \
            "$source_dir/tty1/dependencies.d" "$source_dir/tty1" \
            "$source_dir/ttyS0/dependencies.d" "$source_dir/ttyS0"
        printf '/etc/diy/boot\n' > "$source_dir/boot-setup/up"
        printf 'oneshot\n' > "$source_dir/boot-setup/type"
        printf 'bundle\n' > "$source_dir/default/type"
        for port in boot-setup tty1 ttyS0; do : > "$source_dir/default/contents.d/$port"; done
        for port in tty1 ttyS0; do
            printf 'longrun\n' > "$source_dir/$port/type"
            : > "$source_dir/$port/dependencies.d/boot-setup"
            if [[ "$port" == tty1 ]]; then
                printf '#!/bin/sh\nexec %s\n' "$tty1_getty" > "$source_dir/$port/run"
            else
                printf '#!/bin/sh\nexec /sbin/agetty -L ttyS0 115200 vt100\n' > "$source_dir/$port/run"
            fi
            chmod 0755 "$source_dir/$port/run"
            : > "$source_dir/default/contents.d/$port"
        done
        if [[ "$NETWORK" == yes && "$DESKTOP_CHOICE" == none ]]; then
            mkdir -p "$source_dir/dhcpcd/dependencies.d"
            printf 'longrun\n' > "$source_dir/dhcpcd/type"
            : > "$source_dir/dhcpcd/dependencies.d/boot-setup"
            printf '#!/bin/sh\nexec /usr/sbin/dhcpcd --nobackground\n' > "$source_dir/dhcpcd/run"
            chmod 0755 "$source_dir/dhcpcd/run"
            : > "$source_dir/default/contents.d/dhcpcd"
        fi
        cat > "$skel/rc.init" <<'S6_RC_INIT'
#!/bin/sh
set -eu
/usr/bin/s6-rc-compile /run/s6-rc-compiled /etc/s6-rc/source
/usr/bin/s6-rc-init -c /run/s6-rc-compiled -l /run/s6-rc-live /run/service
exec /usr/bin/s6-rc -l /run/s6-rc-live -u change "${1:-default}"
S6_RC_INIT
        cat > "$skel/runlevel" <<'S6_RC_RUNLEVEL'
#!/bin/sh
set -eu
case "${1:-default}" in
    0) exec /sbin/poweroff ;;
    6) exec /sbin/reboot ;;
    default|2|3|4|5) exec /usr/bin/s6-rc -l /run/s6-rc-live -u change default ;;
    *) echo "Unsupported s6-rc runlevel: $1" >&2; exit 1 ;;
esac
S6_RC_RUNLEVEL
        cat > "$skel/rc.shutdown" <<'S6_RC_SHUTDOWN'
#!/bin/sh
set -eu
/usr/bin/s6-rc -l /run/s6-rc-live -da change
S6_RC_SHUTDOWN
        chmod 0755 "$skel/rc.init" "$skel/runlevel" "$skel/rc.shutdown"
        cat > "$ROOT/usr/libexec/diy-s6-init" <<'S6_INIT_WRAPPER'
#!/bin/sh
set -eu
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
basedir=/run/s6-linux-init
rm -rf "$basedir"
/usr/bin/s6-linux-init-maker -n -p /usr/bin:/usr/sbin:/bin:/sbin \
    -c "$basedir" -f /etc/s6-linux-init/skel "$basedir"
mkdir -p /sbin
cp -a "$basedir/bin/." /sbin/
exec /sbin/init
S6_INIT_WRAPPER
        chmod 0755 "$ROOT/usr/libexec/diy-s6-init"
        return 0
    fi
    rm -f "$ROOT/usr/sbin/reboot" "$ROOT/usr/sbin/poweroff" "$ROOT/usr/sbin/halt"
    if [[ "$INIT_CHOICE" == runit ]]; then
        directory="$ROOT/etc/service"
        mkdir -p "$directory" "$ROOT/etc/runit"
        printf '#!/bin/sh\ncd / || exit 1\n/etc/diy/boot\ntouch /etc/runit/stopit\nchmod 000 /etc/runit/stopit\n' > "$ROOT/etc/runit/1"
        printf '#!/bin/sh\nexec /usr/bin/runsvdir /etc/service\n' > "$ROOT/etc/runit/2"
        printf '#!/bin/sh\n# PID 1 vykdo galutinį reboot syscall po šio etapo.\nsync\numount -a -r 2>/dev/null || :\n' > "$ROOT/etc/runit/3"
        chmod 0755 "$ROOT/etc/runit/"[123]
        printf '#!/bin/sh\nexec /sbin/runit-init 6\n' > "$ROOT/usr/sbin/reboot"
        printf '#!/bin/sh\nexec /sbin/runit-init 0\n' > "$ROOT/usr/sbin/poweroff"
    fi
    chmod 0755 "$ROOT/usr/sbin/reboot" "$ROOT/usr/sbin/poweroff"
    ln -snf poweroff "$ROOT/usr/sbin/halt"
    for port in tty1 ttyS0; do
        mkdir -p "$directory/$port"
        if [[ "$port" == tty1 ]]; then
            printf '#!/bin/sh\nexec %s\n' "$tty1_getty" > "$directory/$port/run"
        else
            printf '#!/bin/sh\nexec /sbin/agetty -L ttyS0 115200 vt100\n' > "$directory/$port/run"
        fi
        chmod 0755 "$directory/$port/run"
        [[ "$INIT_CHOICE" != s6 ]] || printf '5000\n' > "$directory/$port/timeout-kill"
    done
    if [[ "$NETWORK" == yes && "$DESKTOP_CHOICE" == none ]]; then
        mkdir -p "$directory/dhcpcd"
        printf '#!/bin/sh\nexec /usr/sbin/dhcpcd --nobackground\n' > "$directory/dhcpcd/run"
        chmod 0755 "$directory/dhcpcd/run"
        [[ "$INIT_CHOICE" != s6 ]] || printf '5000\n' > "$directory/dhcpcd/timeout-kill"
    else
        rm -f "$directory/dhcpcd/run" "$directory/dhcpcd/timeout-kill"
        rmdir "$directory/dhcpcd" 2>/dev/null || :
    fi
}

system_bus() {
    [[ "$INIT_CHOICE" == systemd ]] || return 0
    # Build the system bus separately from systemd so both binaries can have
    # independent cache keys. A D-Bus recipe change must not invalidate the
    # already reusable systemd artifact.
    desktop_package expat
    desktop_meson dbus -Dsystemd=disabled -Duser_session=false \
        -Dmodular_tests=disabled -Dxml_docs=disabled -Ddoxygen_docs=disabled \
        -Dducktype_docs=disabled -Dx11_autolaunch=disabled \
        -Dselinux=disabled -Dapparmor=disabled -Dlibaudit=disabled
}

init_system() {
    local source
    case "$INIT_CHOICE" in
        busybox) : ;;                 # BusyBox jau sukompiliuotas userland etape.
        openrc|systemd)
            source=$(unpack libcap)
            make -C "$source/libcap" -j"$JOBS" CROSS_COMPILE="$TARGET-" BUILD_CC="$HOST_CC" \
                CC="$CC" AR="$AR" lib=lib prefix=/usr SHARED=yes GOLANG=no
            make -C "$source/libcap" CROSS_COMPILE="$TARGET-" BUILD_CC="$HOST_CC" \
                CC="$CC" AR="$AR" lib=lib prefix=/usr SHARED=yes GOLANG=no DESTDIR="$ROOT" install
            ;;
    esac
    case "$INIT_CHOICE" in
        sysvinit|runit|dinit|s6) small_init_tools ;;
        openrc)
            local -a openrc_flags=(
                -Dsysvinit=true          # įdiegia SysV suderinamus OpenRC scenarijus
                -Dagetty=[]              # OpenRC nekuria savo agetty; konsolę tvarko init konfigūracija
                -Duucp_group=root        # priskiria uucp grupės teises root grupei, nes atskiros nėra
                -Dpam=false              # neįjungia PAM integracijos
                -Dselinux=disabled       # neįtraukia SELinux integracijos
                -Daudit=disabled         # neįtraukia Linux Audit integracijos
                -Dbash-completions=false # neįdiegia OpenRC Bash užbaigimų
                -Dzsh-completions=false  # neįdiegia OpenRC Zsh užbaigimų
                -Dpkgconfig=false        # nekuria pkg-config metaduomenų bibliotekoms
                -Dbranding='"DIY Linux"' # nustato OpenRC programų rodoma distribucijos žymą
            )
            meson_package openrc "${openrc_flags[@]}"
            ;;
        systemd)
            local network=false
            local pam=false
            [[ "$NETWORK" != yes || "$DESKTOP_CHOICE" != none ]] || network=true
            [[ ${PKG_MATE_CONTROL_CENTER:-no} != yes && ${PKG_MATE_POWER_MANAGER:-no} != yes ]] || pam=true
            local -a systemd_flags=(
                -Dmode=release           # įjungia systemd leidimo režimo kompiliavimą
                -Dtests=false            # nekuria systemd testų
                -Dman=disabled           # nekuria man puslapių
                -Dlibmount=enabled       # įtraukia mount bibliotekos integraciją
                -Dblkid=enabled          # įtraukia failų sistemų UUID/žymų aptikimą
                -Dkmod=enabled           # įtraukia branduolio modulių valdymą
                -Dlibcrypt=enabled       # naudoja libcrypt prisijungimo kriptografijai
                -Dpam="$pam"            # PAM įjungiamas, kai pasirenkamos PAM reikalaujančios darbalaukio programos
                -Dselinux=disabled       # neįtraukia SELinux integracijos
                -Dapparmor=disabled      # neįtraukia AppArmor integracijos
                -Daudit=disabled         # neįtraukia Linux Audit integracijos
                -Dpolkit=disabled        # nekuria systemd polkit taisyklių
                -Dhomed=disabled         # nekuria systemd-homed paskyrų valdytojo
                -Dbootloader=disabled    # nekuria systemd paleidyklės įrankių
                -Dnetworkd="$network"   # systemd-networkd tik kai profilyje to reikia
                -Dresolve="$network"    # systemd-resolved tik kai profilyje to reikia
            )
            meson_package systemd "${systemd_flags[@]}"
            ;;
    esac
    if [[ "$NETWORK" == yes && "$DESKTOP_CHOICE" == none && "$INIT_CHOICE" != systemd ]]; then
        source=$(unpack dhcpcd)
        (cd "$source"
         CC="$CC" AR="$AR" ./configure --build="$HOST" --host="$TARGET" \
             --prefix=/usr --sysconfdir=/etc --libexecdir=/usr/libexec \
             --dbdir=/var/lib/dhcpcd --privsepuser=dhcpcd
         make -j"$JOBS"; make DESTDIR="$ROOT" install)
    fi
}

# 7. Paketų tvarkyklės. Tai šios sistemos paketams, o ne svetimos distro bazės
# pakeitimui. Pasirašymas įjungtas; saugykla ir jos raktas pridedami po paleidimo.
# dpkg 1.23.11 log.c naudoja free(), bet neįtraukia stdlib.h.
# Taisyti šaltinį po SHA patikros; pakartotinis tęsinys include nedubliuoja.
patch_dpkg_headers() {
    local source=$1
    if ! grep -q '^#include <stdlib.h>' "$source/lib/dpkg/log.c"; then
        sed -i '/^#include <stdarg.h>/a #include <stdlib.h>' "$source/lib/dpkg/log.c"
    fi
    grep -q '^#include <stdlib.h>' "$source/lib/dpkg/log.c" || die "$(tr_text 'Failed to apply dpkg log.c stdlib.h fix' 'Nepavyko pritaikyti dpkg log.c stdlib.h pataisos')"
}

package_libraries() {
    local source
    source=$(unpack zlib)
    (cd "$source"; ./configure --prefix=/usr; make -j"$JOBS"; make DESTDIR="$ROOT" install)
    source=$(unpack bzip2)
    (cd "$source"
     # Abu Makefile naudoja tuos pačius .o; make nepastebi CFLAGS pakeitimo.
     # Pašalinti ir po ankstesnio nesėkmingo bandymo likusius ne-PIC objektus.
     make clean
     make -j"$JOBS" CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS='-O2 -fPIC -D_FILE_OFFSET_BITS=64'
     make CC="$CC" AR="$AR" RANLIB="$RANLIB" CFLAGS='-O2 -fPIC -D_FILE_OFFSET_BITS=64' PREFIX="$ROOT/usr" install
     make -B -f Makefile-libbz2_so CC="$CC" CFLAGS='-O2 -fPIC -D_FILE_OFFSET_BITS=64'
     install -m0755 libbz2.so.1.0.8 "$ROOT/usr/lib/"
     ln -snf libbz2.so.1.0.8 "$ROOT/usr/lib/libbz2.so.1.0"
     ln -snf libbz2.so.1.0 "$ROOT/usr/lib/libbz2.so")
    # xz: bendrosios bibliotekos ir komandos lieka, statinė archyvo versija,
    # dokumentacija ir vertimų failai nepridedami.
    autotools xz --disable-static --disable-doc --disable-nls
    source=$(unpack zstd)
    make -C "$source" -j"$JOBS" CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB"
    make -C "$source" CC="$CC" AR="$AR" RANLIB="$RANLIB" PREFIX=/usr DESTDIR="$ROOT" install
    download_tls
    # GnuPG grandinė naudoja bendrąją libgpg-error biblioteką; praleidžiami
    # .a archyvas ir dokumentacijos kūrimo žingsniai.
    autotools libgpg-error --disable-static --disable-doc
    # Naujos libgpg-error versijos pateikia gpgrt-config, o ne gpg-error-config.
    # Nurodyti jo kelią: rootfs/bin negalima dėti į host PATH.
    export GPGRT_CONFIG="$ROOT/usr/bin/gpgrt-config"
    [[ -x "$GPGRT_CONFIG" ]] || die "$(tr_text 'Missing gpgrt-config after installing libgpg-error' 'Po libgpg-error diegimo trūksta gpgrt-config')"
    "$GPGRT_CONFIG" --libdir="$ROOT/usr/lib" gpg-error --exists || die "$(tr_text 'gpgrt-config cannot find the target system gpg-error.pc' 'gpgrt-config neaptinka kuriamos sistemos gpg-error.pc')"
    autotools libgcrypt --disable-static --disable-doc --with-libgpg-error-prefix="$ROOT/usr"
    autotools libassuan --disable-static --with-libgpg-error-prefix="$ROOT/usr"
    autotools libksba --disable-static --with-libgpg-error-prefix="$ROOT/usr"
    autotools npth --disable-static
    autotools gnupg --disable-doc --disable-tests --disable-gpgsm --disable-scdaemon \
        --disable-dirmngr --disable-keyboxd --disable-gpgtar --disable-ldap --disable-sqlite \
        --disable-ntbtls --disable-gnutls --disable-tofu \
        --with-libgpg-error-prefix="$ROOT/usr" --with-libgcrypt-prefix="$ROOT/usr" \
        --with-libassuan-prefix="$ROOT/usr" --with-ksba-prefix="$ROOT/usr" --with-npth-prefix="$ROOT/usr"
}

package_manager() {
    [[ "$PACKAGE_MANAGER" != none ]] || return 0
    # Senesnėms bibliotekoms (pvz., Berkeley DB) reikia C11, ne GCC numatyto C23.
    local CFLAGS='-O2 -pipe -std=gnu11'
    export CFLAGS
    package_libraries
    local source
    case "$PACKAGE_MANAGER" in
        apt)
            # dpkg: verčiami pranešimai ir dselect sąsaja nepridedami; kūrimo
            # dokumentai ir SELinux priklausomybė nereikalingi minimaliai APT sistemai.
            autotools libmd --disable-static
            source=$(unpack lz4)
            make -C "$source" -j"$JOBS" CC="$CC" AR="$AR"
            make -C "$source" CC="$CC" AR="$AR" PREFIX=/usr DESTDIR="$ROOT" install
            source=$(unpack xxhash)
            make -C "$source" -j"$JOBS" CC="$CC" AR="$AR"
            make -C "$source" CC="$CC" AR="$AR" PREFIX=/usr DESTDIR="$ROOT" install
            # dpkg ir dpkg-deb nereikia target Perl; dpkg-dev Perl įrankiams jo reikės.
            source=$(unpack dpkg)
            patch_dpkg_headers "$source"
            autotools dpkg --disable-nls --disable-dselect --disable-devel-docs --without-libselinux
            source=$(unpack db)
            # Berkeley DB funkcijos vardas kertasi su GCC atominiu builtin.
            sed -i 's/__atomic_compare_exchange/db_atomic_compare_exchange/g' "$source/src/dbinc/atomic.h"
            mkdir -p "$BUILD/db"
            (cd "$BUILD/db"
             local -a db_flags=(
                 --build="$HOST" --host="$TARGET" # kompiliavimo ir vykdymo architektūros
                 --prefix=/usr                     # tikslinės sistemos diegimo šaknis
                 --enable-shared                   # kuria dalijamąsias Berkeley DB bibliotekas
                 --disable-static                  # nekuria statinių .a bibliotekų
                 --disable-cxx                     # nekuria C++ API
                 --disable-java                    # nekuria Java sąsajos
                 --disable-tcl                     # nekuria Tcl sąsajos
             )
             "$source/dist/configure" "${db_flags[@]}"
             make -j"$JOBS"; make DESTDIR="$ROOT" install)
            # triehash yra šeimininke vykdomas Perl kodo generatorius.
            source=$(unpack triehash)
            install -m0755 "$source/triehash.pl" "$TOOLS/bin/triehash"
            source=$(unpack apt)
            cmake -S "$source" -B "$BUILD/apt" -G Ninja \
                -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR="$TARGET_ARCH" \
                -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
                -DCMAKE_SYSROOT="$ROOT" -DCMAKE_FIND_ROOT_PATH="$ROOT" \
                -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
                -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
                -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
                -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib \
                -DCMAKE_INSTALL_LIBEXECDIR=lib -DCMAKE_INSTALL_SYSCONFDIR=/etc \
                -DCMAKE_INSTALL_LOCALSTATEDIR=/var -DCMAKE_BUILD_TYPE=Release \
                -DCOMMON_ARCH="$DEB_ARCH" -DDPKG_DATADIR=/usr/share/dpkg -DROOT_GROUP=root \
                -DTRIEHASH_EXECUTABLE="$TOOLS/bin/triehash" -DSQV_EXECUTABLE=SQV_EXECUTABLE-NOTFOUND \
                -DWITH_DOC=OFF -DWITH_TESTS=OFF -DUSE_NLS=OFF
            cmake --build "$BUILD/apt" --parallel "$JOBS"
            DESTDIR="$ROOT" cmake --install "$BUILD/apt"
            ;;
        pacman)
            # curl: TLS per OpenSSL su tikslinės sistemos biblioteka ir CA rinkmena;
            # išjungiami pasirenkami protokolai / priklausomybės, kurių pacman nereikia.
            autotools curl --with-openssl="$ROOT/usr" --with-ca-bundle=/etc/ssl/cert.pem \
                --without-libpsl --without-libidn2 --without-librtmp --without-libssh2 \
                --without-nghttp2 --without-nghttp3 --without-ngtcp2 --disable-ldap --disable-ldaps
            # libarchive lieka bendroji biblioteka; nereikalingi XML/Exp at/Nettle formatai išjungti.
            autotools libarchive --disable-static --without-xml2 --without-expat --without-nettle
            # GPGME palieka GPG bazinę sąsają, praleidžia kitų GnuPG įrankių testus,
            # o --with-*-prefix nurodo kuriamos sistemos priklausomybių vietas.
            autotools gpgme --enable-languages=no --disable-static --disable-gpg-test --disable-gpgsm-test \
                --disable-gpgconf-test --disable-g13-test --with-libgpg-error-prefix="$ROOT/usr" \
                --with-libassuan-prefix="$ROOT/usr"
            meson_package pacman -Ddoc=disabled -Ddoxygen=disabled -Di18n=false \
                -Dcurl=enabled -Dgpgme=enabled -Dcrypto=openssl -Dfile-seccomp=disabled
            ;;
    esac
}

configure_packages() {
    [[ "$PACKAGE_MANAGER" != none ]] || return 0
    local apt_uid
    mkdir -p "$ROOT/usr/share/doc/diy-linux"
    cat > "$ROOT/usr/share/doc/diy-linux/packages.txt" <<NOTES
Ši savarankiška sistema neturi Debian ar Arch paketų suderinamumo garantijos.
Prijunk savo šiai glibc, $TARGET_ARCH ir init sistemai paruoštą pasirašytą saugyklą.
Baziniai iš šaltinių įdiegti failai nėra įregistruoti paketų duomenų bazėje:
nekaitaliok jų svetimos distribucijos paketais, nenaudok --overwrite / --force.
RAM rootfs pakeitimai dingsta perkrovus. Nuolatiniam naudojimui reikia disko rootfs.
Paketų tvarkyklė pati nesukuria saugyklos ar suderinamų paketų.
NOTES
    case "$PACKAGE_MANAGER" in
        apt)
            mkdir -p "$ROOT/etc/apt"/{apt.conf.d,sources.list.d,keyrings} \
                "$ROOT/var/lib/dpkg"/{info,updates,triggers} "$ROOT/var/cache/apt/archives/partial" \
                "$ROOT/var/lib/apt/lists/partial"
            # APT drops download privileges to _apt. Keep this account and the
            # writable partial directories in sync (including minimal systems
            # that do not inherit Debian's base-passwd accounts).
            apt_uid=42
            if grep -q '^_apt:' "$ROOT/etc/passwd"; then
                apt_uid=$(awk -F: '$1=="_apt" {print $3; exit}' "$ROOT/etc/passwd")
                [[ "$apt_uid" =~ ^[0-9]+$ ]] || die "Invalid _apt UID in target passwd file"
            else
                if awk -F: -v uid="$apt_uid" '$3==uid {found=1} END {exit !found}' "$ROOT/etc/passwd"; then
                    apt_uid=194
                    while awk -F: -v uid="$apt_uid" '$3==uid {found=1} END {exit !found}' "$ROOT/etc/passwd"; do
                        apt_uid=$((apt_uid + 1))
                        (( apt_uid < 60000 )) || die "No free UID for the _apt account"
                    done
                fi
                printf '_apt:x:%s:65534:APT sandbox:/nonexistent:/usr/sbin/nologin\n' "$apt_uid" >> "$ROOT/etc/passwd"
            fi
            grep -q '^nogroup:' "$ROOT/etc/group" || printf 'nogroup:x:65534:\n' >> "$ROOT/etc/group"
            touch "$ROOT/var/lib/dpkg/status" "$ROOT/var/lib/dpkg/available"
            printf '%s\n' "$DEB_ARCH" > "$ROOT/var/lib/dpkg/arch"
            cat > "$ROOT/etc/apt/sources.list" <<APT_SOURCES
# Pridėk savo suderinamą saugyklą ir patikrintą viešąjį raktą:
# deb [arch=$DEB_ARCH signed-by=/etc/apt/keyrings/diy.gpg] https://packages.example.org/diy stable main
APT_SOURCES
            cat > "$ROOT/etc/apt/apt.conf.d/00diy" <<APT_CONFIG
APT::Architecture "$DEB_ARCH";
APT::Key::GPGVCommand "/usr/bin/gpgv";
Acquire::https::CaInfo "/etc/ssl/cert.pem";
APT_CONFIG
            chmod 0755 "$ROOT/etc/apt" "$ROOT/etc/apt/apt.conf.d" "$ROOT/etc/apt/sources.list.d" \
                "$ROOT/etc/apt/keyrings" "$ROOT/var/lib/dpkg" "$ROOT/var/lib/dpkg/info" \
                "$ROOT/var/lib/dpkg/updates" "$ROOT/var/lib/dpkg/triggers" "$ROOT/var/lib/apt" \
                "$ROOT/var/lib/apt/lists" "$ROOT/var/cache/apt" "$ROOT/var/cache/apt/archives"
            chmod 0644 "$ROOT/var/lib/dpkg/status" "$ROOT/var/lib/dpkg/available" \
                "$ROOT/var/lib/dpkg/arch" "$ROOT/etc/apt/sources.list" "$ROOT/etc/apt/apt.conf.d/00diy"
            chmod 0700 "$ROOT/var/cache/apt/archives/partial" "$ROOT/var/lib/apt/lists/partial"
            cat >> "$ROOT/usr/share/doc/diy-linux/packages.txt" <<'APT_NOTES'
APT: įrašyk saugyklą į /etc/apt/sources.list, jos viešąjį raktą į
/etc/apt/keyrings/diy.gpg. Tada: apt update; apt install <paketas>.
Vietinis .deb: apt install ./paketas.deb arba dpkg -i paketas.deb.
dpkg-dev Perl scenarijams ir Debian priežiūros scenarijams gali reikėti Perl
bei papildomų programų; tai nėra pilna Debian kūrimo aplinka.
APT_NOTES
            ;;
        pacman)
            mkdir -p "$ROOT/var/lib/pacman/local" "$ROOT/var/cache/pacman/pkg" "$ROOT/etc/pacman.d/gnupg"
            chmod 0755 "$ROOT/var/lib/pacman" "$ROOT/var/lib/pacman/local" \
                "$ROOT/var/cache/pacman" "$ROOT/var/cache/pacman/pkg"
            chmod 0700 "$ROOT/etc/pacman.d/gnupg"
            cat > "$ROOT/etc/pacman.conf" <<PACMAN_CONFIG
[options]
Architecture = $TARGET_ARCH
CheckSpace
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Required
# [diy]
# Server = https://packages.example.org/diy/\$arch
PACMAN_CONFIG
            cat >> "$ROOT/usr/share/doc/diy-linux/packages.txt" <<'PACMAN_NOTES'
Pacman: po paleidimo vykdyk pacman-key --init. Importuok savo patikrintą
saugyklos raktą: pacman-key --add diy.asc; pacman-key --lsign-key <fingerprint>.
Pridėk [diy] saugyklą į /etc/pacman.conf. Tada: pacman -Syu; pacman -S <paketas>.
Vietinis pasirašytas paketas: pacman -U ./paketas.pkg.tar.zst.
makepkg reikia Bash ir kūrimo įrankių. Pasirink GCC, jei kompiliuosi sistemoje;
konkretiems PKGBUILD dar gali reikėti file, pkg-config, patch ir kitų priklausomybių.
PACMAN_NOTES
            ;;
    esac
}

# 8. Pasirenkamas GCC galutinėje sistemoje.
# Pasirinktinis GCC, kuris jau VEIKS naujoje sistemoje, kartu su make/binutils.
# Kūrimo kryžminis GCC lieka BASE/cross-tools ir į rootfs nepatenka.
native_development() {
    local source dependency
    [[ "$WITH_GCC" == yes ]] || return 0
    source=$(unpack binutils)
    mkdir -p "$BUILD/binutils-native"
    (cd "$BUILD/binutils-native"
     "$source/configure" --build="$HOST" --host="$TARGET" --target="$TARGET" \
         --prefix=/usr --disable-nls --disable-multilib --disable-werror
     make -j"$JOBS"; make DESTDIR="$ROOT" install)
    source=$(unpack gcc)
    for dependency in gmp mpfr mpc; do
        [[ -d "$source/$dependency" ]] || cp -a "$(unpack "$dependency")" "$source/$dependency"
    done
    mkdir -p "$BUILD/gcc-native"
    (cd "$BUILD/gcc-native"
     CC_FOR_BUILD="$HOST_CC" CXX_FOR_BUILD="$HOST_CXX" CC_FOR_TARGET="$CC" CXX_FOR_TARGET="$CXX" \
     "$source/configure" --build="$HOST" --host="$TARGET" --target="$TARGET" \
         --prefix=/usr --libdir=/usr/lib --with-sysroot=/ --with-build-sysroot="$ROOT" \
         --with-build-time-tools="$TOOLS/$TARGET/bin" \
         --disable-bootstrap --disable-multilib --disable-nls --disable-libsanitizer \
         --disable-libquadmath --disable-libgomp --enable-languages=c,c++
     make -j"$JOBS" CC_FOR_TARGET="$CC" CXX_FOR_TARGET="$CXX" AR_FOR_TARGET="$AR" RANLIB_FOR_TARGET="$RANLIB"
     make DESTDIR="$ROOT" install)
    autotools make
    ln -snf gcc "$ROOT/usr/bin/cc"
}

# 9. Branduolys. Disko / tinklo tvarkyklės įkompiliuotos, kad ISO nereikėtų dracut.
# Kbuild HOST įrankiai (extract-cert ir kt.) naudoja šeimininko OpenSSL/libc.
# Target pkg-config keliai neturi patekti į jų kompiliavimo komandas.
configure_prompt() {
    mkdir -p "$ROOT/usr/libexec" "$ROOT/etc/skel"
    printf '%s\n' "$DIY_LANG" > "$ROOT/etc/diy-language"
    printf 'NAME="%s"\nPRETTY_NAME="%s"\nID=diy-linux\n' "$OS_NAME" "$OS_NAME" > "$ROOT/etc/os-release"
    printf '%s (%s)\nHostname: %s\n\n' "$OS_NAME" "$INIT_CHOICE" "$SYSTEM_NAME" > "$ROOT/etc/issue.base"
    cat > "$ROOT/usr/libexec/diy-prelogin" <<'PRELOGIN'
#!/bin/sh
[ -r /etc/issue.base ] && cat /etc/issue.base
. /etc/os-release 2>/dev/null || :
if [ -x /usr/bin/neofetch ]; then
    /usr/bin/neofetch || printf 'Welcome to %s.\n' "${PRETTY_NAME:-Linux}"
else
    printf 'Welcome to %s.\n' "${PRETTY_NAME:-Linux}"
fi
[ -x /usr/bin/diy-ssh-info ] && /usr/bin/diy-ssh-info
PRELOGIN
    chmod 0755 "$ROOT/usr/libexec/diy-prelogin"
    cat > "$ROOT/etc/profile" <<'PROFILE'
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
export LANG=C.UTF-8
umask 022
if [ -z "${DIY_WELCOME_SHOWN:-}" ]; then
    export DIY_WELCOME_SHOWN=1
    /usr/libexec/diy-prelogin
fi
if [ -n "${BASH_VERSION:-}" ]; then
    PS1='\u@\h:\w\$ '
else
    HOSTNAME=$(hostname 2>/dev/null || cat /etc/hostname)
    export HOSTNAME
    PS1='${USER:-user}@${HOSTNAME:-localhost}:${PWD}\$ '
fi
PROFILE
    if [[ "$PKG_NANO" == yes ]]; then
        printf 'export EDITOR=nano VISUAL=nano\n' >> "$ROOT/etc/profile"
    elif [[ "$PKG_VIM" == yes ]]; then
        printf 'export EDITOR=vim VISUAL=vim\n' >> "$ROOT/etc/profile"
    fi
    cat > "$ROOT/etc/skel/.bashrc" <<'BASHRC'
# Interactive prompt: account name, system hostname, and current directory.
case $- in *i*) PS1='\u@\h:\w\$ ' ;; esac
BASHRC
    install -m0644 "$ROOT/etc/skel/.bashrc" "$ROOT/root/.bashrc"
}

ensure_nginx_account() {
    local id gid
    if ! grep -q '^nginx:' "$ROOT/etc/group"; then
        for id in {800..899}; do
            if ! awk -F: -v id="$id" '$3 == id { found=1 } END { exit !found }' "$ROOT/etc/group"; then
                printf 'nginx:x:%s:\n' "$id" >> "$ROOT/etc/group"
                break
            fi
        done
        grep -q '^nginx:' "$ROOT/etc/group" || die "$(tr_text 'No free group ID for nginx' 'Nginx grupei nėra laisvo GID')"
    fi
    gid=$(awk -F: '$1 == "nginx" { print $3; exit }' "$ROOT/etc/group")
    if ! grep -q '^nginx:' "$ROOT/etc/passwd"; then
        for id in {800..899}; do
            if ! awk -F: -v id="$id" '$3 == id { found=1 } END { exit !found }' "$ROOT/etc/passwd"; then
                printf 'nginx:x:%s:%s:Nginx service:/var/lib/nginx:/bin/false\n' "$id" "$gid" >> "$ROOT/etc/passwd"
                break
            fi
        done
        grep -q '^nginx:' "$ROOT/etc/passwd" || die "$(tr_text 'No free user ID for nginx' 'Nginx paskyrai nėra laisvo UID')"
    fi
    [[ ! -f "$ROOT/etc/shadow" ]] || grep -q '^nginx:' "$ROOT/etc/shadow" || printf 'nginx:!:::::::\n' >> "$ROOT/etc/shadow"
}

ensure_sshd_account() {
    local id gid
    if ! grep -q '^sshd:' "$ROOT/etc/group"; then
        for id in {700..799}; do
            if ! awk -F: -v id="$id" '$3 == id { found=1 } END { exit !found }' "$ROOT/etc/group"; then
                printf 'sshd:x:%s:\n' "$id" >> "$ROOT/etc/group"
                break
            fi
        done
        grep -q '^sshd:' "$ROOT/etc/group" || die "$(tr_text 'No free group ID for sshd' 'sshd grupei nėra laisvo GID')"
    fi
    gid=$(awk -F: '$1 == "sshd" { print $3; exit }' "$ROOT/etc/group")
    if ! grep -q '^sshd:' "$ROOT/etc/passwd"; then
        for id in {700..799}; do
            if ! awk -F: -v id="$id" '$3 == id { found=1 } END { exit !found }' "$ROOT/etc/passwd"; then
                printf 'sshd:x:%s:%s:OpenSSH privilege separation:/var/empty:/bin/false\n' "$id" "$gid" >> "$ROOT/etc/passwd"
                break
            fi
        done
        grep -q '^sshd:' "$ROOT/etc/passwd" || die "$(tr_text 'No free user ID for sshd' 'sshd paskyrai nėra laisvo UID')"
    fi
    [[ ! -f "$ROOT/etc/shadow" ]] || grep -q '^sshd:' "$ROOT/etc/shadow" || printf 'sshd:!:::::::\n' >> "$ROOT/etc/shadow"
    mkdir -p "$ROOT/var/empty"
    chmod 0755 "$ROOT/var/empty"
}

configure_sshd_service() {
    [[ "$PKG_OPENSSH" == yes ]] || return 0
    local unit_dir="$ROOT/etc/systemd/system" run_dir
    ensure_sshd_account
    mkdir -p "$ROOT/etc/ssh" "$ROOT/usr/libexec"
    cat > "$ROOT/etc/ssh/sshd_config" <<SSHD_CONFIG
# OpenSSH server defaults for DIY Linux.
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_rsa_key
PermitRootLogin no
AllowUsers $USER_NAME
PasswordAuthentication yes
PermitEmptyPasswords no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
UsePAM no
StrictModes yes
PidFile /run/sshd.pid
Subsystem sftp internal-sftp
SSHD_CONFIG
    cat > "$ROOT/usr/libexec/diy-sshd-start" <<'SSHD_START'
#!/bin/sh
set -eu
umask 077
mkdir -p /run/sshd
chmod 0755 /run/sshd
/usr/bin/ssh-keygen -A
mkdir -p /var/log
exec /usr/sbin/sshd -D -E /var/log/sshd.log -f /etc/ssh/sshd_config
SSHD_START
    chmod 0755 "$ROOT/usr/libexec/diy-sshd-start"

    case "$INIT_CHOICE" in
        systemd)
            mkdir -p "$unit_dir/multi-user.target.wants"
            cat > "$unit_dir/sshd.service" <<'SYSTEMD_SSHD'
[Unit]
Description=OpenSSH server
After=local-fs.target network.target
Wants=network.target

[Service]
Type=simple
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
ExecStartPre=/usr/bin/ssh-keygen -A
ExecStart=/usr/libexec/diy-sshd-start
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
SYSTEMD_SSHD
            ln -snf ../sshd.service "$unit_dir/multi-user.target.wants/sshd.service"
            ;;
        openrc)
            cat > "$ROOT/etc/init.d/sshd" <<'OPENRC_SSHD'
#!/sbin/openrc-run
description="OpenSSH server"
command=/usr/libexec/diy-sshd-start
command_background=yes
pidfile=/run/sshd.pid
depend() { need localmount; use net; }
OPENRC_SSHD
            chmod 0755 "$ROOT/etc/init.d/sshd"
            mkdir -p "$ROOT/etc/runlevels/default"
            ln -snf /etc/init.d/sshd "$ROOT/etc/runlevels/default/sshd"
            ;;
        busybox|sysvinit)
            printf '\n/usr/libexec/diy-sshd-start >>/var/log/sshd.log 2>&1 &\n' >> "$ROOT/etc/diy/boot"
            ;;
        runit)
            run_dir="$ROOT/etc/service/sshd"
            mkdir -p "$run_dir"
            printf '#!/bin/sh\nexec /usr/libexec/diy-sshd-start\n' > "$run_dir/run"
            chmod 0755 "$run_dir/run"
            ;;
        dinit)
            cat > "$ROOT/etc/dinit.d/sshd" <<'DINIT_SSHD'
type = process
command = /usr/libexec/diy-sshd-start
restart = true
depends-on: diy-boot
DINIT_SSHD
            printf 'depends-on: sshd\n' >> "$ROOT/etc/dinit.d/boot"
            ;;
        s6)
            run_dir="$ROOT/etc/s6-rc/source"
            mkdir -p "$run_dir/sshd/dependencies.d" "$run_dir/default/contents.d"
            printf 'longrun\n' > "$run_dir/sshd/type"
            : > "$run_dir/sshd/dependencies.d/boot-setup"
            printf '#!/bin/sh\nexec /usr/libexec/diy-sshd-start\n' > "$run_dir/sshd/run"
            chmod 0755 "$run_dir/sshd/run"
            : > "$run_dir/default/contents.d/sshd"
            ;;
    esac

    # Print the actual address at login time; DHCP may not have completed
    # during image creation, and live images may receive a different address.
    cat > "$ROOT/usr/bin/diy-ssh-info" <<'SSH_INFO'
#!/bin/sh
if [ ! -x /usr/sbin/sshd ]; then exit 0; fi
if [ -x /usr/sbin/ip ]; then
    addresses=$(/usr/sbin/ip -o -4 addr show scope global 2>/dev/null |
        while read -r index iface family address rest; do
            [ "$family" = inet ] || continue
            address=${address%%/*}
            printf 'ssh %s@%s\n' 'DIY_SSH_USERNAME' "$address"
        done)
    if [ -n "$addresses" ]; then
        printf '%s\n' "$addresses" | while IFS= read -r command; do printf 'SSH: %s\n' "$command"; done
        exit 0
    fi
fi
printf '%s\n' 'SSH server is enabled; no IPv4 address is available yet. Run diy-ssh-info after connecting to a network.'
SSH_INFO
    sed -i "s/DIY_SSH_USERNAME/$USER_NAME/g" "$ROOT/usr/bin/diy-ssh-info"
    chmod 0755 "$ROOT/usr/bin/diy-ssh-info"
}

configure_web_services() {
    [[ "$PKG_NGINX" == yes ]] || return 0
    local unit_dir="$ROOT/etc/systemd/system"
    mkdir -p "$ROOT/etc/nginx" "$ROOT/etc/php-fpm.d" "$ROOT/var/log/nginx" \
        "$ROOT/var/lib/nginx/client_temp" "$ROOT/var/lib/nginx/proxy_temp" \
        "$ROOT/var/lib/nginx/fastcgi_temp" "$ROOT/run/lock" "$ROOT/srv/www/html" "$ROOT/usr/libexec"
    chmod 1777 "$ROOT/var/lib/nginx/client_temp" "$ROOT/var/lib/nginx/proxy_temp" \
        "$ROOT/var/lib/nginx/fastcgi_temp"
    cat > "$ROOT/etc/nginx/nginx.conf" <<'NGINX_CONFIG'
user nginx nginx;
worker_processes 1;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;
events { worker_connections 512; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    server_tokens off;
    sendfile on;
    keepalive_timeout 30;
    access_log /var/log/nginx/access.log;
    server {
        listen 80 default_server;
        server_name _;
        root /srv/www/html;
        index index.php index.html;
        location / { try_files $uri $uri/ =404; }
NGINX_CONFIG
    if [[ "$PKG_PHP" == yes ]]; then
        cat >> "$ROOT/etc/nginx/nginx.conf" <<'NGINX_PHP'
        location ~ \.php$ {
            try_files $uri =404;
            include /etc/nginx/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            fastcgi_pass unix:/run/php-fpm.sock;
        }
NGINX_PHP
    fi
    cat >> "$ROOT/etc/nginx/nginx.conf" <<'NGINX_END'
        location ~ /\. { deny all; }
    }
}
NGINX_END
    if [[ "$PKG_PHP" == yes ]]; then
        cat > "$ROOT/etc/php-fpm.conf" <<'PHP_FPM_CONFIG'
[global]
pid = /run/php-fpm.pid
error_log = /var/log/php-fpm.log
daemonize = no
include = /etc/php-fpm.d/*.conf
PHP_FPM_CONFIG
        cat > "$ROOT/etc/php-fpm.d/www.conf" <<'PHP_FPM_POOL'
[www]
user = nginx
group = nginx
listen = /run/php-fpm.sock
listen.owner = nginx
listen.group = nginx
listen.mode = 0660
pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 10s
pm.max_requests = 500
clear_env = yes
security.limit_extensions = .php
PHP_FPM_POOL
        printf '\nexpose_php = Off\ndisplay_errors = Off\nlog_errors = On\ncgi.fix_pathinfo = 0\n' >> "$ROOT/etc/php.ini"
        if [[ ! -f "$ROOT/srv/www/html/index.php" ]]; then
            printf '%s\n' '<?php header("Content-Type: text/plain; charset=utf-8"); echo "PHP-FPM is working. Replace this page with your application.\n"; ?>' > "$ROOT/srv/www/html/index.php"
        fi
    elif [[ ! -f "$ROOT/srv/www/html/index.html" ]]; then
        printf '%s\n' '<!doctype html><title>Nginx is running</title><h1>Nginx is running</h1>' > "$ROOT/srv/www/html/index.html"
    fi
    case "$INIT_CHOICE" in
        openrc)
            if [[ "$PKG_PHP" == yes ]]; then
                cat > "$ROOT/etc/init.d/php-fpm" <<'OPENRC_PHP'
#!/sbin/openrc-run
description="PHP FastCGI Process Manager"
command=/usr/sbin/php-fpm
command_args="--nodaemonize --fpm-config /etc/php-fpm.conf"
command_background=yes
pidfile=/run/php-fpm.pid
depend() { need localmount; }
OPENRC_PHP
                chmod 0755 "$ROOT/etc/init.d/php-fpm"
                ln -snf /etc/init.d/php-fpm "$ROOT/etc/runlevels/default/php-fpm"
            fi
            cat > "$ROOT/etc/init.d/nginx" <<'OPENRC_NGINX'
#!/sbin/openrc-run
description="Nginx HTTP server"
command=/usr/sbin/nginx
command_args="-g 'daemon off;' -c /etc/nginx/nginx.conf"
command_background=yes
pidfile=/run/nginx.pid
depend() { need localmount; }
start_pre() {
    checkpath --directory --mode 0755 /var/log/nginx /var/lib/nginx /run/lock
    checkpath --directory --mode 1777 /var/lib/nginx/client_temp /var/lib/nginx/proxy_temp /var/lib/nginx/fastcgi_temp
}
OPENRC_NGINX
            if [[ "$PKG_PHP" == yes ]]; then
                sed -i 's/need localmount/need localmount php-fpm/' "$ROOT/etc/init.d/nginx"
            fi
            chmod 0755 "$ROOT/etc/init.d/nginx"
            ln -snf /etc/init.d/nginx "$ROOT/etc/runlevels/default/nginx"
            ;;
        systemd)
            mkdir -p "$unit_dir/multi-user.target.wants"
            if [[ "$PKG_PHP" == yes ]]; then
                cat > "$unit_dir/php-fpm.service" <<'SYSTEMD_PHP'
[Unit]
Description=PHP FastCGI Process Manager
After=local-fs.target
[Service]
Type=simple
ExecStart=/usr/sbin/php-fpm --nodaemonize --fpm-config /etc/php-fpm.conf
Restart=on-failure
[Install]
WantedBy=multi-user.target
SYSTEMD_PHP
                ln -snf ../php-fpm.service "$unit_dir/multi-user.target.wants/php-fpm.service"
            fi
            cat > "$unit_dir/nginx.service" <<'SYSTEMD_NGINX'
[Unit]
Description=Nginx HTTP server
After=network.target local-fs.target
[Service]
Type=simple
ExecStartPre=/usr/bin/mkdir -p /var/log/nginx /var/lib/nginx /run/lock /var/lib/nginx/client_temp /var/lib/nginx/proxy_temp /var/lib/nginx/fastcgi_temp
ExecStartPre=/usr/bin/chmod 1777 /var/lib/nginx/client_temp /var/lib/nginx/proxy_temp /var/lib/nginx/fastcgi_temp
ExecStart=/usr/sbin/nginx -g "daemon off;" -c /etc/nginx/nginx.conf
ExecReload=/usr/sbin/nginx -s reload
Restart=on-failure
[Install]
WantedBy=multi-user.target
SYSTEMD_NGINX
            if [[ "$PKG_PHP" == yes ]]; then
                sed -i '/^After=/a Requires=php-fpm.service' "$unit_dir/nginx.service"
                sed -i '/^Requires=/a After=php-fpm.service' "$unit_dir/nginx.service"
            fi
            ln -snf ../nginx.service "$unit_dir/multi-user.target.wants/nginx.service"
            ;;
        *)
            cat > "$ROOT/usr/libexec/diy-web-boot" <<'WEB_BOOT'
#!/bin/sh
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
mkdir -p /var/log/nginx /var/lib/nginx /run/lock /var/lib/nginx/client_temp /var/lib/nginx/proxy_temp /var/lib/nginx/fastcgi_temp
chmod 1777 /var/lib/nginx/client_temp /var/lib/nginx/proxy_temp /var/lib/nginx/fastcgi_temp
if [ -x /usr/sbin/php-fpm ]; then
    /usr/sbin/php-fpm --nodaemonize --fpm-config /etc/php-fpm.conf >>/var/log/php-fpm.log 2>&1 &
    i=0
    while [ ! -S /run/php-fpm.sock ] && [ "$i" -lt 20 ]; do sleep 1; i=$((i+1)); done
fi
/usr/sbin/nginx -g 'daemon off;' -c /etc/nginx/nginx.conf >>/var/log/nginx/startup.log 2>&1 &
WEB_BOOT
            chmod 0755 "$ROOT/usr/libexec/diy-web-boot"
            printf '\n/usr/libexec/diy-web-boot\n' >> "$ROOT/etc/diy/boot"
            ;;
    esac
}

configure_system() {
    local tty1_getty serial_getty getty_path getty_args dhcpcd_uid tty_gid
    local needs_desktop_auth=no upower_enabled=no
    [[ ${DESKTOP_CHOICE:-none} != mate && \
       ${PKG_MATE_CONTROL_CENTER:-no} != yes && \
       ${PKG_MATE_POWER_MANAGER:-no} != yes ]] || needs_desktop_auth=yes
    [[ ${DESKTOP_CHOICE:-none} != mate && ${PKG_FIREFOX:-no} != yes ]] || upower_enabled=yes
    mkdir -p "$ROOT/etc" "$ROOT/dev" "$ROOT/proc" "$ROOT/sys" "$ROOT/run" \
        "$ROOT/tmp" "$ROOT/root" "$ROOT/home" "$ROOT/var/log" "$ROOT/var/run"
    chmod 1777 "$ROOT/tmp"
    configure_timezone
    if [[ "$INIT_CHOICE" == systemd ]]; then
        # D-Bus defaults to the unprivileged messagebus account. Console-only
        # systemd profiles still run D-Bus for logind and system services.
        configure_graphical_runtime_accounts_locale
        [[ -x "$ROOT/usr/bin/dbus-daemon" && -x "$ROOT/usr/bin/dbus-uuidgen" ]] ||
            die "$(tr_text 'systemd requires dbus-daemon and dbus-uuidgen in the target rootfs' 'systemd reikia dbus-daemon ir dbus-uuidgen programų tikslinėje rootfs')"
        configure_desktop_init_services
    fi
    printf '%s\n' "$SYSTEM_NAME" > "$ROOT/etc/hostname"
    cat > "$ROOT/etc/hosts" <<HOSTS
127.0.0.1 localhost
127.0.1.1 $SYSTEM_NAME
::1 localhost ip6-localhost ip6-loopback
HOSTS
    [[ -f "$ROOT/etc/passwd" ]] || cat > "$ROOT/etc/passwd" <<'PASSWD'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
PASSWD
    [[ -f "$ROOT/etc/group" ]] || cat > "$ROOT/etc/group" <<'GROUP'
root:x:0:
users:x:100:
GROUP
    tty_gid=$(awk -F: '$1 == "tty" { print $3; exit }' "$ROOT/etc/group")
    if [[ -z "$tty_gid" ]]; then
        tty_gid=5
        if awk -F: -v gid="$tty_gid" '$3 == gid { found=1 } END { exit !found }' "$ROOT/etc/group"; then
            for tty_gid in {900..999}; do
                if ! awk -F: -v gid="$tty_gid" '$3 == gid { found=1 } END { exit found }' "$ROOT/etc/group"; then break; fi
                tty_gid=''
            done
            [[ -n "$tty_gid" ]] || die "$(tr_text 'No free group ID is available for tty' 'tty grupei nėra laisvo GID')"
        fi
        printf 'tty:x:%s:\n' "$tty_gid" >> "$ROOT/etc/group"
    fi
    if [[ "$NETWORK" == yes && "$DESKTOP_CHOICE" == none && "$INIT_CHOICE" != systemd ]]; then
        # dhcpcd is built with privilege separation enabled and needs a real
        # account even on this minimal rootfs.
        if ! grep -q '^dhcpcd:' "$ROOT/etc/passwd" || ! grep -q '^dhcpcd:' "$ROOT/etc/group"; then
            for dhcpcd_uid in {900..999}; do
                if ! awk -F: -v id="$dhcpcd_uid" \
                    'FNR==NR { if ($3 == id) used=1; next } $3 == id { used=1 } END { exit used ? 0 : 1 }' \
                    "$ROOT/etc/passwd" "$ROOT/etc/group"; then
                    break
                fi
                dhcpcd_uid=''
            done
            [[ -n "$dhcpcd_uid" ]] || die "$(tr_text 'No free system UID is available for dhcpcd' 'dhcpcd paskyrai nėra laisvo sistemos UID')"
            grep -q '^dhcpcd:' "$ROOT/etc/group" || printf 'dhcpcd:x:%s:\n' "$dhcpcd_uid" >> "$ROOT/etc/group"
            grep -q '^dhcpcd:' "$ROOT/etc/passwd" || printf 'dhcpcd:x:%s:%s:dhcpcd privilege separation:/var/lib/dhcpcd:/bin/false\n' \
                "$dhcpcd_uid" "$dhcpcd_uid" >> "$ROOT/etc/passwd"
            [[ -f "$ROOT/etc/shadow" ]] || printf 'root:%s:0:0:99999:7:::\n' "$ROOT_PASSWORD_HASH" > "$ROOT/etc/shadow"
            grep -q '^dhcpcd:' "$ROOT/etc/shadow" || printf 'dhcpcd:!:::::::\n' >> "$ROOT/etc/shadow"
            mkdir -p "$ROOT/var/lib/dhcpcd"
        fi
    fi
    [[ -f "$ROOT/etc/shadow" ]] || printf 'root:%s:0:0:99999:7:::\n' "$ROOT_PASSWORD_HASH" > "$ROOT/etc/shadow"
    chmod 0600 "$ROOT/etc/shadow"
    [[ -f "$ROOT/etc/gshadow" ]] || printf 'root:!::\n' > "$ROOT/etc/gshadow"
    [[ "$PKG_NGINX" != yes ]] || ensure_nginx_account
    mkdir -p "$ROOT/etc/diy"
    cat > "$ROOT/etc/diy/boot" <<'COMMON_BOOT'
#!/bin/sh
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
cd / || exit 1
hostname -F /etc/hostname
mkdir -p /dev/pts
mount -a
# PTYs need both the devpts mount and the conventional /dev/ptmx link.
if ! grep -q ' /dev/pts devpts ' /proc/mounts; then
    mount -t devpts devpts /dev/pts -o gid=5,mode=0620,ptmxmode=0666,nosuid,noexec 2>/dev/null || :
fi
[ ! -e /dev/pts/ptmx ] || ln -snf pts/ptmx /dev/ptmx
ip link set lo up 2>/dev/null || :
ip addr replace 127.0.0.1/8 dev lo 2>/dev/null || :
mkdir -p /run/lock /run/dhcpcd
: > /run/utmp
COMMON_BOOT
    chmod 0755 "$ROOT/etc/diy/boot"
    sed -i "s/gid=5/gid=$tty_gid/g" "$ROOT/etc/diy/boot"
    if [[ "$INIT_CHOICE" == busybox && "$NETWORK" == yes && "$DESKTOP_CHOICE" == none ]]; then
        cat >> "$ROOT/etc/diy/boot" <<'BUSYBOX_DHCP'
/usr/sbin/dhcpcd --background --quiet >>/var/log/dhcpcd.log 2>&1 || :
BUSYBOX_DHCP
    fi
    printf 'proc /proc proc nosuid,noexec,nodev 0 0\nsysfs /sys sysfs nosuid,noexec,nodev 0 0\ndevpts /dev/pts devpts gid=%s,mode=0620,ptmxmode=0666,nosuid,noexec 0 0\ntmpfs /tmp tmpfs mode=1777,nosuid,nodev 0 0\n' "$tty_gid" > "$ROOT/etc/fstab"
    ln -snf /proc/self/mounts "$ROOT/etc/mtab"
    : > "$ROOT/etc/issue"
    if [[ "$INIT_CHOICE" == sysvinit || "$INIT_CHOICE" == runit || "$INIT_CHOICE" == dinit || "$INIT_CHOICE" == s6 || "$INIT_CHOICE" == busybox ]]; then
        configure_small_init
    fi
    if [[ "$INIT_CHOICE" == busybox ]]; then
        if [[ -x "$ROOT/usr/sbin/agetty" ]]; then
            tty1_getty='/sbin/agetty tty1 38400 linux'
            [[ "$AUTOLOGIN" != yes ]] || tty1_getty="/sbin/agetty --autologin $USER_NAME tty1 38400 linux"
            serial_getty='/sbin/agetty -L ttyS0 115200 vt100'
        else
            getty_path=''
            for getty_path in /sbin/getty /usr/sbin/getty /bin/getty /usr/bin/getty; do
                [[ ! -x "$ROOT$getty_path" ]] || break
            done
            [[ -x "$ROOT$getty_path" ]] || die "$(tr_text 'BusyBox init requires getty or util-linux agetty' 'BusyBox init reikia getty arba util-linux agetty')"
            tty1_getty="$getty_path 38400 tty1"
            serial_getty="$getty_path -L 115200 ttyS0 vt100"
        fi
        cat > "$ROOT/etc/inittab" <<'INITTAB'
::sysinit:/etc/diy/boot
::ctrlaltdel:/sbin/reboot
::shutdown:/etc/diy/shutdown poweroff
INITTAB
        printf '::respawn:%s\n::respawn:%s\n' "$tty1_getty" "$serial_getty" >> "$ROOT/etc/inittab"
    elif [[ "$INIT_CHOICE" == openrc ]]; then
        mkdir -p "$ROOT/etc/runlevels/sysinit" "$ROOT/etc/runlevels/boot" "$ROOT/etc/runlevels/default" "$ROOT/etc/conf.d"
        for service in devfs dmesg mdev; do
                # Xorg uses udev; do not run mdev alongside the udev daemon.
                [[ "$DESKTOP_CHOICE" == none || "$service" != mdev ]] || continue
            [[ ! -x "$ROOT/etc/init.d/$service" ]] || ln -snf "/etc/init.d/$service" "$ROOT/etc/runlevels/sysinit/$service"
        done
        for service in localmount; do
            [[ ! -x "$ROOT/etc/init.d/$service" ]] || ln -snf "/etc/init.d/$service" "$ROOT/etc/runlevels/boot/$service"
        done
        cat > "$ROOT/etc/init.d/diy-loopback" <<'LOOPBACK_SERVICE'
#!/sbin/openrc-run
description="Configure the loopback network interface"
depend() { before net; }
start() {
    ebegin "Configuring loopback interface"
    /usr/sbin/ip link set lo up && /usr/sbin/ip addr replace 127.0.0.1/8 dev lo
    eend $?
}
LOOPBACK_SERVICE
        chmod 0755 "$ROOT/etc/init.d/diy-loopback"
        ln -snf /etc/init.d/diy-loopback "$ROOT/etc/runlevels/boot/diy-loopback"
        if [[ "$TOOLS_CHOICE" == gnu ]]; then
            for service in tty1 ttyS0; do
                ln -snf agetty "$ROOT/etc/init.d/agetty.$service"
                ln -snf "/etc/init.d/agetty.$service" "$ROOT/etc/runlevels/default/agetty.$service"
            done
            printf 'baud="115200"\nterm_type="vt100"\nagetty_options="-L"\n' > "$ROOT/etc/conf.d/agetty.ttyS0"
            if [[ "$AUTOLOGIN" == yes ]]; then
                printf 'baud="38400"\nterm_type="linux"\nagetty_options="--autologin %s"\n' "$USER_NAME" > "$ROOT/etc/conf.d/agetty.tty1"
            else
                printf 'baud="38400"\nterm_type="linux"\n' > "$ROOT/etc/conf.d/agetty.tty1"
            fi
            if [[ ( ${PKG_MATE_CONTROL_CENTER:-no} == yes || ${PKG_MATE_POWER_MANAGER:-no} == yes ) && "$INIT_CHOICE" != systemd ]]; then
                # pam_elogind must not be invoked by an autologin getty until the
                # session daemon and its system D-Bus connection are available.
                printf 'rc_need="elogind"\n' >> "$ROOT/etc/conf.d/agetty.tty1"
            fi
        else
            getty_path=''
            for getty_path in /sbin/getty /usr/sbin/getty /bin/getty /usr/bin/getty; do
                [[ ! -x "$ROOT$getty_path" ]] || break
            done
            [[ -x "$ROOT$getty_path" ]] || die "$(tr_text 'OpenRC with BusyBox requires the BusyBox getty applet' 'OpenRC su BusyBox reikia BusyBox getty programėlės')"
            for service in tty1 ttyS0; do
                if [[ "$service" == tty1 ]]; then getty_args='38400 tty1 linux'
                else getty_args='-L 115200 ttyS0 vt100'; fi
                cat > "$ROOT/etc/init.d/getty.$service" <<BUSYBOX_GETTY
#!/sbin/openrc-run
description="BusyBox getty on $service"
command="$getty_path"
command_args="$getty_args"
supervisor=supervise-daemon
pidfile=/run/openrc-getty-$service.pid
depend() { need localmount; }
BUSYBOX_GETTY
                chmod 0755 "$ROOT/etc/init.d/getty.$service"
                ln -snf "/etc/init.d/getty.$service" "$ROOT/etc/runlevels/default/getty.$service"
            done
        fi
        if [[ "$NETWORK" == yes && "$DESKTOP_CHOICE" == none ]]; then
            cat > "$ROOT/etc/init.d/dhcpcd" <<'DHCP_SERVICE'
#!/sbin/openrc-run
command=/usr/sbin/dhcpcd
command_args=--nobackground
command_background=yes
pidfile=/run/dhcpcd-openrc.pid
depend() { need localmount; after bootmisc; provide net; }
DHCP_SERVICE
            chmod 0755 "$ROOT/etc/init.d/dhcpcd"
            ln -snf /etc/init.d/dhcpcd "$ROOT/etc/runlevels/default/dhcpcd"
        fi
    elif [[ "$INIT_CHOICE" == systemd ]]; then
        mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants" "$ROOT/etc/systemd/system/getty.target.wants"
        # The image is configured during its build (hostname, users, and
        # credentials). systemd-firstboot would otherwise open an interactive
        # wizard on the boot console and appear to hang the first boot.
        ln -snf /dev/null "$ROOT/etc/systemd/system/systemd-firstboot.service"
        ln -snf /usr/lib/systemd/system/multi-user.target "$ROOT/etc/systemd/system/default.target"
        ln -snf /usr/lib/systemd/system/getty@.service "$ROOT/etc/systemd/system/getty.target.wants/getty@tty1.service"
        if [[ "$AUTOLOGIN" == yes ]]; then
            mkdir -p "$ROOT/etc/systemd/system/getty@tty1.service.d"
            cat > "$ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<AUTLOGIN_UNIT
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER_NAME --noclear %I \$TERM
AUTLOGIN_UNIT
        fi
        if [[ "$NETWORK" == yes && "$DESKTOP_CHOICE" == none ]]; then
            mkdir -p "$ROOT/etc/systemd/network"
            ln -snf /usr/lib/systemd/system/systemd-networkd.service "$ROOT/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
            ln -snf /usr/lib/systemd/system/systemd-resolved.service "$ROOT/etc/systemd/system/multi-user.target.wants/systemd-resolved.service"
            printf '[Match]\nName=en* eth*\n[Network]\nDHCP=yes\n' > "$ROOT/etc/systemd/network/20-wired.network"
            ln -snf /run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"
        fi
    fi
    [[ "$PKG_OPENSSH" != yes ]] || configure_sshd_service
    [[ "$PKG_NGINX" != yes ]] || configure_web_services
    cat > "$ROOT/init" <<'INIT'
#!/bin/sh
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
cd / || exit 1
mount -t proc proc /proc 2>/dev/null || :
mount -t sysfs sysfs /sys 2>/dev/null || :
mount -t devtmpfs devtmpfs /dev 2>/dev/null || :
# RFKILL is misc device 10:242. Normally devtmpfs creates it itself; retain
# the node if a minimal init environment failed to populate /dev.
if [ ! -c /dev/rfkill ] && command -v mknod >/dev/null 2>&1; then
    mknod -m 0644 /dev/rfkill c 10 242 2>/dev/null || :
fi
[ ! -c /dev/rfkill ] || chmod 0644 /dev/rfkill 2>/dev/null || :
ln -snf /proc/self/fd /dev/fd
ln -snf /proc/self/fd/0 /dev/stdin
ln -snf /proc/self/fd/1 /dev/stdout
ln -snf /proc/self/fd/2 /dev/stderr
mkdir -p /run /tmp /var/log
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run 2>/dev/null || :
hostname -F /etc/hostname 2>/dev/null || :
INIT
    case "$INIT_CHOICE" in
        systemd) printf 'exec /usr/lib/systemd/systemd\n' >> "$ROOT/init" ;;
        openrc) printf 'exec /sbin/openrc-init\n' >> "$ROOT/init" ;;
        busybox) printf 'exec /usr/bin/busybox init\n' >> "$ROOT/init" ;;
        sysvinit) printf 'exec /usr/sbin/init\n' >> "$ROOT/init" ;;
        runit) printf 'exec /sbin/runit-init\n' >> "$ROOT/init" ;;
        dinit) printf 'exec /usr/bin/dinit\n' >> "$ROOT/init" ;;
        s6) printf 'exec /usr/libexec/diy-s6-init\n' >> "$ROOT/init" ;;
    esac
    chmod 0755 "$ROOT/init"
    configure_prompt
}

kernel_make() {
    env -u PKG_CONFIG_SYSROOT_DIR -u PKG_CONFIG_LIBDIR -u PKG_CONFIG_PATH \
        -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS -u LIBRARY_PATH \
        -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u GPGRT_CONFIG \
        -u HOSTCFLAGS -u HOSTCXXFLAGS -u HOSTLDFLAGS -u HOSTLDLIBS \
        KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=diy-linux \
        KBUILD_BUILD_TIMESTAMP="$(date -u -d "@$SOURCE_DATE_EPOCH" '+%a %b %d %H:%M:%S UTC %Y')" \
        make HOSTCC="$HOST_CC" HOSTCXX="$HOST_CXX" \
        HOSTPKG_CONFIG="$(command -v pkg-config)" "$@"
}

kernel() {
    local source option regdb_source
    source=$(unpack linux)
    mkdir -p "$BUILD/linux"
    if [[ ! -f "$BUILD/linux/.config" ]]; then
        kernel_make -C "$source" O="$BUILD/linux" ARCH="$KERNEL_ARCH" "$KERNEL_CONFIG"
    fi
    for option in BLK_DEV_INITRD RD_GZIP RD_ZSTD DEVTMPFS DEVTMPFS_MOUNT TMPFS TMPFS_POSIX_ACL \
        CGROUPS NAMESPACES UNIX INET SERIAL_8250 SERIAL_8250_CONSOLE VIRTIO \
        VIRTIO_PCI VIRTIO_MMIO VIRTIO_BLK VIRTIO_NET PCI_HOST_GENERIC SERIAL_AMBA_PL011 \
        SERIAL_AMBA_PL011_CONSOLE EXT4_FS EXT4_USE_FOR_EXT2 EFI EFI_STUB \
        UNIX98_PTYS \
        BLK_DEV_LOOP BLK_DEV_SR BLK_DEV_SD SCSI SCSI_VIRTIO ATA SATA_AHCI ATA_PIIX NVME_CORE BLK_DEV_NVME \
        USB USB_XHCI_HCD USB_XHCI_PCI USB_STORAGE USB_UAS ISO9660_FS UDF_FS FAT_FS VFAT_FS \
        SQUASHFS SQUASHFS_ZSTD OVERLAY_FS; do
        "$source/scripts/config" --file "$BUILD/linux/.config" --enable "$option"
    done
    if [[ "$DESKTOP_CHOICE" == mate || "$DESKTOP_CHOICE" == lxde || "$DESKTOP_CHOICE" == fluxbox ]]; then
        for option in VT VT_CONSOLE INPUT INPUT_EVDEV INPUT_KEYBOARD INPUT_MOUSE SERIO SERIO_I8042 \
            KEYBOARD_ATKBD MOUSE_PS2 HID HID_GENERIC USB_HID USB USB_XHCI_HCD USB_EHCI_HCD USB_UHCI_HCD \
            DRM DRM_BOCHS DRM_VIRTIO_GPU DRM_SIMPLEDRM SYSFB_SIMPLEFB DRM_FBDEV_EMULATION \
            FRAMEBUFFER_CONSOLE UNIX SYSVIPC SHMEM TMPFS_POSIX_ACL SND SND_PCM; do
            "$source/scripts/config" --file "$BUILD/linux/.config" --enable "$option"
        done
        if [[ "$PKG_FIREFOX" == yes ]]; then
            for option in USER_NS SECCOMP SECCOMP_FILTER; do
                "$source/scripts/config" --file "$BUILD/linux/.config" --enable "$option"
            done
        fi
    fi
    # Only desktop builds need the broad graphics/audio module set. Keeping
    # these out of console kernels reduces compilation time and module size.
    if [[ "$DESKTOP_CHOICE" == mate || "$DESKTOP_CHOICE" == lxde || "$DESKTOP_CHOICE" == fluxbox ]]; then
        for option in DRM SND SND_PCM SND_SOC SND_SOC_SOF_INTEL_TOPLEVEL; do
            "$source/scripts/config" --file "$BUILD/linux/.config" --enable "$option"
        done
        for option in DRM_AMDGPU DRM_RADEON DRM_I915 DRM_XE DRM_NOUVEAU DRM_VMWGFX DRM_QXL DRM_VBOXVIDEO \
            SND_HDA_INTEL SND_HDA_CODEC_REALTEK SND_HDA_CODEC_HDMI SND_HDA_GENERIC \
            SND_HDA_CODEC_CIRRUS SND_HDA_CODEC_CONEXANT SND_HDA_CODEC_SIGMATEL SND_HDA_CODEC_VIA \
            SND_USB_AUDIO SND_INTEL8X0 SND_INTEL8X0M SND_EMU10K1 SND_ENS1370 \
            SND_SOC_SOF SND_SOC_SOF_AMD_TOPLEVEL SND_SOC_AMD_ACP SND_SOC_INTEL_AVS \
            SND_SOC_SOF_SKYLAKE SND_SOC_SOF_APOLLOLAKE SND_SOC_SOF_GEMINILAKE \
            SND_SOC_SOF_CANNONLAKE SND_SOC_SOF_COFFEELAKE SND_SOC_SOF_COMETLAKE \
            SND_SOC_SOF_ICELAKE SND_SOC_SOF_JASPERLAKE SND_SOC_SOF_TIGERLAKE \
            SND_SOC_SOF_ALDERLAKE SND_SOC_SOF_METEORLAKE SND_SOC_SOF_LUNARLAKE \
            SND_SOC_SOF_PANTHERLAKE SND_SOC_SOF_NOVALAKE SND_SOC_SOF_AMD_RENOIR \
            SND_SOC_SOF_AMD_VANGOGH SND_SOC_SOF_AMD_REMBRANDT; do
            "$source/scripts/config" --file "$BUILD/linux/.config" --module "$option"
        done
    fi
    # Wi-Fi modules and vendor firmware are only needed when networking is
    # enabled. Keep Broadcom/Intel families included for common MacBook radios.
    if [[ "$NETWORK" == yes ]]; then
        for option in WLAN CFG80211 MAC80211 RFKILL WLAN_VENDOR_ATH WLAN_VENDOR_BROADCOM \
            WLAN_VENDOR_INTEL WLAN_VENDOR_MEDIATEK WLAN_VENDOR_REALTEK WLAN_VENDOR_RALINK \
            WLAN_VENDOR_MARVELL WLAN_VENDOR_TI BRCMFMAC_PCIE BRCMFMAC_USB; do
            "$source/scripts/config" --file "$BUILD/linux/.config" --enable "$option"
        done
        for option in ATH9K ATH10K ATH11K ATH12K ATH10K_PCI ATH10K_USB ATH11K_PCI \
            BRCMFMAC BRCMUTIL BRCMSMAC B43 B43LEGACY BCMA SSB \
            IWLWIFI IWLMVM IWLDVM MT76_CORE MT7921E MT7921U MT7925E MT7925U MT7615E MT76x2E MT76x0E \
            RTLWIFI RTL8192CE RTL8192CU RTL8723AE RTL8723BE RTL8821AE RTL8XXXU \
            RTW88 RTW88_8822BE RTW88_8822CE RTW88_8723DE RTW88_8821CE RTW88_8822BU RTW88_8723DU \
            RTW89 RTW89_8851BE RTW89_8852BE RTW89_8852CE RTW89_8922AE RT2X00 MWIFIEX WLCORE; do
            "$source/scripts/config" --file "$BUILD/linux/.config" --module "$option"
        done
    fi
    if [[ "$NETWORK" == yes ]]; then
        # Repair profiles whose firmware stage was already stamped before
        # wireless-regdb was included. This also makes --resume recover them.
        if [[ ! -s "$ROOT/lib/firmware/regulatory.db" || \
              ! -s "$ROOT/lib/firmware/regulatory.db.p7s" || \
              ! -s "$ROOT/usr/share/wireless-regdb/wens.x509.pem" ]]; then
            install_wireless_regdb
        fi
        regdb_source=$(unpack wireless-regdb)
        [[ -s "$regdb_source/wens.x509.pem" && -s "$ROOT/lib/firmware/regulatory.db" && -s "$ROOT/lib/firmware/regulatory.db.p7s" ]] ||
            die 'Wi-Fi regulatory database or signing certificate is missing'
        "$source/scripts/config" --file "$BUILD/linux/.config" --enable CFG80211_REQUIRE_SIGNED_REGDB \
            --enable CFG80211_USE_KERNEL_REGDB_KEYS --set-str SYSTEM_TRUSTED_KEYS "$regdb_source/wens.x509.pem"
    fi
    if [[ "$BOOT_CHOICE" == efistub ]]; then
        "$source/scripts/config" --file "$BUILD/linux/.config" --enable CMDLINE_BOOL --enable CMDLINE_EXTEND \
            --set-str CMDLINE "quiet console=tty0 console=$SERIAL_TTY,115200 initrd=/EFI/Linux/initramfs.cpio.zst"
    fi
    kernel_make -C "$source" O="$BUILD/linux" ARCH="$KERNEL_ARCH" CROSS_COMPILE="$TARGET-" olddefconfig
    local required_option
    local -a required_kernel_options=(BLK_DEV_INITRD RD_ZSTD DEVTMPFS DEVTMPFS_MOUNT TMPFS UNIX98_PTYS CGROUPS NAMESPACES \
        UNIX INET VIRTIO VIRTIO_PCI VIRTIO_BLK BLK_DEV_LOOP BLK_DEV_SR BLK_DEV_SD SCSI SCSI_VIRTIO \
        EXT4_FS ISO9660_FS SQUASHFS SQUASHFS_ZSTD OVERLAY_FS)
    if [[ "$KERNEL_ARCH" == arm64 ]]; then
        required_kernel_options+=(PCI_HOST_GENERIC SERIAL_AMBA_PL011 SERIAL_AMBA_PL011_CONSOLE)
    fi
    for required_option in "${required_kernel_options[@]}"; do
        grep -qx "CONFIG_${required_option}=y" "$BUILD/linux/.config" ||
            die "$(tr_text "Kernel configuration did not enable required CONFIG_${required_option}=y" "Branduolio konfigūracija neįjungė būtino CONFIG_${required_option}=y")"
    done
    kernel_make -C "$source" O="$BUILD/linux" ARCH="$KERNEL_ARCH" CROSS_COMPILE="$TARGET-" -j"$JOBS"
    kernel_make -C "$source" O="$BUILD/linux" ARCH="$KERNEL_ARCH" CROSS_COMPILE="$TARGET-" \
        INSTALL_MOD_PATH="$ROOT" DEPMOD="$(command -v depmod)" modules_install
    install -m0644 "$BUILD/linux/$KERNEL_IMAGE" "$ROOT/boot/bzImage"
    install -m0644 "$BUILD/linux/$KERNEL_IMAGE" "$IMAGES/bzImage"
    install -m0644 "$BUILD/linux/.config" "$ROOT/boot/kernel.config"
}

boot_tools() {
    case "$BOOT_CHOICE" in
        bios|uefi) grub_tools ;;
        lilo) build_lilo_tools ;;
        syslinux|refind|limine) unpack "$BOOT_CHOICE" >/dev/null ;;
        systemd-boot) unpack "$SDBOOT_PACKAGE" >/dev/null ;;
        efistub|none) : ;;
    esac
}

build_lilo_tools() {
    local bin86_source lilo_source tools="$BASE/lilo-tools"
    mkdir -p "$tools/bin" "$tools/sbin"
    bin86_source=$(unpack linux86)
    (cd "$bin86_source"; make CC=gcc as86 ld86)
    install -m0755 "$bin86_source/bin/as86" "$tools/bin/as86"
    install -m0755 "$bin86_source/bin/ld86" "$tools/bin/ld86"
    lilo_source=$(unpack lilo)
    # LILO 24.2 predates GCC's default -fno-common; its common symbols need
    # the compatibility flag. Its src/Makefile also depends on ../test.img,
    # which is a small marker created by the source tree's top-level test.img
    # target; create it explicitly without building diagnostic floppy images.
    env -u CC -u CFLAGS -u CPPFLAGS -u LDFLAGS PATH="$tools/bin:$PATH" \
        make -C "$lilo_source" test.img
    env -u CC -u CFLAGS -u CPPFLAGS -u LDFLAGS PATH="$tools/bin:$PATH" \
        make -C "$lilo_source/src" OPT='-Os -fcommon' all
    install -m0755 "$lilo_source/src/lilo" "$tools/sbin/lilo"
}

copy_to_esp() {
    local image=$1 source=$2 destination=$3 parent part component
    local -a dirs=()
    parent=${destination%/*}
    IFS=/ read -r -a dirs <<< "$parent"
    part=
    for component in "${dirs[@]}"; do
        [[ -n "$component" ]] || continue
        part+="/$component"
        mmd -i "$image" "::$part" 2>/dev/null || :
    done
    mcopy -i "$image" -o "$source" "::$destination"
}

create_uefi_image() {
    local iso=$1 source loader config_file esp="$IMAGES/diy-linux-esp.img"
    local image_bytes esp_mib block_mib=64
    local efi_path="EFI/BOOT/$EFI_BOOT"
    rm -f "$esp"
    image_bytes=$(($(stat -c %s "$IMAGES/bzImage") + $(stat -c %s "$IMAGES/initramfs.cpio.zst") + \
        $(stat -c %s "$IMAGES/rootfs.squashfs") + 48 * 1024 * 1024))
    esp_mib=$(((image_bytes + block_mib * 1024 * 1024 - 1) / (block_mib * 1024 * 1024) * block_mib))
    (( esp_mib >= 128 )) || esp_mib=128
    local fat_file_limit=4294967295 image
    for image in "$IMAGES/bzImage" "$IMAGES/initramfs.cpio.zst" "$IMAGES/rootfs.squashfs"; do
        (( $(stat -c %s "$image") <= fat_file_limit )) || die "$(tr_text 'An EFI partition file exceeds the FAT 4 GiB per-file limit' 'EFI skaidinio failas viršija FAT 4 GiB vieno failo ribą')"
    done
    truncate -s "${esp_mib}M" "$esp"
    mformat -i "$esp" -F ::
    case "$BOOT_CHOICE" in
        refind)
            source="$SOURCES/refind-${VERSION[refind]}"
            loader=$(find "$source" \( -type f -o -type l \) -iname "refind_${EFI_SUFFIX}.efi" -print -quit)
            [[ -n "$loader" ]] || die "$(tr_text 'rEFInd EFI binary not found in archive' 'Archyve nerastas rEFInd EFI failas')"
            copy_to_esp "$esp" "$loader" "$efi_path"
            copy_to_esp "$esp" "$IMAGES/bzImage" EFI/Linux/bzImage
            copy_to_esp "$esp" "$IMAGES/initramfs.cpio.zst" EFI/Linux/initramfs.cpio.zst
            copy_to_esp "$esp" "$IMAGES/rootfs.squashfs" boot/rootfs.squashfs
            config_file="$BASE/refind.conf"
            printf 'timeout 5\nmenuentry "%s" {\n    loader /EFI/Linux/bzImage\n    initrd /EFI/Linux/initramfs.cpio.zst\n    options "quiet console=tty0 console=%s,115200"\n}\n' "$OS_NAME" "$SERIAL_TTY" > "$config_file"
            copy_to_esp "$esp" "$config_file" EFI/BOOT/refind.conf
            ;;
        systemd-boot)
            source="$SOURCES/$SDBOOT_PACKAGE-${VERSION[$SDBOOT_PACKAGE]}"
            loader=$(find "$source" \( -type f -o -type l \) -iname "systemd-boot${EFI_SUFFIX}.efi" -print -quit)
            [[ -n "$loader" ]] || die "$(tr_text 'systemd-boot EFI binary not found in package' 'Pakete nerastas systemd-boot EFI failas')"
            copy_to_esp "$esp" "$loader" "$efi_path"
            copy_to_esp "$esp" "$IMAGES/bzImage" EFI/Linux/bzImage
            copy_to_esp "$esp" "$IMAGES/initramfs.cpio.zst" EFI/Linux/initramfs.cpio.zst
            copy_to_esp "$esp" "$IMAGES/rootfs.squashfs" boot/rootfs.squashfs
            config_file="$BASE/loader.conf"
            printf 'default diy.conf\ntimeout 5\n' > "$config_file"
            copy_to_esp "$esp" "$config_file" loader/loader.conf
            config_file="$BASE/diy.conf"
            printf 'title %s\nlinux /EFI/Linux/bzImage\ninitrd /EFI/Linux/initramfs.cpio.zst\noptions quiet console=tty0 console=%s,115200\n' "$OS_NAME" "$SERIAL_TTY" > "$config_file"
            copy_to_esp "$esp" "$config_file" loader/entries/diy.conf
            ;;
        efistub)
            # The kernel itself is the firmware fallback EFI executable. The
            # EFI stub command line points at this initramfs on the same ESP.
            copy_to_esp "$esp" "$IMAGES/bzImage" "$efi_path"
            copy_to_esp "$esp" "$IMAGES/initramfs.cpio.zst" EFI/Linux/initramfs.cpio.zst
            copy_to_esp "$esp" "$IMAGES/rootfs.squashfs" boot/rootfs.squashfs
            ;;
    esac
    cp "$esp" "$iso/efi.img"
    xorriso -as mkisofs -R -J -V DIY_LINUX -o "$IMAGES/$SYSTEM_NAME.iso" \
        -eltorito-alt-boot -e efi.img -no-emul-boot \
        -efi-boot-part --efi-boot-image --protective-msdos-label "$iso" >/dev/null
}

strip_elf() {
    # Keep target binaries executable and usable; only discard debug sections.
    # STRIP is the cross-tool from the selected target toolchain, not host strip.
    local file=${1:?strip_elf requires an ELF file} original_mode status
    [[ -n ${STRIP:-} ]] || die "$(tr_text 'Target strip tool is not configured' 'Nenurodytas tikslinės sistemos strip įrankis')"
    # Some upstream install rules deliberately install binaries as 0555. GNU
    # strip needs write access to the input while replacing it; restore the
    # exact original mode (including setuid/setgid bits) after it completes.
    original_mode=$(stat -c '%a' -- "$file") || return
    chmod u+w -- "$file" || return
    if "$STRIP" --strip-debug "$file"; then
        chmod "$original_mode" -- "$file"
    else
        status=$?
        chmod "$original_mode" -- "$file" || :
        return "$status"
    fi
}


create_lilo_image() {
    local temporary caller_uid caller_gid lilo_label
    local lilo_bin="$BASE/lilo-tools/sbin/lilo"
    lilo_label=${OS_NAME//[ .-]/_}
    lilo_label=${lilo_label:0:15}
    [[ -x "$lilo_bin" ]] || die "$(tr_text 'LILO installer was not built' 'LILO diegiklis nesukompiliuotas')"
    command -v losetup >/dev/null && command -v sfdisk >/dev/null && \
        command -v mkfs.ext2 >/dev/null && command -v mount >/dev/null && command -v umount >/dev/null && command -v mountpoint >/dev/null || \
        die "$(tr_text 'LILO IMG creation requires losetup, sfdisk, mkfs.ext2, mount, umount and mountpoint' 'LILO IMG kūrimui reikia losetup, sfdisk, mkfs.ext2, mount, umount ir mountpoint')"
    if (( EUID != 0 )); then
        command -v sudo >/dev/null || die "$(tr_text 'Creating a LILO BIOS image requires sudo for a temporary loop device' 'LILO BIOS atvaizdui sukurti reikia sudo laikinam loop įrenginiui')"
    fi
    temporary=$(mktemp "$IMAGES/.diy-linux-lilo.XXXXXX")
    caller_uid=${SUDO_UID:-$(id -u)}; caller_gid=${SUDO_GID:-$(id -g)}
    local -a sudo_args=("$temporary" "$IMAGES/diy-linux.img" "$IMAGES/bzImage" \
        "$IMAGES/initramfs.cpio.zst" "$IMAGES/rootfs.squashfs" "$lilo_bin" "$caller_uid" "$caller_gid" "$SERIAL_TTY" "$lilo_label")
    local -a privilege=()
    if (( EUID != 0 )); then
        printf '%s\n' "$(tr_text 'Using sudo only for a loop device backed by the new image file; physical disks are not touched.' 'sudo bus naudojamas tik naujam atvaizdo failui prijungti per loop; fiziniai diskai neliečiami.')"
        privilege=(sudo)
    fi
    # Pass the helper as bash -c text, not bash stdin: a child command that
    # accidentally reads stdin must not consume the rest of this script.
    "${privilege[@]}" bash -c "$(cat <<'LILO_IMAGE_ROOT'
set -Eeuo pipefail
temporary=$1 final=$2 kernel=$3 initramfs=$4 rootfs_image=$5 lilo_bin=$6 owner_uid=$7 owner_gid=$8 serial_tty=$9 lilo_label=${10}
mount_dir=''; loopdev=''; partdev=''; config=''; created_disk_node=''; created_part_node=''
cleanup() {
    [[ -z "$config" ]] || rm -f -- "$config"
    [[ -z "$mount_dir" ]] || { mountpoint -q "$mount_dir" && umount "$mount_dir" || :; }
    [[ -z "$partdev" ]] || losetup -d "$partdev" || :
    [[ -z "$loopdev" ]] || losetup -d "$loopdev" || :
    [[ -z "$created_part_node" ]] || rm -f -- "$created_part_node"
    [[ -z "$created_disk_node" ]] || rm -f -- "$created_disk_node"
    [[ ! -e "$temporary" ]] || rm -f -- "$temporary"
    [[ -z "$mount_dir" ]] || rmdir "$mount_dir" 2>/dev/null || :
}
trap cleanup EXIT
[[ -s "$kernel" && -s "$initramfs" && -x "$lilo_bin" ]]
[[ -f "$temporary" && ! -L "$temporary" ]]
bytes=$(( $(stat -c %s "$kernel") + $(stat -c %s "$initramfs") + $(stat -c %s "$rootfs_image") + 160 * 1024 * 1024 ))
image_mib=$(((bytes + 1024 * 1024 - 1) / (1024 * 1024)))
(( image_mib >= 256 )) || image_mib=256
disk_cylinders=$((image_mib * 8)) # LILO mkrescue geometry: 32 sectors * 8 heads.
truncate -s "${image_mib}M" "$temporary"
printf 'label: dos\nunit: sectors\n\nstart=2048, type=83, bootable\n' | sfdisk "$temporary" >/dev/null
# LILO identifies a disk's partitions from the low three bits of the block
# device minor number. Therefore its base loop device must have minor % 8 == 0
# and the separate offset loop device must be the immediately following minor.
# --find can return /dev/loop1 when loop0 is busy, which LILO mistakes for
# partition 1 and then reports as bad geometry. Allocate a free aligned pair.
# LILO 24.2's loop-device handling is limited to minor numbers 0..15.
for ((loop_index=0; loop_index<=8; loop_index+=8)); do
    disk_candidate=/dev/loop${loop_index}
    part_candidate=/dev/loop$((loop_index + 1))
    if [[ ! -e "$disk_candidate" ]]; then
        mknod -m0600 "$disk_candidate" b 7 "$loop_index" || continue
        created_disk_node=$disk_candidate
    fi
    if [[ ! -b "$disk_candidate" ]] || losetup "$disk_candidate" >/dev/null 2>&1; then
        [[ -z "$created_disk_node" ]] || { rm -f -- "$created_disk_node"; created_disk_node=''; }
        continue
    fi
    if [[ ! -e "$part_candidate" ]]; then
        mknod -m0600 "$part_candidate" b 7 "$((loop_index + 1))" || {
            [[ -z "$created_disk_node" ]] || { rm -f -- "$created_disk_node"; created_disk_node=''; }
            continue
        }
        created_part_node=$part_candidate
    fi
    if [[ ! -b "$part_candidate" ]] || losetup "$part_candidate" >/dev/null 2>&1; then
        [[ -z "$created_part_node" ]] || { rm -f -- "$created_part_node"; created_part_node=''; }
        [[ -z "$created_disk_node" ]] || { rm -f -- "$created_disk_node"; created_disk_node=''; }
        continue
    fi
    if losetup "$disk_candidate" "$temporary" >/dev/null 2>&1; then
        loopdev=$disk_candidate
        if losetup --offset $((2048 * 512)) "$part_candidate" "$temporary" >/dev/null 2>&1; then
            partdev=$part_candidate
            break
        fi
        losetup -d "$loopdev" || :
        loopdev=''
    fi
    [[ -z "$created_part_node" ]] || { rm -f -- "$created_part_node"; created_part_node=''; }
    [[ -z "$created_disk_node" ]] || { rm -f -- "$created_disk_node"; created_disk_node=''; }
done
[[ -n "$loopdev" && -n "$partdev" ]] || {
    printf 'LILO: could not allocate a supported free pair (/dev/loop0 + /dev/loop1 or /dev/loop8 + /dev/loop9). Close processes using these loop devices and retry.\n' >&2
    exit 1
}
[[ -b "$partdev" ]] || { printf 'LILO: partition device did not appear: %s\n' "$partdev" >&2; exit 1; }
mkfs.ext2 -F "$partdev" >/dev/null
mount_dir=$(mktemp -d /tmp/diy-lilo-mount.XXXXXX)
mount "$partdev" "$mount_dir"
mkdir -p "$mount_dir/boot"
install -m0644 "$kernel" "$mount_dir/boot/bzImage"
install -m0644 "$initramfs" "$mount_dir/boot/initramfs.cpio.zst"
install -m0644 "$rootfs_image" "$mount_dir/boot/rootfs.squashfs"
config=$(mktemp /tmp/diy-lilo-conf.XXXXXX)
cat > "$config" <<LILOCFG
boot=$loopdev
map=$mount_dir/boot/map
install=text
backup=/dev/null
prompt
timeout=50
default=$lilo_label
lba32
large-memory
static-bios-codes
disk=$loopdev
    bios=0x80
    sectors=32
    heads=8
    cylinders=$disk_cylinders
    max-partitions=7
    partition=$partdev
        start=2048
image=$mount_dir/boot/bzImage
    label=$lilo_label
    read-only
    initrd=$mount_dir/boot/initramfs.cpio.zst
    append="quiet console=tty0 console=$serial_tty,115200"
LILOCFG
# Validate the boot map and disk configuration before writing anything to the
# temporary image. LILO's -t mode is documented to leave both sectors and map
# files untouched; the following invocation performs the actual installation.
"$lilo_bin" -t -C "$config" -v
"$lilo_bin" -C "$config" -v
sync
umount "$mount_dir"
losetup -d "$partdev"; partdev=''
losetup -d "$loopdev"; loopdev=''
rmdir "$mount_dir"; mount_dir=''
mv -f -- "$temporary" "$final"
chown "$owner_uid:$owner_gid" "$final"
chmod 0644 "$final"
LILO_IMAGE_ROOT
)" _ "${sudo_args[@]}"
}

pack_boot_image() {
    [[ "$BOOT_CHOICE" != none ]] || return 0
    [[ -n ${BASE:-} && "$BASE" == /* && "$BASE" != / &&
       -n ${ROOT:-} && "$ROOT" == "$BASE/rootfs" && -d "$ROOT" && ! -L "$ROOT" &&
       -n ${IMAGES:-} && "$IMAGES" == "$BASE/images" && -d "$IMAGES" ]] ||
        die "$(tr_text 'Refusing to package: profile paths are empty or inconsistent.' 'Atsisakoma pakuoti: profilio keliai tušti arba nesutampa.')"
    local iso="$BASE/iso" source bios_bin efi_bin efi_loader bios_sys ldlinux config_file limine_installer
    rm -rf -- "$iso"
    mkdir -p "$iso/boot"
    cp "$IMAGES/bzImage" "$IMAGES/initramfs.cpio.zst" "$IMAGES/rootfs.squashfs" "$iso/boot/"
    case "$BOOT_CHOICE" in
        lilo) create_lilo_image ;;
        bios|uefi)
            mkdir -p "$iso/boot/grub"
            cat > "$iso/boot/grub/grub.cfg" <<GRUBCFG
set timeout=5
set default=0
GRUBCFG
            if [[ "$TARGET_ARCH" == aarch64 ]]; then
                # GRUB's PC-style serial --unit flag is not valid for the
                # ARM64 UEFI serial device (QEMU virt exposes a PL011 MMIO
                # UART). Keep GRUB on the firmware console; Linux still gets
                # its ttyAMA0 console from the kernel command line below.
                printf '%s\n' 'terminal_input console' 'terminal_output console' \
                    >> "$iso/boot/grub/grub.cfg"
            else
                printf '%s\n' 'serial --unit=0 --speed=115200' \
                    'terminal_input console serial' \
                    'terminal_output console serial' \
                    >> "$iso/boot/grub/grub.cfg"
            fi
            cat >> "$iso/boot/grub/grub.cfg" <<GRUBCFG
menuentry "$OS_NAME (Live)" {
    linux /boot/bzImage quiet console=tty0 console=$SERIAL_TTY,115200
    initrd /boot/initramfs.cpio.zst
}
GRUBCFG
            prepare_grub_font
            # Locally built GRUB 2.14 can stop at firmware handoff on both
            # SeaBIOS and OVMF. Prefer the host's tested GRUB for x86_64 ISO
            # images; retain the profile-local tools as fallback elsewhere.
            if [[ "$TARGET_ARCH" == x86_64 ]] &&
               command -v grub-mkrescue >/dev/null 2>&1; then
                if ! grub-mkrescue --fonts='' --themes='' \
                    --label-font="$BASE/grub-tools/share/grub/unicode.pf2" \
                    -o "$IMAGES/$SYSTEM_NAME.iso" "$iso"; then
                    rm -f "$IMAGES/$SYSTEM_NAME.iso"
                    "$BASE/grub-tools/bin/grub-mkrescue" --fonts='' --themes='' \
                        --label-font="$BASE/grub-tools/share/grub/unicode.pf2" \
                        -o "$IMAGES/$SYSTEM_NAME.iso" "$iso"
                fi
            else
                "$BASE/grub-tools/bin/grub-mkrescue" --fonts='' --themes='' \
                    --label-font="$BASE/grub-tools/share/grub/unicode.pf2" \
                    -o "$IMAGES/$SYSTEM_NAME.iso" "$iso"
            fi
            ;;
        syslinux)
            source="$SOURCES/syslinux-${VERSION[syslinux]}"
            bios_bin=$(find "$source" -type f -path '*/bios/core/isolinux.bin' -print -quit)
            ldlinux=$(find "$source" -type f -path '*/bios/com32/elflink/ldlinux/ldlinux.c32' -print -quit)
            [[ -n "$bios_bin" && -n "$ldlinux" ]] || die "$(tr_text 'Syslinux ISO boot files are missing' 'Trūksta Syslinux ISO paleidimo failų')"
            mkdir -p "$iso/isolinux"
            cp "$bios_bin" "$iso/isolinux/isolinux.bin"
            cp "$ldlinux" "$iso/isolinux/ldlinux.c32"
            config_file="$iso/isolinux/isolinux.cfg"
            printf 'PROMPT 0\nTIMEOUT 50\nDEFAULT diy\nLABEL diy\n  MENU LABEL %s\n  KERNEL /boot/bzImage\n  INITRD /boot/initramfs.cpio.zst\n  APPEND quiet console=tty0 console=%s,115200\n' "$OS_NAME" "$SERIAL_TTY" > "$config_file"
            bios_bin=$(find "$source" -type f -path '*/bios/mbr/isohdpfx.bin' -print -quit)
            [[ -n "$bios_bin" ]] || die "$(tr_text 'Syslinux isohybrid MBR is missing' 'Trūksta Syslinux isohybrid MBR')"
            xorriso -as mkisofs -R -J -V DIY_LINUX -o "$IMAGES/$SYSTEM_NAME.iso" \
                -isohybrid-mbr "$bios_bin" -b isolinux/isolinux.bin -c isolinux/boot.cat \
                -no-emul-boot -boot-load-size 4 -boot-info-table "$iso" >/dev/null
            ;;
        limine)
            source="$SOURCES/limine-${VERSION[limine]}"
            # Binary release tarballs contain the EFI/BIOS boot assets but no
            # native `limine` installer on Linux; build that host-side utility.
            [[ -x "$source/limine" ]] || make -C "$source" CC="$HOST_CC" CFLAGS='-O2 -pipe'
            bios_bin=$(find "$source" -type f -name limine-bios-cd.bin -print -quit)
            efi_bin=$(find "$source" -type f -name limine-uefi-cd.bin -print -quit)
            efi_loader=$(find "$source" -type f -iname 'BOOTX64.EFI' -print -quit)
            bios_sys=$(find "$source" -type f -name limine-bios.sys -print -quit)
            limine_installer=$(find "$source" -type f -name limine -perm -u+x -print -quit)
            [[ -n "$bios_bin" && -n "$efi_bin" && -n "$efi_loader" && -n "$bios_sys" && -n "$limine_installer" ]] || die "$(tr_text 'Limine BIOS/UEFI boot files are missing' 'Trūksta Limine BIOS/UEFI paleidimo failų')"
            cp "$bios_bin" "$iso/limine-bios-cd.bin"
            cp "$efi_bin" "$iso/limine-uefi-cd.bin"
            cp "$bios_sys" "$iso/limine-bios.sys"
            mkdir -p "$iso/EFI/BOOT"
            cp "$efi_loader" "$iso/EFI/BOOT/BOOTX64.EFI"
            printf 'timeout: 5\n\n/%s\n    protocol: linux\n    kernel_path: boot():/boot/bzImage\n    module_path: boot():/boot/initramfs.cpio.zst\n    cmdline: quiet console=tty0 console=%s,115200\n' "$OS_NAME" "$SERIAL_TTY" > "$iso/limine.conf"
            xorriso -as mkisofs -R -J -V DIY_LINUX -o "$IMAGES/$SYSTEM_NAME.iso" \
                -b limine-bios-cd.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
                --efi-boot limine-uefi-cd.bin --efi-boot-part --efi-boot-image \
                --protective-msdos-label "$iso" >/dev/null
            "$limine_installer" bios-install "$IMAGES/$SYSTEM_NAME.iso"
            ;;
        refind|systemd-boot|efistub)
            create_uefi_image "$iso"
            ;;
        *) die "$(tr_text 'Unsupported boot image recipe' 'Nepalaikomas paleidimo atvaizdo receptas')" ;;
    esac
}

copy_live_initrd_path() {
    local source=$1 root=$2 tree=$3 relative real link target interpreter needed dependency
    [[ "$source" == "$root/"* && ( -e "$source" || -L "$source" ) ]] ||
        die "$(tr_text "Missing early-boot file: $source" "Trūksta ankstyvojo paleidimo failo: $source")"
    [[ ! -v LIVE_INITRD_SEEN[$source] ]] || return 0
    LIVE_INITRD_SEEN[$source]=1
    relative=${source#"$root"/}
    mkdir -p "$tree/$(dirname "$relative")"
    cp -a "$source" "$tree/$relative"

    if [[ -L "$source" ]]; then
        link=$(readlink "$source")
        if [[ "$link" == /* ]]; then target="$root$link"
        else target="$(dirname "$source")/$link"; fi
        target=$(realpath -m -- "$target")
        copy_live_initrd_path "$target" "$root" "$tree"
        return 0
    fi
    real=$source
    readelf -h "$real" >/dev/null 2>&1 || return 0
    interpreter=$(readelf -l "$real" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p' | head -n 1)
    if [[ -n "$interpreter" ]]; then
        copy_live_initrd_path "$root$interpreter" "$root" "$tree"
    fi
    while IFS= read -r needed; do
        [[ -n "$needed" ]] || continue
        dependency=$(find "$root/lib" "$root/lib64" "$root/usr/lib" -name "$needed" -print -quit 2>/dev/null || :)
        [[ -n "$dependency" ]] || die "$(tr_text "Cannot resolve early-boot library $needed for $source" "Nepavyko rasti ankstyvojo paleidimo bibliotekos $needed ($source)")"
        copy_live_initrd_path "$dependency" "$root" "$tree"
    done < <(readelf -d "$real" 2>/dev/null | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
}

build_live_initramfs() {
    local tree="$BUILD/live-initramfs"
    rm -rf -- "$tree"
    mkdir -p "$tree"/{dev,proc,sys,run,newroot,usr/bin,usr/sbin}
    cat > "$tree/init" <<'LIVE_INIT'
#!/usr/bin/bash
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
mount -t proc proc /proc 2>/dev/null || :
mount -t sysfs sysfs /sys 2>/dev/null || :
mount -t devtmpfs devtmpfs /dev 2>/dev/null || :
# RFKILL is misc device 10:242; provide a fallback if devtmpfs omitted it.
if [ ! -c /dev/rfkill ] && command -v mknod >/dev/null 2>&1; then
    mknod -m 0644 /dev/rfkill c 10 242 2>/dev/null || :
fi
[ ! -c /dev/rfkill ] || chmod 0644 /dev/rfkill 2>/dev/null || :
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run 2>/dev/null || :
mkdir -p /run/media /run/lower /run/upper /run/work /newroot
shopt -s nullglob
start_live_root() {
    mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /run/upper || return 1
    mkdir -p /run/upper/upper /run/upper/work
    if ! mount -t overlay overlay -o lowerdir=/run/lower,upperdir=/run/upper/upper,workdir=/run/upper/work /newroot; then
        umount /run/upper 2>/dev/null || :
        umount /run/lower 2>/dev/null || :
        return 1
    fi
    printf '%s\n' 'DIY Linux: live changes use RAM and are discarded at shutdown.' > /dev/console
    mkdir -p /newroot/dev /newroot/proc /newroot/sys /newroot/run
    mount --move /dev /newroot/dev || return 1
    mount --move /proc /newroot/proc || return 1
    mount --move /sys /newroot/sys || return 1
    mount --move /run /newroot/run || return 1
    exec /usr/sbin/switch_root /newroot /init
}
for attempt in {1..30}; do
    for device in /dev/sr* /dev/sd* /dev/nvme*n* /dev/vd* /dev/mmcblk*; do
        [[ -b "$device" ]] || continue
        if mount -t squashfs -o ro "$device" /run/lower 2>/dev/null; then
            start_live_root || :
        fi
        mount -o ro "$device" /run/media 2>/dev/null || continue
        for image in /run/media/boot/rootfs.squashfs /run/media/rootfs.squashfs; do
            [[ -s "$image" ]] || continue
            if ! mount -t squashfs -o loop,ro "$image" /run/lower 2>/dev/null; then continue; fi
            start_live_root || :
        done
        umount /run/media 2>/dev/null || :
    done
    sleep 1
done
printf '%s\n' 'DIY Linux: could not find boot/rootfs.squashfs on CD, USB, or disk.' 'Check the boot medium and required storage drivers.'
exec /usr/bin/bash
LIVE_INIT
    chmod 0755 "$tree/init"
    declare -gA LIVE_INITRD_SEEN=()
    local path
    for path in usr/bin/bash usr/bin/mount usr/bin/umount usr/bin/sleep usr/bin/mkdir \
        usr/bin/chmod usr/bin/mknod usr/sbin/switch_root; do
        copy_live_initrd_path "$ROOT/$path" "$ROOT" "$tree"
    done
    # BusyBox-only profiles may not provide blkid; those use the documented
    # RAM overlay fallback instead of failing while building the initramfs.
    if [[ -x "$ROOT/usr/sbin/blkid" ]]; then
        copy_live_initrd_path "$ROOT/usr/sbin/blkid" "$ROOT" "$tree"
    elif [[ -x "$ROOT/usr/bin/blkid" ]]; then
        copy_live_initrd_path "$ROOT/usr/bin/blkid" "$ROOT" "$tree"
    fi
    # cfg80211 may request its signed regulatory database before switch_root.
    # Keep only these tiny files in initramfs so Wi-Fi starts without an early
    # firmware lookup warning; the full firmware remains in the SquashFS.
    if [[ -s "$ROOT/lib/firmware/regulatory.db" && -s "$ROOT/lib/firmware/regulatory.db.p7s" ]]; then
        install -d -m0755 "$tree/lib/firmware"
        install -m0644 "$ROOT/lib/firmware/regulatory.db" "$tree/lib/firmware/regulatory.db"
        install -m0644 "$ROOT/lib/firmware/regulatory.db.p7s" "$tree/lib/firmware/regulatory.db.p7s"
    fi
}

verify_desktop_network() {
    [[ "$NETWORK" != yes ]] && return 0
    local program option
    for program in /usr/sbin/NetworkManager /usr/sbin/wpa_supplicant /usr/bin/nm-applet \
        /usr/bin/nm-connection-editor /usr/sbin/iw; do
        [[ -x "$ROOT$program" ]] || die "$(tr_text "Desktop Wi-Fi is missing $program" "Darbalaukio Wi-Fi trūksta $program")"
    done
    [[ -s "$ROOT/lib/firmware/regulatory.db" && -s "$ROOT/lib/firmware/regulatory.db.p7s" ]] ||
        die "$(tr_text 'Wi-Fi regulatory database is missing' 'Trūksta Wi-Fi reguliavimo duomenų bazės')"
    if [[ -d "$ROOT/lib/firmware/intel/iwlwifi" ]] && \
        find "$ROOT/lib/modules" -type f -name 'iwlwifi.ko*' -print -quit | grep -q .; then
        local iwl_firmware
        iwl_firmware=$(find "$ROOT/lib/firmware/intel/iwlwifi" -maxdepth 1 -type f \
            \( -name 'iwlwifi-*.ucode' -o -name 'iwlwifi-*.pnvm' \) -print -quit)
        [[ -n "$iwl_firmware" && -e "$ROOT/lib/firmware/${iwl_firmware##*/}" ]] ||
            die "$(tr_text 'Intel Wi-Fi firmware is not available at the path expected by the kernel driver' 'Intel Wi-Fi firmware nėra branduolio tvarkyklės laukiamame kelyje')"
    fi
    for option in WLAN CFG80211 MAC80211 RFKILL; do
        grep -qx "CONFIG_$option=y" "$ROOT/boot/kernel.config" ||
            die "$(tr_text "Wi-Fi kernel support is missing CONFIG_$option=y" "Wi-Fi branduolyje trūksta CONFIG_$option=y")"
    done
    # Intel MacBook Pros commonly use Broadcom PCIe radios. Keep both newer
    # brcmfmac devices and older b43/brcmsmac families available in the image.
    for option in BRCMFMAC BRCMSMAC B43 B43LEGACY BCMA SSB; do
        grep -Eq "^CONFIG_${option}=m$" "$ROOT/boot/kernel.config" ||
            die "$(tr_text "Broadcom Wi-Fi kernel support is missing CONFIG_${option}=m" "Broadcom Wi-Fi branduolyje trūksta CONFIG_${option}=m")"
    done
    for module in brcmfmac brcmutil brcmsmac b43 b43legacy bcma ssb; do
        find "$ROOT/lib/modules" -type f -name "$module.ko*" -print -quit | grep -q . ||
            die "$(tr_text "Broadcom Wi-Fi kernel module is missing: $module" "Trūksta Broadcom Wi-Fi branduolio modulio: $module")"
    done
    for firmware in brcmfmac4350-pcie.bin brcmfmac43602-pcie.bin; do
        [[ -s "$ROOT/lib/firmware/brcm/$firmware" ]] ||
            die "$(tr_text "Broadcom Mac Wi-Fi firmware is missing: $firmware" "Trūksta Broadcom Mac Wi-Fi firmware: $firmware")"
    done
    local startup_ok=no supplicant_ok=no
    if [[ "$DESKTOP_CHOICE" == lxde ]]; then
        ! grep -Eq 'type[[:space:]]*=[[:space:]]*netstatus' \
            "$ROOT/etc/xdg/lxpanel/LXDE/panels/panel" ||
            die "$(tr_text 'LXDE legacy network-properties icon is still enabled' 'LXDE vis dar įjungta sena tinklo savybių piktograma')"
        grep -Eq 'type[[:space:]]*=[[:space:]]*tray' \
            "$ROOT/etc/xdg/lxpanel/LXDE/panels/panel" ||
            die "$(tr_text 'LXDE panel has no system tray for the NetworkManager applet' 'LXDE skydelyje nėra dėklo NetworkManager programėlei')"
        [[ -x "$ROOT/usr/bin/nm-applet" ]] ||
            die "$(tr_text 'NetworkManager Wi-Fi tray applet is missing' 'Trūksta NetworkManager Wi-Fi dėklo programėlės')"
        grep -qx 'network_gui/command=no' \
            "$ROOT/home/$USER_NAME/.config/lxsession/LXDE/desktop.conf" ||
            die "$(tr_text 'LXDE network applet must use the single XDG autostart path' 'LXDE tinklo programėlė turi naudoti vieną XDG automatinio paleidimo kelią')"
        grep -qx 'OnlyShowIn=LXDE;' "$ROOT/etc/xdg/autostart/nm-applet.desktop" ||
            die "$(tr_text 'NetworkManager applet is not enabled for the LXDE session' 'NetworkManager programėlė neįjungta LXDE sesijai')"
    else
        [[ -f "$ROOT/etc/xdg/autostart/nm-applet.desktop" ]] ||
            die "$(tr_text 'NetworkManager tray applet autostart is missing' 'Trūksta NetworkManager piktogramos automatinio paleidimo')"
    fi
    case "$INIT_CHOICE" in
        openrc)
            [[ -L "$ROOT/etc/runlevels/default/NetworkManager" ]] && startup_ok=yes
            [[ -L "$ROOT/etc/runlevels/default/wpa_supplicant" ]] && supplicant_ok=yes ;;
        systemd)
            [[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/NetworkManager.service" ]] && startup_ok=yes
            [[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service" ]] && supplicant_ok=yes ;;
        *)
            grep -Fq '/usr/libexec/diy-desktop-boot' "$ROOT/etc/diy/boot" && startup_ok=yes
            grep -Fq '/usr/sbin/wpa_supplicant -u -B' "$ROOT/usr/libexec/diy-desktop-boot" && supplicant_ok=yes ;;
    esac
    [[ "$startup_ok" == yes ]] ||
        die "$(tr_text 'NetworkManager startup is not configured for the selected init system' 'NetworkManager paleidimas nesukonfigūruotas pasirinktai init sistemai')"
    [[ "$supplicant_ok" == yes ]] ||
        die "$(tr_text 'wpa_supplicant D-Bus startup is not configured for the selected init system' 'wpa_supplicant D-Bus paleidimas nesukonfigūruotas pasirinktai init sistemai')"
}

verify_desktop_audio_tray() {
    [[ -x "$ROOT/usr/bin/diy-sound-mixer" && -f "$ROOT/etc/xdg/autostart/diy-volume-applet.desktop" ]] ||
        die "$(tr_text 'Desktop sound tray icon is missing' 'Darbalaukio garso piktogramos dėkle trūksta')"
    case "$DESKTOP_CHOICE" in
        mate)
            grep -q 'applet-iid=NotificationAreaAppletFactory::NotificationArea' \
                "$ROOT/usr/share/mate-panel/layouts/default.layout" ||
                die "$(tr_text 'MATE default panel has no notification area for network and sound icons' 'Numatytame MATE skydelyje nėra pranešimų srities tinklo ir garso piktogramoms')" ;;
        lxde)
            grep -Eq 'type[[:space:]]*=[[:space:]]*tray' "$ROOT/etc/xdg/lxpanel/LXDE/panels/panel" ||
                die "$(tr_text 'LXDE panel has no system tray for sound and network icons' 'LXDE skydelyje nėra dėklo garso ir tinklo piktogramoms')" ;;
    esac
}

prune_missing_desktop_entries() {
    local directory desktop_file command_line executable candidate found
    local -a words
    for directory in "$ROOT/usr/share/applications" "$ROOT/usr/local/share/applications"; do
        [[ -d "$directory" ]] || continue
        for desktop_file in "$directory"/*.desktop; do
            [[ -f "$desktop_file" ]] || continue
            command_line=$(sed -n 's/^TryExec=//p' "$desktop_file" | head -n 1)
            if [[ -z "$command_line" ]]; then
                command_line=$(sed -n 's/^Exec=//p' "$desktop_file" | head -n 1)
            fi
            # Directory entries and D-Bus-only launchers may not have Exec.
            [[ -n "$command_line" ]] || continue
            read -r -a words <<< "$command_line"
            ((${#words[@]})) || continue
            executable=${words[0]}
            executable=${executable#\"}; executable=${executable%\"}
            if [[ "$executable" == env || "$executable" == /usr/bin/env ]]; then
                words=("${words[@]:1}")
                while ((${#words[@]})) && [[ "${words[0]}" == -* || "${words[0]}" == *=* ]]; do
                    words=("${words[@]:1}")
                done
                ((${#words[@]})) || continue
                executable=${words[0]}
            fi
            found=no
            if [[ "$executable" == /* ]]; then
                [[ -x "$ROOT$executable" ]] && found=yes
            else
                for candidate in "$ROOT/usr/bin/$executable" "$ROOT/usr/sbin/$executable" \
                    "$ROOT/bin/$executable" "$ROOT/sbin/$executable"; do
                    [[ ! -x "$candidate" ]] || { found=yes; break; }
                done
            fi
            if [[ "$found" != yes ]]; then
                rm -f -- "$desktop_file"
                say "$(tr_text 'Removed menu entry with missing program: ' 'Pašalintas meniu įrašas, nes nėra programos: ')${desktop_file##*/} ($executable)"
            fi
        done
    done
}

verify_and_pack() {
    local dhcpcd_uid module_file
    [[ -z "$SQUASH_JOBS" || "$SQUASH_JOBS" =~ ^[1-9][0-9]*$ ]] ||
        die "$(tr_text 'SQUASH_JOBS must be a positive integer' 'SQUASH_JOBS turi būti teigiamas sveikasis skaičius')"
    dhcpcd_uid=$(awk -F: '$1 == "dhcpcd" { print $3; exit }' "$ROOT/etc/passwd")
    [[ "$BOOT_CHOICE" != lilo || ${IMAGE_FORMAT:-auto} != iso ]] ||
        die "$(tr_text 'LILO supports raw IMG output only, not ISO.' 'LILO palaiko tik raw IMG atvaizdą, ne ISO.')"
    configure_timezone
    ensure_dbus_launch_helper_mode
    if [[ -x "$ROOT/usr/libexec/dbus-daemon-launch-helper" ]]; then
        [[ -u "$ROOT/usr/libexec/dbus-daemon-launch-helper" ]] ||
            die "$(tr_text 'D-Bus activation helper is missing its setuid bit' 'D-Bus aktyvinimo pagalbininkui trūksta setuid bito')"
    fi
    # Remove installation artifacts left in rootfs profiles made by older versions.
    local legacy_file
    for legacy_file in usr/sbin/diy-install usr/sbin/diy-update-grub usr/libexec/diy-disk-root \
        usr/libexec/diy-disk-init var/log/diy-install.log; do
        [[ ! -e "$ROOT/$legacy_file" && ! -L "$ROOT/$legacy_file" ]] || rm -f -- "$ROOT/$legacy_file"
    done
    prune_missing_desktop_entries
    if [[ -d "$ROOT/usr/libexec/diy-installer-ui" && ! -L "$ROOT/usr/libexec/diy-installer-ui" ]]; then
        rm -rf -- "$ROOT/usr/libexec/diy-installer-ui"
    fi
    [[ ! -e "$ROOT/etc/diy-live" ]] || rm -f -- "$ROOT/etc/diy-live"
    if [[ "$DESKTOP_CHOICE" == mate ]]; then
        [[ -x "$ROOT/usr/bin/xterm" && -f "$ROOT/usr/share/applications/xterm.desktop" ]] ||
            die "$(tr_text 'XTerm terminal or desktop launcher is missing' 'Trūksta XTerm terminalo arba darbalaukio paleidyklės')"
        [[ -e "$ROOT/usr/lib/librsvg-2.so" || -e "$ROOT/usr/lib/librsvg-2.so.2" ]] ||
            die "$(tr_text 'MATE SVG support (librsvg) is missing' 'MATE trūksta SVG palaikymo (librsvg)')"
        for program in startmate startx xinit xauth mate-session mate-panel marco dbus-run-session; do
            [[ -x "$ROOT/usr/bin/$program" ]] || die "$(tr_text "MATE desktop is missing $program" "MATE darbalaukiui trūksta $program")"
        done
        [[ -x "$ROOT/usr/bin/pulseaudio" && -x "$ROOT/usr/bin/alsamixer" && \
           -x "$ROOT/usr/bin/diy-sound-mixer" && -f "$ROOT/usr/share/applications/diy-sound-mixer.desktop" ]] ||
            die "$(tr_text 'Desktop audio server or mixer is missing' 'Darbalaukyje trūksta garso serverio arba maišytuvo')"
        if [[ "$PKG_CAJA" != yes ]]; then
            [[ -x "$ROOT/usr/bin/pcmanfm" ]] ||
                die "$(tr_text 'MATE background fallback (PCManFM) is missing' 'Trūksta MATE fono pakaitalo (PCManFM)')"
            [[ -z ${wallpaper_default_path:-} || \
               -f "$ROOT/home/$USER_NAME/.config/pcmanfm/MATE/desktop-items-0.conf" ]] ||
                die "$(tr_text 'MATE background fallback (PCManFM) is missing or not configured' 'Trūksta MATE fono pakaitalo (PCManFM) arba jo konfigūracijos')"
        fi
        verify_desktop_audio_tray
        if [[ "$PKG_FIREFOX" == yes ]]; then
            [[ -x "$ROOT/usr/bin/bwrap" && -x "$ROOT/usr/bin/diy-firefox-sandbox" ]] || die "$(tr_text 'Firefox sandbox is incomplete (bubblewrap or launcher missing)' 'Firefox smėlio dėžė nebaigta (trūksta bubblewrap arba paleidiklio)')"
            for option in USER_NS SECCOMP SECCOMP_FILTER; do
                grep -qx "CONFIG_$option=y" "$ROOT/boot/kernel.config" || die "$(tr_text "Firefox sandbox requires CONFIG_$option=y" "Firefox smėlio dėžei reikia CONFIG_$option=y")"
            done
        fi
        [[ "$PKG_CAJA" != yes || -x "$ROOT/usr/bin/caja" ]] || die "$(tr_text 'MATE desktop is missing selected Caja' 'MATE darbalaukyje trūksta pasirinktos Caja')"
        [[ "$PKG_PLUMA" != yes || -x "$ROOT/usr/bin/pluma" ]] || die "$(tr_text 'MATE desktop is missing selected Pluma' 'MATE darbalaukyje trūksta pasirinktos Pluma')"
        [[ "$PKG_ENGRAMPA" != yes || -x "$ROOT/usr/bin/engrampa" ]] || die "$(tr_text 'MATE desktop is missing selected Engrampa' 'MATE darbalaukyje trūksta pasirinktos Engrampa')"
        [[ "$PKG_EOM" != yes || -x "$ROOT/usr/bin/eom" ]] || die "$(tr_text 'MATE desktop is missing selected Eye of MATE' 'MATE darbalaukyje trūksta pasirinktos Eye of MATE')"
        [[ -u "$ROOT/usr/libexec/Xorg.wrap" ]] || die "$(tr_text 'Xorg wrapper must have the SUID bit' 'Xorg wrapper turi turėti SUID bitą')"
        for option in DRM_BOCHS DRM_VIRTIO_GPU INPUT_EVDEV VT; do
            grep -qx "CONFIG_$option=y" "$ROOT/boot/kernel.config" || die "$(tr_text "MATE kernel requires CONFIG_$option=y" "MATE branduoliui reikia CONFIG_$option=y")"
        done
        grep -qx 'CONFIG_SND=y' "$ROOT/boot/kernel.config" ||
            die "$(tr_text 'MATE audio requires CONFIG_SND=y' 'MATE garsui reikia CONFIG_SND=y')"
        grep -Eq '^CONFIG_SND_PCM=(y|m)$' "$ROOT/boot/kernel.config" ||
            die "$(tr_text 'MATE audio requires CONFIG_SND_PCM=y or m' 'MATE garsui reikia CONFIG_SND_PCM=y arba m')"
        if grep -qx 'CONFIG_SND_PCM=m' "$ROOT/boot/kernel.config"; then
            find "$ROOT/lib/modules" -type f -name 'snd-pcm.ko*' -print -quit | grep -q . ||
                die "$(tr_text 'CONFIG_SND_PCM=m but snd_pcm kernel module is missing' 'CONFIG_SND_PCM=m, bet trūksta snd_pcm branduolio modulio')"
        fi
        for module_file in snd-hda-intel snd-hda-codec-realtek-lib snd-hda-codec-hdmi snd-usb-audio; do
            find "$ROOT/lib/modules" -type f -name "$module_file.ko*" -print -quit | grep -q . ||
                die "$(tr_text "MATE audio kernel module is missing: $module_file" "Trūksta MATE garso branduolio modulio: $module_file")"
        done
    fi
    if [[ "$DESKTOP_CHOICE" == fluxbox ]]; then
        for program in fluxbox startfluxbox startx xinit xauth xterm dbus-run-session alsamixer pcmanfm lxpanel; do
            [[ -x "$ROOT/usr/bin/$program" ]] || die "$(tr_text "Fluxbox desktop is missing $program" "Fluxbox darbalaukiui trūksta $program")"
        done
        [[ -x "$ROOT/usr/libexec/diy-fluxbox-session" && -f "$ROOT/home/$USER_NAME/.fluxbox/menu" && \
           -f "$ROOT/home/$USER_NAME/.fluxbox/init" && \
           -f "$ROOT/etc/xdg/lxpanel/default/panels/panel" && \
           -f "$ROOT/home/$USER_NAME/.config/pcmanfm/LXDE/desktop-items-0.conf" && \
           -u "$ROOT/usr/libexec/Xorg.wrap" ]] ||
            die "$(tr_text 'Fluxbox session files or Xorg permissions are incomplete' 'Fluxbox sesijos failai arba Xorg teisės nesukonfigūruotos')"
        for option in DRM_BOCHS DRM_VIRTIO_GPU INPUT_EVDEV VT; do
            grep -qx "CONFIG_$option=y" "$ROOT/boot/kernel.config" || die "$(tr_text "Fluxbox kernel requires CONFIG_$option=y" "Fluxbox branduoliui reikia CONFIG_$option=y")"
        done
    fi
    if [[ "$DESKTOP_CHOICE" == lxde ]]; then
        for program in startlxde startx xinit xauth lxsession lxpanel pcmanfm lxappearance lxrandr fluxbox dbus-run-session xterm; do
            [[ -x "$ROOT/usr/bin/$program" ]] || die "$(tr_text "LXDE desktop is missing $program" "LXDE darbalaukiui trūksta $program")"
        done
        [[ -x "$ROOT/usr/libexec/diy-lxde-session" && \
           -f "$ROOT/home/$USER_NAME/.config/lxsession/LXDE/desktop.conf" && \
           -f "$ROOT/home/$USER_NAME/.config/pcmanfm/LXDE/desktop-items-0.conf" && \
           -f "$ROOT/etc/xdg/lxpanel/LXDE/panels/panel" && -u "$ROOT/usr/libexec/Xorg.wrap" ]] ||
            die "$(tr_text 'LXDE session, panel configuration, or Xorg permissions are incomplete' 'LXDE sesija, skydelio konfigūracija arba Xorg teisės nesukonfigūruotos')"
        grep -qx 'terminal_manager/command=xterm' \
            "$ROOT/home/$USER_NAME/.config/lxsession/LXDE/desktop.conf" ||
            die "$(tr_text 'LXDE default terminal is not configured as xterm' 'LXDE numatytuoju terminalu nesukonfigūruotas xterm')"
        if [[ "$NETWORK" == yes ]]; then
            grep -qx 'network_gui/command=no' \
                "$ROOT/home/$USER_NAME/.config/lxsession/LXDE/desktop.conf" ||
                die "$(tr_text 'LXDE network applet is not configured' 'LXDE tinklo piktograma nesukonfigūruota')"
            grep -qx 'OnlyShowIn=LXDE;' "$ROOT/etc/xdg/autostart/nm-applet.desktop" ||
                die "$(tr_text 'LXDE NetworkManager autostart is missing' 'Trūksta LXDE NetworkManager automatinio paleidimo')"
        fi
        [[ -x "$ROOT/usr/bin/pulseaudio" && -x "$ROOT/usr/bin/alsamixer" && \
           -x "$ROOT/usr/bin/diy-sound-mixer" ]] ||
            die "$(tr_text 'LXDE audio server or mixer is missing' 'LXDE darbalaukyje trūksta garso serverio arba maišytuvo')"
        verify_desktop_audio_tray
        for option in DRM_BOCHS DRM_VIRTIO_GPU INPUT_EVDEV VT; do
            grep -qx "CONFIG_$option=y" "$ROOT/boot/kernel.config" || die "$(tr_text "LXDE kernel requires CONFIG_$option=y" "LXDE branduoliui reikia CONFIG_$option=y")"
        done
    fi
    if [[ "$PKG_FIREFOX" == yes ]]; then
        [[ -x "$ROOT/usr/bin/bwrap" && -x "$ROOT/usr/bin/diy-firefox-sandbox" && \
           -x "$ROOT/usr/bin/firefox" ]] || die "$(tr_text 'Firefox sandbox is incomplete (Firefox or bubblewrap missing)' 'Firefox smėlio dėžė nebaigta (trūksta Firefox arba bubblewrap)')"
        for option in USER_NS SECCOMP SECCOMP_FILTER; do
            grep -qx "CONFIG_$option=y" "$ROOT/boot/kernel.config" || die "$(tr_text "Firefox sandbox requires CONFIG_$option=y" "Firefox smėlio dėžei reikia CONFIG_$option=y")"
        done
    fi
    [[ "$DESKTOP_CHOICE" == none || "$NETWORK" != yes ]] || verify_desktop_network
    case "$PACKAGE_MANAGER" in
        apt) [[ -x "$ROOT/usr/bin/apt" && -x "$ROOT/usr/bin/dpkg" && -x "$ROOT/usr/bin/gpgv" ]] || die "$(tr_text 'Missing APT / dpkg / gpgv' 'Trūksta APT / dpkg / gpgv')" ;;
        pacman) [[ -x "$ROOT/usr/bin/pacman" && -x "$ROOT/usr/bin/gpg" && -x "$ROOT/usr/bin/bash" ]] || die "$(tr_text 'Missing pacman / gpg / Bash' 'Trūksta pacman / gpg / Bash')" ;;
    esac
    if [[ "$PKG_OPENSSH" == yes ]]; then
        [[ -x "$ROOT/usr/bin/ssh" && -x "$ROOT/usr/bin/ssh-keygen" && \
           -x "$ROOT/usr/sbin/sshd" && -x "$ROOT/usr/libexec/diy-sshd-start" && \
           -x "$ROOT/usr/bin/diy-ssh-info" && -f "$ROOT/etc/ssh/sshd_config" && \
           -d "$ROOT/var/empty" ]] ||
            die "$(tr_text 'OpenSSH client/server files or host-key startup helper are missing' 'Trūksta OpenSSH kliento/serverio failų arba host raktų paleidimo pagalbininko')"
        case "$INIT_CHOICE" in
            systemd) [[ -f "$ROOT/etc/systemd/system/sshd.service" && \
                       -L "$ROOT/etc/systemd/system/multi-user.target.wants/sshd.service" ]] ||
                    die "$(tr_text 'OpenSSH systemd service is not enabled' 'OpenSSH systemd tarnyba neįjungta')" ;;
            openrc) [[ -x "$ROOT/etc/init.d/sshd" && -L "$ROOT/etc/runlevels/default/sshd" ]] ||
                    die "$(tr_text 'OpenSSH OpenRC service is not enabled' 'OpenSSH OpenRC tarnyba neįjungta')" ;;
            busybox|sysvinit) grep -Fq '/usr/libexec/diy-sshd-start' "$ROOT/etc/diy/boot" ||
                    die "$(tr_text 'OpenSSH boot hook is missing' 'Trūksta OpenSSH paleidimo kablio')" ;;
            runit) [[ -x "$ROOT/etc/service/sshd/run" ]] ||
                    die "$(tr_text 'OpenSSH runit service is not enabled' 'OpenSSH runit tarnyba neįjungta')" ;;
            dinit) [[ -f "$ROOT/etc/dinit.d/sshd" ]] && grep -Fq 'depends-on: sshd' "$ROOT/etc/dinit.d/boot" ||
                    die "$(tr_text 'OpenSSH Dinit service is not enabled' 'OpenSSH Dinit tarnyba neįjungta')" ;;
            s6) [[ -x "$ROOT/etc/s6-rc/source/sshd/run" && \
                  -f "$ROOT/etc/s6-rc/source/default/contents.d/sshd" ]] ||
                    die "$(tr_text 'OpenSSH s6 service is not enabled' 'OpenSSH s6 tarnyba neįjungta')" ;;
        esac
    fi
    [[ "$SHELL_CHOICE" != zsh && "$SHELL_CHOICE" != fish ]] || [[ -x "$ROOT/usr/bin/$SHELL_CHOICE" ]] || die "$(tr_text "Missing $SHELL_CHOICE shell" "Trūksta $SHELL_CHOICE apvalkalo")"
    [[ -x "$ROOT/usr/bin/login" ]] || die "$(tr_text 'Missing login program: run --repair-login for this system directory' 'Trūksta login programos: paleisk --repair-login šios sistemos katalogui')"
    if [[ "$PKG_NGINX" == yes ]]; then
        [[ -x "$ROOT/usr/sbin/nginx" && -f "$ROOT/etc/nginx/nginx.conf" ]] ||
            die "$(tr_text 'Nginx binary or configuration is missing' 'Trūksta Nginx programos arba konfigūracijos')"
        case "$INIT_CHOICE" in
            openrc) [[ -x "$ROOT/etc/init.d/nginx" && -L "$ROOT/etc/runlevels/default/nginx" ]] || die "$(tr_text 'Nginx OpenRC service is not enabled' 'Nginx OpenRC tarnyba neįjungta')" ;;
            systemd) [[ -f "$ROOT/etc/systemd/system/nginx.service" && -L "$ROOT/etc/systemd/system/multi-user.target.wants/nginx.service" ]] || die "$(tr_text 'Nginx systemd service is not enabled' 'Nginx systemd tarnyba neįjungta')" ;;
            *) grep -qFx '/usr/libexec/diy-web-boot' "$ROOT/etc/diy/boot" || die "$(tr_text 'Nginx boot hook is missing' 'Trūksta Nginx paleidimo kablio')" ;;
        esac
    fi
    if [[ "$PKG_PHP" == yes ]]; then
        [[ -x "$ROOT/usr/bin/php" && -x "$ROOT/usr/sbin/php-fpm" && \
           -f "$ROOT/etc/php.ini" && -f "$ROOT/etc/php-fpm.conf" && \
           -f "$ROOT/etc/php-fpm.d/www.conf" ]] ||
            die "$(tr_text 'PHP CLI / PHP-FPM binaries or configuration are missing' 'Trūksta PHP CLI / PHP-FPM programų arba konfigūracijos')"
    fi
    local program file option
    for program in nano wget ping neofetch vim fdisk; do
        option="PKG_${program^^}"
        if [[ ${!option} == yes ]]; then
            [[ -x "$ROOT/usr/bin/$program" || -x "$ROOT/usr/sbin/$program" ]] || die "$(tr_text "Missing selected program: $program" "Trūksta pasirinktos programos: $program")"
        fi
    done
    # Paprasta, bet prasminga patikra prieš skelbiant, kad rootfs paruoštas.
    for program in "$ROOT/usr/bin/bash" "$ROOT/usr/libexec/diy-prelogin" "$ROOT/usr/bin/sh" "$ROOT/usr/lib/${ELF_LOADER##*/}" "$ROOT/init" "$ROOT/boot/bzImage"; do
        [[ -e "$program" || -L "$program" ]] || die "$(tr_text "Missing $program" "Trūksta $program")"
    done
    case "$INIT_CHOICE" in
        sysvinit) [[ -x "$ROOT/usr/sbin/init" ]] || die "$(tr_text 'Missing SysVinit' 'Trūksta SysVinit')" ;;
        runit) [[ -x "$ROOT/usr/sbin/runit" && -x "$ROOT/usr/bin/runsvdir" ]] || die "$(tr_text 'Missing runit' 'Trūksta runit')" ;;
        dinit) [[ -x "$ROOT/usr/bin/dinit" && -x "$ROOT/usr/bin/dinitctl" && -f "$ROOT/etc/dinit.d/boot" && -f "$ROOT/etc/dinit/shutdown-hook" ]] || die "$(tr_text 'Dinit binaries or boot services are missing' 'Trūksta Dinit programų arba paleidimo paslaugų')" ;;
        s6)
            for program in s6-svscan s6-rc-compile s6-rc-init s6-linux-init-maker s6-linux-init s6-linux-init-shutdownd; do
                [[ -x "$ROOT/usr/bin/$program" ]] || die "$(tr_text "Missing s6 stack component: $program" "Trūksta s6 komponento: $program")"
            done
            [[ -x "$ROOT/usr/libexec/diy-s6-init" && -x "$ROOT/etc/s6-linux-init/skel/rc.init" && \
               -f "$ROOT/etc/s6-rc/source/default/contents.d/boot-setup" ]] ||
                die "$(tr_text 's6 service database or Linux init setup is incomplete' 's6 paslaugų duomenų bazė arba Linux init nustatymai neužbaigti')"
            ;;
        openrc) [[ -x "$ROOT/usr/sbin/openrc-init" ]] || die "$(tr_text 'Missing openrc-init' 'Trūksta openrc-init')" ;;
        systemd) [[ -x "$ROOT/usr/lib/systemd/systemd" ]] || die "$(tr_text 'Missing systemd' 'Trūksta systemd')" ;;
        busybox) [[ -x "$ROOT/usr/bin/busybox" || -x "$ROOT/bin/busybox" ]] || die "$(tr_text 'Missing BusyBox init' 'Trūksta BusyBox init')" ;;
    esac
    if [[ "$INIT_CHOICE" == openrc && "$TOOLS_CHOICE" == busybox ]]; then
        [[ -x "$ROOT/usr/bin/getty" && -x "$ROOT/usr/bin/login" && \
           -x "$ROOT/etc/init.d/getty.tty1" && -x "$ROOT/etc/init.d/getty.ttyS0" && \
           -L "$ROOT/etc/runlevels/default/getty.tty1" && \
           -L "$ROOT/etc/runlevels/default/getty.ttyS0" ]] ||
            die "$(tr_text 'OpenRC BusyBox console getty or login service is incomplete' 'Trūksta OpenRC BusyBox konsolės getty arba login tarnybos')"
    fi
    if ! needs_busybox; then
        [[ ! -e "$ROOT/usr/bin/busybox" ]] || die "$(tr_text 'Unselected BusyBox must not remain in rootfs' 'Nepasirinktas BusyBox neturi likti rootfs')"
    fi
    if [[ "$WITH_GCC" == no && ${REPACKING:-no} != yes ]]; then
        # Pašalinami tik šiame rootfs įdiegti kūrimo failai, ne šeimininko failai.
        find "$ROOT/usr/include" -type f -delete
        # Glibc *_nonshared.a reikia linker skriptams ir išsaugotam SDK.
        find "$ROOT/usr/lib" -name '*.a' ! -name '*_nonshared.a' -type f -delete
    fi
    # strip taikomas tik tikriems ELF failams. Scenarijų ir konfigūracijų neliečia.
    while IFS= read -r -d '' file; do
        # GRUB jau apdorojo firmware ir ELF modulius savo taisyklėmis.
        # Bendras strip gali pakeisti jų vidinį išdėstymą / metaduomenis.
        case "$file" in
            "$ROOT/usr/lib/firmware/"*|"$ROOT/usr/lib/grub/"*|"$ROOT/usr/lib/modules/"*) continue ;;
        esac
        # Firmware payloads can be ELF containers with PT_LOAD segments but
        # no section table (for example Qualcomm .mbn files). GNU strip
        # rejects those, although readelf -h accepts them. Only strip ELF
        # files that actually have sections to process.
        if [[ -w "$file" ]] && readelf -h "$file" 2>/dev/null | grep -Eq 'Number of section headers:[[:space:]]*[1-9][0-9]*'; then
            strip_elf "$file"
        fi
    done < <(find "$ROOT/usr/bin" "$ROOT/usr/sbin" "$ROOT/usr/lib" -type f -print0)
    say "$(tr_text 'Packaging (fakeroot: root access is not needed)' 'Pakavimas (fakeroot: nereikia root teisių)')"
    build_live_initramfs
    FAKEROOTDONTTRYCHOWN=1 fakeroot bash -Eeuo pipefail -c '
        root=$1; images=$2; package_manager=$3; user_name=$4; early=$5; jobs=$6; dhcpcd_uid=$7; keep_tar=$8
        cd "$root"
        # Devtmpfs prisijungs /init metu, bet ankstyvai kernel console reikia mazgo.
        [[ ! -e dev/console ]] || unlink dev/console
        [[ ! -e dev/null ]] || unlink dev/null
        mknod -m 0600 dev/console c 5 1
        mknod -m 0666 dev/null c 1 3
        chown -hR 0:0 .
        # The MATE clock applet asks this privileged helper to adjust time.
        # Make the privilege explicit in the image metadata; otherwise it
        # starts but reports that its setuid helper has incorrect permissions.
        if [[ -x usr/libexec/msd-datetime-mechanism ]]; then
            chown 0:0 usr/libexec/msd-datetime-mechanism
            chmod 4755 usr/libexec/msd-datetime-mechanism
            [[ $(stat -c %u usr/libexec/msd-datetime-mechanism) == 0 && \
               -u usr/libexec/msd-datetime-mechanism ]] || {
                echo "MATE datetime helper must be root-owned and setuid" >&2
                exit 1
            }
        fi
        if [[ -x usr/libexec/dbus-daemon-launch-helper ]]; then
            messagebus_gid=$(grep "^messagebus:" etc/group | cut -d: -f3)
            [[ "$messagebus_gid" =~ ^[0-9]+$ ]] || { echo "Missing messagebus group for D-Bus launch helper" >&2; exit 1; }
            chown 0:"$messagebus_gid" usr/libexec/dbus-daemon-launch-helper
            chmod 4750 usr/libexec/dbus-daemon-launch-helper
        fi
        if [[ "$dhcpcd_uid" =~ ^[0-9]+$ && -d var/lib/dhcpcd ]]; then
            chown "$dhcpcd_uid:$dhcpcd_uid" var/lib/dhcpcd
        fi
        if [[ -n "$user_name" && -d "home/$user_name" ]]; then
            chown -hR 1000:1000 "home/$user_name"
        fi
        if [[ "$package_manager" == apt ]]; then
            apt_uid=$(grep "^_apt:" etc/passwd | cut -d: -f3)
            [[ "$apt_uid" =~ ^[0-9]+$ ]] || { echo "Missing valid _apt account for APT permissions" >&2; exit 1; }
            chown 0:0 var/lib/dpkg var/lib/dpkg/info var/lib/dpkg/updates var/lib/dpkg/triggers \
                var/lib/apt var/lib/apt/lists var/cache/apt var/cache/apt/archives
            chown "$apt_uid:65534" var/cache/apt/archives/partial var/lib/apt/lists/partial
            chmod 0755 var/lib/dpkg var/lib/dpkg/info var/lib/dpkg/updates var/lib/dpkg/triggers \
                var/lib/apt var/lib/apt/lists var/cache/apt var/cache/apt/archives
            chmod 0700 var/cache/apt/archives/partial var/lib/apt/lists/partial
            chmod 0644 var/lib/dpkg/status var/lib/dpkg/available var/lib/dpkg/arch \
                etc/apt/sources.list etc/apt/apt.conf.d/00diy
        elif [[ "$package_manager" == pacman ]]; then
            chown 0:0 var/lib/pacman var/lib/pacman/local var/cache/pacman var/cache/pacman/pkg
            chmod 0755 var/lib/pacman var/lib/pacman/local var/cache/pacman var/cache/pacman/pkg
            chmod 0700 etc/pacman.d/gnupg
        fi
        if [[ "$keep_tar" == yes ]]; then
            tar --numeric-owner -czf "$images/rootfs.tar.gz" .
        else
            rm -f "$images/rootfs.tar.gz"
        fi
        rm -f "$images/rootfs.squashfs.new" "$images/initramfs.cpio.zst.new"
        mksquashfs . "$images/rootfs.squashfs.new" -comp zstd -Xcompression-level 8 \
            -noappend -processors "$jobs" -no-progress >/dev/null
        mv -f "$images/rootfs.squashfs.new" "$images/rootfs.squashfs"
        mkdir -p "$early"/{dev,proc,sys,run,newroot,usr/bin,usr/sbin}
        mknod -m 0600 "$early/dev/console" c 5 1
        mknod -m 0666 "$early/dev/null" c 1 3
        mknod -m 0666 "$early/dev/tty" c 5 0
        (cd "$early"; find . -print0 | cpio --null -o --format=newc) |
            zstd -T0 -9 -q -o "$images/initramfs.cpio.zst.new"
        mv -f "$images/initramfs.cpio.zst.new" "$images/initramfs.cpio.zst"
    ' _ "$ROOT" "$IMAGES" "$PACKAGE_MANAGER" "$USER_NAME" "$BUILD/live-initramfs" "${SQUASH_JOBS:-$JOBS}" "$dhcpcd_uid" "$KEEP_ROOTFS_TAR"
    pack_boot_image
    if [[ ${IMAGE_FORMAT:-auto} == img || ( ${IMAGE_FORMAT:-auto} == auto && -f "$IMAGES/diy-linux.img" ) ]]; then
        case "$BOOT_CHOICE" in
            refind|efistub|systemd-boot) cp "$IMAGES/diy-linux-esp.img" "$IMAGES/diy-linux.img" ;;
            bios|uefi|syslinux|limine) cp "$IMAGES/$SYSTEM_NAME.iso" "$IMAGES/diy-linux.img" ;;
        esac
    fi
    (cd "$IMAGES"; sha256sum bzImage rootfs.squashfs initramfs.cpio.zst > SHA256SUMS
     [[ ! -f rootfs.tar.gz ]] || sha256sum rootfs.tar.gz >> SHA256SUMS
     for image in "$SYSTEM_NAME.iso" diy-linux.img diy-linux-esp.img; do
         [[ ! -f "$image" ]] || sha256sum "$image" >> SHA256SUMS
     done)
    say "$(tr_text "Images saved: $IMAGES" "Atvaizdai išsaugoti: $IMAGES")"
    printf "$(tr_text 'Build log: %s/build.log\n' 'Kompiliavimo žurnalas: %s/build.log\n')" "$BASE"
}

# Print only: starting a VM remains an explicit user action. Keep Bash quoting
# correct for paths containing spaces or shell metacharacters.
print_qemu_command() {
    local arch=${TARGET_ARCH:-x86_64} boot=${BOOT_CHOICE:-none} format=${IMAGE_FORMAT:-auto}
    local iso_image="$IMAGES/${SYSTEM_NAME:-diy-linux}.iso"
    local media='' kind='' candidate firmware='' code='' variables='' vars_copy='' memory=2048
    local qemu_cpus=${QEMU_CPUS:-1}
    local -a command=() candidates=() pairs=()
    case "$arch" in
        x86_64) command=(qemu-system-x86_64) ;;
        i686) command=(qemu-system-i386) ;;
        aarch64) command=(qemu-system-aarch64 -machine virt,accel=kvm:tcg -cpu cortex-a72) ;;
        *) return 0 ;;
    esac
    [[ "$arch" == aarch64 ]] || command+=(-machine accel=kvm:tcg)
    # The read-only SquashFS root is mounted directly; only the writable overlay
    # consumes guest RAM during boot.
    [[ ${DESKTOP_CHOICE:-none} != mate && ${DESKTOP_CHOICE:-none} != lxde && ${DESKTOP_CHOICE:-none} != fluxbox ]] || memory=6144
    [[ "$qemu_cpus" =~ ^[1-9][0-9]*$ ]] && (( qemu_cpus <= 64 )) || qemu_cpus=1
    command+=(-m "$memory" -smp "$qemu_cpus")
    if [[ ${DESKTOP_CHOICE:-none} == mate || ${DESKTOP_CHOICE:-none} == lxde || ${DESKTOP_CHOICE:-none} == fluxbox ]]; then command+=(-vga std)
    else command+=(-nographic); fi
    local qemu_boot_log="$IMAGES/qemu-boot.log"
    # Route the emulated serial console to a file. The bootloader and kernel
    # already send their console output to SERIAL_TTY, so this captures both.
    command+=(-serial "file:$qemu_boot_log")
    [[ ${DESKTOP_CHOICE:-none} != none ]] || command+=(-monitor stdio)
    local qemu_audio=no
    if [[ ${DESKTOP_CHOICE:-none} == mate || ${DESKTOP_CHOICE:-none} == lxde || ${DESKTOP_CHOICE:-none} == fluxbox ]]; then
        # The PulseAudio backend makes QEMU abort when the host has no
        # PulseAudio / PipeWire-Pulse server. Add virtual HDA only if the
        # backend is reachable now; booting the ISO must not depend on audio.
        if command -v pactl >/dev/null 2>&1 && pactl info >/dev/null 2>&1; then
            qemu_audio=yes
            command+=(-audiodev pa,id=diy-audio0 -device ich9-intel-hda \
                -device hda-duplex,audiodev=diy-audio0)
        fi
    fi
    if [[ ${PKG_OPENSSH:-no} == yes ]]; then
        # QEMU user networking hides the guest address from the host by
        # default. Forward a loopback-only host port so SSH works safely.
        command+=(-nic 'user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22')
    else
        command+=(-nic user,model=virtio-net-pci)
    fi
    if [[ "$format" != img && "$boot" != none && "$boot" != lilo && -s "$iso_image" ]]; then
        media="$iso_image"; kind=iso
    elif [[ "$boot" != none && -s "$IMAGES/diy-linux.img" ]]; then
        media="$IMAGES/diy-linux.img"; kind=disk
        # These IMG outputs are byte copies of the bootable ISO.
        case "$boot" in bios|uefi|syslinux|limine) kind=iso ;; esac
    fi
    if [[ -z "$media" ]]; then
        [[ -s "$IMAGES/bzImage" && -s "$IMAGES/initramfs.cpio.zst" ]] || return 0
        [[ -s "$IMAGES/rootfs.squashfs" ]] || return 0
        command+=(-kernel "$IMAGES/bzImage" -initrd "$IMAGES/initramfs.cpio.zst"
            -append "console=${SERIAL_TTY:-ttyS0},115200"
            -drive "file=$IMAGES/rootfs.squashfs,format=raw,if=virtio,readonly=on")
    else
        case "$boot" in
            uefi|refind|efistub|systemd-boot)
                case "$arch" in
                    x86_64)
                        candidates=(/usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF.fd /usr/share/edk2/ovmf/OVMF.fd)
                        pairs=(/usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd) ;;
                    i686)
                        candidates=(/usr/share/OVMF/OVMF32.fd /usr/share/edk2/ia32/OVMF.fd)
                        pairs=(/usr/share/edk2/ovmf-ia32/OVMF_CODE.fd) ;;
                    aarch64)
                        candidates=(/usr/share/qemu-efi-aarch64/QEMU_EFI.fd)
                        pairs=(/usr/share/AAVMF/AAVMF_CODE.fd) ;;
                esac
                for candidate in "${candidates[@]}"; do
                    if [[ -r "$candidate" ]]; then firmware=$candidate; break; fi
                done
                if [[ -n "$firmware" ]]; then command+=(-bios "$firmware")
                else
                    for candidate in "${pairs[@]}"; do
                        variables=${candidate/CODE/VARS}
                        if [[ -r "$candidate" && -r "$variables" ]]; then code=$candidate; break; fi
                    done
                    if [[ -n "$code" ]]; then
                        vars_copy="$IMAGES/qemu-${variables##*/}"
                        command+=(-drive "if=pflash,format=raw,readonly=on,file=${code//,/,,}"
                            -drive "if=pflash,format=raw,file=${vars_copy//,/,,}")
                    else
                        firmware=${candidates[0]}
                        command+=(-bios "$firmware")
                        printf '%s\n' "$(tr_text "UEFI firmware is missing. Install OVMF / AAVMF for $arch, or adjust the -bios path below." "Trūksta UEFI firmware. Įdiek $arch skirtą OVMF / AAVMF arba pakeisk žemiau esantį -bios kelią.")"
                    fi
                fi ;;
        esac
        if [[ "$kind" == iso && "$arch" == aarch64 ]]; then
            command+=(-drive "if=none,id=cdrom,media=cdrom,format=raw,readonly=on,file=${media//,/,,}"
                -device virtio-scsi-pci,id=scsi -device scsi-cd,drive=cdrom -boot d)
        elif [[ "$kind" == iso ]]; then command+=(-boot d -cdrom "$media")
        elif [[ "$arch" == aarch64 ]]; then
            command+=(-drive "if=none,id=bootdisk,format=raw,file=${media//,/,,}"
                -device virtio-blk-pci,drive=bootdisk)
        elif [[ "$boot" == lilo ]]; then
            command+=(-boot c -drive "format=raw,file=${media//,/,,}")
        else command+=(-drive "format=raw,file=${media//,/,,}"); fi
    fi
    printf '\n%s\n' "$(tr_text 'Test with QEMU (copy and run):' 'Bandymas su QEMU (nukopijuok ir paleisk):')"
    if [[ -n "$vars_copy" ]]; then
        printf 'test -e %q || cp -- %q %q\n' "$vars_copy" "$variables" "$vars_copy"
    fi
    printf '%q' "${command[0]}"; printf ' %q' "${command[@]:1}"; printf '\n'
    if [[ ${PKG_OPENSSH:-no} == yes ]]; then
        printf '%s\n' "$(tr_text 'SSH from the host to this QEMU guest: ssh -p 2222 USER@127.0.0.1' 'SSH iš pagrindinio kompiuterio į QEMU sistemą: ssh -p 2222 USER@127.0.0.1' | sed "s/USER/${USER_NAME}/g")"
    fi
    printf '%s\n' "$(tr_text "Boot log: $qemu_boot_log (replaced on each run)" "Įkrovos žurnalas: $qemu_boot_log (paleidus iš naujo perrašomas)")"
    if [[ ${DESKTOP_CHOICE:-none} == mate || ${DESKTOP_CHOICE:-none} == lxde || ${DESKTOP_CHOICE:-none} == fluxbox ]] && [[ $qemu_audio != yes ]]; then
        printf '%s\n' "$(tr_text 'Host PulseAudio / PipeWire-Pulse is unavailable; QEMU sound was omitted so startup can continue.' 'Šeimininko PulseAudio / PipeWire-Pulse nepasiekiamas, todėl QEMU garsas praleistas, kad sistema galėtų pasileisti.')"
    fi
    if [[ ${DESKTOP_CHOICE:-none} != none ]]; then
        if [[ ${DESKTOP_AUTOSTART:-no} == yes ]]; then
            printf '%s\n' "$(tr_text 'After logging in in the QEMU window, the desktop starts automatically.' 'Prisijungus QEMU lange darbalaukis pasileis automatiškai.')"
        else
            case ${DESKTOP_CHOICE:-none} in
                mate) printf '%s\n' "$(tr_text 'After logging in in the QEMU window, run: startmate' 'Prisijungęs QEMU lange paleisk: startmate')" ;;
                fluxbox) printf '%s\n' "$(tr_text 'After logging in in the QEMU window, run: startfluxbox' 'Prisijungęs QEMU lange paleisk: startfluxbox')" ;;
                lxde) printf '%s\n' "$(tr_text 'After logging in in the QEMU window, run: startlxde' 'Prisijungęs QEMU lange paleisk: startlxde')" ;;
            esac
        fi
    fi
}

self_test() {
    local arch shell tools init manager boot count=0 desktop_packages lxde_packages_list name low high
    local desktop profile_shell profile_init profile_boot profile_manager profile_gcc profile_network
    for arch in x86_64 i686 aarch64; do
    TARGET_ARCH=$arch; architecture
    for manager in none apt pacman; do
        for shell in busybox bash dash zsh fish; do
            for tools in busybox gnu; do
                for init in busybox openrc sysvinit runit dinit s6 systemd; do
                    for boot in bios uefi syslinux lilo refind efistub limine systemd-boot none; do
                    (TARGET_ARCH=$arch BOOT_CHOICE=$boot PACKAGE_MANAGER=$manager SHELL_CHOICE=$shell TOOLS_CHOICE=$tools INIT_CHOICE=$init
                     if ! boot_compatible "$boot" || [[ ( "$init" =~ ^(systemd|sysvinit|runit|dinit|s6)$ && "$tools" == busybox ) ||
                           ( "$manager" != none && "$tools" != gnu ) ||
                           ( "$shell" == fish && "$tools" != gnu ) ]]; then
                         if validate; then exit 1; fi
                     else validate; fi)
                    count=$((count+1))
                    done
                done
            done
        done
    done
    done
    TARGET_ARCH=x86_64; architecture
    PACKAGE_MANAGER=none
    (PACKAGE_MANAGER=invalid; if validate; then exit 1; fi)
    (TARGET_ARCH=x86_64 DESKTOP_CHOICE=mate TOOLS_CHOICE=gnu INIT_CHOICE=openrc PKG_GEANY=yes PKG_FIREFOX=yes; validate)
    (DESKTOP_CHOICE=xfce; if validate; then exit 1; fi)
    # Exercise GNU desktop profiles across every supported shell, init,
    # bootloader, package manager, GCC and networking combination.
    for desktop in mate lxde; do
        for profile_shell in busybox bash dash zsh fish; do
            for profile_init in busybox openrc sysvinit runit dinit s6 systemd; do
                for profile_boot in bios uefi syslinux lilo refind efistub limine systemd-boot none; do
                    for profile_manager in none apt pacman; do
                        for profile_gcc in yes no; do
                            for profile_network in yes no; do
                                (TARGET_ARCH=x86_64 DESKTOP_CHOICE=$desktop TOOLS_CHOICE=gnu \
                                    SHELL_CHOICE=$profile_shell INIT_CHOICE=$profile_init \
                                    BOOT_CHOICE=$profile_boot PACKAGE_MANAGER=$profile_manager \
                                    WITH_GCC=$profile_gcc NETWORK=$profile_network; validate) ||
                                    die "Invalid desktop profile: $desktop / $profile_shell / $profile_init / $profile_boot / $profile_manager / GCC=$profile_gcc / NETWORK=$profile_network"
                                count=$((count+1))
                            done
                        done
                    done
                done
            done
        done
    done
    # MATE and LXDE are supported with BusyBox init. Console-only
    # BusyBox utilities also support OpenRC through BusyBox getty and login.
    # Keep the desktop limitations explicit: no Fish or external package manager.
    for desktop in mate lxde; do
        for profile_shell in busybox bash dash zsh; do
            for profile_boot in bios uefi syslinux lilo refind efistub limine systemd-boot none; do
                for profile_gcc in yes no; do
                    for profile_network in yes no; do
                        (TARGET_ARCH=x86_64 DESKTOP_CHOICE=$desktop TOOLS_CHOICE=busybox \
                            SHELL_CHOICE=$profile_shell INIT_CHOICE=busybox BOOT_CHOICE=$profile_boot \
                            PACKAGE_MANAGER=none WITH_GCC=$profile_gcc NETWORK=$profile_network; validate) ||
                            die "Invalid BusyBox desktop profile: $desktop / $profile_shell / $profile_boot / GCC=$profile_gcc / NETWORK=$profile_network"
                        count=$((count+1))
                    done
                done
            done
        done
    done
    # These are honest current recipe limits, not arbitrary init/boot locks.
    (TARGET_ARCH=aarch64 DESKTOP_CHOICE=mate TOOLS_CHOICE=gnu; if validate; then exit 1; fi)
    (TARGET_ARCH=x86_64 DESKTOP_CHOICE=mate TOOLS_CHOICE=busybox INIT_CHOICE=openrc; if validate; then exit 1; fi)
    (TARGET_ARCH=x86_64 DESKTOP_CHOICE=mate TOOLS_CHOICE=busybox INIT_CHOICE=busybox SHELL_CHOICE=fish; if validate; then exit 1; fi)
    [[ "$(desktop_base_packages)" == *libsndfile* && "$(desktop_base_packages)" == *pulseaudio* && "$(desktop_base_packages)" == *sound-mixer* ]] || die 'Desktop package plan omitted sound support or PulseAudio dependency'
    desktop_packages=$(NETWORK=yes desktop_base_packages | tr '\n' ' ')
    for name in wireless-regdb wpa_supplicant NetworkManager network-manager-applet; do
        [[ " $desktop_packages " == *" $name "* ]] || die "Desktop network package plan omitted $name"
    done
    [[ "$(PKG_FIREFOX=yes desktop_base_packages)" == *bubblewrap* ]] || die 'Firefox profile omitted bubblewrap from the package plan'
    [[ "$(PKG_FIREFOX=no desktop_base_packages)" != *bubblewrap* ]] || die 'bubblewrap should not be built when Firefox is disabled'
    eom_packages=$(PKG_EOM=yes mate_packages | tr '\n' ' ')
    [[ " $eom_packages " == *' librsvg '* && " $eom_packages " == *' libexif '* && \
       " $eom_packages " == *' gobject-introspection '* && " $eom_packages " == *' libpeas '* && \
       " $eom_packages " == *' eom '* ]] || die 'Eye of MATE profile omitted SVG or introspection dependencies'
    [[ "$(PKG_EOM=no mate_packages)" == *librsvg* ]] || die 'MATE package plan omitted its SVG icon loader'
    (DESKTOP_CHOICE=none PKG_GEANY=yes; if validate; then exit 1; fi)
    (SYSTEM_NAME=GRG; validate; [[ "$SYSTEM_NAME" == grg ]])
    (SYSTEM_NAME=grg-; if validate; then exit 1; fi)
    (SYSTEM_NAME=grg_name; if validate; then exit 1; fi)
    (JOBS=0; if validate; then exit 1; fi)
    (SQUASH_JOBS=0; if validate; then exit 1; fi)
    (ROOT_PASSWORD_HASH='bad'; if validate; then exit 1; fi)
    (SHELL_CHOICE=bash TOOLS_CHOICE=gnu INIT_CHOICE=openrc; if needs_busybox; then exit 1; fi)
    (SHELL_CHOICE=dash TOOLS_CHOICE=gnu INIT_CHOICE=busybox; needs_busybox)
    (PACKAGE_MANAGER=none SHELL_CHOICE=bash DESKTOP_CHOICE=mate; host_needs_cmake)
    (PACKAGE_MANAGER=none SHELL_CHOICE=bash DESKTOP_CHOICE=mate; host_needs_cmake)
    (PACKAGE_MANAGER=none SHELL_CHOICE=bash DESKTOP_CHOICE=none; if host_needs_cmake; then exit 1; fi)
    for name in desktop:mate desktop:lxde shell:dash tools:gnu init:systemd boot:refind extra:WITH_GCC extra:NETWORK; do
        read -r low high <<< "$(estimate_iso_tenths "$name")"
        (( high > 0 && low <= high )) || die "Invalid ISO size estimate for $name"
    done
    (TOOLS_CHOICE=busybox INIT_CHOICE=busybox SHELL_CHOICE=busybox
        [[ "$(estimate_iso_tenths init:busybox)" == '0 0' && "$(estimate_iso_tenths shell:busybox)" == '0 0' ]]) ||
        die 'BusyBox ISO size estimate double-counted shared binary'
    lxde_packages_list=$(lxde_packages | tr '\n' ' ')
    for name in dbus-glib duktape libfm-extra menu-cache libfm keybinder lxmenu-data lxde-icon-theme lxpanel lxsession pcmanfm lxappearance lxrandr lxde-common fluxbox; do
        [[ " $lxde_packages_list " == *" $name "* ]] || die "LXDE package plan omitted $name"
    done
    for name in linux-pam elogind polkit mate-polkit upower; do
        [[ " $lxde_packages_list " != *" $name "* ]] || die "LXDE package plan unexpectedly includes $name"
    done
    fluxbox_packages_list=$(fluxbox_packages | tr '\n' ' ')
    [[ " $fluxbox_packages_list " == *' lxpanel '* ]] || die 'Fluxbox package plan omitted lxpanel'
    fluxbox_firefox_packages=$(PKG_FIREFOX=yes INIT_CHOICE=openrc TOOLS_CHOICE=gnu fluxbox_packages | tr '\n' ' ')
    for name in duktape elogind polkit upower; do
        [[ " $fluxbox_firefox_packages " == *" $name "* ]] || die "Fluxbox with Firefox omitted $name"
    done
    (PKG_CAJA=no; [[ " $(mate_packages) " == *' pcmanfm '* ]]) || die 'MATE without Caja has no PCManFM wallpaper provider'
    (PKG_CAJA=yes; mate_packages | grep -qx caja) || die 'MATE with Caja omitted Caja'
    (TOOLS_CHOICE=gnu INIT_CHOICE=busybox SHELL_CHOICE=busybox
        [[ "$(estimate_iso_tenths init:busybox)" == '0 0' && "$(estimate_iso_tenths shell:busybox)" == '5 20' ]]) ||
        die 'BusyBox ISO size estimate missed the shared binary'
    (PKG_NANO=no PKG_WGET=no PKG_PING=no PKG_NEOFETCH=yes PKG_VIM=no PKG_FDISK=no PKG_GEANY=no \
        PKG_FIREFOX=no PKG_PLUMA=no PKG_CAJA=no PKG_ENGRAMPA=no PKG_EOM=no \
        PACKAGE_MANAGER=pacman SHELL_CHOICE=bash DESKTOP_CHOICE=none INIT_CHOICE=none \
        TOOLS_CHOICE=none BOOT_CHOICE=none WITH_GCC=no NETWORK=no
        [[ "$(selected_iso_delta)" == '5.1–12.2 MiB' && "$(iso_estimate_label shell bash)" == '+0 MiB ISO' ]]) ||
        die 'ISO size estimate calculation failed'
    for name in "${!VERSION[@]}"; do
        [[ ${SHA[$name]} =~ ^[a-f0-9]{64}$ && ${URL[$name]} == https://* ]] || die "$(tr_text "Invalid $name manifest" "Netinkamas $name manifestas")"
    done
    printf "$(tr_text 'Configuration (%s combinations) and manifest checks passed. No compilation performed.\n' 'Praėjo pasirinkimų (%s deriniai) ir manifestų patikros. Kompiliavimas neatliktas.\n')" "$count"
}

# GCC genautomata gali sunaudoti daug RAM net kompiliuojant su -j1.
save_memory_retry() {
    local kind=${1:-} file="$WORK_DIR/.diy-linux-retry" temporary
    [[ "$kind" == toolchain || ( "$kind" == build && -n ${BASE:-} && -f "$BASE/build.session" ) ]] || return 0
    temporary="$file.tmp.$$"
    (umask 077
        printf 'KIND=%s\nWORK_DIR=%s\nTARGET_ARCH=%s\nJOBS=%s\nBASE=%s\n' \
            "$kind" "$WORK_DIR" "$TARGET_ARCH" "$JOBS" "${BASE:-}" > "$temporary")
    mv -f -- "$temporary" "$file"
}

check_build_memory() {
    [[ ${MEMORY_CHECK:-yes} != no ]] || return 0
    local available swap available_mib memory_message
    read -r available swap < <(awk '
        /^MemAvailable:/ {ram=$2} /^SwapFree:/ {swap=$2}
        END {print ram+0, swap+0}' /proc/meminfo)
    if (( available + swap < 6 * 1024 * 1024 )); then
        save_memory_retry "${RETRY_KIND:-}"
        available_mib=$(((available + swap) / 1024))
        if [[ "$DIY_LANG" == lt ]]; then
            printf -v memory_message 'GCC kūrimui šiuo metu likę tik %s MiB RAM + laisvo swap. Paruošk swap: bash %s --prepare-swap 8. Tada pakartok tuos pačius pasirinkimus; baigti toolchain etapai išlieka. MEMORY_CHECK=no leidžia tęsti savo rizika' \
                "$available_mib" "${BASH_SOURCE[0]}"
        else
            printf -v memory_message 'Only %s MiB of RAM + free swap available for GCC. Prepare swap: bash %s --prepare-swap 8. Repeat the same build choices; completed toolchain stages are preserved. MEMORY_CHECK=no allows proceeding at your own risk' \
                "$available_mib" "${BASH_SOURCE[0]}"
        fi
        die "$memory_message"
    fi
}

prepare_swap() {
    local size=${1:-8} available_kib directory swap_file
    [[ "$size" =~ ^[1-9][0-9]?$ ]] && (( size <= 64 )) || die "$(tr_text 'Swap size must be 1-64 GiB' 'Swap dydis turi būti 1–64 GiB')"
    directory="$WORK_DIR"
    mkdir -p "$directory"
    directory=$(cd "$directory" && pwd -P)
    [[ "$directory" != / && "$directory" != *[[:space:]]* && "$directory" != *"'"* ]] || die "$(tr_text 'Invalid swap working directory path' 'Swap darbo katalogo kelias netinkamas')"
    # One file per requested size lets the user add a second swap area after an
    # earlier smaller swap has proved insufficient; never resize a live file.
    swap_file="$directory/diy-build-${size}g.swap"
    command -v sudo >/dev/null || die "$(tr_text 'Preparing swap requires sudo' 'Swap paruošimui reikia sudo')"
    command -v mkswap >/dev/null && command -v swapon >/dev/null || die "$(tr_text 'Preparing swap requires util-linux (mkswap, swapon)' 'Swap paruošimui reikia util-linux (mkswap, swapon)')"
    # Neperrašomas ankstesnis failas ir nekeičiama fstab. Swap veiks iki perkrovimo.
    say "$(tr_text "Preparing swap: $size GiB ($swap_file)" "Swap paruošimas: $size GiB ($swap_file)")"
    sudo bash -Eeuo pipefail -c '
# Inline translation: English first, Lithuanian second. No external catalog required.
tr_text() {
    if [ "${DIY_LANG:-en}" = lt ]; then printf '\''%s'\'' "$2"; else printf '\''%s'\'' "$1"; fi
}
        DIY_LANG=$3
        file=$1; gib=$2
        if [[ -e "$file" || -L "$file" ]]; then
            [[ -f "$file" && ! -L "$file" ]] || { echo "$(tr_text "Invalid swap file" "Netinkamas swap failas")" >&2; exit 1; }
            # Įjungti leidžiama tik jau sukurtą swap, ne bet kokį failą.
            [[ $(blkid -p -s TYPE -o value "$file") == swap ]] || { echo "$(tr_text "File already exists but is not swap; it will not be overwritten" "Failas jau yra, bet nėra swap; jis nebus perrašytas")" >&2; exit 1; }
            if swapon --show=NAME --noheadings | grep -Fxq "$file"; then
                echo "$(tr_text "Swap is already enabled" "Swap jau įjungtas")"; exit 0
            fi
            swapon "$file"; exit
        fi
        fstype=$(stat -f -c %T "$(dirname "$file")")
        [[ "$fstype" != btrfs ]] || { echo "$(tr_text "Btrfs: use your distribution swap preparation tool (requires NOCOW); file was not created" "Btrfs: naudok distribucijos swap paruošimo įrankį (reikia NOCOW); failas nesukurtas")" >&2; exit 1; }
        case "$fstype" in
            tmpfs|ramfs|overlay|overlayfs|nfs|nfs4|cifs|smb2|fuse*)
                printf "%s\n" "$(tr_text "Swap file is unsupported on $fstype; choose a local disk filesystem. No file created." "Swap failas $fstype nepalaikomas; pasirink vietinę disko failų sistemą. Failas nesukurtas.")" >&2
                exit 1 ;;
        esac
        available=$(df -Pk "$(dirname "$file")" | awk "NR==2 {print \$4}")
        (( available > (gib+2)*1024*1024 )) || { echo "$(tr_text "Not enough free disk space for swap and building" "Swap ir kūrimui nepakanka laisvos disko vietos")" >&2; exit 1; }
        # noclobber ir 0600 nuo sukūrimo: neperrašyti esamo failo.
        umask 077; set -o noclobber; : > "$file"; set +o noclobber
        dd if=/dev/zero of="$file" bs=1M count="$((gib*1024))" status=progress
        mkswap "$file"
        swapon "$file"
    ' _ "$swap_file" "$size" "$DIY_LANG"
    retry_file="$directory/.diy-linux-retry"
    if [[ -f "$retry_file" ]]; then
        retry_kind='' retry_work='' retry_arch='' retry_jobs='' retry_base=''
        while IFS='=' read -r name value; do
            case "$name" in
                KIND) retry_kind=$value ;;
                WORK_DIR) retry_work=$value ;;
                TARGET_ARCH) retry_arch=$value ;;
                JOBS) retry_jobs=$value ;;
                BASE) retry_base=$value ;;
            esac
        done < "$retry_file"
        [[ "$retry_work" == "$directory" && "$retry_arch" =~ ^(x86_64|i686|aarch64)$ && "$retry_jobs" =~ ^[1-9][0-9]*$ ]] ||
            die "$(tr_text 'Saved automatic-resume settings are invalid; retry the build manually.' 'Automatinio tęsinio nustatymai netinkami; kūrimą paleisk rankiniu būdu.')"
        rm -f -- "$retry_file"
        case "$retry_kind" in
            toolchain)
                say "$(tr_text 'Swap is ready; automatically continuing the saved toolchain build.' 'Swap paruoštas; automatiškai tęsiamas išsaugotas toolchain kūrimas.')"
                exec env WORK_DIR="$retry_work" TARGET_ARCH="$retry_arch" JOBS="$retry_jobs" DIY_LANG="$DIY_LANG" \
                    bash "${BASH_SOURCE[0]}" --toolchain ;;
            build)
                [[ "$retry_base" == "$directory"/* && -f "$retry_base/build.session" && ! -f "$retry_base/build.complete" ]] ||
                    die "$(tr_text 'Saved build is no longer resumable; start it again from the menu.' 'Išsaugoto kūrimo tęsti nebegalima; paleisk jį iš meniu iš naujo.')"
                pointer=$(session_pointer)
                (umask 077; printf '%s\n' "$retry_base" > "$pointer.tmp.$$")
                mv -f -- "$pointer.tmp.$$" "$pointer"
                say "$(tr_text 'Swap is ready; automatically resuming the saved build.' 'Swap paruoštas; automatiškai tęsiamas išsaugotas kūrimas.')"
                exec env WORK_DIR="$retry_work" DIY_LANG="$DIY_LANG" bash "${BASH_SOURCE[0]}" --resume ;;
            *) rm -f -- "$retry_file" ;;
        esac
    fi
    printf "$(tr_text 'Swap is ready. No saved interrupted build was found, so start the same build from the menu. Disable swap: sudo swapoff "%s"\n' 'Swap paruoštas. Išsaugoto nutraukto kūrimo nerasta, todėl tą patį kūrimą paleisk iš meniu. Swap išjungimas: sudo swapoff "%s"\n')" "$swap_file"
}


main() {
    if [[ ${1:-} == --version ]]; then
        printf '%s\n' "$(tr_text "DIY Linux version $DIY_VERSION" "DIY Linux versija $DIY_VERSION")"
        return
    fi
    if [[ ${1:-} != --help && ${1:-} != -h ]]; then
        printf '%s\n' "$(tr_text "DIY Linux builder version $DIY_VERSION" "DIY Linux kūrimo scenarijaus versija $DIY_VERSION")"
    fi
    case ${1:---menu} in
        --build|--resume|--fresh|--menu|--new|--plan|--install-deps)
            if [[ ${WITH_INSTALLER:-no} == yes ]]; then
                printf '%s\n' "$(tr_text 'Warning: WITH_INSTALLER is obsolete and ignored; the disk installer is not part of this build.' 'Įspėjimas: WITH_INSTALLER pasenęs ir ignoruojamas; disko diegiklis į šį kūrimą neįtraukiamas.')" >&2
            fi ;;
    esac
    case ${1:---menu} in
        --help|-h) help_text; return ;;
        --update) update_source_versions; return ;;
        --desktop-info) desktop_description "${2:-mate}"; return ;;
        --toolchain) build_toolchain_only; return ;;
        --versions) local name; for name in "${!VERSION[@]}"; do printf '%-14s %s\n' "$name" "${VERSION[$name]}"; done | sort; return ;;
        --self-test) self_test; return ;;
        --prepare-swap) prepare_swap "${2:-8}"; return ;;
        --enter|--chroot) enter_system "${2:-}"; return ;;
        --add-user) add_user "${2:-user}" "${3:-}"; return ;;
        --repair-login) repair_login "${2:-}"; return ;;
        --repack) repack_system "${2:-}" auto; return ;;
        --iso) repack_system "${2:-}" iso; return ;;
        --img) repack_system "${2:-}" img; return ;;
        --install-deps) validate || die "$VALIDATION_ERROR"; check_host; say "$(tr_text 'Host dependencies are ready' 'Šeimininko priklausomybės paruoštos')"; return ;;
        --plan) validate || die "$VALIDATION_ERROR"; plan; return ;;
        --edit) edit_system_menu; return ;;
        --new) session_choose --new ;;
        --menu) start_menu || return 0; session_choose "$START_MODE" ;;
        --build|--resume|--fresh) session_choose "$1" ;;
        *) die "$(tr_text 'Unknown argument. Usage: --help' 'Nežinomas argumentas. Naudojimas: --help')" ;;
    esac
    if [[ "$USER_PASSWORD_HASH" == '!' ]]; then
        if [[ -t 0 && -t 1 ]]; then
            system_password_prompt
        else
            die "$(tr_text 'A login password is required. Set ROOT_PASSWORD_HASH=$(openssl passwd -6) and rerun; the default user will use the same password unless USER_PASSWORD_HASH is explicitly set.' 'Reikia prisijungimo slaptažodžio. Nustatyk ROOT_PASSWORD_HASH=$(openssl passwd -6) ir kartok; numatytasis vartotojas naudos tą patį slaptažodį, jei aiškiai nenustatytas USER_PASSWORD_HASH.')"
        fi
    fi
    PKG_NEOFETCH=yes
    validate || die "$VALIDATION_ERROR"
    check_host
    workspace
    rm -f -- "$WORK_DIR/.diy-linux-retry"
    session_save
    RETRY_KIND=build
    printf "$(tr_text 'Each stage has its own progress row. Full log: %s/build.log\n' 'Kiekvienas etapas turi atskirą progreso eilutę. Visas žurnalas: %s/build.log\n')" "$BASE"
    local system_log="$BASE/build.log"
    toolchain_workspace
    local -a stage_names=(01a-binutils 01b-gcc-initial 01c-glibc 01d-gcc-final
        02-userland "02d-extras-$PKG_NANO-$PKG_NEOFETCH-$PKG_VIM-$PKG_FDISK"
        "02c-network-tools-$PKG_PING" 02a-login-su-v2 02b-sudo)
    [[ "$INIT_CHOICE" != systemd ]] || stage_names+=(03-system-bus)
    stage_names+=(03-init-v2
        "03b-wget-$PKG_WGET" "03c-openssh-v1-$PKG_OPENSSH" 03a-package-manager 04-native-gcc 04b-linux-firmware-v2)
    local package name
    if [[ "$DESKTOP_CHOICE" == mate || "$DESKTOP_CHOICE" == lxde || "$DESKTOP_CHOICE" == fluxbox ]]; then
        if [[ "$DESKTOP_CHOICE" == mate ]]; then
            for package in $(desktop_base_packages) $(mate_packages); do
                if [[ "$package" == eudev ]]; then stage_names+=(desktop-eudev-v2)
                elif [[ "$package" == sound-mixer ]]; then stage_names+=(desktop-sound-mixer-v2)
                elif [[ "$package" == gobject-introspection ]]; then stage_names+=(desktop-gobject-introspection-v4)
                elif [[ "$package" == mate-session-manager ]]; then stage_names+=(desktop-mate-session-manager-v4)
                elif [[ "$package" == mate-settings-daemon ]]; then stage_names+=(desktop-mate-settings-daemon-v3)
                elif [[ "$package" == mate-power-manager || "$package" == caja ]]; then stage_names+=("desktop-$package-v2")
                elif [[ "$package" == libxklavier ]]; then stage_names+=(desktop-libxklavier-v2)
                else stage_names+=("desktop-$package-v1"); fi
            done
            stage_names+=("desktop-app-geany-$PKG_GEANY" "desktop-app-firefox-$PKG_FIREFOX")
        elif [[ "$DESKTOP_CHOICE" == lxde ]]; then
            for package in $(desktop_base_packages) $(lxde_packages); do
                if [[ "$package" == eudev ]]; then stage_names+=(desktop-eudev-v2)
                elif [[ "$package" == sound-mixer ]]; then stage_names+=(desktop-sound-mixer-v2)
                elif [[ "$package" == gobject-introspection ]]; then stage_names+=(desktop-gobject-introspection-v4)
                else stage_names+=("desktop-$package-v1"); fi
            done
            stage_names+=("desktop-app-firefox-$PKG_FIREFOX")
        else
            for package in $(desktop_base_packages) $(fluxbox_packages); do
                if [[ "$package" == eudev ]]; then stage_names+=(desktop-eudev-v2)
                elif [[ "$package" == sound-mixer ]]; then stage_names+=(desktop-sound-mixer-v2)
                elif [[ "$package" == gobject-introspection ]]; then stage_names+=(desktop-gobject-introspection-v4)
                else stage_names+=("desktop-$package-v1"); fi
            done
            stage_names+=("desktop-app-firefox-$PKG_FIREFOX")
        fi
        [[ "$PKG_NGINX" != yes ]] || stage_names+=(web-stack-v1)
        stage_names+=("05-kernel-live-squashfs-v7")
    else
        [[ "$PKG_NGINX" != yes ]] || stage_names+=(web-stack-v1)
        stage_names+=(05-kernel-live-squashfs-v7)
    fi
    stage_names+=("06-boot-tools-v2-$BOOT_CHOICE")
    local -a stage_labels=()
    for name in "${stage_names[@]}"; do stage_labels+=("$(stage_label "$name")"); done
    stage_labels+=("$(tr_text 'System configuration' 'Sistemos konfigūracija')"
        "$(tr_text 'Package configuration' 'Paketų konfigūracija')"
        "$(tr_text 'User and sudoers' 'Vartotojas ir sudoers')"
        "$(tr_text 'Desktop configuration' 'Darbalaukio konfigūracija')"
        "$(tr_text 'Packaging images' 'Atvaizdų pakavimas')")
    progress_start "${#stage_labels[@]}" "$system_log" "${stage_labels[@]}"
    step '01a-binutils' bootstrap_binutils
    local requested_jobs=$JOBS
    JOBS=1                     # GCC generatoriams paliekama kuo daugiau RAM.
    [[ -f "$STAMPS/01b-gcc-initial" ]] || check_build_memory
    step '01b-gcc-initial' bootstrap_gcc_initial
    step '01c-glibc' bootstrap_glibc
    [[ -f "$STAMPS/01d-gcc-final" ]] || check_build_memory
    step '01d-gcc-final' bootstrap_gcc_final
    JOBS=$requested_jobs
    system_toolchain
    cross_environment
    step '02-userland' userland
    step "02d-extras-$PKG_NANO-$PKG_NEOFETCH-$PKG_VIM-$PKG_FDISK" extra_programs
    step "02c-network-tools-$PKG_PING" network_tools
    step 02a-login-su-v2 login_tools
    step '02b-sudo' sudo_tools
    if [[ "$INIT_CHOICE" == systemd ]]; then step '03-system-bus' system_bus; fi
    step '03-init-v2' init_system
    step "03b-wget-$PKG_WGET" wget_tools
    step "03c-openssh-v1-$PKG_OPENSSH" openssh_tools
    step '03a-package-manager' package_manager
    step '04-native-gcc' native_development
    step '04b-linux-firmware-v2' desktop_firmware
    graphical_desktop
    desktop_applications
    [[ "$PKG_NGINX" != yes ]] || step web-stack-v1 web_stack
    step 05-kernel-live-squashfs-v7 kernel
    step "06-boot-tools-v2-$BOOT_CHOICE" boot_tools
    run_quiet "$(tr_text 'System configuration' 'Sistemos konfigūracija')" configure_system
    run_quiet "$(tr_text 'Package configuration' 'Paketų konfigūracija')" configure_packages
    run_quiet "$(tr_text 'User and sudoers' 'Vartotojas ir sudoers')" configure_user
    run_quiet "$(tr_text 'Desktop configuration' 'Darbalaukio konfigūracija')" configure_desktop
    save_system
    run_quiet "$(tr_text 'Packaging images' 'Atvaizdų pakavimas')" verify_and_pack
    session_complete
    progress_stop
    printf "$(tr_text '\n%sComplete: 100%%.%s Images: %s\nLog: %s/build.log\n' '\n%sBaigta: 100%%.%s Atvaizdai: %s\nŽurnalas: %s/build.log\n')" "$C_OK" "$C_RESET" "$IMAGES" "$BASE"
    printf "$(tr_text 'Login username: %s. Administration: sudo -i (user password).\n' 'Prisijungimo vardas: %s. Administravimas: sudo -i (vartotojo slaptažodis).\n')" "$USER_NAME"
    print_qemu_command
}

architecture || die "$VALIDATION_ERROR"
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi

