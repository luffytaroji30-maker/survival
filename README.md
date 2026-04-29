# Survival 1.21 — Railway Deployment

Paper 1.21 Minecraft server + web management panel, deployable to Railway with a single `git push`.

## What you get

- **Paper 1.21** (latest stable build, auto-downloaded on first boot) tuned with Aikar's flags for low GC pauses.
- **Web panel** ([panel/](panel/)) — login, console, players, plugins, files, backups, settings, users.
- **Persistent `/data` volume** — world, plugins, configs and backups survive redeploys.
- **PlugManX** auto-installed so the panel can hot-load/unload plugins.
- **RCON** on `127.0.0.1:25575` (internal only) wired to the panel automatically.

## Repository layout

```
Dockerfile              # Builds JDK 21 + Node 20 + Paper runtime
railway.toml            # Railway service config (Dockerfile + volume)
scripts/
  start.sh              # Container entrypoint (downloads Paper, runs panel + server)
  sync-rcon.sh
  server.properties.default
  bukkit.yml.default
  spigot.yml.default
  paper-global.yml.default
panel/                  # React + Express management panel
```

## Deploy to Railway

1. **Push this repo to GitHub.**
2. In Railway: **New Project → Deploy from GitHub Repo** → select this repo. Railway will detect `railway.toml` and build from the Dockerfile.
3. **Attach a Volume** to the service:
   - Service → *Settings* → *Volumes* → **Add Volume**
   - Mount path: `/data`
   - Size: `20 GB` is plenty for survival; bump as needed.
4. **Set environment variables** (Service → *Variables*):

   | Variable          | Default                  | Notes                                  |
   |-------------------|--------------------------|----------------------------------------|
   | `MC_VERSION`      | `1.21.10`                | Any Paper 1.21.x build                 |
   | `MEMORY_MB`       | `6144`                   | Heap size. Pro plan: 6144–8192 is safe |
   | `PANEL_USERNAME`  | `admin`                  | **Change this**                        |
   | `PANEL_PASSWORD`  | `adminadmin123`          | **Change this**                        |
   | `RCON_PASSWORD`   | `HellC0re_Rc0n2026!`     | **Change this**                        |
   | `EULA`            | `TRUE`                   | Accepts the Mojang EULA                |

5. **Generate the panel domain** (Service → *Settings* → *Networking* → **Generate Domain**). That URL serves the panel.
6. **Add a TCP Proxy** so players can connect to the Minecraft server:
   - Service → *Settings* → *Networking* → **TCP Proxy** → Target port `25565`.
   - Railway gives you a host like `mainline.proxy.rlwy.net` and a public port (e.g. `12345`). That `host:port` is what players type into Minecraft.
7. Wait for the first build to finish, open the panel domain, log in.

## Performance notes (Pro plan, no lag)

- Paper + Aikar's G1GC flags are configured in [scripts/start.sh](scripts/start.sh).
- `view-distance=8`, `simulation-distance=6` (defaults in [scripts/server.properties.default](scripts/server.properties.default)) — change from the panel Settings page if you want.
- Entity activation/tracking ranges in [scripts/spigot.yml.default](scripts/spigot.yml.default) reduce CPU work for distant mobs.
- `MEMORY_MB=6144` works well for ~20 players. Bump up to 8192 if running many plugins or pre-generating large worlds.
- Want pre-generated chunks? Drop the **Chunky** plugin in `/data/plugins` from the panel and run `chunky start world square 0 0 5000`.

## Local development

```powershell
# Run the panel UI in dev mode (hot reload, no MC server)
cd panel
npm install
npm run dev
```

The dev server proxies API calls to a real backend; for end-to-end testing locally, use Docker:

```powershell
docker build -t survival .
docker run --rm -it -p 3000:3000 -p 25565:25565 -v ${PWD}/data:/data survival
```

Open http://localhost:3000 → log in with `admin` / `adminadmin123`.

## Updating Paper

Change `MC_VERSION` in Railway and redeploy. The container will detect the version change and download the new build on next boot. World data is preserved.
