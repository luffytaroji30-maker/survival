#!/usr/bin/env bash
# =====================================================================
# Container entrypoint
#   - Prepares /data on first boot (downloads Paper, writes configs)
#   - Starts Paper (Minecraft) and the panel side-by-side
#   - Forwards SIGTERM cleanly so Railway shutdowns persist data
# =====================================================================
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
MC_VERSION="${MC_VERSION:-1.21.10}"
MEMORY_MB="${MEMORY_MB:-6144}"
RCON_PASSWORD="${RCON_PASSWORD:-HellC0re_Rc0n2026!}"
EULA="${EULA:-TRUE}"

mkdir -p "$DATA_DIR" "$DATA_DIR/logs" "$DATA_DIR/plugins" "$DATA_DIR/backups"

# ---------------------------------------------------------------------
# 1) Ensure paper.jar exists (download latest build for $MC_VERSION)
# ---------------------------------------------------------------------
PAPER_JAR="$DATA_DIR/paper.jar"
PAPER_VERSION_FILE="$DATA_DIR/.paper-version"

NEED_DOWNLOAD=0
if [[ ! -f "$PAPER_JAR" ]]; then
  NEED_DOWNLOAD=1
elif [[ ! -f "$PAPER_VERSION_FILE" ]] || [[ "$(cat "$PAPER_VERSION_FILE" 2>/dev/null)" != "$MC_VERSION" ]]; then
  echo "[boot] Paper version changed -> re-downloading"
  NEED_DOWNLOAD=1
fi

if [[ "$NEED_DOWNLOAD" == "1" ]]; then
  echo "[boot] Fetching Paper $MC_VERSION ..."
  BUILD=$(curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}/builds" \
            | jq -r '[.builds[] | select(.channel=="default")] | last | .build')
  if [[ -z "$BUILD" || "$BUILD" == "null" ]]; then
    BUILD=$(curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}/builds" \
              | jq -r '.builds | last | .build')
  fi
  JAR_NAME="paper-${MC_VERSION}-${BUILD}.jar"
  URL="https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}/builds/${BUILD}/downloads/${JAR_NAME}"
  echo "[boot] Downloading $URL"
  curl -fSL --retry 5 --retry-delay 3 -o "$PAPER_JAR.tmp" "$URL"
  mv "$PAPER_JAR.tmp" "$PAPER_JAR"
  echo "$MC_VERSION" > "$PAPER_VERSION_FILE"
  echo "[boot] Paper $MC_VERSION build $BUILD installed."
fi

# ---------------------------------------------------------------------
# 2) First-boot template files (only created if missing — never overwrites)
# ---------------------------------------------------------------------
[[ -f "$DATA_DIR/eula.txt" ]] || echo "eula=${EULA}" > "$DATA_DIR/eula.txt"

if [[ ! -f "$DATA_DIR/server.properties" ]]; then
  echo "[boot] Writing default server.properties"
  cp /app/scripts/server.properties.default "$DATA_DIR/server.properties"
fi

# Always sync RCON config to current env (panel needs it to match)
/app/scripts/sync-rcon.sh

# Paper / Bukkit performance defaults (only if missing)
[[ -f "$DATA_DIR/bukkit.yml" ]]          || cp /app/scripts/bukkit.yml.default          "$DATA_DIR/bukkit.yml"
[[ -f "$DATA_DIR/spigot.yml" ]]          || cp /app/scripts/spigot.yml.default          "$DATA_DIR/spigot.yml"
[[ -d "$DATA_DIR/config" ]]              || mkdir -p "$DATA_DIR/config"
[[ -f "$DATA_DIR/config/paper-global.yml" ]] || cp /app/scripts/paper-global.yml.default "$DATA_DIR/config/paper-global.yml"

# ---------------------------------------------------------------------
# 2b) Tolerance patches for Railway's TCP proxy (idempotent — run every boot).
#     Prevents "moved too quickly" / "keepalive out-of-order" disconnects
#     caused by proxy-induced jitter.
# ---------------------------------------------------------------------
patch_yaml_value() {
  # patch_yaml_value <file> <key> <new_value>
  local file="$1" key="$2" val="$3"
  [[ -f "$file" ]] || return 0
  if grep -qE "^[[:space:]]*${key}:" "$file"; then
    sed -i -E "s|^([[:space:]]*${key}:).*|\1 ${val}|" "$file"
  fi
}
patch_yaml_value "$DATA_DIR/spigot.yml" "timeout-time"                 "300"
patch_yaml_value "$DATA_DIR/spigot.yml" "moved-too-quickly-multiplier" "25.0"
patch_yaml_value "$DATA_DIR/spigot.yml" "moved-wrongly-threshold"      "0.25"
patch_yaml_value "$DATA_DIR/config/paper-global.yml" "max-packet-rate" "2000.0"

