# ACEVO Server Manager - Docker

Run [Emperor Servers'](https://emperorservers.com/) Assetto Corsa EVO Server
Manager in Docker. Wine is bundled since the AC EVO dedicated server
executable is Windows-only.

Confirmed working end-to-end: manager boots, downloads the game server via
steamcmd, and successfully runs multiple race servers.

## Quick start

All you need to provide yourself is `acsm-evo-control.sh` and two files from
your Emperor Servers control panel — installing fetches everything else
(`docker-compose.yml`, `.env.example`) from this repo:

```bash
# 1. fetch the control script
curl -fsSLO https://raw.githubusercontent.com/hjongedijk/ac-evo-server-tool/main/acsm-evo-control.sh
chmod +x acsm-evo-control.sh

# 2. put these two files next to it:
#    - acevo-server-manager_vX.Y.Z.zip   (download from your control panel)
#    - ACEVO.License                     (same control panel)

# 3. run it - fetches the tooling files, scaffolds data/, moves the zip and
#    license into place, seeds config.yml, and interactively asks for your
#    timezone, Steam login, and how many servers you want (it sets those up
#    for you automatically - no web UI clicking needed)
./acsm-evo-control.sh install
```

Visit `http://<host>:8773` — default login `admin` / `servermanager`, change
immediately.

Full documentation, including updating, adding more servers later, GitHub
release setup, and everything that was fixed to get this running (Wine
quirks, steamcmd gotchas, port forwarding, etc.) is in
**[README-docker.md](README-docker.md)**.

## Two ways to run

- `docker-compose.yml` — pulls the published base image from GHCR (no local
  build). Recommended for normal use.
- `docker-compose.dev.yml` — builds locally from `bin/Dockerfile`. Use this
  when changing the Dockerfile/entrypoint itself.

The image never contains the proprietary manager binary — that's supplied at
runtime from your own `releases/<version>/` folder, either as a raw zip
(auto-extracted on container start) or pre-extracted.

## Managing your deployment

`acsm-evo-control.sh` is a single tool for everything after first-time setup
too — run it with no arguments for an interactive menu, or use it directly:

```bash
./acsm-evo-control.sh add-server         # register a new server with the
                                          # manager and publish its ports -
                                          # no web UI needed
./acsm-evo-control.sh update-manager /path/to/acevo-server-manager_v1.6.4.zip
./acsm-evo-control.sh update-game        # re-run steamcmd to update game files
./acsm-evo-control.sh status             # show version, servers, container state
```

No rebuild needed for any of these — see
[README-docker.md](README-docker.md#managing-your-deployment) for details.

## License note

This repo's tooling (Dockerfile, scripts, compose files) is free to use and
modify. The `acevo-server-manager` binary itself is proprietary software
from Emperor Servers and is never included here — you supply your own copy,
downloaded from your own control panel account.
