# Arch-Linux Installation Script

My personal Arch Linux install script.

I got tired of typing the same fifty commands every time I reinstalled Arch, so I
turned the [ArchWiki Installation guide](https://wiki.archlinux.org/title/Installation_guide)
into one interactive script. It asks me a few questions, shows me exactly what it's
about to do, and then does it. Nothing gets written to disk until I say so.

I kept it close to the official guide on purpose. Every part of the script is tagged
with the guide's section number (`§1.9`, `§3.8`, ...), so if something looks odd you
can open the wiki next to it and follow along.

## Official archinstall or this script?

Worth knowing up front: the Arch ISO already comes with an official guided
installer, [**archinstall**](https://wiki.archlinux.org/title/Archinstall).
Boot the ISO, get online, and type:

```bash
archinstall
```

It's maintained by the Arch team, has a nice menu-driven interface, and is a great
choice, especially if it's your first install.

So why does this repo exist? I wanted something that follows the Installation guide
line by line, so I can read the script and learn what each step does, and that
works the way I like to install. Use whichever one you're comfortable with:

- **archinstall** if you want the official, well-tested path with a menu UI.
- **This script** if you want a simple bash script you can read top to bottom,
  tweak, and reuse with your own saved answers.

Both start the same way: download the ISO, boot it, get online. Only the last step
differs.

## Getting the Arch ISO

Always get the ISO from the official site. The steps below follow §1.1–1.4 of the
Installation guide.

1. **Download it.** Go to <https://archlinux.org/download/> and grab
   `archlinux-YYYY.MM.DD-x86_64.iso`. Use either the BitTorrent link or an HTTP
   mirror close to you (they're listed by country further down the page).

2. **Check it.** The download page lists the SHA256 checksum for the current
   release. Compare it with your file:

   On Windows (PowerShell):

   ```powershell
   Get-FileHash .\archlinux-*-x86_64.iso -Algorithm SHA256
   ```

   On Linux:

   ```bash
   sha256sum archlinux-*-x86_64.iso
   ```

   If the hashes don't match, download it again. For the extra-careful: the page
   also has a PGP signature (`.iso.sig`). If you already run Arch,
   `pacman-key -v archlinux-*-x86_64.iso.sig` verifies it.

3. **Write it to a USB stick** (at least 2 GB; everything on it gets wiped):

   - **Windows:** use [Rufus](https://rufus.ie). Pick the stick and the ISO, then
     Start. If the stick doesn't boot, write it again and choose *DD Image* mode
     when Rufus asks. [Ventoy](https://www.ventoy.net) works too: just copy the ISO
     onto the stick, and you can keep `arch-install.sh` right next to it.
   - **Linux:** find the stick with `lsblk` (use the whole device, e.g. `/dev/sdb`,
     not `/dev/sdb1`), then:

     ```bash
     dd bs=4M if=archlinux-YYYY.MM.DD-x86_64.iso of=/dev/sdX conv=fsync oflag=direct status=progress
     ```

4. **Boot it.** The Arch ISO doesn't support Secure Boot, so turn it off in your
   firmware settings first (you can set it up again after installing). Then pick the
   USB stick from your boot menu (usually F12, F11, F8 or Esc during startup) and
   choose *Arch Linux install medium*. You'll land on a root shell. That's where
   this script comes in.

Using a 32-bit PC, ARM or RISC-V machine? Get the image from that port's own site
instead (links in [Credits](#credits)).

## Grabbing it from the live ISO

Boot the Arch ISO and get online first. Ethernet just works; for Wi-Fi use `iwctl`,
or just run the script anyway and it'll walk you through connecting.

Then grab the script and its checksum:

```bash
curl -fLO https://raw.githubusercontent.com/mavi-cyber/arch-install/main/arch-install.sh
curl -fLO https://raw.githubusercontent.com/mavi-cyber/arch-install/main/arch-install.sh.sha256
```

Check it, then run it:

```bash
sha256sum -c arch-install.sh.sha256
bash arch-install.sh
```

That URL is a pain to type on a TTY, so I keep a short link that redirects to it.
I'd recommend doing the same.

### Checking the download

Please don't run a script that partitions your disk without checking it first.
The SHA-256 of the current `arch-install.sh` (v1.0.0) is:

```
17ab5eff8b80134ba636d866a1284d5231ec87f12f5ce9ab35ca3a25625f196c
```

`sha256sum -c arch-install.sh.sha256` should print `arch-install.sh: OK`. If you
get `FAILED`, delete the file and download it again. Got the script some other way
(USB stick, another PC)? Run `sha256sum arch-install.sh` and compare the output
with the hash above.

### No internet yet? Use a USB stick

Drop `arch-install.sh` onto any FAT32/exFAT stick (a Ventoy data partition works too),
then on the ISO:

```bash
lsblk
```

```bash
mount --mkdir /dev/sdX1 /media/usb
```

```bash
bash /media/usb/arch-install.sh
```

You'll still need internet later for the packages, but the script helps you get
connected.

### Or pull it from another PC on your network

On the machine that has the script:

```bash
python -m http.server 8000
```

On the ISO:

```bash
curl -fO http://<that-pc-ip>:8000/arch-install.sh
```

(On Windows, allow Python through the firewall when it asks.)

> **Heads up if you edit this on Windows:** bash hates CRLF line endings. The
> `.gitattributes` keeps git honest, but if you ever see `$'\r': command not found`,
> run `sed -i 's/\r$//' arch-install.sh` and you're good.

## Running it

```bash
bash arch-install.sh [--config answers.conf] [--post post-install.sh] [--dry-run]
```

| Flag | What it does |
| --- | --- |
| `-c, --config FILE` | Pre-fills answers from a file. Anything missing or invalid still gets asked. |
| `-p, --post FILE` | Runs your own script inside the new system at the end (dotfiles, AUR helper, whatever). |
| `-n, --dry-run` | Asks everything and shows the plan, but touches nothing. Great for a first look. |

Here's how a run goes:

1. It asks its questions. Every one has a sane default, so Enter gets you far.
   Typing `?` at the keymap, time zone or locale prompt lists what's valid.
2. You get a **summary screen**. From there you can go back and change any section,
   save your answers and quit, or carry on.
3. To actually start, you type the disk's name (e.g. `nvme0n1`). That's deliberate:
   I never want to wipe the wrong drive by mashing Enter.
4. It installs, sets everything up, and asks whether to reboot.

When it's done, your answers are saved in `/root/arch-install.conf` on the new system.
Passwords, disks and partitions are never saved, so that file is safe to push to your
own repo. Next time:

```bash
bash arch-install.sh --config arch-install.conf
```

With that, a reinstall is mostly pressing Enter. There's an
[answers.example.conf](answers.example.conf) with every option documented.

The full log goes to `/tmp/arch-install.log` during the install and gets copied to
`/var/log/arch-install.log` on the new system.

## What it sets up

Roughly in the order of the guide:

- **Keyboard & font (§1.5)**: any console keymap, plus an optional big Terminus font
  for HiDPI screens. Both carry over to the installed system.
- **Boot mode (§1.6)**: detects 64-bit UEFI, 32-bit UEFI, legacy BIOS, or board
  firmware without UEFI, and adjusts everything after that.
- **Internet & clock (§1.7–1.8)**: guided Wi-Fi via `iwctl` if you're offline, then
  waits for NTP so package signatures don't fail.
- **Partitioning (§1.9)**, two ways:
  - **Auto** wipes the disk and creates GPT with an EFI partition (or BIOS boot
    partition), or MBR for really old BIOS machines.
  - **Manual** opens `cfdisk` and lets you pick partitions, which is what you want
    for dual boot. If it spots an existing EFI partition it defaults to *keeping*
    it, so Windows' boot loader survives.
- **Filesystems (§1.10)**: ext4, Btrfs (with `@ @home @log @pkg @snapshots`
  subvolumes and zstd compression), XFS, or F2FS. Optional LUKS2 encryption for root.
- **Swap**: zram (my default), a swap file (Btrfs-aware), a swap partition, or none.
- **Mirrors (§2.1)**: keep them, rank the fastest for your country with `reflector`,
  or edit the list by hand.
- **Packages (§2.2)**:
  - your pick of kernel, firmware, and CPU microcode (auto-detected, skipped in VMs)
  - an editor, man pages, and a network stack
  - optionally a desktop (GNOME, KDE Plasma or Xfce) with PipeWire and the right GPU
    drivers, plus VM guest tools, multilib, and any extras you want

  Before it touches your disk, it checks that **every** package actually exists, so
  a typo can't kill the install halfway through.
- **System config (§3.1–3.5)**: fstab with UUIDs, time zone, locales, hostname, and
  NetworkManager or systemd-networkd + iwd. Wi-Fi you joined on the ISO carries over.
- **Initramfs (§3.6)**: adds the encryption hook when needed and rebuilds.
- **Accounts (§3.7)**: root password, or a locked root, plus a sudo user in `wheel`.
- **Boot loader (§3.8)**: systemd-boot (UEFI) or GRUB (UEFI/BIOS). GRUB can use
  os-prober for dual boot and install to the fallback `EFI/BOOT` path for fussy
  firmware.

If anything fails midway, the script unmounts everything and closes the encrypted
volume, so you can fix the problem and just run it again.

## Disks

It lists every real disk and hides the ones you should never install to: the USB
you booted from, loop devices, optical drives, zram, and the eMMC `boot0`/`boot1`/`rpmb`
areas.

HDDs, SATA SSDs, NVMe, eMMC/SD cards, USB drives and VM disks all work. It handles
both partition naming styles (`sda1` and `nvme0n1p1`), so you don't have to think
about it.

A few things it does depending on the drive:

- **SSD / NVMe / eMMC**: offers a whole-drive TRIM before partitioning, mounts with
  `noatime`, turns on the weekly `fstrim.timer`, and lets TRIM pass through LUKS.
  That's less wear and keeps the drive fast.
- **Advanced Format drives**: shows the logical/physical sector sizes and tells you
  if the drive could run in native 4K mode. The wiki has a tip about this; the
  script won't reformat anything for you.
- **USB drives**: offers a *portable* install that boots on other PCs. It puts all
  drivers in the initramfs, installs both Intel and AMD microcode, and uses the
  fallback EFI path.

## Architectures

Quick honesty note: official Arch Linux is **x86_64 only**. The other architectures
are community ports with their own ISOs and repos. The script detects your CPU and
adapts its packages, keyring, partition types and boot loader.

| Arch | Distro | How well it works |
| --- | --- | --- |
| `x86_64` | Arch Linux | Fully supported: 64-bit UEFI, 32-bit UEFI and BIOS. |
| `i686` | Arch Linux 32 | Boot their ISO and run it. GRUB for BIOS/UEFI. |
| `aarch64` | Arch Linux ARM | Run it from an ALARM system. UEFI machines get systemd-boot or GRUB. Boards without UEFI (Raspberry Pi etc.) need their own boot setup afterwards. |
| `armv7h` | Arch Linux ARM | Same deal as aarch64. |
| `riscv64` | Arch Linux RISC-V | Best effort. Expect rough edges. |

## Before you trust it with real hardware

Try it in a VM first. I test in VirtualBox/QEMU with UEFI and BIOS, auto and manual
layouts, and with encryption on. `--dry-run` is also handy for clicking through
every question without risking anything.

Found a bug or have a machine it doesn't handle? Open an issue and include
`/var/log/arch-install.log` (or `/tmp/arch-install.log` if the install didn't
finish).

## Credits

This script is just automation on top of other people's great work:

- **[Arch Linux](https://archlinux.org)**: the distribution itself, its packages,
  and the official ISO. Huge thanks to the Arch developers, package maintainers
  and mirror operators.
- **[ArchWiki](https://wiki.archlinux.org)**: the
  [Installation guide](https://wiki.archlinux.org/title/Installation_guide) this
  script follows step by step, plus the pages on partitioning, dm-crypt, Btrfs,
  zram, systemd-boot and GRUB. ArchWiki content is available under the
  [GNU FDL 1.3 or later](https://www.gnu.org/licenses/fdl-1.3.html). If the
  script and the wiki ever disagree, trust the wiki.
- **[archinstall](https://github.com/archlinux/archinstall)**: the official guided
  installer that ships on the ISO. If you'd rather not use my script, use this.
- **Community ports** that make other architectures possible:
  [Arch Linux 32](https://archlinux32.org),
  [Arch Linux ARM](https://archlinuxarm.org) and
  [Arch Linux RISC-V](https://archriscv.felixc.at).
- The tools it drives: `pacstrap`/`arch-chroot`/`genfstab` (arch-install-scripts),
  `reflector`, `gptfdisk`, `cryptsetup`, `iwd` and `systemd`.

This is a personal project. It isn't affiliated with or endorsed by Arch Linux.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).