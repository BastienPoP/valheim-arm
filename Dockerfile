# Valheim dedicated server for ARM64.
#
# Valheim has no ARM build. It does have an official x86_64 *Linux* server, and
# that is what runs here, under Box64. Box64 emulates only the game's own code:
# calls into the system libraries (libc, pthread, libstdc++, libm) are redirected
# to their native ARM64 versions. There is no Windows compatibility layer and no
# X server.
#
# Build:
#   docker build -t valheim-arm .
#
# On a Raspberry Pi 4 or any other Cortex-A72 host, the CPU-tuned Box64 build is
# a slightly better fit:
#   docker build --build-arg BOX64_PACKAGE=box64-rpi4 -t valheim-arm .

FROM debian:13-slim

# "box64" is the generic ARMv8-A build. "box64-rpi4" is the same source tuned for
# the Cortex-A72 (Raspberry Pi 4 and many ARM virtualisers).
ARG BOX64_PACKAGE=box64
ARG STEAMCMD_URL=https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz

# The server does not run as root. 1000 is the first UID a Linux distribution
# hands to a human, so on a single-user host the bind-mounted directories
# already belong to it and nothing has to be chowned. Override both to match
# another account:
#   docker build --build-arg UID=1001 --build-arg GID=1001 .
ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive
# C.UTF-8 is built into glibc: no locales package to install, and accented server
# names are still handled correctly.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# libgcc-s1-amd64-cross and libstdc++6-amd64-cross satisfy Box64's amd64
# dependency without enabling the amd64 multiarch (which would pull in a whole
# extra apt index). libatomic1 and libpulse0 are the libraries the server manual
# asks for.
# "upgrade" matters: the base image is rebuilt on its own schedule, so by the
# time this builds it is usually a few weeks behind on security updates. Without
# it the image ships known-vulnerable packages that Debian has already fixed.
#
# curl is NOT here. It is only needed to fetch SteamCMD at build time, and it is
# installed and purged inside that one layer below, so it never reaches the
# published image — curl and libcurl are among the most frequently patched
# packages in a Debian base, and nothing at runtime uses them.
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      "${BOX64_PACKAGE}" \
      libgcc-s1-amd64-cross \
      libstdc++6-amd64-cross \
      libatomic1 \
      libpulse0 \
      libpulse-mainloop-glib0 \
      ca-certificates \
      procps \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

# nologin, no password: this account exists to own files and run one process,
# never to be logged into.
RUN groupadd -g "${GID}" valheim \
 && useradd -u "${UID}" -g "${GID}" -d /home/valheim -m -s /usr/sbin/nologin valheim

# Box64 redirects the PulseAudio libraries to their native ARM64 versions, but it
# looks them up under their UNVERSIONED name (libpulse-mainloop-glib.so), which
# only the -dev package ships. Without these links the log fills up with
# "Error initializing native libpulse-mainloop-glib.so.0". Creating the links by
# hand is cheaper than pulling in the whole development chain.
RUN set -e; \
    for f in /usr/lib/*/libpulse.so.0 \
             /usr/lib/*/libpulse-simple.so.0 \
             /usr/lib/*/libpulse-mainloop-glib.so.0; do \
        [ -e "$f" ] || continue; \
        ln -sf "$(basename "$f")" "${f%.0}"; \
    done; \
    ls -l /usr/lib/*/libpulse*.so

