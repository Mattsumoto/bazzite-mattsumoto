#!/bin/bash
#
# Build script for the custom Bazzite image.
# Target machine: ASUS ROG STRIX X570-F GAMING / Ryzen 7 5800X / RTX 3080 (GA102)
#                 Samsung Odyssey OLED G9 (G91SD) + LG Ultrawide
#                 ASUS PCE-AC88 (Broadcom BCM4366) / Intel I211 ethernet
#
# Everything here is configuration and firmware only - no package swaps - so the
# image stays as close to stock Bazzite as possible and keeps receiving upstream
# updates cleanly via `bootc upgrade`.

set -ouex pipefail

### 1. Lay down our system files (kargs, modprobe rules, firmware, helpers)
cp -avf "/ctx/system_files"/. /

### 2. Make sure the helper tools are executable regardless of how git
###    checked them out on the build runner.
chmod 0755 /usr/bin/g9-display /usr/bin/broadcom-wifi-fix /usr/bin/hw-fixes

### 3. Sanity-check that the pieces that matter actually landed. A silent
###    missing kargs file would produce an image that looks fine and fixes
###    nothing, so fail the build loudly instead.
test -f /usr/lib/bootc/kargs.d/10-rog-x570-rtx3080.toml
test -f /usr/lib/modprobe.d/nvidia-rtx3080.conf
test -f /usr/lib/modprobe.d/broadcom-bcm4366.conf
test -f /usr/share/bazzite-hw-fixes/firmware/brcmfmac4366c-pcie.bin.ac88u
test -f /usr/lib/firmware/edid/samsung-g91sd-base.bin
test -x /usr/bin/g9-display

### 4. Confirm the stock Broadcom firmware is present in the base image. If it
###    is, `broadcom-wifi-fix` is a fallback rather than the only option.
if [ -f /usr/lib/firmware/brcm/brcmfmac4366c-pcie.bin ]; then
    echo "OK: stock brcmfmac4366c-pcie.bin present in base image"
else
    echo "NOTE: stock brcmfmac4366c-pcie.bin absent; the AC88 override will be required"
fi

echo "Custom hardware-fix layer built successfully."