# ---------------------------------------------------------------------
# 3) Auto-install PlugManX (panel uses `plugman` for hot load/unload)
# ---------------------------------------------------------------------
if ! ls "$DATA_DIR/plugins"/PlugManX*.jar >/dev/null 2>&1 && ! ls "$DATA_DIR/plugins"/plugmanx*.jar >/dev/null 2>&1; then
  echo "[boot] Installing PlugManX ..."
  PMX_URL=$(curl -fsSL https://api.modrinth.com/v2/project/plugmanx/version \
             | jq -r '.[0].files[] | select(.primary==true) | .url' | head -n1)
  if [[ -n "$PMX_URL" && "$PMX_URL" != "null" ]]; then
    curl -fsSL "$PMX_URL" -o "$DATA_DIR/plugins/PlugManX.jar" || echo "[boot] PlugManX download failed (non-fatal)"
  fi
fi

# ---------------------------------------------------------------------
# 4) Start panel (background) on PANEL_PORT (default 8080)
#    Never uses 25565 — that belongs to Paper.
# ---------------------------------------------------------------------
export PANEL_PORT="${PANEL_PORT:-8080}"
echo "[boot] Starting panel on port $PANEL_PORT ..."
( cd /app/panel && PORT="$PANEL_PORT" node server.cjs ) &
PANEL_PID=$!

# ---------------------------------------------------------------------
# 5) Start Paper (foreground) with Aikar's flags for low-latency GC
# ---------------------------------------------------------------------
cd "$DATA_DIR"

JVM_FLAGS=(
  "-Xms${MEMORY_MB}M"
  "-Xmx${MEMORY_MB}M"
  -XX:+UseG1GC
  -XX:+ParallelRefProcEnabled
  -XX:MaxGCPauseMillis=200
  -XX:+UnlockExperimentalVMOptions
  -XX:+DisableExplicitGC
  -XX:+AlwaysPreTouch
  -XX:G1NewSizePercent=30
  -XX:G1MaxNewSizePercent=40
  -XX:G1HeapRegionSize=8M
  -XX:G1ReservePercent=20
  -XX:G1HeapWastePercent=5
  -XX:G1MixedGCCountTarget=4
  -XX:InitiatingHeapOccupancyPercent=15
  -XX:G1MixedGCLiveThresholdPercent=90
  -XX:G1RSetUpdatingPauseTimePercent=5
  -XX:SurvivorRatio=32
  -XX:+PerfDisableSharedMem
  -XX:MaxTenuringThreshold=1
  -Dusing.aikars.flags=https://mcflags.emc.gs
  -Daikars.new.flags=true
  -Dfile.encoding=UTF-8
)

# Trap signals to gracefully shut down both processes (preserves world data)
shutdown() {
  echo "[boot] SIGTERM received — stopping Paper gracefully ..."
  if [[ -n "${PAPER_PID:-}" ]] && kill -0 "$PAPER_PID" 2>/dev/null; then
    # SIGTERM lets Paper run its shutdown hook and save the world cleanly
    kill -TERM "$PAPER_PID"
  fi
  if [[ -n "${PANEL_PID:-}" ]] && kill -0 "$PANEL_PID" 2>/dev/null; then
    kill -TERM "$PANEL_PID"
  fi
  wait "$PAPER_PID" 2>/dev/null || true
  wait "$PANEL_PID" 2>/dev/null || true
  exit 0
}
trap shutdown SIGTERM SIGINT

echo "[boot] Starting Paper $MC_VERSION with ${MEMORY_MB}MB heap ..."
java "${JVM_FLAGS[@]}" -jar "$PAPER_JAR" --nogui &
PAPER_PID=$!

# Wait for whichever exits first; treat panel exit as fatal too
wait -n "$PAPER_PID" "$PANEL_PID"
EXIT_CODE=$?
echo "[boot] A child process exited (code $EXIT_CODE). Shutting down."
shutdown
