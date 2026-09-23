# Valheim dedicated server for ARM64.
#
# Valheim has no ARM build. It does have an official x86_64 *Linux* server, and
# that is what runs here, under Box64. Box64 emulates only the game's own code:
# calls into the system libraries (libc, pthread, libstdc++, libm) are redirected
# to their native ARM64 versions. There is no Wine, no X server, no Win32 layer.
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

ENV DEBIAN_FRONTEND=noninteractive
# C.UTF-8 is built into glibc: no locales package to install, and accented server
# names are still handled correctly.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# libgcc-s1-amd64-cross and libstdc++6-amd64-cross satisfy Box64's amd64
# dependency without enabling the amd64 multiarch (which would pull in a whole
# extra apt index). libatomic1 and libpulse0 are the libraries the server manual
# asks for.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      "${BOX64_PACKAGE}" \
      libgcc-s1-amd64-cross \
      libstdc++6-amd64-cross \
      libatomic1 \
      libpulse0 \
      libpulse-mainloop-glib0 \
      ca-certificates \
      curl \
      procps \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

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
RUN set -e; \
    mkdir -p /opt/steamcmd; \
    curl -sSfL "${STEAMCMD_URL}" | tar -xz -C /opt/steamcmd; \
    for i in 1 2 3 4; do \
        box64 /opt/steamcmd/linux32/steamcmd +quit && break; \
        rc=$?; \
        [ "$rc" = 42 ] || exit "$rc"; \
    done; \
    test -x /opt/steamcmd/linux64/steamcmd; \
    rm -rf /root/Steam/logs

COPY box64.rc.example /opt/defaults/box64.rc.example
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

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

ENTRYPOINT ["/entrypoint.sh"]
