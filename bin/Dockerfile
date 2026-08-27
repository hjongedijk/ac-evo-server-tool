# Assetto Corsa EVO Server Manager - base Docker image
# Base image bundles 64-bit Wine (needed because the AC EVO dedicated server
# executable is Windows-only) plus steamcmd to fetch the game server files.
#
# IMPORTANT: this image deliberately does NOT contain the proprietary
# acevo-server-manager binary or its config.yml - those are Emperor Servers'
# licensed software and can't be redistributed. This image is just the OS +
# Wine + steamcmd + entrypoint logic, which is why it's safe to build and
# publish publicly to GHCR. The actual binary is supplied at container
# runtime via a volume mount (see docker-compose.yml) pointing at
# releases/<version>/linux/, which you populate yourself from your own
# Emperor Servers download.
FROM scottyhardy/docker-wine:stable

USER root

# --- Install steamcmd + basic deps -----------------------------------------
# steamcmd's .deb needs the Steam license accepted, which normally happens
# via an interactive debconf prompt. Since `docker build` has no TTY, we
# pre-seed debconf with acceptance so the install runs unattended.
ENV DEBIAN_FRONTEND=noninteractive

# Makes RUN steps with a pipe (the debconf-set-selections lines below) fail
# the build if the left side of the pipe fails, instead of silently
# succeeding on the right side's exit code alone.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends debconf && \
    echo steam steam/question select "I AGREE" | debconf-set-selections && \
    echo steam steam/license note '' | debconf-set-selections && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        lib32gcc-s1 \
        steamcmd \
        tzdata \
        unzip \
        xvfb \
    && rm -rf /var/lib/apt/lists/*

# Default timezone if TZ isn't set at runtime via .env - actually applied
# (not just declared) by entrypoint.sh symlinking /etc/localtime, since
# tzdata is what makes that meaningful. Override per-container via TZ in
# .env, e.g. TZ=Europe/Berlin.
ENV TZ=UTC

# steamcmd installs a wrapper at /usr/games/steamcmd, which may not be on
# PATH in this base image - symlink it into /usr/local/bin so it's always
# reachable regardless of shell/PATH configuration.
RUN ln -sf /usr/games/steamcmd /usr/local/bin/steamcmd

# --- App layout --------------------------------------------------------------
# /acevo               -> install folder (manager binary + config.yml + license,
#                          populated at runtime from mounted volumes)
# /acevo/vendor        -> read-only mount of releases/<version>/linux/ from
#                          the host, containing the actual proprietary binary
# /acevo/server        -> game server install_path (steamcmd downloads here)
ENV ACEVO_HOME=/acevo
WORKDIR ${ACEVO_HOME}
RUN mkdir -p ${ACEVO_HOME}/server

# Wine (used internally when the manager launches the AC EVO game server exe)
# requires XDG_RUNTIME_DIR to point at an existing, valid directory. Setting
# it here as an image-level ENV (rather than only exporting it in
# entrypoint.sh) ensures it's present in the manager's baseline environment
# even if the manager spawns the game server subprocess with its own
# explicit/controlled environment rather than inheriting the shell's.
ENV XDG_RUNTIME_DIR=/tmp/xdg-runtime
RUN mkdir -p ${XDG_RUNTIME_DIR} && chmod 0700 ${XDG_RUNTIME_DIR}

COPY bin/entrypoint.sh /entrypoint.sh

# Strip any Windows-style CRLF line endings that may have crept in (e.g. from
# editing on Windows) - otherwise the shebang line breaks and the container
# fails with "exec /entrypoint.sh: no such file or directory".
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

# NOTE: you must supply your own ACEVO.License file at runtime by mounting it
# into the container at /acevo/ACEVO.License (see docker-compose.yml).

# Web UI port (matches http.hostname in config.yml, default 0.0.0.0:8773)
EXPOSE 8773

# Game server ports - these are assigned per-server via the manager's own web
# UI, not fixed at the image level. Update the `ports:` section in
# docker-compose.yml to match whatever the UI shows (9800/9801 by default
# for the first server) - EXPOSE here is documentation only and doesn't
# actually publish anything.
EXPOSE 9800/udp
EXPOSE 9800/tcp
EXPOSE 9801/tcp

ENTRYPOINT ["/entrypoint.sh"]
