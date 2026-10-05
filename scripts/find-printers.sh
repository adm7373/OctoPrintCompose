#!/usr/bin/env bash
#
# find-printers.sh — identify the USB-serial devices behind your Creality
# printers, and generate the udev rules that give each one a stable name.
#
# WHY THIS EXISTS
# Both the CR-6 SE and the Ender 3 Pro present the same USB-serial chip, so
# they are indistinguishable by VID:PID. /dev/ttyUSB0 vs /dev/ttyUSB1 depends on
# plug order, and /dev/serial/by-id paths can collide between identical chips.
# The stable approach is to decide which USB port each printer lives in, then
# create a symlink per printer keyed on that port path.
#
# THIS SCRIPT IS READ-ONLY. It never writes to /dev or /etc.
#
# Usage:
#   ./scripts/find-printers.sh              # report what is connected
#   ./scripts/find-printers.sh --print-udev # also print ready-to-use udev rules
#
set -euo pipefail

# USB-serial chips seen on Creality mainboards (vendor:product)
CHIPS=("1a86:7523" "1a86:55d4" "0403:6001" "1a86:7522")

# USB device paths of the USB-serial bridges.
USB_TTYS=(/dev/ttyUSB* /dev/ttyACM*)

# ---------------------------------------------------------------------------
# 1. Raw USB inventory
# ---------------------------------------------------------------------------
echo "=============================================================="
echo " Creality / USB-serial devices"
echo "=============================================================="
if command -v lsusb >/dev/null 2>&1; then
    lsusb || true
else
    echo "(lsusb not installed — install 'usbutils' for a nicer listing)"
fi

echo
echo "=============================================================="
echo " Serial tty devices"
echo "=============================================================="

found=0
for tty in "${USB_TTYS[@]}"; do
    [ -e "$tty" ] || continue
    found=$((found + 1))

    # Resolve the stable /dev/serial/by-id path (may not exist for every chip).
    byid="$(udevadm info -q property -n "$tty" 2>/dev/null \
        | sed -n 's/^DEVLINKS=.*\(\/dev\/serial\/by-id\/[^ ]*\).*/\1/p' | head -1 || true)"

    # USB VID:PID of this tty.
    vidpid="$(udevadm info -q property -n "$tty" 2>/dev/null \
        | sed -n 's/^ID_VENDOR_ID=//p;s/^ID_MODEL_ID=//p' | paste -sd: - || true)"

    # Kernel USB port path, e.g. 1-1.2  (this is what the udev rule matches).
    port="$(basename "$(dirname "$(readlink -f "/sys/class/tty/$(basename "$tty")/device")")" 2>/dev/null || true)"
    port="${port%%:*}"

    echo
    echo "  device    : $tty"
    echo "  by-id     : ${byid:-(none)}"
    echo "  usb port  : ${port:-(unknown)}"
    echo "  vid:pid   : ${vidpid:-(unknown)}"

    # Flag the chips we know Creality uses, and warn on unexpected ones.
    matched=0
    for chip in "${CHIPS[@]}"; do
        [ "$vidpid" = "$chip" ] && matched=1 && break
    done
    if [ "$matched" -eq 1 ]; then
        echo "  note      : looks like a known USB-serial chip"
    else
        echo "  note      : UNEXPECTED vid:pid — expected one of: ${CHIPS[*]}"
        echo "              The udev rule template below filters on these, so"
        echo "              add yours to the ATTRS{idProduct} alternatives."
    fi

    if [ "$found" -eq 1 ]; then
        echo
        echo "  Only ONE serial device found. Plug in the second printer (and"
        echo "  power both on) and re-run this script to see both."
    fi
done

if [ "$found" -eq 0 ]; then
    echo
    echo "  No USB serial devices found. Checklist:"
    echo "    - is the printer powered on?"
    echo "    - is the USB cable a DATA cable? (charge-only cables are common)"
    echo "    - is the cable connected to the mainboard, not the CR Touch screen?"
    echo "    - dmesg | tail -20   (look for 'ch341-uart converter detected')"
fi

# ---------------------------------------------------------------------------
# 2. Suggested udev rules
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--print-udev" ]; then
    cat <<'RULES'

==============================================================
 Copy the output below into udev/99-octoprint-serial.rules,
 then:  sudo cp udev/99-octoprint-serial.rules /etc/udev/rules.d/
        sudo udevadm control --reload-rules && sudo udevadm trigger
==============================================================

# Each printer is matched by the USB port it is plugged into (the "usb port"
# value printed above), NOT by ttyUSB numbering.
#
# !! EDIT ME: replace CR6SE_USB_PORT / E3PRO_USB_PORT with the usb port values
# !! from the report above, and give each printer its own port. If you later
# !! move a printer to a different port, update the rule to match.
#
# Keep each printer on the port you assigned it. USB port paths are stable in
# practice but are not a guarantee if you re-plug into a different socket.

SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", KERNELS=="CR6SE_USB_PORT", SYMLINK+="octoprint-cr6se", MODE="0660", GROUP="dialout"
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", KERNELS=="E3PRO_USB_PORT", SYMLINK+="octoprint-e3pro", MODE="0660", GROUP="dialout"

# If a board reports the newer CH9102 chip (1a86:55d4) instead of CH340
# (1a86:7523), duplicate its rule with these two values:
#   ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="55d4"

RULES
fi
