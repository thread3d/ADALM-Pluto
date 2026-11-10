#!/bin/bash
# Install the udev rule that lets a non-root user open the ADALM-PLUTO over USB.
#
# Why this is needed: the Pluto is a libusb device with no kernel driver, so access is decided by
# the permissions of its /dev/bus/usb node. Ubuntu has rules for RTL-SDR and SDRplay but none for
# Analog Devices, so the node is root-owned and libiio can only open it as root. ogn-rf runs as a
# normal user, so the rule is not optional.
#
# Usage:
#   sudo ./install-pluto-udev.sh                # install (or replace) the rule and re-trigger
#   sudo ./install-pluto-udev.sh --with-tools   # also apt-install iio-utils (iio_info/iio_attr)
#   ./install-pluto-udev.sh --check             # unprivileged: report what is installed
#
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
RULE_SRC=$HERE/../config/90-libiio-pluto.rules
RULE_DST=/etc/udev/rules.d/90-libiio-pluto.rules
GROUP=plugdev

WITH_TOOLS=0
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --with-tools) WITH_TOOLS=1 ;;
    --check)      CHECK_ONLY=1 ;;
    -h|--help)    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------------------------
# --check: no root, no changes. Answers "would a non-root user be able to open the radio?".
# ---------------------------------------------------------------------------------------------
if [ "$CHECK_ONLY" = 1 ]; then
  echo "== udev rule"
  if [ -f "$RULE_DST" ]; then
    echo "  installed: $RULE_DST"
  else
    echo "  NOT installed: $RULE_DST does not exist"
  fi
  for f in /lib/udev/rules.d /etc/udev/rules.d; do
    if grep -rlqs 'idVendor}=="0456"' "$f" 2>/dev/null; then
      echo "  a rule matching vendor 0456 is present in $f"
    fi
  done

  echo "== group membership (libusb access relies on this, or on the seat tag)"
  if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx "$GROUP"; then
    echo "  $(id -un) is in $GROUP"
  else
    echo "  $(id -un) is NOT in $GROUP (uaccess tag may still cover a desktop seat)"
  fi

  echo "== device nodes"
  found=0
  for dev in /sys/bus/usb/devices/*/; do
    [ -f "$dev/idVendor" ] || continue
    [ "$(cat "$dev/idVendor" 2>/dev/null)" = "0456" ] || continue
    found=1
    busnum=$(cat "$dev/busnum" 2>/dev/null)
    devnum=$(cat "$dev/devnum" 2>/dev/null)
    node=$(printf '/dev/bus/usb/%03d/%03d' "${busnum:-0}" "${devnum:-0}")
    printf '  %s  %s:%s  %s\n' "$(basename "$dev")" \
      "$(cat "$dev/idVendor")" "$(cat "$dev/idProduct")" "$(cat "$dev/product" 2>/dev/null)"
    if [ -e "$node" ]; then
      printf '    %s: %s\n' "$node" "$(ls -l "$node" | awk '{print $1, $3, $4}')"
      if [ -r "$node" ] && [ -w "$node" ]; then
        echo "    readable+writable by $(id -un): OK"
      else
        echo "    NOT writable by $(id -un): the rule is not in effect (or needs a replug)"
      fi
    else
      echo "    $node does not exist (busnum/devnum unreadable without root?)"
    fi
  done
  [ "$found" = 1 ] || echo "  no 0456 device is present right now"
  exit 0
fi

# ---------------------------------------------------------------------------------------------
# Install.
# ---------------------------------------------------------------------------------------------
if [ "$(id -u)" != 0 ]; then
  echo "this needs root:  sudo $0 $*" >&2
  exit 1
fi

if [ ! -f "$RULE_SRC" ]; then
  echo "cannot find the rule at $RULE_SRC" >&2
  echo "(run this from the repository; it expects ../config/90-libiio-pluto.rules)" >&2
  exit 1
fi

echo "== installing $RULE_DST"
install -o root -g root -m 0644 "$RULE_SRC" "$RULE_DST" || exit 1

# The group has to exist and the invoking user has to be in it, or the MODE/GROUP part of the rule
# quietly does nothing. uaccess covers a desktop seat, but this board is normally reached over ssh,
# where there is no seat and the group is the only thing that works.
if getent group "$GROUP" >/dev/null 2>&1; then
  REAL_USER=${SUDO_USER:-}
  if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    if id -nG "$REAL_USER" | tr ' ' '\n' | grep -qx "$GROUP"; then
      echo "   $REAL_USER is already in $GROUP"
    else
      echo "   adding $REAL_USER to $GROUP"
      usermod -aG "$GROUP" "$REAL_USER" || echo "   WARNING: could not add $REAL_USER to $GROUP" >&2
      echo "   NOTE: the new group membership takes effect at the next login (or 'newgrp $GROUP')"
    fi
  else
    echo "   (SUDO_USER unset, so no user was added to $GROUP; add one with: usermod -aG $GROUP <user>)"
  fi
else
  echo "   WARNING: group $GROUP does not exist; only the uaccess tag will apply" >&2
fi

echo "== reloading udev rules"
udevadm control --reload-rules || echo "   WARNING: udevadm control failed" >&2
udevadm trigger --subsystem-match=usb || echo "   WARNING: udevadm trigger failed" >&2
udevadm settle --timeout=5 2>/dev/null

if [ "$WITH_TOOLS" = 1 ]; then
  if command -v iio_info >/dev/null 2>&1; then
    echo "== iio-utils already installed: $(command -v iio_info)"
  else
    echo "== installing iio-utils (iio_info, iio_attr, iio_readdev)"
    apt-get install -y iio-utils || echo "   WARNING: apt-get install failed; the probe does not need these" >&2
  fi
fi

echo
echo "== done. Verify as your normal user (not root):"
echo "     $HERE/probe-pluto.sh"
echo "     $HERE/install-pluto-udev.sh --check"
echo
echo "If the device was already plugged in when the rule was installed, it may need a replug to pick"
echo "up the new permissions. A device that is absent is a different problem: run probe-pluto.sh."
