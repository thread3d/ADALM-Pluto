#!/bin/bash
# Diagnose the ADALM-PLUTO link on this board.
#
# This is the first thing to run, and the only thing to run when the radio misbehaves: it looks at
# the USB tree, the IIO layer, the kernel log and the libiio install, and then names the failure mode
# instead of leaving you to interpret four screens of output.
#
# It is read-only. It changes nothing, needs no root, and installs nothing.
#
# Usage:
#   ./probe-pluto.sh                 # diagnose the link
#   ./probe-pluto.sh --capture      # build and run the libiio receive checker (src/pluto_probe.c)
#   ./probe-pluto.sh --capture -g 20 -f 868200000     # extra args go to the capture probe
#   ./probe-pluto.sh --brief         # one line of verdict, for scripting
#
# Exit status: 0 = the radio is present and usable, 1 = it is not, 2 = usage error.
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PLUTO_VENDOR=0456                     # Analog Devices
MODE=diagnose
BRIEF=0
CAPTURE_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --capture) MODE=capture; shift ;;
    --brief)   BRIEF=1; shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         CAPTURE_ARGS+=("$1"); shift ;;
  esac
done

if [ "$BRIEF" = 1 ] && [ "$MODE" = capture ]; then
  echo "--brief reports the link verdict only and cannot be combined with --capture" >&2
  exit 2
fi

# --brief: the whole diagnostic still runs (every test is cheap), but stdout is thrown away and only
# the one-line verdict is written back to the caller on fd 3. Doing it by redirecting the fd rather
# than by guarding every print means no future printf can accidentally leak into the brief output.
if [ "$BRIEF" = 1 ]; then exec 3>&1 1>/dev/null; fi

