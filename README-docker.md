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
the untouched release `.zip` (auto-extracted on every container start, no
manual unzipping needed) or as a pre-extracted `linux/` folder if you prefer.
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
├── install.sh                    <- run this first, for first-time setup scaffolding
├── update.sh                     <- run this to install a new manager release
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
    ├── server/
    └── store.json/                  <- directory, not a file (see step 5)
```

## First-time setup

### Fastest path: `install.sh`

You only need to provide three files: the installer itself, your manager
release zip, and your license. Everything else is fetched from this repo:

```bash
curl -fsSLO https://raw.githubusercontent.com/hjongedijk/ac-evo-server-tool/main/install.sh
chmod +x install.sh
# now put acevo-server-manager_vX.Y.Z.zip and ACEVO.License next to install.sh
./install.sh
```

It fetches `docker-compose.yml`, `.env.example`, and `update.sh` from
GitHub; creates the `data/`/`releases/` directories; moves your license and
release zip into place (`data/ACEVO.License` and `releases/<version>/`);
seeds `data/config.yml` from the zip with a **freshly generated random
`http.session_key`**; and creates `.env` with `ACEVO_VERSION` already set to
match. `.env.example` is deleted once it's no longer needed. It never
overwrites a file that's already there, so it's safe to re-run (e.g. after
dropping in a new release zip, to pick it up without touching anything
you've customized).

If you're at a real terminal the first time it creates `.env`, it also
prompts you for:
- **Timezone** (defaults to `UTC`).
- **Steam login** for steamcmd — leave blank for anonymous (works fine for
  the AC EVO dedicated server); only asks for the password if you gave a
  username.
- **Number of game servers** you want to run — publishes the matching ports
  in `docker-compose.yml` automatically (server 1: `9800`/`9800`/`9801`,
  server 2: `9802`/`9802`/`9803`, and so on — the same scheme the manager
  itself uses when you add a server in the web UI). You still need to
  create each server in the UI and forward its ports at your
  router/firewall, but you won't need to hand-edit `docker-compose.yml` for
  the common case.

Running non-interactively (no terminal attached), or just pressed Enter
past a prompt? Nothing is lost — everything it would have asked stays at
its single-server/UTC/anonymous default, and you can still change any of it
by hand afterward: `docker compose up -d`.

### Doing it manually (full repo checkout)

If you'd rather clone the repo (e.g. to use `docker-compose.dev.yml`, or to
patch something), here's what `install.sh` automates, spelled out:

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
it's fetched via steamcmd on container start. Already wired up via `.env`
(`ACEVO_AUTO_UPDATE=1`, `ACEVO_STEAM_APPID=4564210` — confirmed correct App
ID for the AC EVO dedicated server tool). Anonymous login works fine for
this app — no Steam credentials needed. If you ever do need your own
account, fill in `STEAM_USER`/`STEAM_PASS` in `.env`; Steam Guard/2FA
accounts need one interactive run first:
`docker compose run --rm acevo-server-manager`.

**6. Game server ports** — the manager assigns these per-server via its own
web UI ("Server Options" page), not `config.yml`. Whatever port it shows
there must match the compose file's `ports:` section — the first server
defaulted to `9800` (TCP+UDP) and `9801` (TCP).

This mapping is **not automatic** — nothing in the container discovers new
servers and opens their ports for you. If you add a second (or third)
server in the UI, it gets its own port pair, and that traffic won't reach
the container at all until you add a matching block to `ports:` in
`docker-compose.yml` (there are commented-out example lines for a second
server already there) and restart with `docker compose up -d`. Do this for
every server you add, and make sure each port is forwarded from your public
IP at the router/firewall level too — the game's backend does an external
UDP reachability check and will shut the server down if it can't reach it
from outside. None of this touches `bin/Dockerfile` — its `EXPOSE` lines
are documentation only and don't publish anything themselves.

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

## Updating to a new manager release

When Emperor Servers ships a new version:

```bash
./update.sh /path/to/acevo-server-manager_v1.6.4.zip
```

Don't have `update.sh` on hand (e.g. you only have `docker-compose.yml` and
`.env`, not the full repo/zip)? It's also baked into the published image —
pull it back out:
```bash
docker compose cp acevo-server-manager:/opt/update.sh ./update.sh
chmod +x update.sh
```

This works from anywhere — it locates the repo root automatically, copies
the zip as-is into `releases/v1.6.4/` (no extraction — the container does
that automatically on start), updates `.env` to point at it, and
**restarts** the container (no rebuild, since the version lives in a volume
mount, not the image). Your `data/` folder (config, license, downloaded game
server, database) is never touched.

Use `--dev` if you're running the local-build compose file instead:
```bash
./update.sh /path/to/acevo-server-manager_v1.6.4.zip --dev
```

Version numbers with a hotfix/build suffix (e.g. `v1.6.4-1`) are handled
automatically. If a filename doesn't parse cleanly, pass the version
explicitly:
```bash
./update.sh acevo-server-manager_v1.6.4-1.zip v1.6.4-1
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

### Doing it manually (without update.sh)

```bash
mkdir -p releases/v1.6.4
cp acevo-server-manager_v1.6.4.zip releases/v1.6.4/
sed -i 's/^ACEVO_VERSION=.*/ACEVO_VERSION=v1.6.4/' .env
docker compose up -d
```

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
  location, with the binary `chmod +x`'d, on every container start
