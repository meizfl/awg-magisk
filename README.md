# awg-quick-magisk

A Magisk module that runs [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-tools)
(a WireGuard fork with traffic obfuscation) directly on rooted Android — no
companion app, no VpnService, no Termux required.

It brings up `wg0` through the `amneziawg-go` userspace backend and the
**native** Android `awg-quick` (compiled straight from
`wg-quick/android.c` in the upstream repo — the same code path the official
AmneziaWG Android app uses), which configures routing, iptables and DNS
(via `android.net.IDnsResolver` over Binder) on its own.

## Why this exists

The official AmneziaWG Android app wraps this same logic behind
`VpnService` and a GUI. This module runs it as a systemless Magisk service
instead — useful for headless setups, routers-in-a-phone, CI devices, or
anyone who'd rather manage a `wg0.conf` with a text editor than tap through
an app.

## ⚠️ Binaries are not included — build them yourself

`awg`, `awg-quick` and `amneziawg-go` are **not** shipped in this repo.
Building them requires the Android NDK (for bionic libc linking), so the
build step is a separate, one-time thing you run yourself:

```bash
cd build

./build-abi21.sh
# Android 5.0+ (API 21+)
# arm64-v8a, armeabi-v7a, x86_64, x86

./build-abi18.sh
# Android 4.3–4.4.4 (API 18–19)
# armeabi-v7a, x86

./build-abi21.sh arm64
# или: ./build-abi21.sh arm64-v8a
# arm64-v8a only - for most modern ARM64 devices
```

Requirements: `git`, `curl`, `unzip`, `go >= 1.21`, ~10 GB free disk space
(the Android NDK unpacks to a few GB).

The script:
1. Downloads Android NDK r27c.
2. Clones [amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools)
   and [amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go).
3. Builds `awg` — the CLI tool (the Makefile target is called `wg`, only
   renamed to `awg` on `make install`) — dynamically linked against the
   Android ABI via the NDK toolchain. No static linking: the device already
   ships a system `libc.so`.
4. Compiles the **native** `awg-quick` from `wg-quick/android.c` — not a
   bash script, a real C implementation shipped by amneziawg-tools
   specifically for Android. It starts `amneziawg-go` itself (when it
   detects AmneziaWG parameters like Jc/Jmin/H1-H4 in the config),
   configures routes and iptables rules, and applies DNS through
   `android.net.IDnsResolver` over Binder (`dlopen("libbinder_ndk.so")` at
   runtime — no explicit link-time dependency on libbinder).
5. Cross-compiles `amneziawg-go` (`GOOS=android`, cgo enabled, NDK
   compiler).
6. Lays everything out under `bin/arch/<abi>/` and packages the final
   `build/dist/awg-quick-magisk.zip`.

### Older devices (API < 24, Android 5.0–6.0)

`build.sh` defaults to `API_LEVEL=21` — the hard floor for any NDK r23+
(there are no headers/libs below it). Nothing extra to do for that; to
target something narrower instead:

```bash
API_LEVEL=24 ./build.sh arm64
```

Verified in the source to *not* be a blocker on API 21–23:
- `genkey.c`'s `getentropy()` call is gated behind `__GLIBC__`/`__APPLE__`
  and is never compiled on Android — it always falls through to a raw
  `getrandom` syscall, which works on any kernel regardless of API level.
- `libbinder_ndk.so` is loaded via `dlopen()` with a `binder_available`
  check; if it's missing on an old device, DNS-via-Binder is silently
  skipped instead of crashing. Routing and iptables rules are unaffected.

Not independently verified on real Android 5/6 hardware: the exact `ndc`
command syntax `android.c` uses may differ on very old `netd` versions. If
routing doesn't apply on such a device (interface comes up but traffic
doesn't flow), check `logs/supervisor.log` for `[#] ndc ...` errors.

### Why `awg-supervisor` is so thin

`awg-supervisor` is a minimal wrapper: `awg-quick up/down <config>` plus a
network-readiness wait and logging. It does **not** start `amneziawg-go` or
touch routing/DNS itself — the compiled `awg-quick` (`android.c`) already
does all of that internally. `scripts/routing.sh` and `scripts/dns.sh` are
optional extra hooks (e.g. your own LAN-bypass rules), enabled only via
`AWG_EXTRA_HOOKS=1` in `service.sh`, to avoid duplicating or conflicting
with what `awg-quick` already handles.

### bionic is missing `strchrnul()`

