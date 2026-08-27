#!/bin/bash
# Diagnostic script for debugging steamcmd download issues.
# Run this INSIDE the container:
#   docker compose exec acevo-server-manager bash /debug-steamcmd.sh <APPID>
# or copy it in and run manually. Prints verbose steamcmd output so we can
# see exactly what's failing (network, login, app id, disk space, etc).

set -x  # print every command as it runs

APPID="${1:-${ACEVO_STEAM_APPID}}"

echo "=================================================="
echo "1. Checking environment"
echo "=================================================="
echo "ACEVO_AUTO_UPDATE=${ACEVO_AUTO_UPDATE}"
echo "ACEVO_STEAM_APPID=${ACEVO_STEAM_APPID}"
echo "Using APPID=${APPID}"
echo "STEAM_USER set: $( [ -n "${STEAM_USER}" ] && echo yes || echo no )"

if [ -z "$APPID" ]; then
    echo "ERROR: No App ID given and ACEVO_STEAM_APPID is not set."
    echo "Usage: bash debug-steamcmd.sh <APPID>"
    exit 1
fi

echo "=================================================="
echo "2. Checking disk space"
echo "=================================================="
df -h /acevo

echo "=================================================="
echo "3. Checking DNS / network reachability to Steam"
echo "=================================================="
getent hosts steamcommunity.com
getent hosts api.steampowered.com
curl -sS -o /dev/null -w "HTTP %{http_code}\n" https://api.steampowered.com/ISteamWebAPIUtil/GetServerInfo/v1/ || echo "curl to Steam API FAILED"

echo "=================================================="
echo "4. Checking steamcmd binary exists"
echo "=================================================="
which steamcmd || echo "steamcmd NOT FOUND on PATH"
steamcmd +quit 2>&1 | head -40

echo "=================================================="
echo "5. Running app_info_print to confirm the App ID is valid"
echo "=================================================="
steamcmd +login anonymous +app_info_print "${APPID}" +quit 2>&1 | tail -60

echo "=================================================="
echo "6. Attempting the actual install/update with full verbose output"
echo "=================================================="
mkdir -p /acevo/server
if [ -n "${STEAM_USER}" ] && [ -n "${STEAM_PASS}" ]; then
    steamcmd \
        +@sSteamCmdForcePlatformType windows \
        +force_install_dir /acevo/server \
        +login "${STEAM_USER}" "${STEAM_PASS}" \
        +app_update "${APPID}" validate \
        +quit
else
    steamcmd \
        +@sSteamCmdForcePlatformType windows \
        +force_install_dir /acevo/server \
        +login anonymous \
        +app_update "${APPID}" validate \
        +quit
fi

echo "=================================================="
echo "7. Result: contents of /acevo/server"
echo "=================================================="
ls -la /acevo/server

set +x
echo "Done. Scroll up for the first ERROR / FAILED line - that's the actual cause."
