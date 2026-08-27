# Running ACEVO Server Manager in Docker

This containerizes the Linux build of `acevo-server-manager`. Wine is
included because the AC EVO dedicated server executable itself is
Windows-only — the manager (a native Linux binary) launches and controls it
under Wine. This setup has been confirmed working end-to-end: manager boots,
downloads the game server via steamcmd, and successfully runs a race server.

## Two ways to run this

- **`docker-compose.yml`** (recommended for normal use) — pulls the
  pre-built base image from GHCR (`ghcr.io/hjongedijk/ac-evo-server-tool`).
  No local build needed. Switching manager versions is just a `.env`
  change + restart.
- **`docker-compose.dev.yml`** — builds the image locally from `bin/Dockerfile`.
  Use this only if you're changing the Dockerfile/entrypoint itself and want
  to test before pushing a tooling release.

**Important architectural point:** the image itself (published or locally
built) never contains the proprietary `acevo-server-manager` binary — that
can't be redistributed. Instead, the image is just Wine + steamcmd + the
entrypoint logic, and the actual version-specific binary is mounted in at
container **runtime** from your own `releases/<version>/` folder — either as
the untouched release `.zip` (auto-extracted on first start and whenever it
changes, skipped on later restarts, no manual unzipping needed) or as a
pre-extracted `linux/` folder if you prefer.
This is what makes it safe to publish the image publicly, and as a bonus it
means switching manager versions no longer requires a rebuild at all — just
change `ACEVO_VERSION` in `.env` and restart.

## Directory layout

```
acsm-evo/
├── docker-compose.yml           <- prod: pulls published GHCR image
├── docker-compose.dev.yml       <- dev: builds locally
├── .env                         <- YOUR config: version, Steam creds, etc. (gitignored)
├── .env.example                 <- tracked template, copy to .env
├── .gitignore
├── TOOLING_VERSION               <- current tooling version, updated by release.sh
├── README.md
├── README-docker.md
├── acsm-evo-control.sh           <- install, update, add servers - everything, one tool
├── release.sh                    <- run this to cut a new tooling release
├── bin/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── debug-steamcmd.sh
├── releases/
│   └── v1.6.3/
│       ├── acevo-server-manager_v1.6.3.zip   <- OPTION A: raw zip, auto-extracted
│       └── linux/                             <- OPTION B: pre-extracted (takes priority if present)
│           ├── acevo-server-manager
│           └── config.yml
└── data/                         <- persistent, never touched by upgrades
    ├── config.yml
    ├── ACEVO.License
    ├── server/                      <- steamcmd-downloaded game files + one
    │                                    working copy per server (server_0/, server_1/, ...)
    └── store.json/                  <- manager's own store; directory, not a file (see step 4)
```

## First-time setup

### Fastest path: `acsm-evo-control.sh install`

You only need to provide three files: the control script itself, your
manager release zip, and your license. Everything else is fetched from this
repo:

```bash
curl -fsSLO https://raw.githubusercontent.com/hjongedijk/ac-evo-server-tool/main/acsm-evo-control.sh
chmod +x acsm-evo-control.sh
# now put acevo-server-manager_vX.Y.Z.zip and ACEVO.License next to it
./acsm-evo-control.sh install
```

