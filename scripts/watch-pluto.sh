#!/bin/bash
# Capture the brief life of an intermittent ADALM-PLUTO.
#
# The reason this exists: this radio enumerates and then disappears again within one or two seconds,
# which is too fast to inspect by hand. This script polls the USB, IIO, serial console and block
# layers several times a second, records every change with a timestamp, and dumps the full state of
# the device each time it comes back — so the next replug produces evidence instead of a shrug.
#
# Usage:
#   ./watch-pluto.sh                      # watch for 240 s, log to ./pluto-watch-<time>.log
#   ./watch-pluto.sh -d 600 -i 50         # 10 minutes, 20 samples a second
#   ./watch-pluto.sh -o /tmp/w.log        # a specific log file
#
# While it runs, replug the radio. Then read the log, or let whoever asked read it.
#
# Read-only: it writes a log and nothing else. No root needed.
set -u

VENDOR=0456

DURATION=240
INTERVAL=200               # [ms]
LOG=

while [ $# -gt 0 ]; do
  case "$1" in
    -d) [ $# -ge 2 ] || { echo "-d needs seconds" >&2; exit 2; }; DURATION=$2; shift 2 ;;
    -i) [ $# -ge 2 ] || { echo "-i needs milliseconds" >&2; exit 2; }; INTERVAL=$2; shift 2 ;;
    -o) [ $# -ge 2 ] || { echo "-o needs a path" >&2; exit 2; };     LOG=$2;      shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1 (try --help)" >&2; exit 2 ;;
  esac
done

case "$DURATION" in ''|*[!0-9]*) echo "duration must be a whole number of seconds" >&2; exit 2 ;; esac
case "$INTERVAL" in ''|*[!0-9]*) echo "interval must be a whole number of milliseconds" >&2; exit 2 ;; esac

# sleep(1) takes fractions; do the division once instead of at every poll.
SLEEP_S=$(awk -v ms="$INTERVAL" 'BEGIN { printf "%.3f", ms / 1000 }')

[ -n "$LOG" ] || LOG="$PWD/pluto-watch-$(date +%Y%m%d-%H%M%S).log"
: > "$LOG" || { echo "cannot write $LOG" >&2; exit 1; }

log() { printf '%s %s\n' "$(date +%H:%M:%S.%3N)" "$*" >> "$LOG"; }

KERNEL_MARK=$(date '+%Y-%m-%d %H:%M:%S')
log "=== watch started, ${DURATION}s, sampling every ${INTERVAL}ms ==="
log "=== host $(uname -srm) ==="

