#!/bin/bash
# Usage: ./bin/update.sh /path/to/acevo-server-manager_v1_6_4.zip [version] [--dev]
#
# Copies a new release zip AS-IS into releases/<version>/ (no extraction
# needed - the container extracts it automatically on start), updates .env
# to point at it, and restarts the container. Your data/ folder (config,
# license, game server files, store) is never touched.
#
# By default targets docker-compose.yml (the published GHCR image) - since
# the version is just a volume mount, this only needs a restart, no rebuild.
# Pass --dev to target docker-compose.dev.yml instead, which DOES rebuild
# locally (use this if you're also testing Dockerfile/entrypoint changes).
#
# Version is normally auto-detected from the filename (handles suffixes like
# "v1_6_4-1" -> "v1.6.4-1"), but you can always override it explicitly:
#   ./bin/update.sh acevo-server-manager_v1_6_4-1.zip v1.6.4-1
#
# Can be run from anywhere (cds to the repo root automatically).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Pull out --dev from the args wherever it appears.
DEV=0
ARGS=()
for arg in "$@"; do
    if [ "$arg" = "--dev" ]; then
        DEV=1
    else
        ARGS+=("$arg")
    fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

ZIP_PATH="${1:-}"
VERSION_OVERRIDE="${2:-}"

if [ -z "$ZIP_PATH" ] || [ ! -f "$ZIP_PATH" ]; then
    echo "Usage: $0 /path/to/acevo-server-manager_vX_Y_Z.zip [version] [--dev]"
    exit 1
fi

# Resolve to an absolute path (relative to the CALLER's cwd) before we cd to
# the repo root, otherwise a relative path like "./downloaded.zip" would no
# longer resolve correctly after the cd below.
ZIP_PATH="$(cd "$(dirname "$ZIP_PATH")" && pwd)/$(basename "$ZIP_PATH")"

cd "$REPO_ROOT"

if [ -n "$VERSION_OVERRIDE" ]; then
    VERSION="$VERSION_OVERRIDE"
else
    # Derive a version string from the zip filename, e.g.
    # acevo-server-manager_v1_6_4.zip     -> v1.6.4
    # acevo-server-manager_v1_6_4-1.zip   -> v1.6.4-1   (hotfix/build suffix)
    BASENAME=$(basename "$ZIP_PATH" .zip)
    RAW=$(echo "$BASENAME" | grep -oP '(?<=_v)[0-9]+(_[0-9]+)*(-[0-9A-Za-z]+)*' || true)

    if [ -z "$RAW" ]; then
        VERSION=""
    else
        # Split off any hyphenated suffix (e.g. "-1"), dot-ify only the
        # underscore-separated numeric part before it, then reattach the
        # suffix untouched.
        MAIN="${RAW%%-*}"
        SUFFIX="${RAW#"$MAIN"}"
        MAIN_DOTTED=$(echo "$MAIN" | tr '_' '.')
        VERSION="v${MAIN_DOTTED}${SUFFIX}"
    fi
fi

if [ -z "$VERSION" ]; then
    echo "Could not parse a version number from filename '$ZIP_PATH'."
    echo "Pass it explicitly instead: $0 $ZIP_PATH v1.6.4-1"
    exit 1
fi

echo "Using version: ${VERSION}"

DEST="releases/${VERSION}"
mkdir -p "$DEST"

DEST_ZIP="${DEST}/$(basename "$ZIP_PATH")"
if [ -f "$DEST_ZIP" ]; then
    echo "${DEST_ZIP} already exists - skipping copy."
else
    echo "Copying zip into ${DEST}/ (extraction happens automatically in the container)..."
    cp "$ZIP_PATH" "$DEST_ZIP"
fi

echo "Updating .env to ACEVO_VERSION=${VERSION}"
if grep -q '^ACEVO_VERSION=' .env 2>/dev/null; then
    sed -i "s/^ACEVO_VERSION=.*/ACEVO_VERSION=${VERSION}/" .env
else
    echo "ACEVO_VERSION=${VERSION}" >> .env
fi

if [ "$DEV" = "1" ]; then
    echo "Rebuilding and restarting (dev, local build)..."
    docker compose -f docker-compose.dev.yml up -d --build
    LOGS_CMD="docker compose -f docker-compose.dev.yml logs -f acevo-server-manager"
else
    echo "Restarting with new version (prod, published image - no rebuild needed)..."
    docker compose up -d
    LOGS_CMD="docker compose logs -f acevo-server-manager"
fi

echo ""
echo "Done. Now running ${VERSION}. Check logs with:"
echo "  ${LOGS_CMD}"
echo ""
echo "If something's wrong, roll back with:"
echo "  sed -i 's/^ACEVO_VERSION=.*/ACEVO_VERSION=<previous-version>/' .env"
if [ "$DEV" = "1" ]; then
    echo "  docker compose -f docker-compose.dev.yml up -d --build"
else
    echo "  docker compose up -d"
fi
