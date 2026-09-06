#!/usr/bin/bash
#
# wifi-doctor - offline diagnosis and repair for the ASUS PCE-AC88 (BCM4366)
#               on Bazzite, for the case where the card associates but fails
#               at "configuring interface" and loops.
#
# That symptom means the radio, firmware and authentication are all working.
# The failure is at IP configuration (DHCP), which has a small set of usual
# causes on this chip. Everything here works with NO internet connection and
# installs nothing.
#
# Usage - run these in order, testing your wifi after each:
#
#   sudo ./wifi-doctor.sh diag     collect diagnostics into a log file
#   sudo ./wifi-doctor.sh fix      apply the safe fixes (start here)
#   sudo ./wifi-doctor.sh iwd      escalation: switch NetworkManager to iwd
#   sudo ./wifi-doctor.sh roamoff  escalation: disable firmware roaming
#   sudo ./wifi-doctor.sh revert   undo everything this script did
#
# The log is written next to this script (i.e. onto your USB stick) so you can
# bring it back to a machine with internet.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${SCRIPT_DIR}/wifi-doctor-$(date +%Y%m%d-%H%M%S).log"
NMCONF_DIR="/etc/NetworkManager/conf.d"
MARKER="# managed by wifi-doctor"

need_root() { [ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }; }
hr()  { printf '\n=== %s ===\n' "$*"; }
say() { printf '  %s\n' "$*"; }

# Best-effort discovery of the wifi device and its active/last connection.
wifi_dev() { nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}'; }
wifi_con() {
    local d; d="$(wifi_dev)"
    # Prefer the connection currently bound to the device, else the last wifi profile.
    nmcli -t -f NAME,TYPE,DEVICE connection show 2>/dev/null \
      | awk -F: -v d="$d" '$2 ~ /wireless/ && $3==d {print $1; exit}'
    nmcli -t -f NAME,TYPE connection show 2>/dev/null \
      | awk -F: '$2 ~ /wireless/ {print $1; exit}'
}

