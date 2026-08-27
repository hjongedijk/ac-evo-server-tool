#!/bin/bash
# acsm-evo-control.sh — install, update, and manage this deployment.
# Usage:
#   ./acsm-evo-control.sh install
#   ./acsm-evo-control.sh update-manager /path/to/acevo-server-manager_vX.Y.Z.zip [version] [--dev]
#   ./acsm-evo-control.sh update-game
#   ./acsm-evo-control.sh add-server ["Server Name"]
#   ./acsm-evo-control.sh status
#   ./acsm-evo-control.sh                 (interactive menu)
#
# `install` is a standalone bootstrapper - run it in an empty directory
# alongside just this file, your acevo-server-manager_vX.Y.Z.zip, and your
# ACEVO.License; it fetches docker-compose.yml/.env.example from GitHub.
#
# `update-manager`, `update-game`, `add-server` and `status` assume
# first-time setup is already done (they operate on data/, releases/,
# docker-compose.yml, .env already in place).
set -euo pipefail

GITHUB_REPO="hjongedijk/ac-evo-server-tool"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ============================================================================
# Colors + small output helpers
# ============================================================================
if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'; C_MAGENTA=$'\033[35m'
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_MAGENTA=''
fi

log()     { printf '%s==>%s %s\n' "${C_CYAN}${C_BOLD}" "${C_RESET}" "$1"; }
success() { printf '%s==>%s %s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}" "$1"; }
warn()    { printf '%s==>%s %s\n' "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$1" >&2; }
error()   { printf '%sERROR:%s %s\n' "${C_RED}${C_BOLD}" "${C_RESET}" "$1" >&2; }

banner() {
    printf '%s' "${C_MAGENTA}${C_BOLD}"
    cat <<'EOF'
 █████   ██████ ███████ ███    ███     ███████ ██    ██  ██████
██   ██ ██      ██      ████  ████     ██      ██    ██ ██    ██
███████ ██      ███████ ██ ████ ██     █████   ██    ██ ██    ██
██   ██ ██           ██ ██  ██  ██     ██       ██  ██  ██    ██
██   ██  ██████ ███████ ██      ██     ███████   ████    ██████

                     C O N T R O L   P A N E L
EOF
    printf '%s\n' "${C_RESET}"
}

# ============================================================================
# Shared helpers
# ============================================================================

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

# Publish the TCP+UDP port pair for server index N (0-based) in
# docker-compose.yml, matching the scheme the manager itself uses: server 0
# is 9800/9800/9801, server 1 is 9802/9802/9803, etc. Idempotent - does
# nothing if that port is already published. Inserts right before the
# service's "volumes:" line.
ensure_server_ports() {
    local idx="$1"
    local port=$((9800 + idx * 2))
    local http=$((port + 1))
    if grep -qE "^\s*- \"${port}:${port}/udp\"" docker-compose.yml 2>/dev/null; then
        return
    fi
    local block
    block=$(printf '%s\n%s\n%s' \
        "      - \"${port}:${port}/udp\"     # server $((idx + 1))" \
        "      - \"${port}:${port}/tcp\"" \
        "      - \"${http}:${http}/tcp\"")
    awk -v block="$block" '
        /^    volumes:/ && !done { print block; done=1 }
        { print }
    ' docker-compose.yml > docker-compose.yml.tmp
    mv docker-compose.yml.tmp docker-compose.yml
}

# Parse a version out of an acevo-server-manager zip filename. Handles both
# the dot-separated names Emperor Servers actually ships ("v1.6.4-1.zip")
# and underscore-separated ones ("v1_6_4-1.zip").
parse_zip_version() {
    local zip_path="$1"
    local basename raw main suffix main_dotted
    basename=$(basename "$zip_path" .zip)
    raw=$(echo "$basename" | grep -oP '(?<=_v)[0-9]+(?:[._][0-9]+)*(-[0-9A-Za-z]+)*' || true)
    [ -z "$raw" ] && return 1
    main="${raw%%-*}"
    suffix="${raw#"$main"}"
    main_dotted=$(echo "$main" | tr '_' '.')
    echo "v${main_dotted}${suffix}"
}

require_setup_done() {
    if [ ! -f .env ] || [ ! -s data/config.yml ]; then
        error "First-time setup isn't done yet. Run: $0 install"
        exit 1
    fi
}

require_container_running() {
    local cid
    cid=$(docker compose ps -q acevo-server-manager 2>/dev/null || true)
    if [ -z "$cid" ] || [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" != "true" ]; then
        error "The container isn't running. Start it first: docker compose up -d"
        exit 1
    fi
}

# Default timeout is generous (30 min) because a genuinely fresh install
# has steamcmd download the whole game server from scratch first (can
# easily take several minutes depending on network speed) before the
# manager can even start its own per-server installation step - this is
# NOT related to whether servers are started/stopped in the web UI.
wait_for_container_ready() {
    local timeout="${1:-1800}" waited=0 last_log=""
    log "Waiting for the container to finish its first boot (up to ${timeout}s - a fresh"
    echo "    install downloads the whole game server via steamcmd first, so this can take"
    echo "    a while on the first run)..."
    while [ ! -f "data/store.json/servers/server_0/serverOptions.json" ]; do
        if [ "$waited" -ge "$timeout" ]; then
            warn "Timed out waiting for server_0 to be ready."
            return 1
        fi
        sleep 15
        waited=$((waited + 15))
        if [ $((waited % 60)) -eq 0 ]; then
            last_log=$(docker compose logs --tail 1 acevo-server-manager 2>/dev/null || true)
            echo "    ...still waiting (${waited}s elapsed). Latest: ${last_log}"
        fi
    done
    log "Ready (took ~${waited}s)."
}

# ============================================================================
# add-server - registers a new server directly with the manager (writes its
# store.json entry + copies its per-server game files from an existing
# server), publishes its ports, and tells you to restart. No web UI needed.
# ============================================================================
cmd_add_server() {
    require_setup_done

    local next_idx=0
    while [ -d "data/store.json/servers/server_${next_idx}" ]; do
        next_idx=$((next_idx + 1))
    done
    if [ "$next_idx" -eq 0 ]; then
        error "No existing server found under data/store.json/servers/."
        echo "Start the container first (docker compose up -d) and let it fully boot -" >&2
        echo "it creates server_0 itself on first run - then try again." >&2
        exit 1
    fi

    local template_dir="data/server/_manager/servers/server_0"
    if [ ! -f "${template_dir}/AssettoCorsaEVOServer.exe" ]; then
        error "server_0's game files aren't ready yet (${template_dir}/AssettoCorsaEVOServer.exe missing)."
        echo "Make sure the container has started and fully booted at least once:" >&2
        echo "  docker compose up -d" >&2
        exit 1
    fi

    local new_id="server_${next_idx}"
    local port=$((9800 + next_idx * 2))
    local http=$((port + 1))

    local name="${1:-}" players="16" driver_pass="" admin_pass=""
    if [ -z "$name" ] && [ -t 0 ]; then
        echo ""
        echo "${C_BOLD}--- New server ---${C_RESET}"
        read -r -p "Server name [Server $((next_idx + 1))]: " name
        name="${name:-Server $((next_idx + 1))}"
        read -r -p "Max players [16]: " players
        players="${players:-16}"
        if ! [[ "$players" =~ ^[0-9]+$ ]]; then
            warn "'${players}' isn't a number - using 16."
            players=16
        fi
        read -r -p "Driver password (blank = none): " driver_pass
        read -r -s -p "Admin password (blank = none): " admin_pass
        echo ""
    else
        name="${name:-Server $((next_idx + 1))}"
    fi

    log "Adding ${new_id} (\"${name}\") on port ${port} (web: ${http})"

    mkdir -p "data/store.json/servers/${new_id}"
    cat > "data/store.json/servers/${new_id}/serverOptions.json" <<JSON
{"ServerConfig":{"server_name":"${name}","server_tcp_listener_port":${port},"server_udp_listener_port":${port},"server_tcp_internal_port":${port},"server_udp_internal_port":${port},"server_http_port":${http},"max_players":${players},"cycle":false,"allowed_cars_list_full":null,"driver_password":"${driver_pass}","spectator_password":"","admin_password":"${admin_pass}","type":"MultiplayerServerListSessionType_RANKED","entry_list_path":"","results_path":"","tuning_type":""},"ServerFlags":{"NoLobby":false},"ServerManagerServerOptions":{"RestartCurrentEventOnServerCrash":true,"BlockListedSteamIDs":null}}
JSON
    cat > "data/store.json/servers/${new_id}/perServerOptions.json" <<'JSON'
{"ServerName":{"UseServerNameTemplate":true,"ServerNameTemplate":"{{ .ServerName }} - {{ with .ChampionshipName }}{{ . }}{{ else }}{{ .EventName }}{{ end }}"},"ProcessManagement":{"ServerProcessPriority":3,"ServerProcessCPUAffinity":null}}
JSON
    cat > "data/store.json/servers/${new_id}/notifications.json" <<'JSON'
{"discordEnable":false,"DiscordWebhookURL":"","discordRoleID":0,"reminders":"","discordWebhookNotifyOn":["preset_start","preset_scheduled"],"customText":"","discordWebhookID":0,"discordWebhookToken":""}
JSON

    log "Copying game files from server_0 (this can take a minute)..."
    cp -r "${template_dir}" "data/server/_manager/servers/${new_id}"
    rm -rf "data/server/_manager/servers/${new_id}/_manager/logs"/*
    rm -rf "data/server/_manager/servers/${new_id}/results"/*

    cat > "data/server/_manager/servers/${new_id}/server_config.json" <<JSON
{
  "server_name": "${name}",
  "server_tcp_listener_port": ${port},
  "server_udp_listener_port": ${port},
  "server_tcp_internal_port": ${port},
  "server_udp_internal_port": ${port},
  "server_http_port": ${http},
  "max_players": ${players},
  "cycle": false,
  "allowed_cars_list_full": [],
  "driver_password": "${driver_pass}",
  "spectator_password": "",
  "admin_password": "${admin_pass}",
  "type": "MultiplayerServerListSessionType_RANKED",
  "entry_list_path": "/acevo/server/_manager/servers/${new_id}/entry_list.json",
  "results_path": "/acevo/server/_manager/servers/${new_id}/results/",
  "tuning_type": ""
}
JSON

    ensure_server_ports "$next_idx"

    echo ""
    success "${new_id} added. Restart to pick it up:"
    echo "  docker compose up -d"
    echo "Forward ${port} (TCP+UDP) and ${http} (TCP) at your router/firewall too."
}

# ============================================================================
# install - standalone first-time setup. Fetches docker-compose.yml/
# .env.example from GitHub, scaffolds data/, places your license and
# release zip, prompts for TZ/Steam/server count, and (if you ask for more
# than one server) automatically boots the container and adds the rest via
# add-server - no web UI clicking needed.
# ============================================================================
cmd_install() {
    banner

    log "Resolving latest release of ${GITHUB_REPO}"
    local ref
    ref=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | grep -oP '(?<=": ")[^"]+') || true
    if [ -z "$ref" ]; then
        warn "Could not resolve a release tag - falling back to the main branch."
        ref="main"
    fi
    echo "  Using ref: ${ref}"

    fetch_tooling_file() {
        local path="$1"
        if [ -f "$path" ]; then
            echo "  ${path} already exists - leaving it alone"
            return
        fi
        echo "  Fetching ${path}"
        local tmp
        tmp="$(mktemp)"
        if ! curl -fsSL "https://raw.githubusercontent.com/${GITHUB_REPO}/${ref}/${path}" -o "$tmp"; then
            rm -f "$tmp"
            error "failed to fetch ${path} from ${GITHUB_REPO}@${ref}"
            exit 1
        fi
        mv "$tmp" "$path"
    }

    log "Fetching tooling files"
    fetch_tooling_file docker-compose.yml
    fetch_tooling_file .env.example

    log "Creating data/ and releases/ directories"
    mkdir -p data/server data/store.json releases

    if [ -f data/ACEVO.License ] && [ -s data/ACEVO.License ]; then
        echo "  data/ACEVO.License already exists - leaving it alone"
    elif [ -f ACEVO.License ]; then
        log "Moving ACEVO.License into data/"
        mv ACEVO.License data/ACEVO.License
    else
        warn "No ACEVO.License found alongside this script - creating an empty placeholder."
        echo "    Get one from the emperorservers.com Control Panel and place it at data/ACEVO.License."
        touch data/ACEVO.License
    fi

    local env_prompted=0 session_key_generated=0 num_servers=1
    if [ -f .env ]; then
        echo "  .env already exists - leaving it alone"
    else
        log "Creating .env from .env.example"
        cp .env.example .env

        if [ -t 0 ]; then
            env_prompted=1
            echo ""
            echo "${C_BOLD}--- A couple of quick settings (press Enter to accept the default) ---${C_RESET}"

            local tz_input
            read -r -p "Timezone, e.g. Europe/Berlin [UTC]: " tz_input
            tz_input="${tz_input:-UTC}"
            if [ -f "/usr/share/zoneinfo/${tz_input}" ]; then
                set_env_var TZ "$tz_input"
            else
                warn "'${tz_input}' doesn't look like a valid IANA timezone name - leaving TZ at its default (UTC)."
            fi

            echo "Steam login for steamcmd - typically required for this app (anonymous"
            echo "login has been observed to fail without the base game in your library)."
            local steam_user_input steam_pass_input
            read -r -p "STEAM_USER [blank = try anonymous]: " steam_user_input
            if [ -n "$steam_user_input" ]; then
                read -r -s -p "STEAM_PASS: " steam_pass_input
                echo ""
                set_env_var STEAM_USER "$steam_user_input"
                set_env_var STEAM_PASS "$steam_pass_input"
            fi

            echo ""
            local num_servers_input
            read -r -p "How many game servers do you want to run? [1]: " num_servers_input
            num_servers_input="${num_servers_input:-1}"
            if [[ "$num_servers_input" =~ ^[0-9]+$ ]] && [ "$num_servers_input" -ge 1 ]; then
                num_servers="$num_servers_input"
            else
                warn "'${num_servers_input}' isn't a valid number - defaulting to 1."
            fi
            echo ""
        else
            warn "No terminal attached - skipping the TZ/Steam/server-count prompts (left at .env.example defaults)."
        fi
    fi

    rm -f .env.example

    local latest_version=""
    shopt -s nullglob
    local zip_path
    for zip_path in ./acevo-server-manager*.zip; do
        local version
        if ! version="$(parse_zip_version "$zip_path")"; then
            warn "couldn't parse a version from ${zip_path} - skipping. Place it manually with: $0 update-manager"
            continue
        fi

        local dest="releases/${version}"
        mkdir -p "$dest"
        local dest_zip
        dest_zip="${dest}/$(basename "$zip_path")"
        if [ -f "$dest_zip" ]; then
            echo "  ${dest_zip} already exists - leaving ${zip_path} where it is."
        else
            log "Moving ${zip_path} to ${dest_zip}"
            mv "$zip_path" "$dest_zip"
        fi

        if [ -z "$latest_version" ] || [ "$(printf '%s\n%s\n' "$latest_version" "$version" | sort -V | tail -1)" = "$version" ]; then
            latest_version="$version"
        fi

        if [ ! -f data/config.yml ] || [ ! -s data/config.yml ]; then
            log "Seeding data/config.yml from ${dest_zip}"
            unzip -p "$dest_zip" linux/config.yml > data/config.yml
            log "Generating a random http.session_key"
            local session_key
            session_key="$(generate_secret)"
            sed -i "s/^\(\s*session_key:\).*/\1 ${session_key}/" data/config.yml
            session_key_generated=1
        fi
    done
    shopt -u nullglob

    if [ -n "$latest_version" ]; then
        log "Setting ACEVO_VERSION=${latest_version} in .env"
        set_env_var ACEVO_VERSION "$latest_version"
    elif [ ! -f data/config.yml ] || [ ! -s data/config.yml ]; then
        warn "No acevo-server-manager_*.zip found alongside this script - skipping release placement."
        echo "    Once you've downloaded one, re-run this script (or use: $0 update-manager) to pick it up."
    fi

    # Auto-provision extra servers end-to-end (boot + add-server + reboot) if
    # everything needed is in place. Anything short of that just falls back
    # to printing the manual step - a failure here should never fail install.
    local auto_provisioned=0
    if [ "$num_servers" -gt 1 ] && [ -n "$latest_version" ] && command -v docker >/dev/null 2>&1; then
        log "Setting up ${num_servers} servers - starting the container (this takes a few"
        echo "    minutes the first time, steamcmd downloads the game server)..."
        if docker compose up -d && wait_for_container_ready; then
            local i
            for ((i = 1; i < num_servers; i++)); do
                cmd_add_server || true
            done
            log "Restarting to pick up the new servers..."
            docker compose up -d
            auto_provisioned=1
        else
            warn "Didn't finish auto-adding the extra servers in time - the container is"
            echo "    likely still starting up in the background (nothing is broken)."
            echo "    Check progress: docker compose logs -f acevo-server-manager"
            echo "    Once it's up, add the rest yourself: $0 add-server"
        fi
    fi

    echo ""
    if [ "$auto_provisioned" = "1" ]; then
        success "Done. ${num_servers} servers are configured and running."
        echo "  docker compose logs -f acevo-server-manager"
    else
        success "Done. Remaining steps:"
        local step=1
        if [ "$session_key_generated" != "1" ]; then
            echo "  ${step}. Review data/config.yml: set http.session_key to a random secret."
            step=$((step + 1))
        fi
        if [ "$env_prompted" != "1" ]; then
            echo "  ${step}. Fill in .env: TZ, and STEAM_USER/STEAM_PASS if anonymous steamcmd login"
            echo "     doesn't work for downloading the game server."
            step=$((step + 1))
        fi
        echo "  ${step}. docker compose up -d"
        echo "     docker compose logs -f acevo-server-manager"
        if [ "$num_servers" -gt 1 ]; then
            step=$((step + 1))
            echo "  ${step}. Once it's up: $0 add-server (run $((num_servers - 1)) more time(s))"
        fi
    fi
    echo ""
    echo "See README-docker.md (fetched as part of the repo, or view it on GitHub) for full details."
}

# ============================================================================
# update-manager - install a new manager release: places the zip, bumps
# ACEVO_VERSION, restarts. Your data/ (config, license, game files, store,
# all servers) is never touched.
# ============================================================================
cmd_update_manager() {
    local dev=0
    local args=()
    for arg in "$@"; do
        if [ "$arg" = "--dev" ]; then
            dev=1
        else
            args+=("$arg")
        fi
    done
    set -- "${args[@]+"${args[@]}"}"

    local zip_path="${1:-}" version_override="${2:-}"
    if [ -z "$zip_path" ] && [ -t 0 ]; then
        read -r -p "Path to acevo-server-manager release zip: " zip_path
    fi
    if [ -z "$zip_path" ] || [ ! -f "$zip_path" ]; then
        echo "Usage: $0 update-manager /path/to/acevo-server-manager_vX_Y_Z.zip [version] [--dev]"
        exit 1
    fi
    zip_path="$(cd "$(dirname "$zip_path")" && pwd)/$(basename "$zip_path")"

    local version="$version_override"
    if [ -z "$version" ]; then
        if ! version="$(parse_zip_version "$zip_path")"; then
            error "Could not parse a version number from filename '$zip_path'."
            echo "Pass it explicitly instead: $0 update-manager $zip_path v1.6.4-1"
            exit 1
        fi
    fi
    log "Using version: ${version}"

    local dest="releases/${version}"
    mkdir -p "$dest"
    local dest_zip
    dest_zip="${dest}/$(basename "$zip_path")"
    if [ -f "$dest_zip" ]; then
        echo "${dest_zip} already exists - leaving ${zip_path} where it is."
    else
        log "Moving zip into ${dest}/ (extraction happens automatically in the container)..."
        mv "$zip_path" "$dest_zip"
    fi

    log "Updating .env to ACEVO_VERSION=${version}"
    set_env_var ACEVO_VERSION "$version"

    local logs_cmd
    if [ "$dev" = "1" ]; then
        log "Rebuilding and restarting (dev, local build)..."
        docker compose -f docker-compose.dev.yml up -d --build
        logs_cmd="docker compose -f docker-compose.dev.yml logs -f acevo-server-manager"
    else
        log "Restarting with new version (prod, published image - no rebuild needed)..."
        docker compose up -d
        logs_cmd="docker compose logs -f acevo-server-manager"
    fi

    echo ""
    success "Done. Now running ${version}. Check logs with:"
    echo "  ${logs_cmd}"
    echo ""
    echo "If something's wrong, roll back with:"
    echo "  sed -i 's/^ACEVO_VERSION=.*/ACEVO_VERSION=<previous-version>/' .env"
    if [ "$dev" = "1" ]; then
        echo "  docker compose -f docker-compose.dev.yml up -d --build"
    else
        echo "  docker compose up -d"
    fi
}

# ============================================================================
# update-game - re-run steamcmd inside the running container to update the
# AC EVO dedicated server files, mirroring exactly what entrypoint.sh does
# automatically on every start when ACEVO_AUTO_UPDATE=1 - useful to trigger
# it on demand without a full restart, or if auto-update is turned off.
# ============================================================================
cmd_update_game() {
    require_setup_done
    require_container_running

    local appid
    appid=$(grep '^ACEVO_STEAM_APPID=' .env 2>/dev/null | cut -d= -f2-)
    if [ -z "$appid" ]; then
        error "ACEVO_STEAM_APPID isn't set in .env."
        exit 1
    fi

    log "Updating game server files via steamcmd (app id ${appid})..."
    docker compose exec -T acevo-server-manager sh -c '
        if [ -n "$STEAM_USER" ] && [ -n "$STEAM_PASS" ]; then
            steamcmd +force_install_dir /acevo/server +login "$STEAM_USER" "$STEAM_PASS" +app_update "'"${appid}"'" validate +quit
        else
            steamcmd +force_install_dir /acevo/server +login anonymous +app_update "'"${appid}"'" validate +quit
        fi
    '
    echo ""
    success "Game server files updated."
    echo "Restart to make sure the manager picks up any changes: docker compose up -d"
}

# ============================================================================
# status - read-only summary of the current deployment.
# ============================================================================
cmd_status() {
    echo "${C_BOLD}=== acsm-evo-control status ===${C_RESET}"
    if [ -f .env ]; then
        echo "ACEVO_VERSION: $(grep '^ACEVO_VERSION=' .env 2>/dev/null | cut -d= -f2- || echo '?')"
        echo "IMAGE_TAG:     $(grep '^IMAGE_TAG=' .env 2>/dev/null | cut -d= -f2- || echo '?')"
    else
        warn ".env not found - run: $0 install"
    fi
    echo ""
    echo "${C_BOLD}Servers:${C_RESET}"
    local found=0
    if [ -d data/store.json/servers ]; then
        local d id name port http
        for d in data/store.json/servers/server_*; do
            [ -d "$d" ] || continue
            found=1
            id=$(basename "$d")
            name=$(grep -oP '"server_name":"\K[^"]*' "$d/serverOptions.json" 2>/dev/null || echo "?")
            port=$(grep -oP '"server_tcp_listener_port":\K[0-9]+' "$d/serverOptions.json" 2>/dev/null || echo "?")
            http=$(grep -oP '"server_http_port":\K[0-9]+' "$d/serverOptions.json" 2>/dev/null || echo "?")
            echo "  ${id}: \"${name}\" - port ${port} (tcp+udp), web ${http}"
        done
    fi
    [ "$found" = "0" ] && echo "  (none yet - run: $0 install)"
    echo ""
    if command -v docker >/dev/null 2>&1 && [ -f docker-compose.yml ]; then
        docker compose ps 2>/dev/null || echo "(container not running)"
    fi
}

cmd_help() {
    cat <<EOF
Usage: $0 <command> [args]

Commands:
  install                     First-time setup (standalone - fetches what it needs from GitHub)
  update-manager <zip> [ver]  Install a new manager release and restart (add --dev for local build)
  update-game                 Re-run steamcmd inside the running container to update game files
  add-server ["Name"]         Register a new server with the manager and publish its ports
  status                      Show current version, configured servers, and container state
  help                        Show this message

Run with no command for an interactive menu.
EOF
}

cmd_menu() {
    banner
    echo "  ${C_BOLD}1)${C_RESET} Install / first-time setup"
    echo "  ${C_BOLD}2)${C_RESET} Update manager release"
    echo "  ${C_BOLD}3)${C_RESET} Update game server files (steamcmd)"
    echo "  ${C_BOLD}4)${C_RESET} Add a server"
    echo "  ${C_BOLD}5)${C_RESET} Show status"
    echo "  ${C_BOLD}6)${C_RESET} Exit"
    echo ""
    local choice
    read -r -p "Choice [1-6]: " choice
    echo ""
    case "$choice" in
        1) cmd_install ;;
        2) cmd_update_manager ;;
        3) cmd_update_game ;;
        4) cmd_add_server ;;
        5) cmd_status ;;
        6) exit 0 ;;
        *) error "Unknown choice."; exit 1 ;;
    esac
}

# ============================================================================
# Dispatch
# ============================================================================
case "${1:-}" in
    install) shift; cmd_install "$@" ;;
    update-manager) shift; cmd_update_manager "$@" ;;
    update-game) shift; cmd_update_game "$@" ;;
    add-server) shift; cmd_add_server "$@" ;;
    status) shift; cmd_status "$@" ;;
    help|-h|--help) cmd_help ;;
    "") cmd_menu ;;
    *)
        error "Unknown command: $1"
        echo "" >&2
        cmd_help >&2
        exit 1
        ;;
esac
