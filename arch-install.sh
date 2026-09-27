#!/usr/bin/env bash
#
# arch-install.sh - interactive Arch Linux installer
#
# Walks through the ArchWiki "Installation guide" in order. Comments mark the
# guide's section numbers (e.g. "§1.9 Partition the disks") so every step can
# be traced back to the reference.
#
# Usage: bash arch-install.sh [options]
#   -c, --config FILE   pre-fill answers from FILE (see answers.example.conf)
#   -p, --post FILE     run FILE inside the new system after installing
#   -n, --dry-run       ask everything and show the plan, but change nothing
#   -V, --version       print the version
#   -h, --help          show this help
#
# Everything printed is also logged to /tmp/arch-install.log, and the log is
# copied to /var/log/arch-install.log on the new system.

set -Eeuo pipefail

readonly VERSION="1.0.0"
readonly MNT=/mnt
readonly LOG=/tmp/arch-install.log
readonly ANSWERS_OUT=/tmp/arch-install.conf
readonly CRYPT_NAME=cryptroot
readonly TWO_TIB=2199023255552

# ------------------------------------------------------------------ output

if [[ -t 1 ]]; then
  BOLD=$'\e[1m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' BLUE=$'\e[34m' RESET=$'\e[0m'
else
  BOLD='' RED='' GREEN='' YELLOW='' BLUE='' RESET=''
fi

info()    { printf '%s::%s %s\n' "$BLUE$BOLD" "$RESET" "$*"; }
ok()      { printf '%s[ok]%s %s\n' "$GREEN$BOLD" "$RESET" "$*"; }
warn()    { printf '%s[!]%s %s\n' "$YELLOW$BOLD" "$RESET" "$*" >&2; }
die()     { printf '%sERROR:%s %s\n' "$RED$BOLD" "$RESET" "$*" >&2; exit 1; }
section() { printf '\n%s===== %s =====%s\n' "$BOLD" "$*" "$RESET"; }

usage() {
  sed -n '9,15p' "${BASH_SOURCE[0]}" 2>/dev/null | sed 's/^# \{0,1\}//' ||
    echo "Usage: bash arch-install.sh [-c answers.conf] [-p post.sh] [-n] [-h]"
}

# ------------------------------------------------------------------ state

# Answers that can be loaded from / saved to an answers file. Passwords never are.
CONFIG_KEYS=(KEYMAP CONSOLE_FONT DISK PART_MODE PART_TABLE ESP_SIZE ESP_MOUNT
  ROOT_PART ESP_PART BOOT_PART SWAP_PART FORMAT_ESP TRIM_DISK PORTABLE
  FILESYSTEM ENCRYPT SWAP SWAP_SIZE MIRRORS MIRROR_COUNTRY KERNEL FIRMWARE
  SOF_FIRMWARE MICROCODE TEXT_EDITOR NETWORK DESKTOP GPU_DRIVER GUEST_TOOLS
  MULTILIB EXTRA_PACKAGES TIMEZONE LOCALES HOST_NAME SET_ROOT_PW USERNAME
  BOOTLOADER OS_PROBER REMOVABLE)
# Machine-specific answers: accepted from a file but never written to one, so a
# saved answers file cannot silently point at the wrong disk on another machine.
MACHINE_KEYS=" DISK ROOT_PART ESP_PART BOOT_PART SWAP_PART ESP_MOUNT FORMAT_ESP "

for _k in "${CONFIG_KEYS[@]}"; do printf -v "$_k" '%s' ""; done
unset _k

declare -A SET=()      # keys that have an answer (from the user or a file)
FORCE_ASK=0            # 1 = ask again even if already answered (used by "edit")
STAGE=setup            # setup -> disk -> done; decides what cleanup does
CONFIG_IN="" POST_SCRIPT="" DRY_RUN=0

ARCH="" DISTRO="" BOOT_MODE="" UEFI_BITS="" VIRT="" CPU_VENDOR="" RAM_MIB=0
DISK_NAME="" DISK_BYTES=0 DISK_TRAN="" ROTATIONAL=0 GRUB_DISK=""
ROOT_DEV="" SWAPFILE="" HOOK_STYLE="" GPU_VENDORS=""
ROOT_PASS="" USER_PASS="" LUKS_PASS=""
PKGS=() SERVICES=()

# ------------------------------------------------------------------ errors & cleanup
# Crash early with a clear message, and always hand back the resources we took
# (mounts, swap, the open LUKS mapping) so the script can simply be re-run.

on_err() {
  local code=$? line=$1
  printf '%sERROR:%s "%s" failed (exit %s) at line %s.\n' "$RED$BOLD" "$RESET" \
    "$BASH_COMMAND" "$code" "$line" >&2
  printf 'Full log: %s\n' "$LOG" >&2
}

release_target() {
  if [[ -n $SWAP_PART ]]; then swapoff "$SWAP_PART" 2>/dev/null || true; fi
  umount -R "$MNT" 2>/dev/null || true
  if [[ -e /dev/mapper/$CRYPT_NAME ]]; then cryptsetup close "$CRYPT_NAME" 2>/dev/null || true; fi
}

cleanup() {
  local code=$?
  if [[ $STAGE == disk && $code -ne 0 ]]; then
    warn "Installation did not finish. Releasing mounts so you can re-run the script."
    release_target
  fi
}

trap 'on_err $LINENO' ERR
trap cleanup EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------------ prompts

_have()  { [[ $FORCE_ASK -eq 0 && -n ${SET[$1]-} ]]; }
_store() { printf -v "$1" '%s' "$2"; SET[$1]=1; }

# Reads one line from the terminal into REPLY. Uses /dev/tty so the script
# still works when started as "curl ... | bash".
prompt_line() {
  IFS= read -r -p "$1" REPLY </dev/tty || die "No terminal input available."
}

# ask VAR "question" [default] [validator] [optional]
# The validator gets the answer and prints its own reason when it rejects it.
# For optional questions an empty answer is allowed; "-" clears a default.
ask() {
  local var=$1 q=$2 def=${3-} check=${4-} optional=${5-} ans
  if _have "$var"; then
    if [[ -z ${!var-} && -n $optional ]]; then return 0; fi
    if [[ -z $check ]] || "$check" "${!var-}"; then return 0; fi
    warn "Saved answer for $var is not valid here; asking again."
  fi
  if [[ -n ${SET[$var]-} ]]; then def=${!var-}; fi
  while :; do
    prompt_line "$BOLD$q$RESET${def:+ [$def]}: "
    ans=${REPLY:-$def}
    if [[ $REPLY == "-" && -n $optional ]]; then ans=""; fi
    if [[ -z $ans && -z $optional ]]; then warn "An answer is required."; continue; fi
    if [[ -n $ans && -n $check ]] && ! "$check" "$ans"; then continue; fi
    _store "$var" "$ans"
    return 0
  done
}

# choose VAR "question" "value|label" ...   (the first option is the default)
choose() {
  local var=$1 q=$2 o i n def=1
  shift 2
  local -a vals=() labels=()
  for o in "$@"; do vals+=("${o%%|*}"); labels+=("${o#*|}"); done
  if _have "$var"; then
    for i in "${!vals[@]}"; do
      if [[ ${vals[i]} == "${!var-}" ]]; then return 0; fi
    done
    warn "Saved answer '${!var-}' for $var is not an option here; asking again."
  fi
  if (( ${#vals[@]} == 1 )); then
    info "$q: ${labels[0]} (only option)"
    _store "$var" "${vals[0]}"
    return 0
  fi
  for i in "${!vals[@]}"; do
    if [[ ${vals[i]} == "${!var-}" ]]; then def=$((i + 1)); fi
  done
  printf '%s%s%s\n' "$BOLD" "$q" "$RESET"
  for i in "${!vals[@]}"; do printf '  %2d) %s\n' $((i + 1)) "${labels[i]}"; done
  while :; do
    prompt_line "Choice [$def]: "
    n=${REPLY:-$def}
    if [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#vals[@]} )); then
      _store "$var" "${vals[n - 1]}"
      return 0
    fi
    warn "Enter a number between 1 and ${#vals[@]}."
  done
}

# yesno VAR "question" yes|no   (stores "yes" or "no")
yesno() {
  local var=$1 q=$2 def=$3 hint
  if _have "$var" && [[ ${!var-} == yes || ${!var-} == no ]]; then return 0; fi
  if [[ ${!var-} == yes || ${!var-} == no ]]; then def=${!var}; fi
  if [[ $def == yes ]]; then hint="Y/n"; else hint="y/N"; fi
  while :; do
    prompt_line "$BOLD$q$RESET [$hint]: "
    case ${REPLY,,} in
      '')     _store "$var" "$def"; return 0 ;;
      y|yes)  _store "$var" yes; return 0 ;;
      n|no)   _store "$var" no; return 0 ;;
      *)      warn "Please answer y or n." ;;
    esac
  done
}

# secret VAR "what" - asked twice, never logged, never saved.
secret() {
  local var=$1 what=$2 a b
  if [[ -n ${!var-} && $FORCE_ASK -eq 0 ]]; then return 0; fi
  while :; do
    IFS= read -rs -p "Enter $what: " a </dev/tty || die "No terminal input available."
    echo
    IFS= read -rs -p "Repeat $what: " b </dev/tty || die "No terminal input available."
    echo
    if [[ -z $a ]]; then warn "It must not be empty."
    elif [[ $a != "$b" ]]; then warn "They did not match, try again."
    else printf -v "$var" '%s' "$a"; return 0
    fi
  done
}

# ------------------------------------------------------------------ validators

valid_keymap() {
  if [[ $1 == "?" ]]; then
    localectl list-keymaps 2>/dev/null | column -c "${COLUMNS:-100}" || true
    return 1
  fi
  if grep -qxF -- "$1" <<<"$(localectl list-keymaps 2>/dev/null)"; then return 0; fi
  if [[ -n $(find /usr/share/kbd/keymaps -name "$1.map.gz" -print -quit 2>/dev/null) ]]; then return 0; fi
  warn "Unknown keymap '$1'. Type ? to list them."
  return 1
}

