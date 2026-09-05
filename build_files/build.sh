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
test -f /usr/lib/bootc/install/50-bazzite-mattsumoto.toml
test -f /usr/lib/modprobe.d/broadcom-bcm4366.conf
test -f /usr/share/bazzite-hw-fixes/firmware/brcmfmac4366c-pcie.bin.ac88u
test -f /usr/lib/firmware/edid/samsung-g91sd-base.bin
test -x /usr/bin/g9-display

### 4. Report whether the base image carries Broadcom 4366 firmware.
###    Verified 2026-09-06: it does NOT. That makes `broadcom-wifi-fix enable`
###    mandatory rather than a fallback - without it the card cannot initialise
###    at all. Kept as a check so we notice if upstream starts shipping it.
if [ -f /usr/lib/firmware/brcm/brcmfmac4366c-pcie.bin ]; then
    echo "NOTE: base image now ships brcmfmac4366c-pcie.bin - the AC88 override is optional again"
else
    echo "OK (expected): no stock brcmfmac4366c-pcie.bin; AC88 override is required for wifi"
fi

### 5. NOTE: an earlier revision audited /etc/yum.repos.d for dangling
###    file:// GPG keys, to satisfy bootc-image-builder's depsolve step.
###    That check was wrong twice over: gpgkey paths legitimately contain
###    unexpanded DNF variables ($releasever, $basearch), and /etc/pki is
###    empty at build time because bootc materialises /etc from /usr/etc
###    only at deploy. It therefore disabled Fedora's own repositories.
###    The ISO is built with titanoboa now, which does not depsolve at all,
###    so no repo rewriting is needed. Do not reintroduce it.

echo "Custom hardware-fix layer built successfully."
