# ACEVO Server Manager - Docker

Run [Emperor Servers'](https://emperorservers.com/) Assetto Corsa EVO Server
Manager in Docker. Wine is bundled since the AC EVO dedicated server
executable is Windows-only.

Confirmed working end-to-end: manager boots, downloads the game server via
steamcmd, and successfully runs a race server.

## Quick start

```bash
# 1. put your license file at data/ACEVO.License
# 2. drop the release zip straight into releases/v1.6.3/ (no need to extract)
#    - download from your Emperor Servers control panel
# 3. seed the config
mkdir -p data/server data/store
unzip -p releases/v1.6.3/acevo-server-manager_v1_6_3.zip linux/config.yml > data/config.yml

# 4. copy the env template and fill in the values you need
cp .env.example .env

# 5. edit docker-compose.yml, replace ghcr.io/OWNER/REPO with your repo
# 6. run it
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
./bin/update.sh /path/to/acevo-server-manager_v1_6_4.zip
```

No rebuild needed — see [README-docker.md](README-docker.md#updating-to-a-new-manager-release)
for details.

## License note

This repo's tooling (Dockerfile, scripts, compose files) is free to use and
modify. The `acevo-server-manager` binary itself is proprietary software
from Emperor Servers and is never included here — you supply your own copy,
downloaded from your own control panel account.