# ------------------------------------------------------------------------------------------------
# A full description of whatever state the device is in right now. Empty when it is absent.
# ------------------------------------------------------------------------------------------------
snapshot()
{
  local found=0 dev port out=""
  for dev in /sys/bus/usb/devices/*/; do
    [ -f "$dev/idVendor" ] || continue
    [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$VENDOR" ] || continue
    found=1
    port=$(basename "$dev")
    local cfg busnum devnum node
    cfg=$(cat "$dev/bConfigurationValue" 2>/dev/null)
    busnum=$(cat "$dev/busnum" 2>/dev/null)
    devnum=$(cat "$dev/devnum" 2>/dev/null)
    node=$(printf '/dev/bus/usb/%03d/%03d' "${busnum:-0}" "${devnum:-0}")
    out="port=$port cfg=${cfg:-UNCONFIGURED} node=$node"
    [ -r "$dev/product" ] && out="$out product=$(cat "$dev/product")"
    [ -r "$dev/serial" ] && out="$out serial=$(cat "$dev/serial")"

    # configuration descriptor: bNumInterfaces, bmAttributes, bMaxPower (offsets 22, 25, 26)
    if [ -r "$dev/descriptors" ]; then
      local d
      d=$(od -An -tu1 -j 22 -N 5 "$dev/descriptors" 2>/dev/null | tr -s ' ')
      [ -n "$d" ] && out="$out config[nIf,bAttr,maxPwr]=($d)"
    fi

    # which interfaces are live, and what bound to them
    local iface drv cls
    for iface in "$dev"*:*; do
      [ -d "$iface" ] || continue
      cls=$(cat "$iface/bInterfaceClass" 2>/dev/null)
      drv=$([ -e "$iface/driver" ] && basename "$(readlink -f "$iface/driver")" || echo none)
      out="$out iface[$(basename "$iface") cls=$cls drv=$drv]"
    done
  done

  local iio=""
  for d in /sys/bus/iio/devices/iio:device*; do
    [ -e "$d" ] && iio="$iio $(basename "$d"):$(cat "$d/name" 2>/dev/null)"
  done
  local tty blk
  tty=$(ls /dev/ttyACM* 2>/dev/null | tr '\n' ',')
  blk=$(lsblk -no NAME,VENDOR 2>/dev/null | awk '/File-Stor/ {printf "%s,", $1}')
  local netif
  netif=$(ip -4 -o addr show 2>/dev/null | awk '$4 ~ /^192\.168\.2\./ {printf "%s:%s,", $2, $4}')

  printf 'present=%d %s iio=[%s] tty=[%s] block=[%s] net=[%s]' \
    "$found" "$out" "${iio# }" "${tty%,}" "${blk%,}" "${netif%,}"
}

# ------------------------------------------------------------------------------------------------
# When it does show up, grab the things that are only readable while it is alive.
# ------------------------------------------------------------------------------------------------
detail()
{
  local dev
  for dev in /sys/bus/usb/devices/*/; do
    [ -f "$dev/idVendor" ] || continue
    [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$VENDOR" ] || continue
    log "    detail: $(basename "$dev") descriptors:"
    od -An -tx1 -v "$dev/descriptors" 2>/dev/null | head -6 | sed 's/^/      |/' >> "$LOG"
    if [ -r "$dev/bConfigurationValue" ] && [ -n "$(cat "$dev/bConfigurationValue" 2>/dev/null)" ]; then
      log "    detail: CONFIGURED as value $(cat "$dev/bConfigurationValue")"
    else
      log "    detail: not configured"
    fi
  done
  log "    detail: lsblk: $(lsblk -o NAME,SIZE,VENDOR,MODEL 2>/dev/null | tr '\n' '|')"
  log "    detail: usb devices: $(lsusb 2>/dev/null | tr '\n' '|')"
}

# ------------------------------------------------------------------------------------------------
# Poll.
# ------------------------------------------------------------------------------------------------
PREV=""
APPEARANCES=0
LAST_PRESENT=0
END=$((SECONDS + DURATION))

while [ "$SECONDS" -lt "$END" ]; do
  S=$(snapshot)
  if [ "$S" != "$PREV" ]; then
    log "$S"
    case "$S" in
      present=1*)
        if [ "$LAST_PRESENT" = 0 ]; then
          APPEARANCES=$((APPEARANCES + 1))
          log "    ^^ device appeared"
          detail
        fi
        LAST_PRESENT=1
        ;;
      *)
        if [ "$LAST_PRESENT" = 1 ]; then log "    ^^ device GONE"; fi
        LAST_PRESENT=0
        ;;
    esac
    PREV=$S
  fi
  sleep "$SLEEP_S"
done

log "=== watch finished: device appeared ${APPEARANCES} time(s) in ${DURATION}s ==="

# What the kernel said while we were watching. This is usually the most informative part.
if command -v journalctl >/dev/null 2>&1 && journalctl -k -n 1 >/dev/null 2>&1; then
  log "=== kernel USB events since $KERNEL_MARK ==="
  journalctl -k --no-pager --since "$KERNEL_MARK" 2>/dev/null \
    | grep -iE "usb [0-9]-|$VENDOR|pluto|iio|cdc|rndis|storage|over-?current|reset" \
    | sed 's/^/  /' >> "$LOG"
fi

echo "log written to $LOG"
echo
if [ "$APPEARANCES" = 0 ]; then
  echo "The radio never appeared during the ${DURATION}s window."
else
  echo "The radio appeared ${APPEARANCES} time(s):"
  grep -E "device appeared|device GONE|UNCONFIGURED|CONFIGURED as|GONE" "$LOG" | tail -20 | sed 's/^/  /'
fi
echo
echo "The interesting lines are the first 'device appeared' and the detail block under it:"
echo "  grep -A6 'device appeared' $LOG"