valid_tz() {
  local z=$1
  if [[ $z =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f /usr/share/zoneinfo/$z ]]; then return 0; fi
  if [[ $z == "?" ]]; then
    timedatectl list-timezones 2>/dev/null | cut -d/ -f1 | sort -u | column -c "${COLUMNS:-100}" || true
  elif [[ $z =~ ^[A-Za-z_]+$ && -d /usr/share/zoneinfo/$z ]]; then
    timedatectl list-timezones 2>/dev/null | grep "^$z/" | column -c "${COLUMNS:-100}" || true
  else
    warn "Unknown time zone '$z'. Type ? for regions, or a region (e.g. Asia) to list its zones."
  fi
  return 1
}

valid_locales() {
  local l bad=0
  if [[ $1 == "?" ]]; then
    sed -n 's/ UTF-8$//p' /usr/share/i18n/SUPPORTED | column -c "${COLUMNS:-100}" || true
    return 1
  fi
  for l in $1; do
    if ! grep -qxF -- "$l UTF-8" /usr/share/i18n/SUPPORTED; then
      warn "Unknown UTF-8 locale '$l' (format like en_US.UTF-8; type ? for the list)."
      bad=1
    fi
  done
  return "$bad"
}

valid_hostname() {
  # Rule from hostname(7), quoted in the Installation guide §3.5.
  if [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then return 0; fi
  warn "Use 1-63 characters: lowercase a-z, 0-9 and '-', not starting with '-'."
  return 1
}

valid_username() {
  if [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ && $1 != root ]]; then return 0; fi
  warn "Use up to 32 characters: lowercase letters, digits, '_' or '-', starting with a letter."
  return 1
}

valid_esp_size() {
  if [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 300 && $1 <= 4096 )); then return 0; fi
  warn "Enter a size between 300 and 4096 MiB (1024 is recommended)."
  return 1
}

valid_swap_size() {
  if [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 1024 )); then return 0; fi
  warn "Enter a whole number of GiB between 1 and 1024."
  return 1
}

pkg_exists() {
  pacman -Si -- "$1" >/dev/null 2>&1 && return 0
  [[ -n $(pacman -Sgq -- "$1" 2>/dev/null) ]]
}

valid_packages() {
  local p missing=()
  for p in $1; do
    if ! pkg_exists "$p"; then missing+=("$p"); fi
  done
  if (( ${#missing[@]} == 0 )); then return 0; fi
  warn "Not found in the repositories: ${missing[*]}"
  return 1
}

# ------------------------------------------------------------------ answers file

load_config() {
  local f=$1 line key val n=0
  [[ -r $f ]] || die "Cannot read answers file: $f"
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    if [[ $line =~ ^[[:space:]]*(#|$) ]]; then continue; fi
    if [[ $line =~ ^([A-Z_]+)=(.*)$ ]]; then
      key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
      val=${val#[\"\']} val=${val%[\"\']}
      if [[ " ${CONFIG_KEYS[*]} " == *" $key "* ]]; then
        _store "$key" "$val"
      else
        warn "$f:$n: unknown key '$key' ignored."
      fi
    else
      warn "$f:$n: cannot parse line, ignored."
    fi
  done <"$f"
  ok "Loaded answers from $f"
}

save_config() {
  local k out=${1:-$ANSWERS_OUT}
  {
    printf '# arch-install.sh answers, saved %s UTC\n' "$(date -u '+%F %T')"
    printf '# Re-use with: bash arch-install.sh --config %s\n' "${out##*/}"
    printf '# Passwords, the disk and partitions are never saved; they are always asked.\n'
    for k in "${CONFIG_KEYS[@]}"; do
      if [[ -n ${SET[$k]-} && $MACHINE_KEYS != *" $k "* ]]; then
        printf '%s="%s"\n' "$k" "${!k-}"
      fi
    done
  } >"$out"
}

# ------------------------------------------------------------------ helpers

# Partition N of $DISK: sda -> sda2, nvme0n1 / mmcblk0 / loop0 -> nvme0n1p2.
part() {
  if [[ $DISK =~ [0-9]$ ]]; then printf '%sp%s' "$DISK" "$1"; else printf '%s%s' "$DISK" "$1"; fi
}

wait_for_dev() {
  local i
  for i in {1..40}; do
    if [[ -b $1 ]]; then return 0; fi
    sleep 0.25
  done
  die "Device $1 did not appear."
}

# Field from lsblk -P output: kv NAME 'NAME="/dev/sda" SIZE="1T"' -> /dev/sda
kv() {
  local re="(^| )$1=\"([^\"]*)\""
  if [[ $2 =~ $re ]]; then printf '%s' "${BASH_REMATCH[2]}"; fi
}

parent_disk() { printf '/dev/%s' "$(lsblk -no PKNAME "$1" | head -n1)"; }

human_size() { lsblk -dno SIZE "$1" | tr -d ' '; }

media_kind() { # name rota tran
  case ${1##*/} in
    nvme*)    echo "NVMe SSD" ;;
    mmcblk*)  echo "eMMC/SD card" ;;
    vd*|xvd*) echo "virtual disk" ;;
    *)
      if [[ $3 == usb ]]; then echo "USB drive"
      elif [[ $2 == 1 ]]; then echo "HDD"
      else echo "SSD"
      fi ;;
  esac
}

ensure_tool() { # command package
  if command -v "$1" >/dev/null 2>&1; then return 0; fi
  info "Installing $2 in the live environment (needed for $1)"
  pacman -S --needed --noconfirm "$2" || die "Could not install $2."
}

enable_multilib() { # pacman.conf
  if grep -q '^\[multilib\]' "$1"; then return 0; fi
  sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' "$1"
}

run_shell() {
  info "Starting a shell. Type 'exit' to come back to the installer."
  bash </dev/tty >/dev/tty 2>&1 || true
}

# ================================================================== pre-installation

preflight() {
  section "Pre-flight checks"
  [[ $EUID -eq 0 ]] || die "Run this as root (the live ISO logs you in as root)."
  (( BASH_VERSINFO[0] >= 5 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) ||
    die "Bash 4.4 or newer is required."
  command -v pacman >/dev/null || die "pacman not found - boot the Arch Linux live environment first."

  if mountpoint -q "$MNT" || [[ -e /dev/mapper/$CRYPT_NAME ]]; then
    warn "$MNT is mounted or /dev/mapper/$CRYPT_NAME is open (an earlier attempt?)."
    local UNMOUNT=""
    yesno UNMOUNT "Unmount everything under $MNT and continue?" yes
    if [[ $UNMOUNT == yes ]]; then release_target; else die "Aborted."; fi
  fi
  ok "Running as root with bash $BASH_VERSION"
}

detect_platform() {
  section "Platform"
  case $(uname -m) in
    x86_64)        ARCH=x86_64  DISTRO="Arch Linux" ;;
    i486|i586|i686) ARCH=i686   DISTRO="Arch Linux 32 (community port)" ;;
    aarch64|arm64) ARCH=aarch64 DISTRO="Arch Linux ARM (community port)" ;;
    armv7*)        ARCH=armv7h  DISTRO="Arch Linux ARM (community port)" ;;
    riscv64)       ARCH=riscv64 DISTRO="Arch Linux RISC-V (community port)" ;;
    *)             die "Unsupported CPU architecture: $(uname -m)" ;;
  esac

  # §1.6 Verify the boot mode
  if [[ -r /sys/firmware/efi/fw_platform_size ]]; then
    BOOT_MODE=uefi UEFI_BITS=$(</sys/firmware/efi/fw_platform_size)
  elif [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE=uefi UEFI_BITS=native
  elif [[ $ARCH == x86_64 || $ARCH == i686 ]]; then
    BOOT_MODE=bios
  else
    BOOT_MODE=none   # board firmware such as U-Boot or the Raspberry Pi loader
  fi

  VIRT=$(systemd-detect-virt 2>/dev/null || true)
  VIRT=${VIRT:-none}
  CPU_VENDOR=$(awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
  RAM_MIB=$(( $(awk '/^MemTotal/ {print $2}' /proc/meminfo) / 1024 ))

  info "CPU architecture : $ARCH ($DISTRO)"
  case $BOOT_MODE in
    uefi) info "Boot mode        : UEFI ($UEFI_BITS-bit firmware)" ;;
    bios) info "Boot mode        : BIOS / legacy (CSM)" ;;
    none) info "Boot mode        : board firmware (no UEFI)" ;;
  esac
  info "Virtualisation   : $VIRT"
  info "Memory           : $RAM_MIB MiB"

  if [[ $ARCH != x86_64 ]]; then
    warn "Official Arch Linux supports x86_64 only; $ARCH is handled by $DISTRO."
    warn "Run this from that port's own live environment so pacman uses its repositories."
  fi
  if [[ $BOOT_MODE == uefi && $ARCH == x86_64 && $UEFI_BITS == 32 ]]; then
    warn "64-bit CPU on 32-bit UEFI: only GRUB can boot this (mixed mode)."
  fi
  if [[ $BOOT_MODE == none ]]; then
    warn "No UEFI firmware: the boot loader for this board is board-specific and will not be installed."
  fi
}

# §1.5 Set the console keyboard layout and font
setup_console() {
  section "§1.5 Console keyboard layout and font"
  ask KEYMAP "Console keymap (us, uk, de-latin1, fr ... ? lists all)" us valid_keymap
  loadkeys "$KEYMAP" 2>/dev/null || warn "loadkeys failed (not on a real console?)."
  choose CONSOLE_FONT "Console font" \
    "default|Default font" \
    "ter-124b|Terminus 24 (larger)" \
    "ter-132b|Terminus 32 (HiDPI screens)"
  if [[ $CONSOLE_FONT != default ]]; then
    setfont "$CONSOLE_FONT" 2>/dev/null || warn "setfont failed (not on a real console?)."
  fi
}

