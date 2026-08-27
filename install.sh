#!/bin/bash
# install.sh — standalone bootstrapper for a fresh deployment.
# Usage: run this in an empty directory alongside just:
#   install.sh                                (this file)
#   acevo-server-manager_vX_Y_Z.zip           (from your Emperor Servers control panel)
#   ACEVO.License                             (from your Emperor Servers control panel)
#
# Everything else needed to run (docker-compose.yml, .env.example, update.sh)
# is fetched from GitHub. Safe to re-run - never overwrites a file that's
# already there, so re-running after adding a new release zip just picks
# that up without touching anything you've already customized.
set -euo pipefail

GITHUB_REPO="hjongedijk/ac-evo-server-tool"

# --- Resolve which ref to fetch tooling files from ----------------------------
# Prefer the latest tagged release, since its docker-compose.yml/.env.example
# match the image that "latest" actually points to on GHCR. Fall back to the
# main branch if the API call fails (rate-limited, offline, etc.) - better to
# fetch something recent than to hard-fail here.
echo "==> Resolving latest release of ${GITHUB_REPO}"
REF=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name"' | grep -oP '(?<=": ")[^"]+') || true
if [ -z "$REF" ]; then
    echo "  Could not resolve a release tag - falling back to the main branch."
    REF="main"
fi
echo "  Using ref: ${REF}"

# --- Fetch the tooling files this deployment needs to run ---------------------
fetch() {
    local path="$1"
    if [ -f "$path" ]; then
        echo "  ${path} already exists - leaving it alone"
        return
    fi
    echo "  Fetching ${path}"
    local tmp
    tmp="$(mktemp)"
    if ! curl -fsSL "https://raw.githubusercontent.com/${GITHUB_REPO}/${REF}/${path}" -o "$tmp"; then
        rm -f "$tmp"
        echo "ERROR: failed to fetch ${path} from ${GITHUB_REPO}@${REF}" >&2
        exit 1
    fi
    mv "$tmp" "$path"
}

echo "==> Fetching tooling files"
fetch docker-compose.yml
fetch .env.example
fetch update.sh
chmod +x update.sh

# --- Helpers ----------------------------------------------------------------
# Set (or replace) a KEY=value line in .env. Uses grep+append rather than
# sed substitution so arbitrary secret content (Steam passwords, etc.) never
# has to be escaped for a sed pattern.
set_env_var() {
    local name="$1" value="$2"
    if [ -f .env ] && grep -q "^${name}=" .env; then
        grep -v "^${name}=" .env > .env.tmp && mv .env.tmp .env
    fi
    echo "${name}=${value}" >> .env
}

generate_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# --- Scaffold directories -------------------------------------------------
echo "==> Creating data/ and releases/ directories"
mkdir -p data/server data/store.json releases

# --- License: pick up the one you dropped alongside this script -----------
if [ -f data/ACEVO.License ] && [ -s data/ACEVO.License ]; then
    echo "==> data/ACEVO.License already exists - leaving it alone"
elif [ -f ACEVO.License ]; then
    echo "==> Moving ACEVO.License into data/"
    mv ACEVO.License data/ACEVO.License
else
    echo "==> No ACEVO.License found alongside this script - creating an empty placeholder."
    echo "    Get one from the emperorservers.com Control Panel and place it at data/ACEVO.License."
    touch data/ACEVO.License
fi

# --- .env ------------------------------------------------------------------
ENV_PROMPTED=0
SESSION_KEY_GENERATED=0
if [ -f .env ]; then
    echo "==> .env already exists - leaving it alone"
else
    echo "==> Creating .env from .env.example"
    cp .env.example .env

    if [ -t 0 ]; then
        ENV_PROMPTED=1
        echo ""
        echo "==> A couple of quick settings (press Enter to accept the default):"

        read -r -p "  Timezone, e.g. Europe/Berlin [UTC]: " TZ_INPUT
        TZ_INPUT="${TZ_INPUT:-UTC}"
        if [ -f "/usr/share/zoneinfo/${TZ_INPUT}" ]; then
            set_env_var TZ "$TZ_INPUT"
        else
            echo "  '${TZ_INPUT}' doesn't look like a valid IANA timezone name - leaving TZ at its default (UTC)."
        fi

        echo "  Steam login for steamcmd - anonymous works fine for the AC EVO dedicated"
        echo "  server, only fill this in if that doesn't work for you."
        read -r -p "  STEAM_USER [blank = anonymous]: " STEAM_USER_INPUT
        if [ -n "$STEAM_USER_INPUT" ]; then
            read -r -s -p "  STEAM_PASS: " STEAM_PASS_INPUT
            echo ""
            set_env_var STEAM_USER "$STEAM_USER_INPUT"
            set_env_var STEAM_PASS "$STEAM_PASS_INPUT"
        fi
        echo ""
    else
        echo "  No terminal attached - skipping the TZ/Steam prompts (left at .env.example defaults)."
    fi
