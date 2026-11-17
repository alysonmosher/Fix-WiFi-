#!/usr/bin/env bash
# wifi-diagnose.sh — find what's slowing your Wi-Fi down (macOS & Linux).
# Read-only: it never changes router or system settings.
# Usage: bash wifi-diagnose.sh            (sudo not required)

set -u
PROBLEMS=()
flag() { PROBLEMS+=("$1"); echo "  ⚠️  $1"; }
ok()   { echo "  ✅ $1"; }
hdr()  { printf '\n== %s ==\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

OS=$(uname -s)
SIGNAL="" NOISE="" CHANNEL="" RATE="" BAND="" PHY="" IFACE="" NEIGHBORS=""

# ---------------------------------------------------------------- Wi-Fi link
hdr "Wi-Fi connection"
if [ "$OS" = "Darwin" ]; then
  IFACE=$(networksetup -listallhardwareports | awk '/Wi-Fi|AirPort/{getline; print $2; exit}')
  SP=$(system_profiler SPAirPortDataType 2>/dev/null)
  CUR=$(printf '%s\n' "$SP" | awk '/Current Network Information:/{f=1;next} /Other Local Wi-Fi Networks:/{f=0} f')
  PHY=$(printf '%s\n' "$CUR"     | awk -F': ' '/PHY Mode/{print $2; exit}')
  CHANNEL=$(printf '%s\n' "$CUR" | awk -F': ' '/Channel:/{print $2; exit}')
  SN=$(printf '%s\n' "$CUR"      | awk -F': ' '/Signal \/ Noise/{print $2; exit}')
  SIGNAL=$(printf '%s' "$SN" | grep -oE -- '-?[0-9]+' | sed -n 1p)
  NOISE=$(printf '%s' "$SN"  | grep -oE -- '-?[0-9]+' | sed -n 2p)
  RATE=$(printf '%s\n' "$CUR"    | awk -F': ' '/Transmit Rate/{print $2; exit}')
  case "$CHANNEL" in *2GHz*) BAND=2.4 ;; *5GHz*) BAND=5 ;; *6GHz*) BAND=6 ;; esac
  CHNUM=$(printf '%s' "$CHANNEL" | grep -oE '^[0-9]+')
  # neighbours seen on the same channel number
  NEIGHBORS=$(printf '%s\n' "$SP" | awk '/Other Local Wi-Fi Networks:/{f=1} f' \
              | awk -F': ' -v c="$CHNUM" '/Channel:/{split($2,a," "); if (a[1]==c) n++} END{print n+0}')
elif [ "$OS" = "Linux" ]; then
  if have iw; then
    IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
    if [ -n "$IFACE" ]; then
      LINK=$(iw dev "$IFACE" link 2>/dev/null)
      SIGNAL=$(printf '%s\n' "$LINK" | awk '/signal:/{print $2; exit}')
      RATE=$(printf '%s\n' "$LINK"   | awk -F': ' '/tx bitrate/{print $2; exit}')
      FREQ=$(printf '%s\n' "$LINK"   | awk '/freq:/{print int($2); exit}')
      if [ -n "${FREQ:-}" ]; then
        if   [ "$FREQ" -lt 3000 ]; then BAND=2.4; CHNUM=$(( (FREQ-2407)/5 ))
        elif [ "$FREQ" -lt 5950 ]; then BAND=5;   CHNUM=$(( (FREQ-5000)/5 ))
        else BAND=6; CHNUM=$(( (FREQ-5950)/5 )); fi
        CHANNEL="$CHNUM ($BAND GHz)"
      fi
    fi
  fi
  if have nmcli && [ -n "${CHNUM:-}" ]; then
    NEIGHBORS=$(nmcli -t -f IN-USE,CHAN dev wifi list 2>/dev/null | awk -F: -v c="$CHNUM" '$1!="*" && $2==c{n++} END{print n+0}')
  fi
fi

if [ -z "$IFACE$SIGNAL$CHANNEL" ]; then
  echo "  (No Wi-Fi interface found — are you on Wi-Fi? Wired-only results follow.)"
else
  echo "  Interface: ${IFACE:-?}  PHY: ${PHY:-?}  Channel: ${CHANNEL:-?}  Link rate: ${RATE:-?}"
  echo "  Signal: ${SIGNAL:-?} dBm  Noise: ${NOISE:-?} dBm"
  if [ -n "$SIGNAL" ]; then
    if   [ "$SIGNAL" -le -75 ]; then flag "Very weak signal ($SIGNAL dBm). Move closer, raise/relocate the router, or add a mesh node."
    elif [ "$SIGNAL" -le -67 ]; then flag "Weak signal ($SIGNAL dBm); below -67 dBm speeds drop noticeably."
    else ok "Signal strength is good ($SIGNAL dBm)."; fi
  fi
  if [ -n "$SIGNAL" ] && [ -n "$NOISE" ]; then
    SNR=$(( SIGNAL - NOISE ))
    if [ "$SNR" -lt 25 ]; then flag "Low signal-to-noise ratio (${SNR} dB). Interference from microwaves, baby monitors, Bluetooth or neighbours."
    else ok "Signal-to-noise ratio OK (${SNR} dB)."; fi
  fi
  if [ "$BAND" = "2.4" ]; then
    flag "Connected on 2.4 GHz, which is slower and more crowded. Use the 5 GHz (or 6 GHz) network if you're within range."
    case "${CHNUM:-}" in 1|6|11|"") ;; *) flag "2.4 GHz channel $CHNUM overlaps neighbours. Set the router to channel 1, 6 or 11." ;; esac
  fi
  case "$PHY" in *802.11b*|*802.11g*|*802.11n*) [ -n "$PHY" ] && flag "Old Wi-Fi standard ($PHY). A Wi-Fi 5/6 router or adapter would be much faster." ;; esac
  if [ -n "$NEIGHBORS" ]; then
    if [ "$NEIGHBORS" -ge 5 ]; then flag "$NEIGHBORS other networks share your channel. Pick a less crowded channel in the router settings."
    else ok "$NEIGHBORS other networks on your channel."; fi
  fi