say()  { printf '%s\n' "$*"; }
head1() { printf '\n=== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------------------------------------
# 1. Host
# ------------------------------------------------------------------------------------------------
head1 "host"
say "  $(uname -srm)   $( [ -r /etc/os-release ] && . /etc/os-release && echo "$PRETTY_NAME" )"
say "  uptime: $(uptime | sed 's/.*up //; s/,.*load/  load/')"

# ------------------------------------------------------------------------------------------------
# 2. USB enumeration
# ------------------------------------------------------------------------------------------------
head1 "USB: is an Analog Devices device on the bus?"
PLUTO_FOUND=0
PLUTO_PORT=
PLUTO_VIDPID=
PLUTO_SERIAL=
PLUTO_PRODUCT=
CONFIGURED=
USB_NODE=

for dev in /sys/bus/usb/devices/*/; do
  [ -f "$dev/idVendor" ] || continue
  [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$PLUTO_VENDOR" ] || continue
  PLUTO_FOUND=1
  PLUTO_PORT=$(basename "$dev")
  PLUTO_VIDPID="$(cat "$dev/idVendor"):$(cat "$dev/idProduct")"
  PLUTO_PRODUCT=$(cat "$dev/product" 2>/dev/null)
  PLUTO_SERIAL=$(cat "$dev/serial" 2>/dev/null)
  CONFIGURED=$(cat "$dev/bConfigurationValue" 2>/dev/null)
  busnum=$(cat "$dev/busnum" 2>/dev/null)
  devnum=$(cat "$dev/devnum" 2>/dev/null)
  [ -n "${busnum:-}" ] && USB_NODE=$(printf '/dev/bus/usb/%03d/%03d' "$busnum" "$devnum")

  say "  found on port $PLUTO_PORT   $PLUTO_VIDPID"
  say "    product:  ${PLUTO_PRODUCT:-(none reported)}"
  say "    serial:   ${PLUTO_SERIAL:-(none reported)}"
  say "    driver:   $( [ -e "$dev/driver" ] && basename "$(readlink -f "$dev/driver")" || echo "(none bound to the device node)")"
  # Which USB functions (interfaces) are live tells us which "face" of the Pluto we are looking at.
  for iface in "$dev"*:*; do
    [ -d "$iface" ] || continue
    cls=$(cat "$iface/bInterfaceClass" 2>/dev/null)
    drv=$( [ -e "$iface/driver" ] && basename "$(readlink -f "$iface/driver")" || echo "unclaimed" )
    case "$cls" in
      08) human="mass storage   <- the firmware volume, NOT the radio" ;;
      02) human="CDC (net/serial)" ;;
      ff) human="vendor specific (often the IIO function)" ;;
      e0) human="wireless/RF" ;;
      *)  human="class $cls" ;;
    esac
    say "    iface $(basename "$iface"): $human   [$drv]"
  done
done

if [ "$PLUTO_FOUND" = 0 ]; then
  say "  no device with vendor ID $PLUTO_VENDOR (Analog Devices) is present"
  if have lsusb; then
    say "  (neighbouring USB devices, for context:)"
    lsusb | sed 's/^/    /' | head -20
  fi
fi

# ------------------------------------------------------------------------------------------------
# 3. IIO — the layer libiio actually opens
# ------------------------------------------------------------------------------------------------
head1 "IIO: can libiio open the radio?"
# An important correction, learned the hard way on 2026-11-10: for a Pluto on USB there is NO
# kernel IIO device, ever. The IIO protocol is spoken over libusb in user space, so
# /sys/bus/iio/devices stays empty even when the radio is perfectly healthy. An earlier version of
# this script treated that empty directory as failure and reported a working radio as broken.
# The only honest test is whether libiio can produce a usb:/ip: context.
IIO_FOUND=0
IIO_NAMES=
for iio in /sys/bus/iio/devices/iio:device*; do
  [ -e "$iio" ] || continue
  IIO_FOUND=1
  IIO_NAMES="$IIO_NAMES $(cat "$iio/name" 2>/dev/null)"
done
if [ "$IIO_FOUND" = 1 ]; then
  say "  kernel iio devices:$IIO_NAMES"
else
  say "  kernel iio devices: none  (expected - a USB Pluto is a user-space libiio device)"
fi

# The interesting attributes, if the phy device is there. These answer the open questions in
# docs/ogn-rf-integration.md without needing an ogn-rf build.
for iio in /sys/bus/iio/devices/iio:device*; do
  [ -e "$iio" ] || continue
  case "$(cat "$iio/name" 2>/dev/null)" in
    ad9361-phy)
      say "  ad9361-phy attributes:"
      for attr in sampling_frequency sampling_frequency_available rf_bandwidth \
                  gain_control_mode hardwaregain; do
        if [ -r "$iio/$attr" ]; then
          say "    $attr = $(cat "$iio/$attr" 2>/dev/null)"
        fi
      done
      for ch in voltage0 voltage1 altvoltage0; do
        [ -d "$iio/$ch" ] || continue
        for attr in sampling_frequency sampling_frequency_available rf_bandwidth \
                    hardwaregain gain_control_mode frequency; do
          [ -r "$iio/$ch/$attr" ] || continue
          say "    $ch/$attr = $(cat "$iio/$ch/$attr" 2>/dev/null)"
        done
      done
      ;;
  esac
done

# The real test: build the tiny scanner (if needed) and ask libiio what it can open.
LIBIIO_URI=
if [ "$PLUTO_FOUND" = 1 ]; then
  PSRC=$HERE/../src/pluto_probe.c
  PBIN=$HERE/../pluto_probe
  if [ ! -r /usr/include/iio.h ]; then
    say "  libiio scan: skipped, /usr/include/iio.h is missing (install libiio-dev)"
  else
    if [ ! -x "$PBIN" ] || [ "$PSRC" -nt "$PBIN" ]; then
      # libad9361 gives us ad9361_set_bb_rate(), which is the only way to get exactly 2.0 or 1.0
      # MSPS out of the chip - the plain sampling_frequency attribute bottoms out at 2083333 Hz.
      if [ -r /usr/include/ad9361.h ]; then
        gcc -O2 -w -DUSE_AD9361 -o "$PBIN" "$PSRC" -liio -lad9361 -lm 2>/dev/null || \
        gcc -O2 -w -o "$PBIN" "$PSRC" -liio -lm 2>/dev/null
      else
        gcc -O2 -w -o "$PBIN" "$PSRC" -liio -lm 2>/dev/null
      fi
    fi
    if [ -x "$PBIN" ]; then
      LIBIIO_SCAN=$("$PBIN" --scan 2>/dev/null | tail -1)
      case "$LIBIIO_SCAN" in
        usb:*|ip:*) LIBIIO_URI=$LIBIIO_SCAN
                    say "  libiio scan: $LIBIIO_URI  <- the radio is openable" ;;
        *)          say "  libiio scan: nothing openable (it reported ${LIBIIO_SCAN:-nothing})" ;;
      esac
    else
      say "  libiio scan: could not build the scanner (gcc or libiio-dev missing)"
    fi
  fi
fi

# ------------------------------------------------------------------------------------------------
# 4. The other faces: network gadget, serial console, mass storage
# ------------------------------------------------------------------------------------------------
head1 "other Pluto faces"
NET_IF=$(ip -4 -o addr 2>/dev/null | awk '$4 ~ /^192\.168\.2\./ {print $2, $4}' | head -3)
if [ -n "$NET_IF" ]; then
  say "  network gadget: $(echo "$NET_IF" | tr '\n' ' ')"
  if have ping; then
    if ping -c 1 -W 1 192.168.2.1 >/dev/null 2>&1; then
      say "  192.168.2.1 answers -> the radio could also be reached as ip:192.168.2.1"
    else
      say "  192.168.2.1 does not answer yet"
    fi
  fi
else
  say "  network gadget: no 192.168.2.x interface (the ethernet function is not up, or not configured)"
fi

TTY=$(ls /dev/ttyACM* 2>/dev/null | tr '\n' ' ')
say "  serial console: ${TTY:-none (/dev/ttyACM* absent)}"

BLKROWS=$(lsblk -o NAME,SIZE,VENDOR,MODEL 2>/dev/null | awk 'NR>1 && ($3 ~ /File-Stor|Linux/ || $0 ~ /File-Stor/)')
if [ -n "$BLKROWS" ]; then
  MASS_STORAGE=1
  say "  mass storage:"
  echo "$BLKROWS" | sed 's/^/    /'
else
  MASS_STORAGE=0
  say "  mass storage: none"
fi

# ------------------------------------------------------------------------------------------------
# 5. libiio and permissions
# ------------------------------------------------------------------------------------------------
head1 "libiio and access"
if [ -r /usr/include/iio.h ]; then
  say "  headers: /usr/include/iio.h present (a backend and the probe can be built)"
else
  say "  headers: MISSING (install libiio-dev; the probe cannot be built)"
fi
if ldconfig -p 2>/dev/null | grep -q 'libiio\.so'; then
  say "  runtime: $(ldconfig -p | grep -m1 'libiio\.so' | awk '{print $1}') present"
else
  say "  runtime: MISSING (install libiio0)"
fi
say "  iio_info: $(have iio_info && echo "$(command -v iio_info)" || echo 'not installed (optional; apt install iio-utils)')"

RULE_STATE=no
for f in /lib/udev/rules.d /etc/udev/rules.d; do
  grep -rlqs "idVendor}\"==\"$PLUTO_VENDOR\"\|idVendor}==" "$f" 2>/dev/null && \
    grep -rls "0456" "$f" 2>/dev/null | head -1 | grep -q . && RULE_STATE=yes
done
if [ "$RULE_STATE" = yes ]; then
  say "  udev rule for vendor $PLUTO_VENDOR: present"
else
  say "  udev rule for vendor $PLUTO_VENDOR: absent -> only root can open the radio"
  say "      fix: sudo $HERE/install-pluto-udev.sh"
fi

if [ -n "$USB_NODE" ] && [ -e "$USB_NODE" ]; then
  perms=$(ls -l "$USB_NODE" 2>/dev/null | awk '{print $1, $3, $4}')
  if [ -r "$USB_NODE" ] && [ -w "$USB_NODE" ]; then
    say "  $USB_NODE: $perms  -> readable and writable by $(id -un)"
  else
    say "  $USB_NODE: $perms  -> NOT writable by $(id -un)"
  fi
fi

# ------------------------------------------------------------------------------------------------
# 6. What the kernel said, including the past
# ------------------------------------------------------------------------------------------------
head1 "kernel log (USB events involving Analog Devices, newest last)"
KLOG=
if have journalctl && journalctl -k -n 1 >/dev/null 2>&1; then
  KLOG=$(journalctl -k --no-pager 2>/dev/null | grep -iE "0456|pluto|Analog Devices" | tail -15)
elif [ -r /var/log/kern.log ]; then
  KLOG=$(grep -iE "0456|pluto|Analog Devices" /var/log/kern.log 2>/dev/null | tail -15)
fi
if [ -n "$KLOG" ]; then
  echo "$KLOG" | sed 's/^/  /'
else
  say "  nothing (or the kernel log is not readable by $(id -un); it is in group adm)"
fi

# Did it ever appear, and did it leave? That distinction is the whole point of reading the log.
EVER_SEEN=0
EVER_DISCONNECTED=0
if [ -n "$KLOG" ]; then
  echo "$KLOG" | grep -qi "idVendor=0456\|PlutoSDR" && EVER_SEEN=1
  echo "$KLOG" | grep -qi "USB disconnect" && EVER_DISCONNECTED=1
fi

# ------------------------------------------------------------------------------------------------
# 7. Verdict
# ------------------------------------------------------------------------------------------------
head1 "verdict"
if [ "$PLUTO_FOUND" = 1 ] && [ -n "$LIBIIO_URI" ]; then
  say "  The radio is present and libiio can open it. This is the working case."
  say "  Next: ./probe-pluto.sh --capture        a live receive check, independent of ogn-rf"
  say "        ./probe-pluto.sh --capture -v     the same, plus every attribute the AD9363 reports"
  RC=0
elif [ "$PLUTO_FOUND" = 1 ] && [ -z "$CONFIGURED" ]; then
  say "  The radio is on the bus but never finished configuring: bConfigurationValue is empty,"
  say "  so no interface is live and libiio has nothing to open."
  say "  Look at the kernel lines above for 'can't set config' or a reset right after enumeration."
  say "  In this repository's history that was a power problem, and external power to the radio"
  say "  fixed it - docs/status-log.md, the 11:12 entry."
  if [ "$MASS_STORAGE" = 1 ]; then
    say "  A storage volume did appear, so the gadget is partly up before it gives out."
  else
    say "  No storage volume either, so the gadget never came up at all."
  fi
  RC=1
elif [ "$PLUTO_FOUND" = 1 ] && [ -n "$USB_NODE" ] && [ ! -w "$USB_NODE" ]; then
  say "  The radio is present and CONFIGURED, but $USB_NODE is not writable by $(id -un):"
  say "    $(ls -l "$USB_NODE" 2>/dev/null | awk '{print $1, $3, $4}')"
  say "  libiio opens USB devices through libusb, which needs write access, so this is a"
  say "  permissions gap and not a radio fault. One command fixes it:"
  say "      sudo $HERE/install-pluto-udev.sh"
  RC=1
elif [ "$PLUTO_FOUND" = 1 ]; then
  say "  The radio is present, configured, and this user may write its node - but libiio still"
  say "  cannot produce a usb: context. So the IIO function on the device is not answering,"
  say "  even though its storage function enumerated."
  say "  Next: the device's firmware. See docs/hardware.md, 'The Pluto's several USB faces', and"
  say "  check whether the FAT volume's config enables the IIO/network function."
  RC=1
elif [ "$EVER_SEEN" = 1 ]; then
  say "  No Analog Devices device is on the bus now, but the kernel log shows it WAS connected."
  [ "$EVER_DISCONNECTED" = 1 ] && say "  It disconnected after enumerating - see the log above for the timestamp."
  say "  History worth knowing before re-testing: the radio used to fall off the bus within"
  say "  1-4 seconds on every plug, with no other device on the bus, and giving it EXTERNAL POWER"
  say "  fixed that - it then stayed up and configured. If it is dropping again, suspect its"
  say "  supply first."
  say "  To catch the seconds it lives for, watch while you replug:"
  say "      $HERE/watch-pluto.sh"
  RC=1
else
  say "  No Analog Devices device is on the bus, and the kernel log has no record of one."
  say "  The radio is not connected, or nothing on this machine can see it. Check the cable,"
  say "  and that it is plugged into THIS machine (xavieragx.local, 192.168.0.81)."
  RC=1
fi

[ "$BRIEF" = 1 ] && {
  if [ -n "${LIBIIO_URI:-}" ]; then echo "OK" >&3; else echo "FAIL" >&3; fi
}

# ------------------------------------------------------------------------------------------------
# 8. Optional live capture
# ------------------------------------------------------------------------------------------------
if [ "$MODE" = capture ]; then
  head1 "live capture"
  SRC=$HERE/../src/pluto_probe.c
  BIN=$HERE/../pluto_probe
  if [ ! -f "$SRC" ]; then
    echo "  missing $SRC" >&2; exit 1
  fi
  if [ ! -r /usr/include/iio.h ]; then
    echo "  libiio headers are missing; install libiio-dev first" >&2; exit 1
  fi
  if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
    echo "  building $BIN"
    gcc -O2 -Wall -o "$BIN" "$SRC" -liio -lm || exit 1
  fi
  echo
  "$BIN" "${CAPTURE_ARGS[@]}"
  RC=$?
  echo
  exit $RC
fi

exit $RC
