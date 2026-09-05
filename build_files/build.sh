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

### 4. Confirm the stock Broadcom firmware is present in the base image. If it
###    is, `broadcom-wifi-fix` is a fallback rather than the only option.
if [ -f /usr/lib/firmware/brcm/brcmfmac4366c-pcie.bin ]; then
    echo "OK: stock brcmfmac4366c-pcie.bin present in base image"
else
    echo "NOTE: stock brcmfmac4366c-pcie.bin absent; the AC88 override will be required"
fi

### 5. Repair repository definitions that advertise a missing GPG key.
#
# bootc-image-builder depsolves against the image's own repo configuration when
# building an Anaconda ISO, and aborts outright on a dangling file:// gpgkey:
#   RepoError: Failed to retrieve GPG key for repo 'terra-mesa':
#   Couldn't open file /etc/pki/rpm-gpg/RPM-GPG-KEY-terra44-mesa
# Bazzite itself never trips this because its ISOs are built with titanoboa,
# which does not depsolve. A repo whose key is absent cannot be used for signed
# installs anyway, so disabling it loses nothing and unblocks the ISO build.
#
# Audit everything and print it, then disable only what is actually broken.

echo "=== GPG keys present in the image ==="
ls -1 /etc/pki/rpm-gpg/ 2>/dev/null || echo "(no /etc/pki/rpm-gpg)"

echo "=== auditing repo definitions ==="
shopt -s nullglob
for repo in /etc/yum.repos.d/*.repo; do
    missing=""
    while IFS= read -r line; do
        # A gpgkey= line may list several space-separated URLs.
        for url in ${line#gpgkey=}; do
            case "$url" in
                file://*) path="${url#file://}"
                          [ -f "$path" ] || missing="$missing $path" ;;
            esac
        done
    done < <(grep -h '^gpgkey=' "$repo" 2>/dev/null || true)

    if [ -n "$missing" ]; then
        echo "  DISABLING $(basename "$repo") - missing key(s):$missing"
        sed -i 's/^enabled[[:space:]]*=[[:space:]]*1/enabled=0/' "$repo"
    else
        echo "  ok $(basename "$repo")"
    fi
done
shopt -u nullglob

echo "Custom hardware-fix layer built successfully."
