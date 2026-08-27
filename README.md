# ACEVO Server Manager - Docker

Run [Emperor Servers'](https://emperorservers.com/) Assetto Corsa EVO Server
Manager in Docker. Wine is bundled since the AC EVO dedicated server
executable is Windows-only.

Confirmed working end-to-end: manager boots, downloads the game server via
steamcmd, and successfully runs a race server.

## Quick start

All you need to provide yourself is the installer and two files from your
Emperor Servers control panel — `install.sh` fetches everything else
(`docker-compose.yml`, `.env.example`, `update.sh`) from this repo:

```bash
# 1. fetch the installer
curl -fsSLO https://raw.githubusercontent.com/hjongedijk/ac-evo-server-tool/main/install.sh
chmod +x install.sh

# 2. put these two files next to install.sh:
#    - acevo-server-manager_vX.Y.Z.zip   (download from your control panel)
#    - ACEVO.License                     (same control panel)

# 3. run it - fetches the tooling files, scaffolds data/, moves the zip and
#    license into place, seeds config.yml
./install.sh

# 4. review data/config.yml (set http.session_key) and .env (TZ, Steam
#    creds), then run it
docker compose up -d
docker compose logs -f acevo-server-manager
```

Visit `http://<host>:8773` — default login `admin` / `servermanager`, change
immediately.

Full documentation, including the update workflow, GitHub release setup, and
everything that was fixed to get this running (Wine quirks, steamcmd
gotchas, port forwarding, etc.) is in **[README-docker.md](README-docker.md)**.

## Two ways to run

- `docker-compose.yml` — pulls the published base image from GHCR (no local
  build). Recommended for normal use.
- `docker-compose.dev.yml` — builds locally from `bin/Dockerfile`. Use this
  when changing the Dockerfile/entrypoint itself.

The image never contains the proprietary manager binary — that's supplied at
runtime from your own `releases/<version>/` folder, either as a raw zip
(auto-extracted on container start) or pre-extracted.

## Updating

```bash
./update.sh /path/to/acevo-server-manager_v1.6.4.zip
```

No rebuild needed — see [README-docker.md](README-docker.md#updating-to-a-new-manager-release)
for details.

## License note

This repo's tooling (Dockerfile, scripts, compose files) is free to use and
modify. The `acevo-server-manager` binary itself is proprietary software
from Emperor Servers and is never included here — you supply your own copy,
downloaded from your own control panel account.