online() {
  ping -c1 -W3 ping.archlinux.org >/dev/null 2>&1 ||
    curl -fsI --max-time 6 https://archlinux.org >/dev/null 2>&1
}

wifi_connect() {
  command -v iwctl >/dev/null || { warn "iwctl is not available."; return 0; }
  rfkill unblock wifi 2>/dev/null || true
  local d devs=() opts=() WIFI_DEV="" WIFI_SSID="" pass
  for d in /sys/class/net/*; do
    if [[ -d $d/wireless || -d $d/phy80211 ]]; then devs+=("${d##*/}"); fi
  done
  if (( ${#devs[@]} == 0 )); then warn "No wireless interface found."; return 0; fi
  for d in "${devs[@]}"; do opts+=("$d|$d"); done
  choose WIFI_DEV "Wireless interface" "${opts[@]}"
  info "Scanning..."
  iwctl station "$WIFI_DEV" scan || true
  sleep 4
  iwctl station "$WIFI_DEV" get-networks || true
  ask WIFI_SSID "Network name (SSID)"
  IFS= read -rs -p "Passphrase (leave empty for an open network): " pass </dev/tty || true
  echo
  if [[ -n $pass ]]; then
    iwctl --passphrase "$pass" station "$WIFI_DEV" connect "$WIFI_SSID" || warn "Connection failed."
  else
    iwctl station "$WIFI_DEV" connect "$WIFI_SSID" || warn "Connection failed."
  fi
  info "Waiting for an address..."
  sleep 6
}

# §1.7 Connect to the internet
setup_network() {
  section "§1.7 Internet connection"
  local NET_FIX=""
  while ! online; do
    warn "No internet connection."
    FORCE_ASK=1 choose NET_FIX "How do you want to connect?" \
      "wifi|Wi-Fi (guided iwctl)" \
      "retry|Try again (Ethernet cable just plugged in, phone USB tethering...)" \
      "shell|Open a shell and set it up by hand (mmcli, static IP ...)" \
      "abort|Abort"
    case $NET_FIX in
      wifi)  wifi_connect ;;
      retry) sleep 3 ;;
      shell) run_shell ;;
      abort) die "No network, aborted." ;;
      *)     die "Unexpected choice: $NET_FIX" ;;
    esac
  done
  ok "Online"
}

# §1.8 Update the system clock
sync_clock() {
  section "§1.8 System clock"
  timedatectl set-ntp true 2>/dev/null || true
  local i
  for i in {1..20}; do
    if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]]; then
      ok "Clock synchronised: $(date -u '+%F %T') UTC"
      return 0
    fi
    sleep 1
  done
  warn "Clock not confirmed as synchronised ($(date -u '+%F %T') UTC)."
  warn "If this is wrong, package signature checks can fail."
}

prepare_pacman() {
  section "Package manager"
  sed -i -E 's/^#?ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
  info "Refreshing package databases"
  pacman -Sy --noconfirm >/dev/null
  # An old ISO ships an old keyring; refreshing it avoids "invalid signature" errors.
  local keyring=""
  case $ARCH in
    x86_64)         keyring=archlinux-keyring ;;
    i686)           keyring=archlinux32-keyring ;;
    aarch64|armv7h) keyring=archlinuxarm-keyring ;;
  esac
  if [[ -n $keyring ]]; then
    pacman -S --needed --noconfirm "$keyring" >/dev/null || warn "Could not refresh $keyring."
  fi
  local c
  for c in pacstrap:arch-install-scripts arch-chroot:arch-install-scripts genfstab:arch-install-scripts \
           sgdisk:gptfdisk sfdisk:util-linux wipefs:util-linux mkfs.fat:dosfstools partprobe:parted \
           cryptsetup:cryptsetup blkid:util-linux; do
    ensure_tool "${c%%:*}" "${c#*:}"
  done
  ok "Package databases ready"
}

# ================================================================== planning (no changes yet)

