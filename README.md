# AmneizaWG Magisk

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

./build-abi16.sh
# Android 4.1–4.2 (API 16–17)
# armeabi-v7a, x86

./build-abi21.sh arm64
# или: ./build-abi21.sh arm64-v8a
# arm64-v8a only — 64-bit ARM devices(99% modern smartphones/tablets)
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
   zip under `build/dist/` (`awg-quick-magisk-abi21+.zip` or
   `awg-quick-magisk-abi16-17.zip`, depending on which script you ran).

### Older devices (API < 21)

`build-abi21.sh` targets API 21 (Android 5.0), the range NDK r23c is
officially documented for. `build-abi16.sh` targets API 16–17 (Android
4.1–4.2) instead — empirically, r23c's clang still accepts and
compiles/links these lower target-triple levels as long as no libc symbol
actually missing at that level gets referenced (treat this as
unofficial/best-effort, verified only against r23c).

Verified in the source to *not* be a blocker on these older API levels:
- `genkey.c`'s `getentropy()` call is gated behind `__GLIBC__`/`__APPLE__`
  and is never compiled on Android — it always falls through to a raw
  `getrandom` syscall, which works on any kernel regardless of API level.
- `libbinder_ndk.so` is loaded via `dlopen()` with a `binder_available`
  check; if it's missing on an old device, DNS-via-Binder is silently
  skipped instead of crashing. Routing and iptables rules are unaffected.

Not independently verified on real old hardware: the exact `ndc` command
syntax `android.c` uses may differ on very old `netd` versions. If routing
doesn't apply on such a device (interface comes up but traffic doesn't
flow), check `logs/supervisor.log` for `[#] ndc ...` errors.

### Why `awg-supervisor` is so thin

`awg-supervisor` is a minimal wrapper: `awg-quick up/down <config>` plus a
network-readiness wait and logging. It does **not** start `amneziawg-go` or
touch routing/DNS itself — the compiled `awg-quick` (`android.c`) already
does all of that internally. `scripts/routing.sh` and `scripts/dns.sh` are
optional extra hooks (e.g. your own LAN-bypass rules), enabled only via
`AWG_EXTRA_HOOKS=1` in `service.sh`, to avoid duplicating or conflicting
with what `awg-quick` already handles.

### bionic is missing `getline()` below API 18

`ipc-uapi.h`, `setconf.c` and `wg-quick/android.c` all call `getline()`.
bionic only gained it in API level 18 (Jelly Bean MR2) — targeting anything
lower (like `build-abi16.sh`'s API 16–17) compiles with just an "implicit
declaration" warning but then fails to **link** with `undefined symbol:
getline`, since the symbol genuinely doesn't exist in that API level's
libc. `build-abi16.sh` force-includes a portable `static inline getline()`
shim via `-include` — it is only ever applied there, never in
`build-abi21.sh`, since bionic already exports the real symbol at API 18+
and the shim would clash with it.

### bionic is missing `strchrnul()`

`wg-quick/android.c` calls the GNU `strchrnul()` extension in its per-app
UID selection code, even though bionic never provides it — it's a
glibc/BSD-only function, unrelated to `_GNU_SOURCE` (notably, `config.c` in
the same repo explicitly avoids it with the comment "This is what
strchrnul is for, but that isn't portable" — looks like an oversight
specific to `android.c`). Both `build-abi16.sh` and `build-abi21.sh` patch
in a portable `static inline`
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
exist on Android (`/` is mounted read-only). `build-abi16.sh` and
`build-abi21.sh` redirect both paths to `run/` inside the module directory
via `make RUNSTATEDIR=...` and `-ldflags -X .../ipc.socketDirectory=...`
respectively — they have to match, or `awg` won't be able to reach the
daemon's socket.

## Installing on a device

1. Edit `config/wg0.conf` — fill in your `PrivateKey`, the server's
   `PublicKey`, `Endpoint`, and the obfuscation parameters (`Jc`, `Jmin`,
   `Jmax`, `H1`–`H4`).
2. Install the resulting zip from `build/dist/` via the Magisk App:
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
    ├── build-abi16.sh                                      # NDK cross-compile, API 16-17 (run manually)
    ├── build-abi21.sh                                          # NDK cross-compile, API 21+ (run manually)
    ├── package-abi16.sh                                          # zip packaging for the abi16 build
    └── package-abi21.sh                                              # zip packaging for the abi21 build
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
- Minimum `API_LEVEL` defaults to 21 in `build-abi21.sh` and to 16 in
  `build-abi16.sh` — both are overridable via the `API_LEVEL` env var.

## Disclaimer

This project isn't affiliated with the Amnezia VPN team. It just builds
and wires together their open-source `amneziawg-tools` and `amneziawg-go`
components into a standalone Magisk module.
