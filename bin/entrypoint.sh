#!/bin/bash
set -e

ACEVO_HOME="/acevo"
SERVER_DIR="${ACEVO_HOME}/server"
VENDOR_SRC="/acevo/vendor-src"
VENDOR_WORK="/acevo/vendor-extracted"

# --- Apply timezone -----------------------------------------------------------
# Setting the TZ env var alone affects glibc/most programs, but syncing
# /etc/localtime (and /etc/timezone) makes it consistently apply everywhere,
# including anything that reads system tz files directly rather than $TZ.
# Falls back to UTC (the image's default ENV TZ) if not overridden via .env.
if [ -n "${TZ}" ]; then
    if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
        ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
        echo "${TZ}" > /etc/timezone
        echo "Timezone set to ${TZ}"
    else
        echo "WARNING: TZ=${TZ} is not a recognized zoneinfo name (e.g. Europe/Berlin, America/New_York) - leaving timezone unchanged."
    fi
fi

# --- Resolve the vendor release: pre-extracted OR a raw .zip -----------------
# releases/<version>/ (mounted read-only at VENDOR_SRC) can contain EITHER:
#   - an already-extracted linux/acevo-server-manager + linux/config.yml, OR
#   - the untouched release zip straight from Emperor Servers (e.g.
#     acevo-server-manager_v1_6_4.zip) - no manual unzipping needed, this
#     script extracts it into a writable scratch dir (skipped if already
#     extracted there and the zip hasn't changed since - VENDOR_WORK isn't a
#     mounted volume, so it persists across restarts of the same container,
#     just not across a full recreate).
# Pre-extracted layout takes priority if both happen to be present.
mkdir -p "${VENDOR_WORK}"

if [ -f "${VENDOR_SRC}/linux/acevo-server-manager" ]; then
    BIN_SRC_DIR="${VENDOR_SRC}/linux"
else
    ZIP_MATCHES=$(find "${VENDOR_SRC}" -maxdepth 1 -iname "*.zip" 2>/dev/null)
    ZIP_COUNT=$(echo "${ZIP_MATCHES}" | grep -c . || true)

    if [ "${ZIP_COUNT}" -eq 1 ]; then
        ZIP_FILE=$(echo "${ZIP_MATCHES}" | head -n1)
        BIN_SRC_DIR="${VENDOR_WORK}/linux"
        if [ -f "${BIN_SRC_DIR}/acevo-server-manager" ] && [ "${BIN_SRC_DIR}/acevo-server-manager" -nt "${ZIP_FILE}" ]; then
            echo "$(basename "${ZIP_FILE}") already extracted and up to date - skipping extraction."
        else
            echo "Found release archive $(basename "${ZIP_FILE}") - extracting..."
            unzip -oq "${ZIP_FILE}" -d "${VENDOR_WORK}"
            # unzip preserves the timestamps stored in the archive (whenever
            # Emperor Servers built it), not the extraction time - touch the
            # binary so the "-nt" staleness check above has something
            # meaningful to compare against on the next start.
            touch "${BIN_SRC_DIR}/acevo-server-manager"
        fi
    elif [ "${ZIP_COUNT}" -gt 1 ]; then
        echo "ERROR: multiple .zip files found under releases/<version>/ - expected exactly one."
        echo "Files found:"
        echo "${ZIP_MATCHES}"
        exit 1
    else
        echo "ERROR: no acevo-server-manager binary or .zip archive found under releases/<version>/"
        echo "Either extract the release zip yourself into releases/<version>/linux/, or"
        echo "just drop the untouched acevo-server-manager_vX_Y_Z.zip directly into"
        echo "releases/<version>/ - this script will extract it automatically."
        exit 1
    fi
fi

if [ ! -f "${BIN_SRC_DIR}/acevo-server-manager" ]; then
    echo "ERROR: acevo-server-manager not found in resolved release folder (${BIN_SRC_DIR})"
    exit 1
fi

# Copy the binary out into a writable location (it needs +x, and the manager
# may want to write alongside itself) each start - cheap, and guarantees
# we're always running whatever version is mounted/extracted.
cp "${BIN_SRC_DIR}/acevo-server-manager" "${ACEVO_HOME}/acevo-server-manager"
chmod +x "${ACEVO_HOME}/acevo-server-manager"
cp "${BIN_SRC_DIR}/config.yml" "${ACEVO_HOME}/config.yml.default"