# §1.9 - list disks the way the guide describes: ignore rom, loop, airootfs and
# the mmcblk rpmb/boot0/boot1 hardware partitions, and never offer the medium
# we booted from.
scan_disks() {
  local line name src live="" self=""
  DISK_OPTS=()
  src=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
  if [[ $src == /dev/* ]]; then live=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true); fi
  src=$(findmnt -no SOURCE / 2>/dev/null || true)
  if [[ $src == /dev/* ]]; then self=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 || true); fi

  while IFS= read -r line; do
    name=$(kv NAME "$line")
    [[ $(kv TYPE "$line") == disk ]] || continue
    [[ ${name##*/} =~ ^(zram|ram)|(rpmb|boot[0-9])$ ]] && continue
    [[ -n $live && ${name##*/} == "$live" ]] && continue
    [[ -n $self && ${name##*/} == "$self" ]] && continue
    [[ $(kv SIZE "$line") == 0B ]] && continue
    DISK_OPTS+=("$name|$(printf '%-16s %8s  %-12s %s' "$name" "$(kv SIZE "$line")" \
      "$(media_kind "$name" "$(kv ROTA "$line")" "$(kv TRAN "$line")")" "$(kv MODEL "$line")")")
  done < <(lsblk -dpnP -e 7,11 -o NAME,TYPE,SIZE,ROTA,TRAN,MODEL)
}

disk_facts() { # disk -> ROTATIONAL, DISK_TRAN, DISK_BYTES
  ROTATIONAL=$(cat "/sys/block/${1##*/}/queue/rotational" 2>/dev/null || echo 0)
  DISK_TRAN=$(lsblk -dno TRAN "$1" 2>/dev/null | tr -d ' ' || true)
  DISK_BYTES=$(blockdev --getsize64 "$1")
}

select_disk() {
  section "§1.9 Target disk"
  scan_disks
  (( ${#DISK_OPTS[@]} )) ||
    die "No installable disk found. If yours is missing, check that the disk controller is not in RAID mode."
  choose DISK "Disk to install to" "${DISK_OPTS[@]}"
  DISK_NAME=${DISK##*/}
  disk_facts "$DISK"

  (( DISK_BYTES >= 8 * 1024 ** 3 )) || die "$DISK is smaller than 8 GiB."
  if (( DISK_BYTES < 24 * 1024 ** 3 )); then
    warn "$DISK is small; the guide suggests at least 23-32 GiB for the root partition."
  fi

  # Guide tip: check that NVMe and Advanced Format drives use the optimal sector size.
  local lss pss
  lss=$(blockdev --getss "$DISK") pss=$(blockdev --getpbsz "$DISK")
  info "Sector size: $lss bytes logical / $pss bytes physical"
  if [[ $lss == 512 && $pss == 4096 ]]; then
    warn "This drive has 4096-byte physical sectors but uses 512-byte logical sectors (512e)."
    warn "Partitions are 1 MiB aligned so this is fine; see ArchWiki 'Advanced Format' to switch."
  fi
  if [[ $DISK_NAME == nvme* ]] && command -v nvme >/dev/null && [[ $lss == 512 ]] &&
     grep -q 'Data Size: 4096 bytes' <<<"$(nvme id-ns -H "$DISK" 2>/dev/null)"; then
    warn "This NVMe drive also supports 4096-byte LBAs. Switching needs 'nvme format' (erases the"
    warn "drive); do it before running this script if you want it. See ArchWiki 'Advanced Format'."
  fi
}

default_swap_gib() {
  local g=$(( (RAM_MIB + 1023) / 1024 ))
  if (( g < 4 )); then g=4; fi
  if (( g > 16 )); then g=16; fi
  echo "$g"
}

plan_storage() {
  section "§1.9 Partitioning plan"
  choose PART_MODE "How should the disk be set up?" \
    "auto|Erase $DISK completely and create the recommended layout" \
    "manual|Partition it myself / reuse existing partitions (dual boot)"

  choose FILESYSTEM "Root file system" \
    "ext4|ext4  - reliable, simple (default)" \
    "btrfs|Btrfs - snapshots, compression, subvolumes" \
    "xfs|XFS   - fast with large files" \
    "f2fs|F2FS  - built for flash (SSD, eMMC, SD cards, USB sticks)"
  if [[ $FILESYSTEM == f2fs && $ROTATIONAL == 1 ]]; then
    warn "F2FS is designed for flash storage; ext4 or XFS suit a spinning disk better."
  fi

  yesno ENCRYPT "Encrypt the root file system with LUKS2 (passphrase at every boot)?" no

  local sw=("zram|zram           - compressed swap in RAM, no disk writes (recommended)")
  if [[ $FILESYSTEM != f2fs ]]; then sw+=("file|Swap file      - on the root file system"); fi
  if [[ $ENCRYPT == no ]]; then sw+=("partition|Swap partition - a dedicated partition"); fi
  sw+=("none|No swap")
  choose SWAP "Swap" "${sw[@]}"
  if [[ $SWAP == file || $SWAP == partition ]]; then
    ask SWAP_SIZE "Swap size in GiB (at least your RAM size if you want to hibernate)" \
      "$(default_swap_gib)" valid_swap_size
  fi

  if [[ $DISK_TRAN == usb ]]; then
    yesno PORTABLE "This is a USB drive. Make the install portable (boots on other PCs)?" yes
  else
    _store PORTABLE no
  fi

  if [[ $PART_MODE == auto ]]; then plan_auto_layout; else plan_manual_layout; fi

  local need=""
  case $FILESYSTEM in
    ext4)  need=mkfs.ext4:e2fsprogs ;;
    btrfs) need=mkfs.btrfs:btrfs-progs ;;
    xfs)   need=mkfs.xfs:xfsprogs ;;
    f2fs)  need=mkfs.f2fs:f2fs-tools ;;
    *)     die "Unexpected file system: $FILESYSTEM" ;;
  esac
  ensure_tool "${need%%:*}" "${need#*:}"
}

plan_auto_layout() {
  ESP_PART="" BOOT_PART="" SWAP_PART="" ROOT_PART=""
  GRUB_DISK=$DISK
  if [[ $BOOT_MODE == bios ]]; then
    choose PART_TABLE "Partition table" \
      "gpt|GPT (recommended)" \
      "mbr|MBR/DOS (only for old BIOSes that refuse GPT; up to 2 TiB)"
    if [[ $PART_TABLE == mbr ]] && (( DISK_BYTES > TWO_TIB )); then
      warn "MBR cannot address more than 2 TiB; using GPT."
      _store PART_TABLE gpt
    fi
  else
    _store PART_TABLE gpt
    ask ESP_SIZE "EFI system partition size in MiB" 1024 valid_esp_size
  fi
  _store ESP_MOUNT /boot
  _store FORMAT_ESP yes
  if [[ $ROTATIONAL == 0 ]]; then
    yesno TRIM_DISK "Discard (TRIM) the whole drive first? Instant on SSD/NVMe, gives the controller a clean slate" yes
  else
    _store TRIM_DISK no
  fi
}

pick_partition() { # VAR "question" [allow-none]
  local var=$1 q=$2 line name opts=()
  if [[ -n ${3-} ]]; then opts+=("none|None"); fi
  while IFS= read -r line; do
    [[ $(kv TYPE "$line") == part ]] || continue
    name=$(kv NAME "$line")
    opts+=("$name|$(printf '%-18s %8s  %-7s %s' "$name" "$(kv SIZE "$line")" \
      "$(kv FSTYPE "$line")" "$(kv PARTTYPENAME "$line")")")
  done < <(lsblk -pnP -o NAME,TYPE,SIZE,FSTYPE,PARTTYPENAME)
  (( ${#opts[@]} )) || die "No partitions found."
  choose "$var" "$q" "${opts[@]}"
  if [[ ${!var} == none ]]; then printf -v "$var" '%s' ""; fi
}

# Returns 1 (so the caller asks again) when the chosen partitions don't make sense.
pick_manual_parts() {
  local RUN_CFDISK="" fstype size_mib def p q
  _store TRIM_DISK no
  FORCE_ASK=1 yesno RUN_CFDISK "Open cfdisk on $DISK to create or resize partitions?" yes
  if [[ $RUN_CFDISK == yes ]]; then
    info "You need: a root partition (at least ~24 GiB)$(
      [[ $BOOT_MODE == uefi ]] && printf ', an EFI system partition (reuse an existing one)'
      [[ $BOOT_MODE == bios ]] && printf ', and on GPT disks a 1 MiB "BIOS boot" partition')."
    cfdisk "$DISK" </dev/tty >/dev/tty 2>&1 || warn "cfdisk exited with an error."
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle
  fi

  pick_partition ROOT_PART "Partition for / (it WILL be formatted as $FILESYSTEM)"

  ESP_PART=""
  if [[ $BOOT_MODE == uefi || $BOOT_MODE == none ]]; then
    if [[ $BOOT_MODE == uefi ]]; then
      pick_partition ESP_PART "EFI system partition"
    else
      pick_partition ESP_PART "Boot partition for the board firmware (FAT32)" allow-none
    fi
  fi
  if [[ -n $ESP_PART ]]; then
    fstype=$(blkid -s TYPE -o value "$ESP_PART" 2>/dev/null || true)
    def=yes
    if [[ $fstype == vfat ]]; then
      def=no
      info "$ESP_PART already holds a FAT file system - probably an EFI partition shared with"
      info "another OS. Keep it (answer no) so that system's boot loader survives."
    fi
    # Always asked, never taken from an answers file: formatting a shared ESP
    # would destroy the other system's boot loader.
    FORMAT_ESP=""
    FORCE_ASK=1 yesno FORMAT_ESP "Format $ESP_PART as FAT32?" "$def"
    size_mib=$(( $(blockdev --getsize64 "$ESP_PART") / 1048576 ))
    if (( size_mib < 400 )); then
      warn "$ESP_PART is only $size_mib MiB, too small for kernels: it will be mounted at /efi"
      warn "and kernels stay on the root file system (GRUB only)."
      _store ESP_MOUNT /efi
    else
      choose ESP_MOUNT "Mount the EFI partition at" \
        "/boot|/boot - kernels live on the ESP (works with systemd-boot and GRUB)" \
        "/efi|/efi   - kernels stay on the root file system (GRUB only)"
    fi
  else
    _store ESP_MOUNT /boot
    _store FORMAT_ESP no
  fi

  BOOT_PART=""
  if [[ $ENCRYPT == yes ]] && [[ $BOOT_MODE == bios || $ESP_MOUNT == /efi ]]; then
    info "An encrypted root needs an unencrypted /boot here so the boot loader can read the kernel."
    pick_partition BOOT_PART "Partition for /boot (it WILL be formatted as ext4, ~1 GiB)"
  fi

  SWAP_PART=""
  if [[ $SWAP == partition ]]; then
    pick_partition SWAP_PART "Swap partition (it WILL be formatted)"
  fi

  # Sanity checks - crash early, before anything is written.
  local -A seen=()
  for p in "$ROOT_PART" "$ESP_PART" "$BOOT_PART" "$SWAP_PART"; do
    [[ -z $p ]] && continue
    if [[ -n ${seen[$p]-} ]]; then warn "$p was chosen twice."; return 1; fi
    seen[$p]=1
    if findmnt -rn -S "$p" >/dev/null 2>&1; then warn "$p is mounted; unmount it first."; return 1; fi
  done
  if [[ -n $BOOT_PART ]]; then q=$BOOT_PART; else q=$ROOT_PART; fi
  GRUB_DISK=$(parent_disk "$q")
  disk_facts "$(parent_disk "$ROOT_PART")"
  if [[ $BOOT_MODE == bios && $(lsblk -dno PTTYPE "$GRUB_DISK") == gpt ]] &&
     ! grep -qi 21686148-6449-6e6f-744e-656564454649 <<<"$(lsblk -lno PARTTYPE "$GRUB_DISK")"; then
    warn "GRUB on a GPT disk in BIOS mode needs a 1 MiB partition of type 'BIOS boot' on $GRUB_DISK."
    return 1
  fi
  return 0
}

plan_manual_layout() {
  if pick_manual_parts; then return 0; fi
  until FORCE_ASK=1 pick_manual_parts; do :; done
}

# §2.1 Select the mirrors
plan_mirrors() {
  section "§2.1 Mirrors"
  local opts=("keep|Keep the current mirror list")
  if [[ $ARCH == x86_64 ]]; then opts+=("reflector|Pick the fastest up-to-date mirrors for my country (reflector)"); fi
  opts+=("edit|Edit the mirror list by hand now")
  choose MIRRORS "Mirror list (it is copied to the new system)" "${opts[@]}"
  case $MIRRORS in
    keep) ;;
    reflector)
      ensure_tool reflector reflector
      ask MIRROR_COUNTRY "Country name or code (several: comma-separated, e.g. PK,SG)"
      systemctl stop reflector.service 2>/dev/null || true
      cp /etc/pacman.d/mirrorlist /tmp/mirrorlist.bak
      info "Ranking mirrors (this can take a minute)"
      if reflector --country "$MIRROR_COUNTRY" --protocol https --age 24 --latest 20 \
           --sort rate --save /etc/pacman.d/mirrorlist &&
         grep -q '^Server' /etc/pacman.d/mirrorlist; then
        ok "Mirror list updated"
      else
        warn "reflector failed; keeping the previous mirror list."
        cp /tmp/mirrorlist.bak /etc/pacman.d/mirrorlist
      fi
      ;;
    edit) nano /etc/pacman.d/mirrorlist </dev/tty >/dev/tty 2>&1 || true ;;
    *) die "Unexpected choice: $MIRRORS" ;;
  esac
  pacman -Sy --noconfirm >/dev/null
}

detect_gpus() {
  GPU_VENDORS=""
  command -v lspci >/dev/null || return 0
  local l
  l=$(lspci -mm 2>/dev/null | grep -E '"(VGA compatible controller|3D controller|Display controller)"' || true)
  if [[ $l == *NVIDIA* ]]; then GPU_VENDORS+=" nvidia"; fi
  if [[ $l == *"Advanced Micro Devices"* || $l == *ATI* || $l == *AMD* ]]; then GPU_VENDORS+=" amd"; fi
  if [[ $l == *Intel* ]]; then GPU_VENDORS+=" intel"; fi
  return 0
}

# §2.2 Install essential packages
plan_packages() {
  section "§2.2 Kernel and software"
  case $ARCH in
    x86_64)
      choose KERNEL "Kernel" \
        "linux|linux          - latest stable" \
        "linux-lts|linux-lts      - long-term support" \
        "linux-zen|linux-zen      - tuned for desktops" \
        "linux-hardened|linux-hardened - security-focused" ;;
    i686)    choose KERNEL "Kernel" "linux|linux" "linux-lts|linux-lts" ;;
    aarch64) choose KERNEL "Kernel" "linux-aarch64|linux-aarch64 - generic ARMv8" "linux-rpi|linux-rpi - Raspberry Pi" ;;
    armv7h)  choose KERNEL "Kernel" "linux-armv7|linux-armv7 - generic ARMv7" "linux-rpi|linux-rpi - Raspberry Pi" ;;
    riscv64) choose KERNEL "Kernel" "linux|linux" ;;
    *)       die "Unexpected architecture: $ARCH" ;;
  esac

  if [[ $VIRT == none ]]; then
    yesno FIRMWARE "Install linux-firmware (needed on real hardware)?" yes
  else
    yesno FIRMWARE "Install linux-firmware? (not needed in a $VIRT virtual machine)" no
  fi

  if [[ $ARCH == x86_64 || $ARCH == i686 ]]; then
    local first=none
    if [[ $CPU_VENDOR == GenuineIntel ]]; then first=intel-ucode; fi
    if [[ $CPU_VENDOR == AuthenticAMD ]]; then first=amd-ucode; fi
    if [[ $VIRT != none ]]; then first=none; fi
    if [[ $PORTABLE == yes ]]; then first=both; fi
    local -a mc=("intel-ucode|Intel microcode" "amd-ucode|AMD microcode"
                 "both|Both (portable installs)" "none|None (virtual machine)")
    local -a ordered=()
    local m
    for m in "${mc[@]}"; do if [[ ${m%%|*} == "$first" ]]; then ordered=("$m" "${ordered[@]}"); else ordered+=("$m"); fi; done
    choose MICROCODE "CPU microcode updates (detected: ${CPU_VENDOR:-unknown}, $VIRT)" "${ordered[@]}"
    if [[ $VIRT == none ]]; then
      yesno SOF_FIRMWARE "Install sof-firmware (onboard audio on most laptops since ~2018)?" yes
    else
      _store SOF_FIRMWARE no
    fi
  else
    _store MICROCODE none
    _store SOF_FIRMWARE no
  fi

  choose TEXT_EDITOR "Console text editor" "nano|nano" "vim|vim" "neovim|neovim" "micro|micro"

  choose NETWORK "Networking on the installed system" \
    "networkmanager|NetworkManager - Wi-Fi/Ethernet/VPN, nmtui (desktops, laptops)" \
    "networkd|systemd-networkd + iwd - minimal (servers, VMs)" \
    "none|None - I will set it up myself"

  choose DESKTOP "Desktop" \
    "none|None - console only" \
    "gnome|GNOME" \
    "kde|KDE Plasma" \
    "xfce|Xfce (lightweight)"
  if [[ $DESKTOP != none && $NETWORK == networkd ]]; then
    warn "Desktops integrate best with NetworkManager (you chose systemd-networkd)."
  fi

  if [[ $DESKTOP != none && $ARCH == x86_64 ]]; then
    detect_gpus
    info "Graphics detected:${GPU_VENDORS:- none}"
    if [[ $GPU_VENDORS == *nvidia* ]]; then
      choose GPU_DRIVER "NVIDIA driver" \
        "nvidia-open|NVIDIA (open kernel modules) - GTX 16xx / RTX 20xx and newer" \
        "nouveau|nouveau (open source) - older cards"
    else
      _store GPU_DRIVER mesa
    fi
  else
    _store GPU_DRIVER mesa
  fi

  case $VIRT in
    kvm|qemu|oracle|vmware) yesno GUEST_TOOLS "Install guest tools for $VIRT?" yes ;;
    *) _store GUEST_TOOLS no ;;
  esac

  if [[ $ARCH == x86_64 ]]; then
    yesno MULTILIB "Enable the multilib repository (32-bit apps like Steam or Wine)?" no
    if [[ $MULTILIB == yes ]]; then enable_multilib /etc/pacman.conf; pacman -Sy --noconfirm >/dev/null; fi
  else
    _store MULTILIB no
  fi

  ask EXTRA_PACKAGES "Extra packages, space-separated (e.g. git base-devel openssh; - for none)" "" \
    valid_packages optional
}

