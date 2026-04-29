#!/usr/bin/env bash
# Fallback RCON sync (used only if python3 is unavailable)
set -euo pipefail
PROP="${DATA_DIR:-/data}/server.properties"
PW="${RCON_PASSWORD:-HellC0re_Rc0n2026!}"
TMP="$(mktemp)"
awk -v pw="$PW" '
  BEGIN { rcon_e=0; rcon_p=0; rcon_pw=0; bcast=0 }
  /^enable-rcon=/        { print "enable-rcon=true"; rcon_e=1; next }
  /^rcon\.port=/         { print "rcon.port=25575"; rcon_p=1; next }
  /^rcon\.password=/     { print "rcon.password=" pw; rcon_pw=1; next }
  /^broadcast-rcon-to-ops=/ { print "broadcast-rcon-to-ops=false"; bcast=1; next }
  { print }
  END {
    if (!rcon_e)  print "enable-rcon=true"
    if (!rcon_p)  print "rcon.port=25575"
    if (!rcon_pw) print "rcon.password=" pw
    if (!bcast)   print "broadcast-rcon-to-ops=false"
  }
' "$PROP" > "$TMP"
mv "$TMP" "$PROP"
