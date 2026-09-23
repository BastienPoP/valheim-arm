# valheim-arm

**The official Linux Valheim server, emulated just enough to run on ARM.**

Valheim has no ARM build. It does have an official **x86_64 Linux** dedicated
server, and this image runs it under [Box64](https://github.com/ptitSeb/box64).
Box64 emulates only the game's own code: calls into the system libraries (libc,
pthread, libstdc++, libm) are redirected to their **native ARM64** versions.
There is no Windows compatibility layer and no X server, so the server runs as a
single process tree.

The result is a **375 MB** image running Valheim **1.0** on a Raspberry Pi 4, an
Ampere/Graviton VM, an Apple Silicon Docker Desktop, or any other ARM64 host.

> [!IMPORTANT]
> **This image is lightly tested.** It has been running one private world on one
> machine — a 3-vCPU Cortex-A72 VM with 14 GB of RAM — and nothing more. It has
> not been tested on Raspberry Pi hardware, on other ARM CPUs, with mods, or
> with more than a handful of players. **Crossplay does not work** — see
> [Crossplay](#crossplay). Treat this image as working-but-unproven, keep your
> own backups, and please [open an issue](../../issues) with what you find.

---

## Quick start

```bash
git clone https://github.com/BastienPoP/valheim-arm.git
cd valheim-arm
cp .env.example .env        # then edit SERVER_PASSWORD
docker compose up -d
docker compose logs -f
```

The world is ready when the log prints:

```
Game server connected
ZDOMan.LoadChunks done
```

First start downloads ~2 GB of game files through SteamCMD and takes a few
minutes. Later starts only check for updates.

Then join from the game: **Start game → Select character → Join Game → Join IP**,
and enter `<host-ip>:2456`.

### Without compose

```bash
docker run -d --name valheim \
  -p 2456-2458:2456-2458/udp \
  -v "$PWD/server:/opt/valheim" \
  -v "$PWD/data:/data" \
  -e SERVER_NAME="My Server" \
  -e SERVER_WORLD="Dedicated" \
  -e SERVER_PASSWORD="secret123" \
  --stop-timeout 40 \
  ghcr.io/bastienpop/valheim-arm:latest
```

## Images

| Registry | Pull |
|---|---|
| GitHub Container Registry | `ghcr.io/bastienpop/valheim-arm:latest` |
| Docker Hub | `bastienpop/valheim-arm:latest` |

Tags: `latest`, plus a `X.Y.Z` tag per release. The image is `linux/arm64` only —
it is an ARM64 emulation image and has no reason to exist on x86_64, where you
should run the server natively.

### Building it yourself

```bash
docker build -t valheim-arm .
```

The published image uses the generic `box64` build. On a **Raspberry Pi 4** or
any other Cortex-A72 host, the CPU-tuned build is a slightly better fit:

```bash
docker build --build-arg BOX64_PACKAGE=box64-rpi4 -t valheim-arm .
```

Nothing is compiled: Box64 comes from the Debian package (0.3.4 in Debian 13).

## Volumes

| Path | Contents | Back it up? |
|---|---|---|
| `/opt/valheim` | Game files downloaded by SteamCMD, ~2 GB | No — SteamCMD redownloads them |
| `/data` | World, `adminlist.txt`, `permittedlist.txt`, logs, `config/box64.rc` | **Yes** |

A world lives in `/data/worlds_local/<world>/`. It is not a single file: it is a
set of **numbered generations** (`_main.N.db2`, `_main.N.fwl2`, `_main.N.chunks`,
`_main.N.ok`) plus `.chunk` files, managed by the game's own backup settings.

> [!WARNING]
> When moving a world in, copy **all** of it. A transfer that only brings the
> `cacheMinimap*` files looks like a backup but is not: the server will silently
> create a **new world**. Check `ls data/worlds_local/<world>/` afterwards.

Both directories are bind-mounted in the compose file, so they appear as
`./server` and `./data` next to it. The container runs as root, so the files it
creates are owned by root on the host — that is the usual Docker behaviour and
is why the compose file uses bind mounts rather than named volumes, so you can
see and back up your world without entering the container.

## Configuration

Everything is an environment variable. **An empty variable means the argument is
not passed at all** — that is what keeps the server from overwriting settings
already stored in your world.

### Server

| Variable | Default | Meaning |
|---|---|---|
| `SERVER_NAME` | `Valheim` | Name shown in the browser. Must not contain the password. |
| `SERVER_WORLD` | `Dedicated` | World name. Created if it does not exist. |
| `SERVER_PASSWORD` | *(empty)* | At least 5 characters. Empty = no password. |
| `SERVER_PORT` | `2456` | Game port. The server also uses `+1` and `+2`. |
| `SERVER_PUBLIC` | `0` | `0` unlisted (join by IP), `1` listed in the community browser. |
| `SERVER_SAVE_INTERVAL` | `1800` | Seconds between world saves. |
| `SERVER_BACKUPS` | `4` | Generations of in-game backups to keep. |
| `SERVER_BACKUP_SHORT` | `7200` | Seconds before the first backup. |
| `SERVER_BACKUP_LONG` | `43200` | Seconds between later backups. |
| `SERVER_INSTANCE_ID` | *(empty)* | Distinguishes several servers sharing one Steam account. |
| `SERVER_SIMULATION_DISTANCE` | *(empty)* | Simulated radius in game units. Raising it costs CPU. |
| `SERVER_CONSOLE` | `false` | Adds `-console`. |
| `SERVER_EXTRA_ARGS` | *(empty)* | Anything not modelled here, appended verbatim. |

### Difficulty: presets and modifiers

> [!CAUTION]
> `SERVER_PRESET` and `SERVER_MODIFIERS` **overwrite** the settings stored in the
> world — including the ones you set in game with `setworldmodifier`. They are
> empty by default, and that is deliberate. Set them only if you want the
> container, not the world, to be the source of truth.

| Variable | Example | Meaning |
|---|---|---|
| `SERVER_PRESET` | `hard` | `casual`, `easy`, `normal`, `hard`, `hardcore`, `immersive`, `hammer` |
| `SERVER_MODIFIERS` | `combat=hard,raids=none` | Comma-separated `key=value` pairs |
| `SERVER_SET_KEYS` | `nomap,playerevents` | Comma-separated global keys |
| `SERVER_RESET_MODIFIERS` | `false` | `true` resets every modifier to default |

Modifier keys: `combat` (`veryeasy`…`veryhard`), `deathpenalty`
(`casual`…`hardcore`), `resources` (`muchless`…`most`), `raids`
(`none`…`muchmore`), `portals` (`casual`, `hard`, `veryhard`).

### Updates

| Variable | Default | Meaning |
|---|---|---|
| `UPDATE_ON_START` | `true` | SteamCMD checks for a new server version on every start. |
| `STEAM_VALIDATE` | `true` | Re-verify the 2 GB of game files on every start. |

With `UPDATE_ON_START=true` the server is always on the latest version, but it
only updates **when the container restarts** — after a Valheim patch, restart it
or clients will refuse to connect with a version mismatch.

`STEAM_VALIDATE=true` is what repairs a damaged install; it also adds a minute or
two to every start. Turning it off once the install is known good is safe.

### Emulator

No `BOX64_*` variable is set in the image, so Box64's own defaults apply — and
those are the fastest ones. On first start the container writes a fully
commented [`config/box64.rc`](box64.rc.example) into `/data`; edit it and restart
to change a setting. Precedence is:

```
environment variable  >  /data/config/box64.rc  >  Box64 defaults
```

The log prints, at every start, which value came from where.

If the server crashes or the world becomes inconsistent, climb this ladder one
rung at a time — each rung costs performance. This matters most on ARMv8.0-A CPUs
without the LSE atomic instructions, such as the Cortex-A72:

1. `BOX64_DYNAREC_STRONGMEM=1`, then `2`, then `3`
2. `BOX64_DYNAREC_BIGBLOCK=1`, then `0`
3. `BOX64_DYNAREC_CALLRET=0`
4. `BOX64_DYNAREC_SAFEFLAGS=2`

## Networking

Valheim uses **UDP 2456-2458 only**. TCP forwarding is never needed.

To play from outside your network, forward those three UDP ports to the host and
test from a connection outside your own network (mobile data, for instance).

An unlisted server (`SERVER_PUBLIC=0`) does not answer Steam `A2S_INFO` queries,
so third-party server-status tools will not see it. Only a real connection from
the game proves anything.

## Crossplay

> [!CAUTION]
> **Crossplay is not supported by this image.** It is disabled by default, it
> does not work, and there is no plan to make it work here.

Crossplay is not an extra option on top of the Steam server: it switches the
backend from **Steam** to **PlayFab**. Players would then join with a *join code*
instead of an IP address, so it changes how everyone connects.

Under Box64 it does not come up. Two things stand in the way:

1. **`libparty.so` never loads.** PlayFab Party is an x86_64 plugin that links
   against libogg, and Box64 0.3.4 has no native wrapper for it. Shipping the
   ARM64 `libogg0`, or an x86_64 `libogg.so.0` on `BOX64_LD_LIBRARY_PATH`, was
   tried here — the `ogg_*` symbols still fail to relocate either way.
2. **PlayFab registration is reported broken.** From **box64 0.4.0** onwards the
   registration never completes; see
   [ptitSeb/box64#4403](https://github.com/ptitSeb/box64/issues/4403).

`SERVER_CROSSPLAY=true` exists and adds `-crossplay`, with a warning in the log.
The server will start, but expect the join code never to be issued. It is there
for people who want to experiment, not as a supported feature.

If you get crossplay working under Box64, an issue or a PR would be very welcome.

## Logs

The server writes to the container log and to
`/data/logs/valheim_DD-MM-YYYY.log`. Set `TZ` if you want those timestamps and
filenames in your own timezone rather than UTC.

```bash
docker compose logs -f
```

Several messages are **normal and harmless**:

| Message | Why |
|---|---|
| `ogg_*` symbol errors, `Failed to open plugin: libparty.so`, `DllNotFoundException: libParty.so` | PlayFab Party, the crossplay voice and relay plugin, failing to load. Expected, and harmless: crossplay is [not supported](#crossplay). |
| `AsyncResourceUpload failed`, `Failed to play intro cinematic`, `The referenced script on this Behaviour is missing` | The server starts a Unity engine with no GPU. |
| `setlocale('en_US.UTF-8') failed` | SteamCMD message; the image only ships the `C.UTF-8` locale. |

## Administration

Admins, permitted players and banned players are plain text files in `/data`,
one 64-bit SteamID per line: `adminlist.txt`, `permittedlist.txt`, `bannedlist.txt`.
They are created empty on first start, and the server rereads them without a
restart.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Log: `valheim_server.x86_64 is missing` | The download never happened. Check `UPDATE_ON_START=true` and internet access. |
| The world is empty after a transfer | The `_main.*` files are missing — see the warning under [Volumes](#volumes). |
| Server crashes, or the world turns inconsistent | Climb the Box64 compatibility ladder under [Emulator](#emulator). |
| Clients report a version mismatch after a patch | The server only updates on restart: `docker compose restart`. |
| Players cannot join from outside | Test on the LAN first with `<host-ip>:2456`, then check the UDP port forwarding. |
| The download stalls or the start never finishes | Disk full: `df -h`. |
| `port 2456 already allocated` | Another Valheim server is still running. |

## Credits

- [ptitSeb/box64](https://github.com/ptitSeb/box64) — the emulator that makes
  this possible.
- Iron Gate Studio — Valheim and its dedicated server. This project ships no
  game files; SteamCMD downloads them at runtime.

## License

[MIT](LICENSE). This applies to the packaging in this repository only, not to
Valheim itself.