# §3.3 - §3.5 Time, localization, network name
plan_system() {
  section "§3.3-3.5 Time zone, locale, host name"
  ask TIMEZONE "Time zone (e.g. Asia/Karachi, Europe/Berlin; ? lists regions)" UTC valid_tz
  ask LOCALES "Locales, space-separated, first one is the default (? lists all)" en_US.UTF-8 valid_locales
  ask HOST_NAME "Host name" archlinux valid_hostname
}

# §3.7 Root password (+ an everyday user, from "General recommendations")
plan_users() {
  section "§3.7 Accounts"
  yesno SET_ROOT_PW "Set a root password? (no = root login locked, use sudo instead)" yes
  if [[ $SET_ROOT_PW == no || $DESKTOP != none ]]; then
    info "A regular user with sudo rights is required with this setup."
    ask USERNAME "Username" "" valid_username
  else
    ask USERNAME "Regular user with sudo rights (- for none)" "" valid_username optional
  fi
}

# §3.8 Boot loader
plan_bootloader() {
  section "§3.8 Boot loader"
  local opts=()
  case $BOOT_MODE in
    none) _store BOOTLOADER none; info "Board firmware: install its boot loader yourself afterwards."; return 0 ;;
    bios) opts=("grub|GRUB") ;;
    uefi)
      if [[ $ESP_MOUNT == /boot ]] &&
         { [[ $ARCH == x86_64 && $UEFI_BITS == 64 ]] || [[ $ARCH == aarch64 ]]; }; then
        opts+=("systemd-boot|systemd-boot - simple and fast (UEFI only)")
      fi
      opts+=("grub|GRUB - themes, os-prober for dual boot") ;;
    *) die "Unexpected boot mode: $BOOT_MODE" ;;
  esac
  opts+=("none|No boot loader - I will install one myself")
  choose BOOTLOADER "Boot loader" "${opts[@]}"

  if [[ $BOOTLOADER == grub ]]; then
    local def=no
    if [[ $PART_MODE == manual ]]; then def=yes; fi
    yesno OS_PROBER "Look for other operating systems (dual boot) with os-prober?" "$def"
    if [[ $BOOT_MODE == uefi ]]; then
      def=no
      if [[ $PORTABLE == yes ]]; then def=yes; fi
      yesno REMOVABLE "Also install to the fallback path EFI/BOOT (USB drives, firmware that forgets entries)?" "$def"
    fi
  fi
}

compute_packages() {
  local -a p=(base "$KERNEL") extra=()
  local -A seen=()
  local x
  [[ $FIRMWARE == yes ]] && p+=(linux-firmware)
  [[ $SOF_FIRMWARE == yes ]] && p+=(sof-firmware)
  case $MICROCODE in
    intel-ucode|amd-ucode) p+=("$MICROCODE") ;;
    both) p+=(intel-ucode amd-ucode) ;;
  esac
  case $ARCH in
    i686)           p+=(archlinux32-keyring) ;;
    aarch64|armv7h) p+=(archlinuxarm-keyring) ;;
  esac
  case $FILESYSTEM in
    ext4)  p+=(e2fsprogs) ;;
    btrfs) p+=(btrfs-progs) ;;
    xfs)   p+=(xfsprogs) ;;
    f2fs)  p+=(f2fs-tools) ;;
  esac
  [[ -n $BOOT_PART || $PART_MODE == auto && $BOOT_MODE == bios && $ENCRYPT == yes ]] && p+=(e2fsprogs)
  [[ $BOOT_MODE != bios ]] && p+=(dosfstools)
  [[ $ENCRYPT == yes ]] && p+=(cryptsetup)
  [[ $SWAP == zram ]] && p+=(zram-generator)
  [[ $CONSOLE_FONT != default ]] && p+=(terminus-font)
  # Guide §2.2: an editor, and the documentation packages.
  p+=("$TEXT_EDITOR" man-db man-pages texinfo)
  [[ -n $USERNAME ]] && p+=(sudo)
  case $NETWORK in
    networkmanager) p+=(networkmanager) ;;
    networkd)       p+=(iwd) ;;
  esac
  case $BOOTLOADER in
    grub)
      p+=(grub)
      [[ $BOOT_MODE == uefi ]] && p+=(efibootmgr)
      [[ $OS_PROBER == yes ]] && p+=(os-prober) ;;
  esac
  case $DESKTOP in
    gnome) p+=(gnome) ;;
    kde)   p+=(plasma-meta sddm konsole dolphin) ;;
    xfce)  p+=(xorg-server xfce4 xfce4-goodies lightdm lightdm-gtk-greeter) ;;
  esac
  if [[ $DESKTOP != none ]]; then
    p+=(pipewire pipewire-alsa pipewire-pulse wireplumber noto-fonts)
    [[ $GPU_VENDORS == *intel* ]] && p+=(vulkan-intel intel-media-driver)
    [[ $GPU_VENDORS == *amd* ]] && p+=(vulkan-radeon)
    if [[ $GPU_DRIVER == nvidia-open ]]; then
      if [[ $KERNEL == linux ]]; then p+=(nvidia-open nvidia-utils)
      else p+=(nvidia-open-dkms nvidia-utils "$KERNEL-headers"); fi
    fi
  fi
  if [[ $GUEST_TOOLS == yes ]]; then
    case $VIRT in
      kvm|qemu) p+=(qemu-guest-agent) ;;
      oracle)   p+=(virtualbox-guest-utils) ;;
      vmware)   p+=(open-vm-tools) ;;
    esac
  fi
  read -ra extra <<<"$EXTRA_PACKAGES"
  p+=("${extra[@]}")

  PKGS=()
  for x in "${p[@]}"; do
    if [[ -z $x || -n ${seen[$x]-} ]]; then continue; fi
    seen[$x]=1
    PKGS+=("$x")
  done
}