do_diag() {
    {
        hr "date / kernel"
        date; uname -a
        hr "bootc image"
        bootc status 2>/dev/null | head -30 || echo "(bootc status unavailable)"
        hr "kernel command line"
        cat /proc/cmdline
        hr "PCI network devices"
        lspci -nnk | grep -A4 -iE 'network|ethernet' || true
        hr "wifi packages"
        for p in iwd wpa_supplicant NetworkManager dhcp-client iw; do
            rpm -q "$p" 2>/dev/null || echo "ABSENT: $p"
        done
        hr "firmware override state"
        echo "firmware_class.path = $(cat /sys/module/firmware_class/parameters/path 2>/dev/null || echo unset)"
        ls -la /var/lib/firmware/brcm/ 2>/dev/null || echo "(no /var/lib/firmware/brcm)"
        ls -la /usr/lib/firmware/brcm/brcmfmac4366* 2>/dev/null || echo "(no stock 4366 firmware in /usr)"
        hr "brcmfmac module"
        lsmod | grep -E '^brcmfmac|^brcmutil|^cfg80211' || echo "(brcmfmac not loaded)"
        echo "--- current params ---"
        for f in /sys/module/brcmfmac/parameters/*; do
            [ -e "$f" ] && echo "  $(basename "$f") = $(cat "$f" 2>/dev/null)"
        done
        echo "--- available params ---"
        modinfo -p brcmfmac 2>/dev/null || true
        hr "regulatory domain"
        iw reg get 2>/dev/null || echo "(iw unavailable)"
        hr "rfkill"
        rfkill list 2>/dev/null || true
        hr "devices / connections"
        nmcli device status
        echo
        nmcli connection show
        hr "NetworkManager backend config"
        grep -rs . "$NMCONF_DIR" 2>/dev/null || echo "(no conf.d overrides)"
        hr "active wifi connection settings"
        c="$(wifi_con)"
        if [ -n "$c" ]; then
            echo "connection: $c"
            nmcli connection show "$c" | grep -viE 'psk|password|secret' || true
        else
            echo "(no wifi connection profile found)"
        fi
        hr "visible networks"
        nmcli device wifi list 2>/dev/null | head -20 || true
        hr "kernel messages (brcmfmac / firmware)"
        journalctl -b -k --no-pager 2>/dev/null | grep -iE 'brcmfmac|firmware|cfg80211' | tail -60 || true
        hr "NetworkManager log this boot"
        journalctl -b -u NetworkManager --no-pager 2>/dev/null | tail -150 || true
        hr "wpa_supplicant log this boot"
        journalctl -b -u wpa_supplicant --no-pager 2>/dev/null | tail -60 || true
    } 2>&1 | tee "$LOG"
    echo
    echo "Diagnostics written to: $LOG"
    echo "Copy that file back to a machine with internet and share it."
}

do_fix() {
    need_root
    local dev con; dev="$(wifi_dev)"; con="$(wifi_con)"
    [ -n "$dev" ] || { echo "No wifi device found. Run 'diag' first." >&2; exit 1; }
    say "device: $dev"
    say "connection: ${con:-<none found>}"

    hr "1. Disable MAC address randomisation"
    # NetworkManager randomises the MAC for scanning and per-connection by
    # default. Plenty of routers hand out a lease to the randomised address and
    # then refuse the real one, which looks exactly like a DHCP timeout loop.
    install -d "$NMCONF_DIR"
    cat > "$NMCONF_DIR/00-wifi-doctor.conf" <<EOF
$MARKER
[device]
wifi.scan-rand-mac-address=no

[connection]
wifi.cloned-mac-address=permanent
# 2 = disable power saving. brcmfmac power save is a known cause of dropped
# associations mid-DHCP.
wifi.powersave=2
EOF
    say "wrote $NMCONF_DIR/00-wifi-doctor.conf"

    if [ -n "$con" ]; then
        hr "2. Pin the connection to safe settings"
        nmcli connection modify "$con" wifi.cloned-mac-address permanent   && say "cloned-mac-address = permanent"
        nmcli connection modify "$con" wifi.powersave 2                    && say "powersave = disabled"
        # PMF (802.11w) is required by WPA3. The BCM4366 predates WPA3, and on a
        # WPA2/WPA3 transition-mode AP the negotiation can succeed then fall over.
        # 1 = disable.
        nmcli connection modify "$con" 802-11-wireless-security.pmf 1      && say "PMF = disabled (forces WPA2 behaviour)"
        # A stalled DHCPv6 can hold the whole activation in 'configuring'.
        nmcli connection modify "$con" ipv6.method disabled                && say "IPv6 = disabled"
        nmcli connection modify "$con" ipv4.method auto                    && say "IPv4 = auto (DHCP)"
        # Don't let it give up permanently while we are testing.
        nmcli connection modify "$con" connection.autoconnect yes          && say "autoconnect = yes"
    fi

    hr "3. Regulatory domain"
    iw reg set GB 2>/dev/null && say "runtime regdomain set to GB"
    cat > /etc/modprobe.d/wifi-doctor-regdom.conf <<EOF
$MARKER
options cfg80211 ieee80211_regdom=GB
EOF
    say "persisted regdomain GB"

    hr "4. Restart NetworkManager"
    systemctl restart NetworkManager
    sleep 5
    nmcli device status | sed 's/^/  /'
    echo
    say "Now try connecting. If it still loops, run:  sudo $0 iwd"
}

do_iwd() {
    need_root
    hr "Switch NetworkManager wifi backend to iwd"
    if ! rpm -q iwd >/dev/null 2>&1 && [ ! -x /usr/libexec/iwd ]; then
        echo "  iwd is NOT installed in this image, and it cannot be installed offline."
        echo "  Skip this step - try 'roamoff' instead."
        exit 1
    fi
    cat > "$NMCONF_DIR/01-wifi-doctor-iwd.conf" <<EOF
$MARKER
[device]
wifi.backend=iwd
EOF
    say "wrote $NMCONF_DIR/01-wifi-doctor-iwd.conf"
    systemctl disable --now wpa_supplicant 2>/dev/null || true
    systemctl enable --now iwd
    systemctl restart NetworkManager
    sleep 5
    systemctl is-active iwd NetworkManager | sed 's/^/  /'
    say "Reconnect to your network. You may need to re-enter the password."
}

do_roamoff() {
    need_root
    hr "Disable firmware roaming in brcmfmac"
    # Firmware-side roaming on this chip can tear down a working association
    # mid-DHCP while it hunts for a 'better' AP. Only apply params the running
    # module actually advertises, so we cannot make the module fail to load.
    local opts=""
    modinfo -p brcmfmac 2>/dev/null | grep -q '^roamoff' && opts="roamoff=1"
    if [ -z "$opts" ]; then
        echo "  This brcmfmac build does not expose 'roamoff'. Nothing to do."
        exit 1
    fi
    cat > /etc/modprobe.d/wifi-doctor-brcmfmac.conf <<EOF
$MARKER
options brcmfmac $opts
EOF
    say "wrote options brcmfmac $opts"
    modprobe -r brcmfmac 2>/dev/null || true
    if modprobe brcmfmac; then
        say "module reloaded successfully"
        sleep 3
        nmcli device status | sed 's/^/  /'
    else
        echo "  Module FAILED to reload - reverting this change."
        rm -f /etc/modprobe.d/wifi-doctor-brcmfmac.conf
        modprobe brcmfmac || true
        exit 1
    fi
}

do_revert() {
    need_root
    hr "Removing everything wifi-doctor changed"
    rm -fv "$NMCONF_DIR/00-wifi-doctor.conf" \
           "$NMCONF_DIR/01-wifi-doctor-iwd.conf" \
           /etc/modprobe.d/wifi-doctor-regdom.conf \
           /etc/modprobe.d/wifi-doctor-brcmfmac.conf 2>/dev/null
    local con; con="$(wifi_con)"
    if [ -n "$con" ]; then
        nmcli connection modify "$con" wifi.cloned-mac-address "" 2>/dev/null
        nmcli connection modify "$con" 802-11-wireless-security.pmf 0 2>/dev/null
        nmcli connection modify "$con" ipv6.method auto 2>/dev/null
        say "connection settings reset to defaults"
    fi
    systemctl disable --now iwd 2>/dev/null || true
    systemctl enable --now wpa_supplicant 2>/dev/null || true
    systemctl restart NetworkManager
    say "NetworkManager restarted with stock configuration"
}

case "${1:-}" in
    diag)    do_diag ;;
    fix)     do_fix ;;
    iwd)     do_iwd ;;
    roamoff) do_roamoff ;;
    revert)  do_revert ;;
    *)
        sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
        ;;
esac