It fetches `docker-compose.yml` and `.env.example` from GitHub; creates the
`data/`/`releases/` directories; moves your license and release zip into
place (`data/ACEVO.License` and `releases/<version>/`); seeds
`data/config.yml` from the zip with a **freshly generated random
`http.session_key`**; and creates `.env` with `ACEVO_VERSION` already set to
match. `.env.example` is deleted once it's no longer needed. It never
overwrites a file that's already there, so it's safe to re-run (e.g. after
dropping in a new release zip, to pick it up without touching anything
you've customized).

If you're at a real terminal the first time it creates `.env`, it also
prompts you for:
- **Timezone** (defaults to `UTC`).
- **Steam login** for steamcmd — typically required (see below); only asks
  for the password if you gave a username, and leaving it blank tries
  anonymous login anyway.
- **Number of game servers** you want to run. If you ask for more than one
  and a release zip was found, it does the *entire* rest for you: starts
  the container, waits for the manager's first boot to finish, registers
  each extra server directly with the manager and publishes its ports (see
  [Adding a server](#adding-a-server) below), then restarts once to pick
  them all up — no web UI clicking required.

Running non-interactively (no terminal attached), or just pressed Enter
past a prompt? Nothing is lost — everything it would have asked stays at
its single-server/UTC/anonymous default, and you can still change any of it
by hand afterward, or with `./acsm-evo-control.sh add-server` once it's up:
`docker compose up -d`.

### Doing it manually (full repo checkout)

If you'd rather clone the repo (e.g. to use `docker-compose.dev.yml`, or to
patch something), here's what `acsm-evo-control.sh install` automates,
spelled out:

**1. Set up your `.env`:**
```bash
cp .env.example .env
```
`.env` is a single file for all runtime config — it's auto-read by docker
compose for `${ACEVO_VERSION}`/`${IMAGE_TAG}` interpolation in the compose
files, *and* loaded into the running container via `env_file` (so
`ACEVO_AUTO_UPDATE`, `ACEVO_STEAM_APPID`, `STEAM_USER`/`STEAM_PASS` all live
here too). It's gitignored since it can hold Steam credentials — only
`.env.example` is tracked.

**2. Get your license file** from the emperorservers.com Control Panel (the
"key" button next to "download"). Place it at `data/ACEVO.License`.

**3. Put the manager release in place** — download the zip from your Emperor
Servers control panel and just drop it, untouched, into `releases/v1.6.3/`:
```bash
mkdir -p releases/v1.6.3
cp ~/Downloads/acevo-server-manager_v1.6.3.zip releases/v1.6.3/
```
That's it — no extraction needed. The container extracts it automatically on
every start (cheap, sub-second). It never gets committed to git or baked
into any image, and stays read-only from the container's point of view.

If you'd rather pre-extract it yourself (e.g. to inspect the contents, or
because you're patching something), that also works — just put the two
files from inside the zip's `linux/` folder at
`releases/v1.6.3/linux/acevo-server-manager` and
`releases/v1.6.3/linux/config.yml`. A pre-extracted `linux/` folder always
takes priority over a zip if both are present.

**4. Seed the initial config** (only needed once — after this, `data/config.yml`
is yours and survives upgrades):
```bash
mkdir -p data/server data/store.json
unzip -p releases/v1.6.3/acevo-server-manager_v1.6.3.zip linux/config.yml > data/config.yml
touch data/ACEVO.License   # then paste your real license content in
```
At minimum, check in `data/config.yml`:
- `http.hostname` — leave as `0.0.0.0:8773` so it's reachable from outside the container
- `http.session_key` — change to a random secret
- `store.path` — leave as the default `store.json`. Despite the name it's a
  directory, not a file — the manager manages it internally — and the
  compose files mount `data/store.json/` at exactly that path so the
  default value works unmodified.

**5. Game server files** — the AC EVO dedicated server itself isn't bundled;
it's fetched via steamcmd the first time the container starts (already
wired up via `.env`'s `ACEVO_AUTO_UPDATE=1`/`ACEVO_STEAM_APPID=4564210` —
confirmed correct App ID for the AC EVO dedicated server tool; it only
installs once, not on every restart — see
[Updating game server files](#updating-game-server-files)). **Steam
credentials are typically required** — anonymous login has been observed to
fail for accounts that don't have the base game in their library, even
though this is nominally a free dedicated-server tool. Fill in
`STEAM_USER`/`STEAM_PASS` in `.env`; Steam Guard/2FA accounts need one
interactive run first: `docker compose run --rm acevo-server-manager`.

**6. Game server ports** — each server has its own TCP+UDP port pair, and
that traffic won't reach the container at all until it's published in
`docker-compose.yml`'s `ports:` section and the container is restarted.
`./acsm-evo-control.sh add-server` (see
[Adding a server](#adding-a-server) below) does this for you automatically
using the same scheme the manager itself uses (server 1: `9800`/`9800`/`9801`,
server 2: `9802`/`9802`/`9803`, and so on) — nothing to hand-edit for the
common case. Whatever port a server ends up on must also be forwarded from
your public IP at the router/firewall level — the game's backend does an
external UDP reachability check and will shut the server down if it can't
reach it from outside. None of this touches `bin/Dockerfile` — its `EXPOSE`
lines are documentation only and don't publish anything themselves.

**7. Run it:**
```bash
# prod (pulls published image):
docker compose up -d

# OR dev (builds locally):
docker compose -f docker-compose.dev.yml up -d --build
```
```bash
docker compose logs -f acevo-server-manager
```
Visit `http://<host>:8773` — default login `admin` / `servermanager`, change
immediately.

## Managing your deployment

`acsm-evo-control.sh` handles everything after first-time setup too. Run it
with no arguments for a colored interactive menu, or use a subcommand
directly. All of these assume setup is already done (they operate on
`data/`, `releases/`, `docker-compose.yml`, `.env` already in place) and
exit with an error telling you to run `install` first if it isn't.

Don't have the script on hand (e.g. you only kept `docker-compose.yml` and
`.env`, not the full checkout)? It's also baked into the published image —
pull it back out:
```bash
docker compose cp acevo-server-manager:/opt/acsm-evo-control.sh ./acsm-evo-control.sh
chmod +x acsm-evo-control.sh
```

### Adding a server

```bash
./acsm-evo-control.sh add-server
```

Prompts for a name, max players, and optional driver/admin passwords, then
registers the server **directly with the manager** — no web UI clicking
needed. Concretely, it:
1. Picks the next server index (`server_1`, `server_2`, ...) by scanning
   `data/store.json/servers/`.
2. Writes that server's config directly into
   `data/store.json/servers/server_N/` (`serverOptions.json`,
   `perServerOptions.json`, `notifications.json`) and a matching
   `server_config.json` under `data/server/_manager/servers/server_N/`.
3. Copies that server's game-file working copy from `server_0` (a straight
   file copy of static content — car/track data, the server executable —
   the same ~400MB per server the manager itself creates when you add one
   via the UI).
4. Publishes its ports in `docker-compose.yml` (same scheme as first-time
   setup: `9800`/`9800`/`9801` for server 1, `+2` per additional server).

This is possible because the manager just scans `data/store.json/servers/`
for `server_N` directories at startup — it's not an officially documented
API, but it's exactly what the web UI's "new server" flow produces, and
it's been verified end-to-end against a real multi-server deployment. A
server added this way only shows up after a restart:
```bash
docker compose up -d
```
Requires the container to have started and fully booted **at least once**
already (`add-server` needs `server_0`'s files as a template — it errors
out with a clear message if they're not there yet). Remember to forward
the new server's ports at your router/firewall too.

### Updating the manager release

When Emperor Servers ships a new version:

```bash
./acsm-evo-control.sh update-manager /path/to/acevo-server-manager_v1.6.4.zip
```

This locates the repo root automatically, moves the zip as-is into
`releases/v1.6.4/` (no extraction — the container does that automatically
on start), updates `.env` to point at it, and **restarts** the container
(no rebuild, since the version lives in a volume mount, not the image).
Your `data/` folder (config, license, downloaded game server, database, all
servers) is never touched.

Use `--dev` if you're running the local-build compose file instead:
```bash
./acsm-evo-control.sh update-manager /path/to/acevo-server-manager_v1.6.4.zip --dev
```

Version numbers with a hotfix/build suffix (e.g. `v1.6.4-1`) are handled
automatically. If a filename doesn't parse cleanly, pass the version
explicitly:
```bash
./acsm-evo-control.sh update-manager acevo-server-manager_v1.6.4-1.zip v1.6.4-1
```

The entrypoint also does a light check on every start: if the new release's
default `config.yml` has top-level keys your `data/config.yml` doesn't have
yet, it prints a note listing them so you know to check the changelog and
merge in anything relevant by hand. Your file is never auto-modified.

**Rolling back** if a new version misbehaves:
```bash
sed -i 's/^ACEVO_VERSION=.*/ACEVO_VERSION=v1.6.3/' .env
docker compose up -d
```
(assuming the old release folder is still present under `releases/`).

Doing it by hand instead:
```bash
mkdir -p releases/v1.6.4
cp acevo-server-manager_v1.6.4.zip releases/v1.6.4/
sed -i 's/^ACEVO_VERSION=.*/ACEVO_VERSION=v1.6.4/' .env
docker compose up -d
```

### Updating game server files

The game server files (downloaded via steamcmd, separate from the manager
binary) already auto-update on every container start when
`ACEVO_AUTO_UPDATE=1` is set (the default). To trigger that on demand
without a full restart — or if you've turned auto-update off — re-run it
directly:

```bash
./acsm-evo-control.sh update-game
```

This runs the exact same steamcmd command the entrypoint uses (anonymous or
authenticated, based on `STEAM_USER`/`STEAM_PASS` in `.env`) inside the
already-running container. Requires the container to be up.

### Status

```bash
./acsm-evo-control.sh status
```

Read-only summary: current `ACEVO_VERSION`/`IMAGE_TAG`, every configured
server with its name and ports, and `docker compose ps` output.

## Cutting a GitHub release of this tooling

The easiest way is `release.sh`, which bumps the version, runs the same
lint checks CI runs (so failures surface locally before pushing), commits,
tags, and pushes:

```bash
./release.sh           # auto-computes the next version, e.g. v0.0.1 -> v0.0.2
./release.sh next "Fix XDG_RUNTIME_DIR handling"   # with a custom commit message
./release.sh v2.0.0                                # explicit version (e.g. a MAJOR bump)
```

It writes the resolved version into `TOOLING_VERSION` (tracked in git, purely
for reference), then pushes a `v*` tag. It does **not** create the
GitHub Release itself — `.github/workflows/release.yml` already handles that
automatically whenever it sees the tag pushed, so the script's job stops
once the tag is on GitHub.

That workflow does three things:
1. **Lints** the Dockerfile, shell scripts, and both compose files.
2. **Builds and pushes the base image** to `ghcr.io/<owner>/<repo>` tagged
   both `latest` and the version (e.g. `v0.0.1`). This image contains zero
   proprietary content, so it's safe to publish.
3. **Packages the tooling** (`bin/`, both compose files, both READMEs, etc.)
   into a downloadable zip attached to a GitHub Release.

Prefer doing it by hand instead? Skip the script:
```bash
git tag v0.0.1
git push origin v0.0.1
```

This is a **separate versioning scheme** from `ACEVO_VERSION` (the
`v1.6.3`-style folder names under `releases/` that track the upstream
manager release) — it just happens to share the same `v*` tag format, so
avoid tagging a release here with a version number that could be mistaken
for an upstream manager release. Bump this whenever you change the
Dockerfile, compose files, entrypoint, or update/release scripts in a way
worth snapshotting; it's independent of whatever manager version happens to
be active in `.env` at the time.

**First push note:** GHCR packages sometimes default to private visibility.
If `docker compose pull` fails with an auth error on a fresh machine, go to
the package settings on GitHub and set visibility to public.

## Version control notes

`.gitignore` excludes `data/` (your live state), `.env` (holds Steam
credentials once filled in — only `.env.example` is tracked),
and the actual binaries/configs under `releases/*/linux/` (proprietary,
gated behind your own Emperor Servers account). What git tracks is
everything under `bin/`, both compose files, and the `releases/<version>/`
folder structure itself (e.g. via a `.gitkeep`) — the update workflow and
version history stay reproducible even though the binaries live outside git.

## Known-good configuration (confirmed working)

- Base image: `scottyhardy/docker-wine:stable`
- steamcmd installed via apt with debconf pre-seeded (license auto-accepted;
  otherwise the build hangs waiting for interactive EULA acceptance)
- `steamcmd` symlinked to `/usr/local/bin` (the apt package puts it at
  `/usr/games/steamcmd`, which isn't on PATH by default in this image)
- `XDG_RUNTIME_DIR` set at the image level to `/tmp/xdg-runtime` — Wine
  requires this to be set to a valid, existing directory or the game server
  process fails to start
- `bin/entrypoint.sh` line endings are stripped of any CRLF at build time
  (`sed -i 's/\r$//'`) since a Windows-edited file will otherwise break the
  shebang and fail with a cryptic "no such file or directory" error
- App ID `4564210` confirmed via SteamDB as "Assetto Corsa EVO Dedicated
  Server" (Tool, Windows-only, parent app `3058630`)
- `TZ` (set via `.env`) is genuinely applied, not just declared — `tzdata`
  is installed and the entrypoint symlinks `/etc/localtime` to the matching
  zoneinfo file on every start, with a fallback warning (not a hard failure)
  if an unrecognized zone name is given
- The manager release (raw zip or pre-extracted `linux/` folder) is resolved
  and copied out of the read-only `/acevo/vendor-src` mount into a writable
  location on every container start, with the binary `chmod +x`'d - the
  zip extraction step itself is skipped on restarts where it's already
  extracted and unchanged