# Cross-checks between sections; re-asks whatever is inconsistent.
validate_plan() {
  if [[ -z $USERNAME ]] && [[ $SET_ROOT_PW == no || $DESKTOP != none ]]; then
    warn "A regular user is required (root is locked or a desktop was chosen)."
    FORCE_ASK=1 ask USERNAME "Username" "" valid_username
  fi
  if [[ $BOOTLOADER == systemd-boot && $ESP_MOUNT != /boot ]]; then
    warn "systemd-boot needs the EFI partition mounted at /boot."
    FORCE_ASK=1 plan_bootloader
  fi
  compute_packages
  local x missing=()
  info "Checking that all ${#PKGS[@]} packages exist in the repositories..."
  for x in "${PKGS[@]}"; do
    if ! pkg_exists "$x"; then missing+=("$x"); fi
  done
  if (( ${#missing[@]} )); then
    local core=()
    for x in "${missing[@]}"; do
      if [[ " $EXTRA_PACKAGES " != *" $x "* ]]; then core+=("$x"); fi
    done
    if (( ${#core[@]} )); then
      die "Required packages not available for $ARCH: ${core[*]}. Check the mirror list / repositories."
    fi
    warn "Extra packages not found: ${missing[*]}"
    FORCE_ASK=1 ask EXTRA_PACKAGES "Extra packages (- for none)" "$EXTRA_PACKAGES" valid_packages optional
    compute_packages
  fi
  ok "All packages available"
}

layout_lines() {
  local n=1 size
  if [[ $PART_MODE == auto ]]; then
    printf '  %s will be ERASED and get a new %s partition table:\n' "$DISK" "${PART_TABLE^^}"
    if [[ $PART_TABLE == gpt && $BOOT_MODE == bios ]]; then
      printf '    %-16s %-10s %s\n' "$(part $n)" "1 MiB" "BIOS boot (for GRUB)"; n=$((n + 1))
    elif [[ $BOOT_MODE != bios ]]; then
      printf '    %-16s %-10s %s\n' "$(part $n)" "$ESP_SIZE MiB" "EFI system, FAT32 -> /boot"; n=$((n + 1))
    fi
    if [[ $BOOT_MODE == bios && $ENCRYPT == yes ]]; then
      printf '    %-16s %-10s %s\n' "$(part $n)" "1 GiB" "/boot, ext4 (unencrypted)"; n=$((n + 1))
    fi
    if [[ $SWAP == partition ]]; then
      printf '    %-16s %-10s %s\n' "$(part $n)" "$SWAP_SIZE GiB" "swap"; n=$((n + 1))
    fi
    size="rest"
    printf '    %-16s %-10s %s\n' "$(part $n)" "$size" \
      "/ $FILESYSTEM$([[ $ENCRYPT == yes ]] && printf ' inside LUKS2')"
  else
    printf '  Existing partitions (format = erase):\n'
    printf '    %-16s %s\n' "$ROOT_PART" "/ - FORMAT as $FILESYSTEM$([[ $ENCRYPT == yes ]] && printf ' inside LUKS2')"
    if [[ -n $ESP_PART ]]; then
      printf '    %-16s %s\n' "$ESP_PART" "$ESP_MOUNT - $([[ $FORMAT_ESP == yes ]] && printf 'FORMAT as FAT32' || printf 'keep contents')"
    fi
    if [[ -n $BOOT_PART ]]; then printf '    %-16s %s\n' "$BOOT_PART" "/boot - FORMAT as ext4"; fi
    if [[ -n $SWAP_PART ]]; then printf '    %-16s %s\n' "$SWAP_PART" "swap - FORMAT"; fi
  fi
}

row() { printf '  %-18s %s\n' "$1" "$2"; }

show_summary() {
  section "Summary"
  row "Platform" "$ARCH, $BOOT_MODE${UEFI_BITS:+ ($UEFI_BITS-bit)}, virt: $VIRT"
  row "Disk" "$DISK ($(human_size "$DISK"), $(media_kind "$DISK" "$ROTATIONAL" "$DISK_TRAN"))"
  layout_lines
  row "File system" "$FILESYSTEM$([[ $ROTATIONAL == 0 ]] && printf ', flash-friendly options (noatime, weekly TRIM)')"
  row "Encryption" "$ENCRYPT"
  row "Swap" "$SWAP$([[ $SWAP == file || $SWAP == partition ]] && printf ' (%s GiB)' "$SWAP_SIZE")"
  row "Portable" "$PORTABLE"
  row "Kernel" "$KERNEL"
  row "Microcode" "$MICROCODE"
  row "Network" "$NETWORK"
  row "Desktop" "$DESKTOP$([[ $DESKTOP != none ]] && printf ' (graphics: %s)' "$GPU_DRIVER")"
  row "Boot loader" "$BOOTLOADER$([[ $BOOTLOADER == grub && $OS_PROBER == yes ]] && printf ' + os-prober')"
  row "Time zone" "$TIMEZONE"
  row "Locales" "$LOCALES"
  row "Keymap / font" "$KEYMAP / $CONSOLE_FONT"
  row "Host name" "$HOST_NAME"
  row "Root password" "$SET_ROOT_PW"
  row "User" "${USERNAME:-(none)}"
  row "Packages" "${PKGS[*]}"
}

review_loop() {
  local REVIEW="" EDIT=""
  while :; do
    validate_plan
    show_summary
    FORCE_ASK=1 choose REVIEW "What next?" \
      "install|Continue" \
      "edit|Change something" \
      "save|Save these answers to $ANSWERS_OUT and quit" \
      "quit|Quit without changing anything"
    case $REVIEW in
      install) return 0 ;;
      save)    save_config; ok "Saved to $ANSWERS_OUT"; exit 0 ;;
      quit)    info "Nothing was changed."; exit 0 ;;
      edit)
        FORCE_ASK=1 choose EDIT "Which part?" \
          "storage|Disk, layout, file system, encryption, swap" \
          "mirrors|Mirrors" \
          "packages|Kernel, firmware, network, desktop, extra packages" \
          "system|Keymap, font, time zone, locales, host name" \
          "users|Accounts" \
          "boot|Boot loader"
        case $EDIT in
          storage)  FORCE_ASK=1 select_disk; FORCE_ASK=1 plan_storage; plan_bootloader ;;
          mirrors)  FORCE_ASK=1 plan_mirrors ;;
          packages) FORCE_ASK=1 plan_packages ;;
          system)   FORCE_ASK=1 setup_console; FORCE_ASK=1 plan_system ;;
          users)    FORCE_ASK=1 plan_users ;;
          boot)     FORCE_ASK=1 plan_bootloader ;;
          *)        die "Unexpected choice: $EDIT" ;;
        esac ;;
      *) die "Unexpected choice: $REVIEW" ;;
    esac
  done
}

collect_secrets() {
  section "Passwords"
  if [[ $ENCRYPT == yes ]]; then secret LUKS_PASS "disk encryption passphrase"; fi
  if [[ $SET_ROOT_PW == yes ]]; then secret ROOT_PASS "root password"; fi
  if [[ -n $USERNAME ]]; then secret USER_PASS "password for $USERNAME"; fi
}

confirm_destruction() {
  section "Last chance"
  layout_lines
  if [[ $PART_MODE == auto ]]; then
    warn "EVERYTHING on $DISK ($(human_size "$DISK") $(lsblk -dno MODEL "$DISK" 2>/dev/null)) will be destroyed."
    prompt_line "Type the disk name '$DISK_NAME' to start: "
    [[ $REPLY == "$DISK_NAME" ]] || die "Aborted - nothing was changed."
  else
    warn "The partitions marked FORMAT above will be erased."
    prompt_line "Type YES to start: "
    [[ $REPLY == YES ]] || die "Aborted - nothing was changed."
  fi
}

# ================================================================== installation

free_disk() {
  local p
  if [[ -n $(swapon --show=NAME --noheadings 2>/dev/null | grep "^$DISK" || true) ]]; then
    for p in $(swapon --show=NAME --noheadings | grep "^$DISK"); do swapoff "$p"; done
  fi
  if [[ -n $(findmnt -rno SOURCE | grep "^$DISK" || true) ]]; then
    die "Partitions of $DISK are mounted; unmount them first."
  fi
}

# §1.9 Partition the disks
partition_auto() {
  section "§1.9 Partitioning $DISK"
  local n=1 root_type p
  free_disk
  for p in $(lsblk -lnpo NAME "$DISK" | tail -n +2); do wipefs -aq "$p" || true; done
  wipefs -aq "$DISK"
  if [[ $TRIM_DISK == yes ]]; then
    info "Discarding all blocks on $DISK"
    blkdiscard -f "$DISK" 2>/dev/null || warn "TRIM not supported here; continuing."
  fi

  # GPT type codes: the "Linux root" type for the CPU architecture lets
  # systemd find the root partition automatically.
  case $ARCH in
    x86_64)  root_type=8304 ;;
    i686)    root_type=8303 ;;
    aarch64) root_type=8305 ;;
    *)       root_type=8300 ;;
  esac

  if [[ $PART_TABLE == gpt ]]; then
    sgdisk --zap-all "$DISK" >/dev/null
    if [[ $BOOT_MODE == bios ]]; then
      sgdisk -n "$n:0:+1M" -t "$n:ef02" -c "$n:BIOS boot" "$DISK" >/dev/null; n=$((n + 1))
    else
      sgdisk -n "$n:0:+${ESP_SIZE}M" -t "$n:ef00" -c "$n:EFI system" "$DISK" >/dev/null
      ESP_PART=$(part $n); n=$((n + 1))
    fi
    if [[ $BOOT_MODE == bios && $ENCRYPT == yes ]]; then
      sgdisk -n "$n:0:+1G" -t "$n:8300" -c "$n:boot" "$DISK" >/dev/null
      BOOT_PART=$(part $n); n=$((n + 1))
    fi
    if [[ $SWAP == partition ]]; then
      sgdisk -n "$n:0:+${SWAP_SIZE}G" -t "$n:8200" -c "$n:swap" "$DISK" >/dev/null
      SWAP_PART=$(part $n); n=$((n + 1))
    fi
    sgdisk -n "$n:0:0" -t "$n:$root_type" -c "$n:root" "$DISK" >/dev/null
    ROOT_PART=$(part $n)
  else
    local script=$'label: dos\n'
    if [[ $ENCRYPT == yes ]]; then
      script+=$'size=1GiB, type=83, bootable\n'; BOOT_PART=$(part $n); n=$((n + 1))
    fi
    if [[ $SWAP == partition ]]; then
      script+="size=${SWAP_SIZE}GiB, type=82"$'\n'; SWAP_PART=$(part $n); n=$((n + 1))
    fi
    if [[ -n $BOOT_PART ]]; then script+=$'type=83\n'; else script+=$'type=83, bootable\n'; fi
    ROOT_PART=$(part $n)
    sfdisk -q --wipe always "$DISK" <<<"$script"
  fi

  partprobe "$DISK" 2>/dev/null || true
  udevadm settle
  for p in "$ESP_PART" "$BOOT_PART" "$SWAP_PART" "$ROOT_PART"; do
    if [[ -n $p ]]; then wait_for_dev "$p"; fi
  done
  lsblk -o NAME,SIZE,PARTTYPENAME "$DISK"
}

