# awg-quick-magisk

Magisk module for AmneziaWG (a WireGuard fork with traffic obfuscation) on Android:
brings up `awg0` via the userspace backend `amneziawg-go` and `awg-quick`,
and manages policy routing and DNS without a root VPN app.

## ⚠️ Important: binaries must be built yourself

Prebuilt binaries for `awg`, `awg-quick`, and `amneziawg-go` are **not included** in this
archive — building them requires the Android NDK (to link against bionic libc), which
was unavailable in the environment where this template was prepared (no access to
`dl.google.com`). The full build pipeline is already written and automated —
you only need to run `build/build.sh` once on your machine (Linux/macOS/WSL
with internet) or in CI (e.g. GitHub Actions).

### Build

Requirements: `git`, `curl`, `unzip`, `go >= 1.21`, ~10 GB free space
(the Android NDK unpacks to several GB).

```bash
cd build
./build.sh                # builds for arm64, arm, x86_64, x86
./build.sh arm64           # or only arm64-v8a (99% of modern phones)
```

The script will:

1. Download Android NDK r27c.
2. Clone [amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools)
   and [amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go).
3. Build `awg` — the CLI utility (in the amneziawg-tools Makefile the target is
   named `wg`; it is renamed to `awg` on copy) — dynamically linked for the
   Android ABI with the NDK compiler. Static linking is not used: the device
   already provides system `libc.so`.
4. Compile the **native** `awg-quick` from `wg-quick/android.c` — this is not
   a bash script, but a ready C implementation for Android from the
   amneziawg-tools repository itself. It: brings up the interface via
   `amneziawg-go` (when it detects AmneziaWG parameters `Jc`/`Jmin`/`H1`–`H4` in
   the config), sets up routes and iptables rules, and applies DNS via
   `android.net.IDnsResolver` over Binder (`dlopen("libbinder_ndk.so")` at
   runtime — no separate link against libbinder is needed).
5. Cross-compile `amneziawg-go` (`GOOS=android`, cgo enabled,
   NDK compiler).
6. Place everything under `bin/arch/<abi>/` and package the ready
   `build/dist/awg-quick-magisk.zip`.

### Why `awg-supervisor` is so simple

Originally in this template, `awg-supervisor` itself started `amneziawg-go`,
waited for the UAPI socket, and manually configured routes/DNS. After checking
against the real amneziawg-tools sources, it turned out that all of this
functionality is already implemented inside the compiled `awg-quick`
(`wg-quick/android.c`). Therefore `awg-supervisor` is now a thin wrapper:
`awg-quick up/down <config>` plus waiting for network and logging.
`scripts/routing.sh` and `scripts/dns.sh` remain as **optional** extra hooks
(e.g. custom LAN exclusions) — enabled by the `AWG_EXTRA_HOOKS=1` variable in
`service.sh`; they are off by default to avoid duplicating or conflicting with
what `awg-quick` already does.

On module install, `customize.sh` detects the device ABI and copies the
required binaries from `bin/arch/<abi>/` into `bin/`.

## Installation on device

1. Edit `config/wg0.conf` — fill in your `PrivateKey`, the server `PublicKey`,
   `Endpoint`, and obfuscation parameters (`Jc`, `Jmin`, `Jmax`, `H1`–`H4`).
2. Install `build/dist/awg-quick-magisk.zip` via the Magisk App:
   Modules → Install from storage.
3. Reboot the device — `service.sh` will bring the tunnel up automatically
   after `sys.boot_completed=1`.
4. The "Action" button in the Magisk App toggles VPN on/off (`action.sh`).

## Structure

```
awg-magisk/
├── module.prop          # module metadata
├── customize.sh         # ABI selection and permissions on install
├── service.sh           # auto-start after boot
├── action.sh            # VPN toggle via Action button
├── uninstall.sh         # clean up routes/DNS on uninstall
├── bin/
│   ├── awg              # management CLI (wg-compatible), from amneziawg-tools
│   ├── awg-quick        # Android-adapted wg-quick
│   ├── amneziawg-go     # userspace WireGuard/AmneziaWG backend
│   └── awg-supervisor   # orchestrator: start backend, up/down, routing, dns
├── config/wg0.conf      # your config (template)
├── scripts/
│   ├── routing.sh       # policy routing (ip rule/ip route, fwmark)
│   ├── dns.sh           # DNS via `ndc resolver` (Android netd)
│   └── network.sh       # wait_for_network / MTU auto-detection
├── logs/                # service/action/supervisor/backend logs
└── build/
    ├── build.sh         # cross-compile with NDK (run manually)
    └── package.sh       # final zip packaging
```

## Logs

See `logs/service.log`, `logs/supervisor.log`, `logs/amneziawg-go.log`,
`logs/routing.log`, `logs/dns.log` directly in the module directory
(`/data/adb/modules/awg_quick_magisk/logs/`) via a root file manager
or `adb shell`.

## Known limitations

- **`am broadcast` to a non-existent app**: at the end of `up`/`down`,
  `awg-quick` (`wg-quick/android.c`, function `broadcast_change()`) sends
  `am broadcast` to the package `org.amnezia.awg` (the official AmneziaWG
  app) to refresh its UI. If the environment variable `CALLING_PACKAGE` is
  not set or does not match this package, the broadcast goes to a non-existent
  receiver, fails with an error, and the whole `up` is rolled back. All our
  scripts (`service.sh`, `action.sh`, `awg-supervisor`, `uninstall.sh`) already
  set `CALLING_PACKAGE=org.amnezia.awg` so the code skips the broadcast
  entirely — no need to touch this unless you changed `AWG_PACKAGE_NAME` at
  build time.
- **UAPI socket and read-only `/var`**: by default both the C utility `awg`
  (`RUNSTATEDIR`, usually `/var/run`) and the Go daemon `amneziawg-go`
  (`ipc.socketDirectory`, usually `/var/run/amneziawg`) look for the socket under
  `/var`, which does not exist on Android (`/` is mounted read-only).
  `build/build.sh` overrides both paths to `run/` inside the module directory
  via `make RUNSTATEDIR=...` and `-ldflags -X .../ipc.socketDirectory=...`
  respectively — they must match, otherwise `awg` will fail to connect to the
  daemon socket with an error like `Cannot find device`.
- `scripts/dns.sh` uses `ndc resolver`, which requires root and the presence of
  `netd` (standard on all Android). On custom ROMs with a different DNS stack,
  a patch may be needed.
- `routing.sh` uses fixed `ip rule` priorities (51820–51822) — if you already
  have another VPN module with the same priorities, change `AWG_TABLE`/priorities
  via environment variables in `service.sh`.
- Minimum `minSdkVersion` the binaries are built for is API 24
  (Android 7.0), set in `build/build.sh` (`API_LEVEL`).