fi

# --- Manager release: pick up the zip you dropped alongside this script ---
# Same filename -> version parsing as update.sh (handles both
# "v1.6.4-1.zip" and "v1_6_4-1.zip" -> v1.6.4-1). If more than one zip is
# found, the highest version becomes the active ACEVO_VERSION in .env, but
# all of them get placed under releases/<version>/.
LATEST_VERSION=""
shopt -s nullglob
for ZIP_PATH in ./acevo-server-manager*.zip; do
    BASENAME=$(basename "$ZIP_PATH" .zip)
    RAW=$(echo "$BASENAME" | grep -oP '(?<=_v)[0-9]+(?:[._][0-9]+)*(-[0-9A-Za-z]+)*' || true)
    if [ -z "$RAW" ]; then
        echo "==> WARNING: couldn't parse a version from ${ZIP_PATH} - skipping. Place it manually with update.sh instead."
        continue
    fi
    MAIN="${RAW%%-*}"
    SUFFIX="${RAW#"$MAIN"}"
    MAIN_DOTTED=$(echo "$MAIN" | tr '_' '.')
    VERSION="v${MAIN_DOTTED}${SUFFIX}"

    DEST="releases/${VERSION}"
    mkdir -p "$DEST"
    DEST_ZIP="${DEST}/$(basename "$ZIP_PATH")"
    if [ -f "$DEST_ZIP" ]; then
        echo "==> ${DEST_ZIP} already exists - leaving ${ZIP_PATH} where it is."
    else
        echo "==> Moving ${ZIP_PATH} to ${DEST_ZIP}"
        mv "$ZIP_PATH" "$DEST_ZIP"
    fi

    if [ -z "$LATEST_VERSION" ] || [ "$(printf '%s\n%s\n' "$LATEST_VERSION" "$VERSION" | sort -V | tail -1)" = "$VERSION" ]; then
        LATEST_VERSION="$VERSION"
    fi

    if [ ! -f data/config.yml ] || [ ! -s data/config.yml ]; then
        echo "==> Seeding data/config.yml from ${DEST_ZIP}"
        unzip -p "$DEST_ZIP" linux/config.yml > data/config.yml
        echo "==> Generating a random http.session_key"
        SESSION_KEY="$(generate_secret)"
        sed -i "s/^\(\s*session_key:\).*/\1 ${SESSION_KEY}/" data/config.yml
        SESSION_KEY_GENERATED=1
    fi
done
shopt -u nullglob

if [ -n "$LATEST_VERSION" ]; then
    echo "==> Setting ACEVO_VERSION=${LATEST_VERSION} in .env"
    set_env_var ACEVO_VERSION "$LATEST_VERSION"
elif [ ! -f data/config.yml ] || [ ! -s data/config.yml ]; then
    echo "==> No acevo-server-manager_*.zip found alongside this script - skipping release placement."
    echo "    Once you've downloaded one, re-run this script (or use ./update.sh) to pick it up."
fi

echo ""
echo "==> Done. Remaining steps:"
STEP=1
if [ "$SESSION_KEY_GENERATED" != "1" ]; then
    echo "  ${STEP}. Review data/config.yml: set http.session_key to a random secret."
    STEP=$((STEP + 1))
fi
if [ "$ENV_PROMPTED" != "1" ]; then
    echo "  ${STEP}. Fill in .env: TZ, and STEAM_USER/STEAM_PASS if anonymous steamcmd login"
    echo "     doesn't work for downloading the game server."
    STEP=$((STEP + 1))
fi
echo "  ${STEP}. docker compose up -d"
echo "     docker compose logs -f acevo-server-manager"
echo ""
echo "See README-docker.md (fetched as part of the repo, or view it on GitHub) for full details."
