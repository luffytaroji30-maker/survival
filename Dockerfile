# syntax=docker/dockerfile:1.6
# =========================================================================
# Stage 1 — Build the React panel UI
# =========================================================================
FROM node:20-alpine AS panel-builder
WORKDIR /panel

# Install deps first (better cache)
COPY panel/package.json panel/package-lock.json* panel/pnpm-lock.yaml* panel/yarn.lock* ./
RUN if [ -f package-lock.json ]; then npm ci; \
    else npm install; fi

# Copy source and build
COPY panel/ ./
RUN npm run build

# =========================================================================
# Stage 2 — Runtime: JDK 21 (Paper 1.21 requires Java 21) + Node 20 + tools
# =========================================================================
FROM eclipse-temurin:21-jre-jammy AS runtime

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates jq tar gzip bzip2 unzip xz-utils libarchive-tools tini procps \
        coreutils \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ---- Panel runtime files ----
# Copy panel source (server.cjs, rcon.cjs, package.json) and install prod deps
COPY panel/package.json panel/package-lock.json* ./panel/
RUN cd panel && (if [ -f package-lock.json ]; then npm ci --omit=dev --no-audit --no-fund; \
                else npm install --omit=dev --no-audit --no-fund; fi)
COPY panel/server.cjs panel/rcon.cjs ./panel/
COPY --from=panel-builder /panel/dist ./panel/dist

# ---- Server bootstrap files ----
COPY scripts/ /app/scripts/
RUN chmod +x /app/scripts/*.sh

# Persistent data directory (mount a Railway Volume here at /data)
ENV DATA_DIR=/data \
    MC_VERSION=1.21.10 \
    MEMORY_MB=6144 \
    RCON_PASSWORD=HellC0re_Rc0n2026! \
    PANEL_USERNAME=admin \
    PANEL_PASSWORD=adminadmin123 \
    EULA=TRUE

# Railway: set the public domain target port to 8080 (panel).
# Minecraft uses 25565 (expose via TCP Proxy in Railway networking settings).
EXPOSE 25565
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/scripts/start.sh"]