# SteamCMD. Valve publishes no ARM64 build, so it runs under Box64 too.
#
# The official tarball is only a 2018 bootstrapper: one 32-bit binary and nothing
# else. It downloads the real SteamCMD, including a 64-bit binary, the first time
# it runs. That first run happens here, at build time, so the image ships a
# complete SteamCMD and the server start-up goes straight to the 64-bit binary
# (faster than the 32-bit one under BOX32).
#
# Box64 is invoked on the BINARY, never on steamcmd.sh: given a script it re-execs
# natively, and the x86 binary then is not emulated at all.
# Exit code 42 means "I updated myself, run me again", so the bootstrap needs
# several passes before it is complete.
#
# Everything below happens in ONE layer, so what is removed at the end is really
# gone from the image rather than merely hidden by a later layer:
#   - curl, installed only to fetch the tarball, then purged;
#   - siteserverui/, 36 MB of WINDOWS DLLs (ffmpeg.dll, libEGL.dll, libGLESv2.dll
#     and the api-ms-win-* stubs). It is SteamCMD's graphical front end: dead
#     weight on a headless Linux server, and exactly the kind of vendored binary
#     that vulnerability scanners flag and that apt can never patch;
#   - package/, SteamCMD's own update cache, which it refills by itself when it
#     needs to.
# SteamCMD was verified to still log in and read app metadata without the two.
RUN set -e; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl; \
    mkdir -p /opt/steamcmd; \
    curl -sSfL "${STEAMCMD_URL}" | tar -xz -C /opt/steamcmd; \
    for i in 1 2 3 4; do \
        box64 /opt/steamcmd/linux32/steamcmd +quit && break; \
        rc=$?; \
        [ "$rc" = 42 ] || exit "$rc"; \
    done; \
    test -x /opt/steamcmd/linux64/steamcmd; \
    rm -rf /root/Steam /opt/steamcmd/siteserverui /opt/steamcmd/package; \
    chown -R valheim:valheim /opt/steamcmd; \
    apt-get purge -y curl; \
    apt-get autoremove -y --purge; \
    rm -rf /var/lib/apt/lists/*

COPY box64.rc.example /opt/defaults/box64.rc.example
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# The volume mount points, owned by the server's account so that a named or
# anonymous volume inherits it. A BIND mount does not: the host directory keeps
# its own ownership, which is the one thing this image asks of the user.
#
# Only these two empty directories are chowned here. /opt/steamcmd -- which has
# to be writable because SteamCMD updates itself in place on almost every start
# -- is chowned inside the layer that creates it: a "chown -R" in a later layer
# rewrites every file it touches into that layer, which added 125 MB to the image
# for nothing. /home/valheim needs no chown at all, useradd -m already creating
# it owned by the account.
RUN mkdir -p /opt/valheim /data \
 && chown valheim:valheim /opt/valheim /data

# SERVER_DIR: game files, downloaded by SteamCMD (volume).
# DATA_DIR:   world, adminlist.txt, logs, config/box64.rc (volume).
ENV SERVER_DIR=/opt/valheim \
    DATA_DIR=/data \
    STEAMCMD_DIR=/opt/steamcmd

# Server arguments. An empty variable means the argument is not passed at all.
# CAUTION: SERVER_PRESET and SERVER_MODIFIERS overwrite the settings stored in the
# world. They are empty by default, and that is deliberate.
ENV UPDATE_ON_START=true \
    STEAM_VALIDATE=true \
    STEAM_RESET_ON_FAILURE=true \
    SERVER_NAME=Valheim \
    SERVER_WORLD=Dedicated \
    SERVER_PASSWORD= \
    SERVER_PORT=2456 \
    SERVER_PUBLIC=0 \
    SERVER_SAVE_INTERVAL=1800 \
    SERVER_BACKUPS=4 \
    SERVER_BACKUP_SHORT=7200 \
    SERVER_BACKUP_LONG=43200 \
    SERVER_INSTANCE_ID= \
    SERVER_SIMULATION_DISTANCE= \
    SERVER_PRESET= \
    SERVER_MODIFIERS= \
    SERVER_SET_KEYS= \
    SERVER_RESET_MODIFIERS=false \
    SERVER_CROSSPLAY=false \
    SERVER_CONSOLE=false \
    SERVER_EXTRA_ARGS=

# No BOX64_* is set here: Box64's own defaults apply, the config/box64.rc file
# overrides them, and an environment variable overrides the file.

VOLUME ["/opt/valheim", "/data"]
EXPOSE 2456-2458/udp

ENV HOME=/home/valheim
USER valheim

ENTRYPOINT ["/entrypoint.sh"]