# §1.10 Format the partitions  +  §1.11 Mount the file systems
format_and_mount() {
  section "§1.10 Format / §1.11 Mount"
  ROOT_DEV=$ROOT_PART
  if [[ $ENCRYPT == yes ]]; then
    info "Encrypting $ROOT_PART with LUKS2"
    wipefs -aq "$ROOT_PART"
    printf '%s' "$LUKS_PASS" |
      cryptsetup luksFormat --type luks2 --batch-mode --label cryptroot --key-file=- "$ROOT_PART"
    # On flash, let TRIM pass through the encryption layer; stored in the LUKS
    # header (--persistent) so every later unlock keeps it.
    local -a open_opts=()
    if [[ $ROTATIONAL == 0 ]]; then open_opts=(--allow-discards --persistent); fi
    printf '%s' "$LUKS_PASS" | cryptsetup open "${open_opts[@]}" --key-file=- "$ROOT_PART" "$CRYPT_NAME"
    ROOT_DEV=/dev/mapper/$CRYPT_NAME
  fi

  info "Creating $FILESYSTEM on $ROOT_DEV"
  case $FILESYSTEM in
    ext4)  mkfs.ext4 -q -F -L archroot "$ROOT_DEV" ;;
    btrfs) mkfs.btrfs -q -f -L archroot "$ROOT_DEV" ;;
    xfs)   mkfs.xfs -q -f -L archroot "$ROOT_DEV" ;;
    f2fs)  mkfs.f2fs -q -f -l archroot "$ROOT_DEV" ;;
    *)     die "Unexpected file system: $FILESYSTEM" ;;
  esac
  # Only format the ESP if we created it or the user said so (guide §1.10 warning).
  if [[ -n $ESP_PART && $FORMAT_ESP == yes ]]; then mkfs.fat -F 32 -n EFI "$ESP_PART" >/dev/null; fi
  if [[ -n $BOOT_PART ]]; then mkfs.ext4 -q -F -L boot "$BOOT_PART"; fi
  if [[ -n $SWAP_PART ]]; then mkswap -q -L swap "$SWAP_PART"; fi

  # noatime: skip a metadata write on every read (less wear on flash, faster on HDD).
  if [[ $FILESYSTEM == btrfs ]]; then
    local sv o="noatime,compress=zstd"
    mount "$ROOT_DEV" "$MNT"
    for sv in @ @home @log @pkg @snapshots; do btrfs -q subvolume create "$MNT/$sv"; done
    if [[ $SWAP == file ]]; then btrfs -q subvolume create "$MNT/@swap"; fi
    umount "$MNT"
    mount -o "$o,subvol=@" "$ROOT_DEV" "$MNT"
    mount --mkdir -o "$o,subvol=@home" "$ROOT_DEV" "$MNT/home"
    mount --mkdir -o "$o,subvol=@log" "$ROOT_DEV" "$MNT/var/log"
    mount --mkdir -o "$o,subvol=@pkg" "$ROOT_DEV" "$MNT/var/cache/pacman/pkg"
    mount --mkdir -o "$o,subvol=@snapshots" "$ROOT_DEV" "$MNT/.snapshots"
    if [[ $SWAP == file ]]; then mount --mkdir -o "noatime,subvol=@swap" "$ROOT_DEV" "$MNT/swap"; fi
  else
    mount -o noatime "$ROOT_DEV" "$MNT"
  fi
  if [[ -n $BOOT_PART ]]; then mount --mkdir "$BOOT_PART" "$MNT/boot"; fi
  if [[ -n $ESP_PART ]]; then mount --mkdir -o fmask=0077,dmask=0077 "$ESP_PART" "$MNT$ESP_MOUNT"; fi
  if [[ -n $SWAP_PART ]]; then swapon "$SWAP_PART"; fi

  if [[ $SWAP == file ]]; then
    info "Creating a $SWAP_SIZE GiB swap file"
    if [[ $FILESYSTEM == btrfs ]]; then
      btrfs filesystem mkswapfile --size "${SWAP_SIZE}g" --uuid clear "$MNT/swap/swapfile" >/dev/null
      SWAPFILE=/swap/swapfile
    else
      mkswap -q --file -U clear --size "${SWAP_SIZE}G" "$MNT/swapfile"
      SWAPFILE=/swapfile
    fi
  fi
  findmnt -R "$MNT"
}

# Files the kernel's initramfs build reads; written before pacstrap so the
# first mkinitcpio run already uses them.
write_early_config() {
  mkdir -p "$MNT/etc"
  {
    printf 'KEYMAP=%s\n' "$KEYMAP"
    if [[ $CONSOLE_FONT != default ]]; then printf 'FONT=%s\n' "$CONSOLE_FONT"; fi
  } >"$MNT/etc/vconsole.conf"
  printf 'LANG=%s\n' "${LOCALES%% *}" >"$MNT/etc/locale.conf"
}

# §2.2 Install essential packages
install_packages() {
  section "§2.2 Installing packages"
  info "${PKGS[*]}"
  pacstrap -K "$MNT" "${PKGS[@]}"
  sed -i -E 's/^#?ParallelDownloads.*/ParallelDownloads = 5/' "$MNT/etc/pacman.conf"
  if [[ $MULTILIB == yes ]]; then enable_multilib "$MNT/etc/pacman.conf"; fi
}

# §3.1 Fstab
write_fstab() {
  section "§3.1 fstab"
  genfstab -U "$MNT" >>"$MNT/etc/fstab"
  if [[ -n $SWAPFILE ]]; then printf '%s none swap defaults 0 0\n' "$SWAPFILE" >>"$MNT/etc/fstab"; fi
  grep -v '^#' "$MNT/etc/fstab" | sed '/^$/d' || true
}

# §3.3 - §3.5 (+ services)
configure_system() {
  section "§3.3-3.5 Time, locale, network"
  local l esc
  # §3.3 Time
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$MNT/etc/localtime"
  arch-chroot "$MNT" hwclock --systohc || warn "hwclock failed (common in VMs); /etc/adjtime not written."
  SERVICES=(systemd-timesyncd.service)

  # §3.4 Localization
  for l in $LOCALES; do
    esc=${l//./\\.}
    if grep -q "^#\?$esc UTF-8" "$MNT/etc/locale.gen"; then
      sed -i "s/^#\($esc UTF-8\)/\1/" "$MNT/etc/locale.gen"
    else
      printf '%s UTF-8\n' "$l" >>"$MNT/etc/locale.gen"
    fi
  done
  arch-chroot "$MNT" locale-gen

  # §3.5 Network configuration
  printf '%s\n' "$HOST_NAME" >"$MNT/etc/hostname"
  cat >"$MNT/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOST_NAME.localdomain $HOST_NAME
EOF
  case $NETWORK in
    networkmanager) SERVICES+=(NetworkManager.service) ;;
    networkd)
      mkdir -p "$MNT/etc/systemd/network"
      cat >"$MNT/etc/systemd/network/20-wired.network" <<'EOF'
[Match]
Name=en* eth*

[Link]
RequiredForOnline=routable

[Network]
DHCP=yes
EOF
      cat >"$MNT/etc/systemd/network/25-wireless.network" <<'EOF'
[Match]
Name=wl*

[Link]
RequiredForOnline=routable

[Network]
DHCP=yes
IgnoreCarrierLoss=3s
EOF
      ln -sf /run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"
      # Carry over Wi-Fi networks joined in the live system.
      if compgen -G '/var/lib/iwd/*' >/dev/null; then
        mkdir -p "$MNT/var/lib/iwd"
        cp -a /var/lib/iwd/. "$MNT/var/lib/iwd/"
      fi
      SERVICES+=(systemd-networkd.service systemd-resolved.service iwd.service) ;;
  esac

  if [[ $SWAP == zram ]]; then
    cat >"$MNT/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF
  fi
  # Weekly TRIM instead of continuous discard: keeps flash fast without a cost on every delete.
  if [[ $ROTATIONAL == 0 ]]; then SERVICES+=(fstrim.timer); fi
  case $DESKTOP in
    gnome) SERVICES+=(gdm.service) ;;
    kde)   SERVICES+=(sddm.service) ;;
    xfce)  SERVICES+=(lightdm.service) ;;
  esac
  if [[ $GUEST_TOOLS == yes ]]; then
    case $VIRT in
      oracle) SERVICES+=(vboxservice.service) ;;
      vmware) SERVICES+=(vmtoolsd.service) ;;
    esac
  fi
}

# §3.6 Initramfs
configure_initramfs() {
  section "§3.6 Initramfs"
  local conf=$MNT/etc/mkinitcpio.conf
  if grep -Eq '^HOOKS=.*\bsystemd\b' "$conf"; then HOOK_STYLE=systemd; else HOOK_STYLE=busybox; fi
  if [[ $ENCRYPT == yes ]]; then
    if [[ $HOOK_STYLE == systemd ]]; then
      sed -i -E '/^HOOKS=/ s/\bfilesystems\b/sd-encrypt filesystems/' "$conf"
    else
      sed -i -E '/^HOOKS=/ s/\bfilesystems\b/encrypt filesystems/' "$conf"
    fi
    grep -Eq '^HOOKS=.*encrypt' "$conf" || die "Could not add the encrypt hook to $conf."
  fi
  if [[ $PORTABLE == yes ]]; then
    # Without autodetect the initramfs carries drivers for any machine, not just this one.
    sed -i -E '/^HOOKS=/ s/ autodetect//' "$conf"
  fi
  grep '^HOOKS=' "$conf"
  arch-chroot "$MNT" mkinitcpio -P
}

