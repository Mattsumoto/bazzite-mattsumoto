# bazzite-mattsumoto

A custom [Bazzite](https://bazzite.gg) image with hardware fixes baked in for this specific machine, built automatically by GitHub Actions and delivered as an installable ISO.

**Base image:** `ghcr.io/ublue-os/bazzite-nvidia-open:stable`

## Target hardware

| Component | Detail |
|---|---|
| Motherboard | ASUS ROG STRIX X570-F GAMING (BIOS 4802) |
| CPU | AMD Ryzen 7 5800X |
| Memory | 32 GB |
| GPU | NVIDIA RTX 3080 — GA102, `10de:2216` |
| Primary display | Samsung Odyssey OLED G9 (G91SD), 5120×1440 @144 Hz |
| Secondary display | LG Ultrawide (2016) |
| Wi-Fi | ASUS PCE-AC88 — Broadcom BCM4366, `14e4:43c3` |
| Ethernet | Intel I211, `8086:1539` |
| Audio | Realtek ALC1220, NVIDIA HDMI, HyperX Cloud II Wireless |

---

## What this image changes

Everything here is **configuration and firmware only** — no packages are added or removed. The image tracks upstream Bazzite and keeps updating normally with `bootc upgrade`.

### 1. Monitor: white flash → screen off → back on

5120×1440 @144 Hz over DisplayPort 1.4 requires **DSC** (Display Stream Compression). DSC combined with **VRR** on a QD-OLED panel under the NVIDIA driver is a well-documented cause of exactly this flicker/blank cycle.

Applied via `/usr/lib/bootc/kargs.d/10-rog-x570-rtx3080.toml`:

- `nvidia_drm.modeset=1` and `nvidia_drm.fbdev=1` — proper DRM modesetting and framebuffer handoff. Without `fbdev`, the console→Wayland transition on a DSC link is a common trigger.
- `nvidia.NVreg_PreserveVideoMemoryAllocations=1` — keeps VRAM across suspend/resume, preventing dead or corrupted output on wake.
- `nvidia.NVreg_EnableGpuFirmware=1` — GSP firmware, required by the open kernel modules.

If the panel still misbehaves, the `g9-display` tool switches profiles at runtime (see below). **This is the first thing to try.**

### 2. Wi-Fi: card not detected

The ASUS PCE-AC88's BCM4366 is one of the worst-supported Wi-Fi chips on Linux. `brcmfmac` binds to the device but typically fails on the device-specific `brcmfmac4366c-pcie.txt` NVRAM file, which no distribution ships, and can then exhaust the DMA bounce buffer.

Mitigations applied:

- `swiotlb=65536` — raises the bounce buffer from 64 MB to 128 MB, addressing the documented `swiotlb buffer is full` / `dma_map_single failed` failures. Costs 128 MB of 32 GB.
- `/usr/lib/modprobe.d/broadcom-bcm4366.conf` — blacklists `wl`, `b43`, `brcmsmac` and `bcma`, which do **not** support the 4366 but will bind first and leave you with no interface at all.
- `firmware_class.path=/var/lib/firmware` — lets firmware be overridden at runtime. `/usr` is read-only on bootc, so this is the only writable override point.
- An AC88-specific firmware blob ships at `/usr/share/bazzite-hw-fixes/firmware/`, switched in with `broadcom-wifi-fix enable`.

> **The AC88 firmware is required, not optional.** Image verification showed that Bazzite ships **no** `brcmfmac4366c-pcie.bin` at all, so the card cannot initialise out of the box under any circumstances. `sudo broadcom-wifi-fix enable` is a mandatory step if you want to give the card a chance — it is not a fallback for when the stock firmware misbehaves, because there is no stock firmware.
>
> That blob comes from [an archived third-party repository](https://github.com/Hill-98/phicommk3-firmware), is unsigned, and its provenance cannot be verified. It is therefore left inactive by default rather than loaded for you. It is firmware for the Wi-Fi controller, not code run by your CPU, but that is a judgement call you should make knowingly.

> **Be realistic about this one.** Even with the firmware, these mitigations may not be enough — ASUS's own position is that the card is Windows-only. An **Intel AX210** PCIe card (~£20) works with zero configuration on any modern kernel and is the reliable fix. The Intel I211 ethernet works out of the box regardless, so you are never stranded.

### 3. Platform

- `iommu=pt` — IOMMU passthrough for trusted devices on X570. Reduces translation overhead and bounce-buffer pressure. A no-op if IOMMU is disabled in BIOS.

### 4. Correct NVIDIA variant

The RTX 3080 is Ampere, which the **open** kernel modules support properly. `bazzite-nvidia-open` is the right base — this was already correct in the stock ISO and is preserved here.

---

## Included tools

Run these from a terminal after installing.

### `hw-fixes`
Reports which workarounds are actually live — checks every kernel argument, NVIDIA module state, displays and network interfaces. **Run this first after installing** to confirm the image did what it should.

### `g9-display` — the monitor fix
```bash
g9-display safe        # 120Hz, VRR off, HDR off  <- try this if the screen flickers
g9-display full        # 144Hz, VRR auto, HDR on
g9-display vrr on|off
g9-display hdr on|off
g9-display status
```
If `safe` stops the flickering, reintroduce settings one at a time — VRR first, then 144 Hz — to find which one your link cannot hold.

### `broadcom-wifi-fix` — required for any chance of Wi-Fi
Bazzite ships no firmware for this chip, so the card is dead until you run `enable`.
```bash
broadcom-wifi-fix status         # device, override state, kernel log
sudo broadcom-wifi-fix enable    # install the AC88 firmware (required)
sudo broadcom-wifi-fix disable   # remove it again
```

### Emergency: monitor won't display at all

Extracted EDIDs from this machine ship at `/usr/lib/firmware/edid/`. If the G9 never produces a picture, add this kernel argument from the GRUB menu (press `e` at boot) to force the basic mode set:

```
drm.edid_firmware=DP-1:edid/samsung-g91sd-base.bin
```

These are **base blocks only** (128 bytes, no CTA extension), so they drop high-refresh modes — useful strictly as a recovery aid, not as a daily configuration.

---

## Building it

### One-time setup

```powershell
.\setup.ps1 -GitHubUser yourname
```

This stamps your username into `image-template.env` and `disk_config/iso.toml`, then creates the initial commit.

Then:

1. Create an **empty** public repo named `bazzite-mattsumoto` at <https://github.com/new> (no README).
2. Push it:
   ```bash
   git remote add origin https://github.com/YOURNAME/bazzite-mattsumoto.git
   git push -u origin main
   ```
3. **Actions** tab → enable workflows → run **build.yml**. Takes roughly 15–25 minutes.
4. **Packages** → `bazzite-mattsumoto` → **Package settings** → confirm visibility is **Public**. The ISO build cannot pull a private image.
5. **Actions** → **Build live ISO** → **Run workflow** → download the ISO from the run's artifacts when it finishes.

### Why titanoboa and not bootc-image-builder

The template ships `build-disk.yml`, which uses `bootc-image-builder`. That path does not work against Bazzite: bib depsolves packages at build time, so it needs a declared root filesystem and chokes on Bazzite's third-party Terra repos, which reference a GPG key that is absent from the image. Bazzite never hits either problem because it builds its own ISOs with **titanoboa**, which consumes the finished container image and resolves no packages.

`build-iso.yml` uses titanoboa for that reason. `build-disk.yml` is left in place for qcow2/raw disk images, which do still work.

### The two images

Titanoboa does not convert this image into an ISO. A live ISO needs a *second*, separate image — the environment you actually boot into from the USB — carrying a `dracut-live` initramfs, livesys-scripts, EFI cdboot support and the payload image embedded inside it. `installer/` is that build, ported from [Bazzite's own installer](https://github.com/ublue-os/bazzite/tree/main/installer).

| | |
|---|---|
| `BASE_IMAGE` | the live environment booted from USB |
| `INSTALL_IMAGE_PAYLOAD` | what the installer writes to disk |

The live runtime is plain `ghcr.io/ublue-os/bazzite:stable` — **not** our NVIDIA image. Bazzite strips `-nvidia-open` from the ref for the livecd runtime, and that is not an arbitrary choice.

> An earlier revision of this repo used the NVIDIA image as the live runtime, on the theory that the installer would then render correctly on a DSC panel. The result was a live session that booted to a permanently black screen with no console: the NVIDIA kernel module does not initialise inside the live overlay, so with `nvidia_drm.modeset=1` set, KMS never comes up and nothing is drawn. `installer/iso.yaml` carries a comment saying not to reintroduce those arguments there.

So the installer runs on the generic driver stack, and the NVIDIA fixes apply to the installed system via `kargs.d`. If the G9 misbehaves at the installer, use the **Basic Graphics Mode** boot entry.

### Image naming

The image is called `bazzite-mattsumoto-nvidia-open`, and the suffix is load-bearing. Bazzite's live-session hardware helper (`on_gui_login.sh`) classifies the payload by **name**:

```bash
if [[ $image_name == *-nvidia-open* ]]; then image="nvidia-desktop"
else                                         image="amd_intel"
```

Anything without that suffix is treated as an AMD/Intel image, so on NVIDIA hardware the installer raises a spurious **WRONG IMAGE DETECTED** warning. The name is accurate — this is a `bazzite-nvidia-open` derivative — so this is a fix rather than a workaround.

Image signing is optional — it is skipped automatically unless you add a `SIGNING_SECRET` repository secret.

### Writing the USB

Use Rufus in **DD mode** if prompted. The ISO installs the custom image directly, so the fixes are present on first boot.

### Updating later

Edit a file, push, and the workflow rebuilds. On the installed machine:

```bash
bootc upgrade
```

Kernel-argument changes in `kargs.d` are applied on upgrade too, so you never need to reinstall to change a setting.

---

## Rolling back

This is an image-based OS — the previous deployment is always kept. If an update misbehaves, pick the older entry in the GRUB menu at boot, or:

```bash
sudo bootc rollback
```

## Reverting to stock Bazzite

```bash
sudo bootc switch ghcr.io/ublue-os/bazzite-nvidia-open:stable
```

---

## Sources

- [Bazzite documentation](https://docs.bazzite.gg/) · [image variants](https://docs.bazzite.gg/General/FAQ/)
- [ublue-os/image-template](https://github.com/ublue-os/image-template) — the build system this is based on
- [bootc kernel arguments](https://bootc.dev/bootc/building/kernel-arguments.html)
- [ASUS PCE-AC88 on Linux](https://blog.cooperteam.net/post/2017-11-10-asus-ac88-wifi-on-linux/) · [Arch forum thread](https://bbs.archlinux.org/viewtopic.php?id=258724) · [Level1Techs](https://forum.level1techs.com/t/linux-does-not-recognize-my-wi-fi-card-with-broadcom-bcm4366/110929)
- [Odyssey G9 flicker/VRR on Linux](https://github.com/vpraion/odysseyg9-linux-240hz-vrr-hdr-noflicker) · [NVIDIA VRR black screen reports](https://forums.developer.nvidia.com/t/545-drivers-have-bad-flickering-and-black-screen-issues-when-vrr-is-enabled/269801)
