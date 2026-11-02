# Readipa

Native iOS file manager scoped strictly to **Application Containers**
(`/var/mobile/Containers/Data/Application`) and **App Groups**
(`/var/mobile/Containers/Shared/AppGroup`).

Built on [`airlift`](https://github.com/0xjohnnydev/airlift) (AirTraffic
sandbox-escape primitives) and
[`AirCard-iOS`](https://github.com/Mak5er/AirCard-iOS) (RPPairing host +
loopback tunnel + FFI bridge).

Built with **Xcode 26 / iOS 26 SDK** and adopts **Liquid Glass**; it still runs
on iOS 18+ (glass is availability-gated).

## Features

- **Self-pairing** with an on-device RPPairing host. The 6-digit PIN is shown in
  the app *and* as a **Live Activity** (Lock Screen + Dynamic Island).
- **Pairing survives relaunch and reinstall**: credentials live in Documents and
  are mirrored into the **Keychain**, restored automatically on launch.
- **Tunnel diagnostics**: `Test tunnel` dials RSD `49152` and lockdownd `62078`
  on every candidate address, so you know whether the loopback VPN really works.
- **Catalog**: every installed app with its Data container and App Groups.
- **File manager**: browse, preview, filter, sort, import, rename/move, delete,
  share a single file, and **export a whole container to a ZIP** → *Save to
  Files*.
- **Two access engines**:
  - **HouseArrest** (dev-signed / sideloaded apps) — AFC rooted at the
    container, fast and non-destructive.
  - **AirLift bridge** (App Groups and everything else) — a symlink in
    `/var/mobile/Media` pointing at the container.
- **Recovery**: `Setup › Recovery` lists anything Readipa left in Media and can
  move it back. Nothing is ever deleted automatically.

## Data-safety guarantees

| Guarantee | How |
|---|---|
| Nothing in Media is deleted unless this app created it in the same operation | staging names are namespaced and tracked per call |
| Symlinks are never followed by recursive deletes | `remove_tree_safe` walks post-order and removes links as single entries |
| Reads never relocate data when the container allows direct reads | `probe_bridge` tests listing and reading **separately** (`bridge_readonly`) |
| Every AirTraffic move is verified | poll for *destination present* / *source gone*; failure restores the original |
| The Books sync state is never destroyed | `Books/Sync/Books.plist` is snapshotted and restored around every move |
| A folder is never replaced by a file | the moved-aside entry is inspected first and put straight back |
| Renames never overwrite | an existing destination is refused instead of deleted |
| Risky directory relocation is opt-in | `Setup › AirLift move mode`, default **off** |
| Paths cannot escape the scope | strict Rust validation (root boundary, no `..`/`.`) |
| Big files cannot OOM mid-operation | chunked 256–512 KB streaming everywhere |

## Layout

```
ios-app/            SwiftUI app (Liquid Glass, Live Activity owner, Keychain)
PairingLiveActivity/  WidgetKit extension that renders the PIN
rust-core/          Rust FFI: containers.rs, fsengine.rs, export.rs, exploit.rs
  vendor/idevice    pinned idevice + idevice-ffi
.github/workflows/  macos-26 → Rust → xcodegen → unsigned IPA → Release
```

## Build

```sh
./build-ios.sh        # rust-core → AirliftFFI.xcframework
xcodegen generate
./build-ipa.sh        # unsigned Readipa.ipa
```

CI does the same on `macos-26` (Xcode 26.6 / iOS 26 SDK) and publishes the IPA
as a release asset.

## Requirements

- A loopback VPN providing the RSD tunnel at `10.7.0.1:49152`
  (LocalDevVPN, StosVPN, SideStore WireGuard) — use **Test tunnel** to confirm.
- iOS 27.0 (AirLift's proven build) for the AirLift engine; HouseArrest works on
  broader versions.
- Live Activities enabled in Settings › Readipa for the Lock-Screen PIN.

## Notes

- The IPA is **unsigned**; sign it yourself or install with
  TrollStore / SideStore / AltStore. If you re-sign, the provisioning profile
  must cover **both** `com.d3vin4.readipa` and
  `com.d3vin4.readipa.pairingliveactivity` or the Live Activity extension is
  dropped.
- In AirLift move mode a folder is relocated for the duration of an operation.
  It is always moved back and verified; if that ever fails, the app names the
  exact recovery path.

## License

MIT. Includes code derived from `airlift` (© 2026 Johnny Franks) and
`AirCard-iOS` (© 2026 Maksym Reva), both MIT.