kernel_params() { # $1 = full (systemd-boot) | crypt (GRUB adds root= itself)
  local -a p=()
  if [[ $ENCRYPT == yes ]]; then
    local luks_uuid
    luks_uuid=$(blkid -s UUID -o value "$ROOT_PART")
    if [[ $HOOK_STYLE == systemd ]]; then p+=("rd.luks.name=$luks_uuid=$CRYPT_NAME")
    else p+=("cryptdevice=UUID=$luks_uuid:$CRYPT_NAME"); fi
    if [[ $1 == full ]]; then p+=("root=/dev/mapper/$CRYPT_NAME"); fi
  elif [[ $1 == full ]]; then
    p+=("root=UUID=$(blkid -s UUID -o value "$ROOT_DEV")")
  fi
  if [[ $1 == full ]]; then
    if [[ $FILESYSTEM == btrfs ]]; then p+=(rootflags=subvol=@); fi
    p+=(rw)
  fi
  # zswap would compress pages before they reach zram - disable it (ArchWiki: zram).
  if [[ $SWAP == zram ]]; then p+=(zswap.enabled=0); fi
  printf '%s' "${p[*]}"
}

grub_target() {
  if [[ $BOOT_MODE == bios ]]; then echo i386-pc; return 0; fi
  case $ARCH in
    x86_64)  if [[ $UEFI_BITS == 32 ]]; then echo i386-efi; else echo x86_64-efi; fi ;;
    i686)    if [[ $UEFI_BITS == 64 ]]; then echo x86_64-efi; else echo i386-efi; fi ;;
    aarch64) echo arm64-efi ;;
    armv7h)  echo arm-efi ;;
    riscv64) echo riscv64-efi ;;
    *)       die "No GRUB target for $ARCH" ;;
  esac
}

install_systemd_boot() {
  arch-chroot "$MNT" bootctl install
  local img initrd="" opts ucode_lines="" u
  opts=$(kernel_params full)
  if [[ -e $MNT/boot/vmlinuz-$KERNEL ]]; then img=/vmlinuz-$KERNEL
  elif [[ -e $MNT/boot/Image ]]; then img=/Image
  else die "Kernel image not found in $MNT/boot."; fi
  if [[ -e $MNT/boot/initramfs-$KERNEL.img ]]; then initrd=/initramfs-$KERNEL.img
  elif [[ -e $MNT/boot/initramfs-linux.img ]]; then initrd=/initramfs-linux.img
  else die "initramfs not found in $MNT/boot."; fi
  # Newer mkinitcpio embeds microcode via its "microcode" hook; otherwise load it first.
  if ! grep -Eq '^HOOKS=.*\bmicrocode\b' "$MNT/etc/mkinitcpio.conf"; then
    for u in intel-ucode amd-ucode; do
      if [[ -e $MNT/boot/$u.img ]]; then ucode_lines+="initrd  /$u.img"$'\n'; fi
    done
  fi

  cat >"$MNT/boot/loader/loader.conf" <<EOF
default  arch.conf
timeout  3
console-mode max
editor   no
EOF
  cat >"$MNT/boot/loader/entries/arch.conf" <<EOF
title   Arch Linux ($KERNEL)
linux   $img
${ucode_lines}initrd  $initrd
options $opts
EOF
  if [[ -e $MNT/boot/${initrd%.img}-fallback.img ]]; then
    cat >"$MNT/boot/loader/entries/arch-fallback.conf" <<EOF
title   Arch Linux ($KERNEL, fallback initramfs)
linux   $img
${ucode_lines}initrd  ${initrd%.img}-fallback.img
options $opts
EOF
  fi
  SERVICES+=(systemd-boot-update.service)
}

install_grub() {
  local target params
  target=$(grub_target)
  if [[ $BOOT_MODE == uefi ]]; then
    arch-chroot "$MNT" grub-install --target="$target" --efi-directory="$ESP_MOUNT" --bootloader-id=GRUB
    if [[ $REMOVABLE == yes ]]; then
      arch-chroot "$MNT" grub-install --target="$target" --efi-directory="$ESP_MOUNT" --removable
    fi
  else
    arch-chroot "$MNT" grub-install --target=i386-pc "$GRUB_DISK"
  fi
  params=$(kernel_params crypt)
  sed -i -E "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$params\"|" "$MNT/etc/default/grub"
  if [[ $OS_PROBER == yes ]]; then
    sed -i -E 's/^#?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$MNT/etc/default/grub"
    grep -q '^GRUB_DISABLE_OS_PROBER=false' "$MNT/etc/default/grub" ||
      printf 'GRUB_DISABLE_OS_PROBER=false\n' >>"$MNT/etc/default/grub"
  fi
  arch-chroot "$MNT" grub-mkconfig -o /boot/grub/grub.cfg
}

# §3.8 Boot loader
install_bootloader() {
  section "§3.8 Boot loader: $BOOTLOADER"
  case $BOOTLOADER in
    systemd-boot) install_systemd_boot ;;
    grub)         install_grub ;;
    none)         warn "No boot loader installed - add one before rebooting." ;;
    *)            die "Unexpected boot loader: $BOOTLOADER" ;;
  esac
}

# §3.7 Root password (+ everyday user)
setup_accounts() {
  section "§3.7 Accounts"
  if [[ $SET_ROOT_PW == yes ]]; then
    printf 'root:%s\n' "$ROOT_PASS" | arch-chroot "$MNT" chpasswd
  else
    arch-chroot "$MNT" passwd -l root >/dev/null
  fi
  if [[ -n $USERNAME ]]; then
    arch-chroot "$MNT" useradd -m -G wheel -s /bin/bash "$USERNAME"
    printf '%s:%s\n' "$USERNAME" "$USER_PASS" | arch-chroot "$MNT" chpasswd
    printf '%%wheel ALL=(ALL:ALL) ALL\n' >"$MNT/etc/sudoers.d/10-wheel"
    chmod 0440 "$MNT/etc/sudoers.d/10-wheel"
    arch-chroot "$MNT" visudo -cq || die "sudoers check failed."
    ok "User $USERNAME created (sudo via the wheel group)"
  fi
  ROOT_PASS="" USER_PASS="" LUKS_PASS=""
}

enable_services() {
  section "Services"
  local s
  for s in "${SERVICES[@]}"; do
    if arch-chroot "$MNT" systemctl enable "$s" >/dev/null 2>&1; then ok "$s"
    else warn "Could not enable $s"; fi
  done
}

run_post_script() {
  [[ -n $POST_SCRIPT ]] || return 0
  section "Post-install script"
  install -m 0755 "$POST_SCRIPT" "$MNT/root/post-install.sh"
  arch-chroot "$MNT" env USERNAME="$USERNAME" HOST_NAME="$HOST_NAME" /root/post-install.sh ||
    warn "The post-install script failed; the system is installed anyway."
}

finish() {
  section "§4 Done"
  save_config "$MNT/root/arch-install.conf"
  if [[ -f ${BASH_SOURCE[0]} ]]; then install -m 0755 "${BASH_SOURCE[0]}" "$MNT/root/arch-install.sh"; fi
  cp "$LOG" "$MNT/var/log/arch-install.log"
  sync
  STAGE="done"
  release_target
  ok "Arch Linux is installed on $DISK."
  info "Answers saved in /root/arch-install.conf on the new system (re-use with --config)."
  info "Remove the installation medium before booting."
  local REBOOT_NOW=""
  FORCE_ASK=1 yesno REBOOT_NOW "Reboot now?" yes
  if [[ $REBOOT_NOW == yes ]]; then reboot; fi
}

install_system() {
  STAGE=disk
  save_config
  if [[ $PART_MODE == auto ]]; then partition_auto; fi
  format_and_mount
  write_early_config
  install_packages
  write_fstab
  configure_system
  configure_initramfs
  install_bootloader
  setup_accounts
  enable_services
  run_post_script
  finish
}

# ================================================================== main

main() {
  while (( $# )); do
    case $1 in
      -c|--config)  [[ $# -ge 2 ]] || die "$1 needs a file."; CONFIG_IN=$2; shift 2 ;;
      -p|--post)    [[ $# -ge 2 && -f $2 ]] || die "$1 needs an existing file."; POST_SCRIPT=$(realpath "$2"); shift 2 ;;
      -n|--dry-run) DRY_RUN=1; shift ;;
      -V|--version) echo "arch-install.sh $VERSION"; exit 0 ;;
      -h|--help)    usage; exit 0 ;;
      *)            usage >&2; die "Unknown option: $1" ;;
    esac
  done

  exec > >(tee -a "$LOG") 2>&1
  printf '%sarch-install.sh %s%s - log: %s\n' "$BOLD" "$VERSION" "$RESET" "$LOG"
  if (( DRY_RUN )); then warn "Dry run: nothing on disk will be changed."; fi

  preflight
  if [[ -n $CONFIG_IN ]]; then load_config "$CONFIG_IN"; fi
  detect_platform
  setup_console
  setup_network
  sync_clock
  prepare_pacman

  select_disk
  plan_storage
  plan_mirrors
  plan_packages
  plan_system
  plan_users
  plan_bootloader
  review_loop

  if (( DRY_RUN )); then
    save_config
    ok "Dry run complete. Answers saved to $ANSWERS_OUT - nothing was changed."
    exit 0
  fi
  collect_secrets
  confirm_destruction
  install_system
}

main "$@"