`wg-quick/android.c` calls the GNU `strchrnul()` extension in its per-app
UID selection code, even though bionic never provides it — it's a
glibc/BSD-only function, unrelated to `_GNU_SOURCE` (notably, `config.c` in
the same repo explicitly avoids it with the comment "This is what
strchrnul is for, but that isn't portable" — looks like an oversight
specific to `android.c`). `build.sh` patches in a portable `static inline`
replacement right after the `ARRAY_SIZE` macro before compiling
(idempotent, keyed off a marker comment, so reruns and future repo updates
that don't touch that region stay safe).

### The `CALLING_PACKAGE` workaround

`awg-quick` (`android.c`) sends an `am broadcast` to the official
`org.amnezia.awg` app at the end of `up`/`down` to refresh its UI. Since
this module doesn't use that app, the broadcast would hit a non-existent
package, fail, and roll back the whole `up`. All entry points
(`service.sh`, `action.sh`, `awg-supervisor`, `uninstall.sh`) export
`CALLING_PACKAGE=org.amnezia.awg`, which matches `AWG_PACKAGE_NAME` at
compile time and makes `awg-quick` skip the broadcast entirely
(`broadcast_change()` in the source).

### The UAPI socket and read-only `/var`

By default both the C `awg` CLI (`RUNSTATEDIR`, normally `/var/run`) and
the Go daemon `amneziawg-go` (`ipc.socketDirectory`, normally
`/var/run/amneziawg`) look for the UAPI socket under `/var`, which doesn't
exist on Android (`/` is mounted read-only). `build/build.sh` redirects
both paths to `run/` inside the module directory via `make RUNSTATEDIR=...`
and `-ldflags -X .../ipc.socketDirectory=...` respectively — they have to
match, or `awg` won't be able to reach the daemon's socket.

## Installing on a device

1. Edit `config/wg0.conf` — fill in your `PrivateKey`, the server's
   `PublicKey`, `Endpoint`, and the obfuscation parameters (`Jc`, `Jmin`,
   `Jmax`, `H1`–`H4`).
2. Install `build/dist/awg-quick-magisk.zip` via the Magisk App:
   Modules → Install from storage.
3. Reboot — `service.sh` brings the tunnel up automatically once
   `sys.boot_completed=1`.
4. The "Action" button in the Magisk App toggles the VPN on/off
   (`action.sh`).

## Layout

```
awg-magisk/
├── module.prop          # module metadata
├── customize.sh          # ABI detection + permissions at install time
├── service.sh              # autostart after boot
├── action.sh                 # toggle VPN via the Action button
├── uninstall.sh                # tears down routes/DNS on removal
├── bin/
│   ├── awg                       # control CLI (wg-compatible), from amneziawg-tools
│   ├── awg-quick                    # native Android wg-quick (compiled from android.c)
│   ├── amneziawg-go                    # userspace WireGuard/AmneziaWG backend
│   └── awg-supervisor                     # thin wrapper: up/down, network wait, logging
├── config/wg0.conf                          # your config (template)
├── scripts/
│   ├── routing.sh                              # optional extra policy routing (ip rule/fwmark)
│   ├── dns.sh                                     # optional ndc-based DNS fallback
│   └── network.sh                                    # wait_for_network / MTU detection
├── logs/                                                # service/action/supervisor logs
└── build/
    ├── build.sh                                            # NDK cross-compilation (run manually)
    └── package.sh                                             # final zip packaging
```

## Logs

Check `logs/service.log`, `logs/supervisor.log`, `logs/routing.log`,
`logs/dns.log` directly inside the module directory
(`/data/adb/modules/awg_quick_magisk/logs/`) via a root file manager or
`adb shell`.

## Known limitations

- `scripts/dns.sh` uses `ndc resolver`, which requires root and `netd`
  (standard on all Android builds). Custom ROMs with a different DNS stack
  may need adjustments — but note this script is optional; `awg-quick`
  already configures DNS on its own via Binder.
- `scripts/routing.sh` uses fixed `ip rule` priorities (51820–51822) — if
  you already have another VPN module using the same priorities, change
  `AWG_TABLE`/priorities via environment variables in `service.sh`.
- Minimum `API_LEVEL` the binaries are built for defaults to 21 (Android
  5.0), configurable in `build/build.sh`.

## Disclaimer

This project isn't affiliated with the Amnezia VPN team. It just builds
and wires together their open-source `amneziawg-tools` and `amneziawg-go`
components into a standalone Magisk module.