fi

# ---------------------------------------------------------------- Router
hdr "Router"
if [ "$OS" = "Darwin" ]; then GW=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
else GW=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}'); fi
echo "  Gateway: ${GW:-not found}"

ping_stats() { # host count -> "loss avg max mdev"
  ping -c "$2" -i 0.2 "$1" 2>/dev/null | awk -F'[/ =%]+' '
    /packet loss/{for(i=1;i<=NF;i++) if($i=="packet") loss=$(i-1)}
    /min\/avg\/max/{avg=$(NF-3); max=$(NF-2); dev=$(NF-1)}
    END{print (loss==""?100:loss), avg+0, max+0, dev+0}'
}

if [ -n "${GW:-}" ]; then
  read -r GLOSS GAVG GMAX GDEV < <(ping_stats "$GW" 30)
  echo "  Ping to router: avg ${GAVG} ms, max ${GMAX} ms, jitter ${GDEV} ms, loss ${GLOSS}%"
  awk -v l="$GLOSS" 'BEGIN{exit !(l>0)}' && flag "Packet loss to your own router (${GLOSS}%). This is a Wi-Fi link problem (signal or interference), not your ISP."
  awk -v a="$GAVG" 'BEGIN{exit !(a>10)}'  && flag "High latency to router (${GAVG} ms; should be <5 ms). Interference, congestion or an overloaded router."
  awk -v d="$GDEV" 'BEGIN{exit !(d>10)}'  && flag "High jitter to router (${GDEV} ms). Bad for video calls and gaming."
  # identify router via its web UI
  if have curl; then
    SRV=$(curl -s -m 4 -I "http://$GW" 2>/dev/null | awk -F': ' 'tolower($1)=="server"{print $2}' | tr -d '\r')
    TITLE=$(curl -s -m 4 -L "http://$GW" 2>/dev/null | grep -oiE '<title>[^<]*' | head -1 | sed 's/<title>//I')
    [ -n "$SRV$TITLE" ] && echo "  Router web UI: ${TITLE:-?} (server: ${SRV:-?}). Open http://$GW to change channel or firmware."
  fi
  DEVICES=$(arp -an 2>/dev/null | grep -v incomplete | grep -c .)
  echo "  Devices this computer has recently seen on the network: $DEVICES"
  [ "$DEVICES" -ge 25 ] && flag "$DEVICES active devices; many devices share airtime. Check the router's client list for unknown or bandwidth-hungry ones."
fi

# ---------------------------------------------------------------- Internet
hdr "Internet"
read -r ILOSS IAVG IMAX IDEV < <(ping_stats 1.1.1.1 20)
echo "  Ping to 1.1.1.1: avg ${IAVG} ms, jitter ${IDEV} ms, loss ${ILOSS}%"
[ -n "${GLOSS:-}" ] && awk -v l="$ILOSS" -v g="$GLOSS" 'BEGIN{exit !(l>0 && g==0)}' && flag "Loss to the internet but not to the router: likely your ISP/modem."

if have python3; then
  DNS_MS=$(python3 -I -c 'import socket,time
t=time.time(); socket.getaddrinfo("www.wikipedia.org",80); print(int((time.time()-t)*1000))' 2>/dev/null)
  [ -n "$DNS_MS" ] && echo "  DNS lookup: ${DNS_MS} ms"
  [ -n "$DNS_MS" ] && [ "$DNS_MS" -gt 150 ] && flag "Slow DNS (${DNS_MS} ms). Try 1.1.1.1 or 8.8.8.8 as DNS servers on the router."
fi

if have curl; then
  echo "  Measuring download speed (25 MB)…"
  BPS=$(curl -s -o /dev/null -m 30 -w '%{speed_download}' "https://speed.cloudflare.com/__down?bytes=25000000")
  MBPS=$(awk -v b="${BPS:-0}" 'BEGIN{printf "%.1f", b*8/1e6}')
  echo "  Download: ${MBPS} Mbps"
  [ -n "$RATE" ] && echo "  (Compare with your Wi-Fi link rate of ${RATE} and the speed your ISP plan promises.)"
fi

# ---------------------------------------------------------------- Summary
hdr "Summary"
if [ ${#PROBLEMS[@]} -eq 0 ]; then
  echo "  No obvious problems found. If it's still slow, compare the download speed to your ISP plan and test with a cable."
else
  echo "  ${#PROBLEMS[@]} issue(s) found:"
  i=1; for p in "${PROBLEMS[@]}"; do echo "   $i. $p"; i=$((i+1)); done
fi
echo
echo "  Tip: also check http://${GW:-your-router} for a firmware update, and reboot the router if it hasn't been in weeks."