# --- Bootstrap config.yml on first run ----------------------------------------
# data/config.yml (mounted to /acevo/config.yml) is empty/missing on a brand
# new setup - seed it from this version's default template so the manager has
# something valid to start with. Never overwrites an existing, non-empty
# config.yml, so your own settings always survive version upgrades.
if [ ! -s "${ACEVO_HOME}/config.yml" ]; then
    echo "config.yml is empty or missing - seeding from this release's default template."
    cp "${ACEVO_HOME}/config.yml.default" "${ACEVO_HOME}/config.yml"
else
    # Informational only: flag when a new release ships config keys your
    # current file doesn't have yet, so you know to check the changelog and
    # merge anything relevant by hand. Doesn't touch your file.
    NEW_KEYS=$(grep -oP '^\s*\K[a-zA-Z_]+(?=:)' "${ACEVO_HOME}/config.yml.default" 2>/dev/null | sort -u)
    EXISTING_KEYS=$(grep -oP '^\s*\K[a-zA-Z_]+(?=:)' "${ACEVO_HOME}/config.yml" 2>/dev/null | sort -u)
    MISSING=$(comm -23 <(echo "$NEW_KEYS") <(echo "$EXISTING_KEYS") 2>/dev/null)
    if [ -n "$MISSING" ]; then
        echo "NOTE: this release's default config.yml has top-level keys not found in your config.yml:"
        while IFS= read -r key; do
            echo "  - $key"
        done <<< "$MISSING"
        echo "Check CHANGELOG.txt and merge any relevant new options in manually."
    fi
fi

# --- Sanity check: license file must be mounted in ---------------------------
if [ ! -f "${ACEVO_HOME}/ACEVO.License" ]; then
    echo "ERROR: ACEVO.License not found at ${ACEVO_HOME}/ACEVO.License"
    echo "Mount your license file into the container, e.g.:"
    echo "  -v /path/to/ACEVO.License:/acevo/ACEVO.License"
    exit 1
fi

# --- Optionally auto-install/update the game server via steamcmd -------------
# Set ACEVO_STEAM_APPID and ACEVO_AUTO_UPDATE=1 to enable this on container start.
# Find the correct App ID for the AC EVO dedicated server before using this.
#
# By default this uses anonymous login, which is enough for most dedicated
# server downloads. If the AC EVO server requires a login tied to your own
# Steam account/library, set STEAM_USER and STEAM_PASS (see docker-compose.yml
# for how to pass these in securely via an env file rather than hardcoding
# them). NOTE: if Steam Guard / 2FA is enabled on the account, the first run
# will need to be done interactively once (docker compose run --rm ...) to
# enter the Steam Guard code, since steamcmd will otherwise hang waiting for
# input. After that first successful login, steamcmd caches the auth so
# subsequent unattended runs succeed.
if [ "${ACEVO_AUTO_UPDATE}" = "1" ] && [ -n "${ACEVO_STEAM_APPID}" ]; then
    if [ -n "${STEAM_USER}" ] && [ -n "${STEAM_PASS}" ]; then
        echo "Updating game server via steamcmd (app id ${ACEVO_STEAM_APPID}, authenticated)..."
        steamcmd \
            +force_install_dir "${SERVER_DIR}" \
            +login "${STEAM_USER}" "${STEAM_PASS}" \
            +app_update "${ACEVO_STEAM_APPID}" validate \
            +quit
    else
        echo "Updating game server via steamcmd (app id ${ACEVO_STEAM_APPID}, anonymous)..."
        steamcmd \
            +force_install_dir "${SERVER_DIR}" \
            +login anonymous \
            +app_update "${ACEVO_STEAM_APPID}" validate \
            +quit
    fi
fi

# --- Launch the manager -------------------------------------------------------
# Note: the manager itself is a native Linux binary and does not need Wine or
# a virtual display - only the AC EVO game server executable it launches
# later needs Wine (handled internally by the manager). Running the manager
# directly avoids xvfb-run masking startup errors or hanging.
cd "${ACEVO_HOME}"
export WINEDEBUG=-all
export WINEARCH=win64

# Wine (used internally when the manager launches the AC EVO game server exe)
# requires XDG_RUNTIME_DIR to point at an existing, valid directory - it's
# not set by default in this container, so set and create it here.
export XDG_RUNTIME_DIR=/tmp/xdg-runtime
mkdir -p "${XDG_RUNTIME_DIR}"
chmod 0700 "${XDG_RUNTIME_DIR}"

echo "Starting acevo-server-manager..."
exec ./acevo-server-manager
