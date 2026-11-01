# Readipa

Native iOS file manager scoped strictly to **Application Containers**
(`/var/mobile/Containers/Data/Application`) and **App Groups**
(`/var/mobile/Containers/Shared/AppGroup`).

Built on top of
[`airlift`](https://github.com/0xjohnnydev/airlift) (AirTraffic sandbox-escape
primitives) and [`AirCard-iOS`](https://github.com/Mak5er/AirCard-iOS)
(RPPairing host + tunnel + FFI bridge).

## Capabilities (real, not simulated)

- Pair the device with itself via an on-device RPPairing host.
- Enumerate installed apps (InstallationProxy) and resolve each app's Data
  container + App Group containers.
- Browse, read, write, rename, delete, mkdir inside a container.
- Two engines:
  - **HouseArrest** (dev-signed / sideloaded apps): fast, non-destructive AFC
    rooted at the container.
  - **AirLift bridge** (universal fallback, incl. App Groups): creates a
    symlink in `/var/mobile/Media` pointing at the container root via the
    AirTraffic escape; probes AFC traversal and falls back to move-based
    operations when traversal is denied.
- All paths are validated in Rust to stay inside the two allowed roots.

## Build

The IPA is built on GitHub Actions (`macos-15` runner):

```sh
# locally (on a Mac with Xcode)
./build-ios.sh       # builds Rust core + AirliftFFI.xcframework
xcodegen generate
./build-ipa.sh       # builds unsigned .ipa
```

## Requirements

- A loopback VPN (LocalDevVPN / StosVPN / SideStore WireGuard) providing the
  RSD tunnel at `10.7.0.1:49152` (or configured IP).
- iOS 27.0 (AirLift's proven build) for the AirLift engine; HouseArrest works
  on broader versions.

## License

MIT. See `LICENSE`. Includes code derived from `airlift` (© 2026 Johnny Franks)
and `AirCard-iOS` (© 2026 Maksym Reva), both MIT.
