# Bile

A Filza-style file manager for iOS — plain, honest, and escape-free.

Bile browses your iPhone's filesystem directly from `/`, lists every installed
app through LaunchServices, and keeps a clean activity log. It contains **no
sandbox escape and no exploit code**: whatever iOS refuses to open, Bile
labels "Permission denied" instead of pretending. When a real sandbox escape
ships, it slots into one small layer (`LocalFS`) and every path above lights up.

## Download

Grab the latest unsigned IPA from
[Releases](https://github.com/d3vin4/Readipa/releases) and install it with
your preferred sideloading tool (TrollStore, AltStore, Sideloadly, …).

## Tabs

### Files
- Browse anywhere on disk, starting at `/`
- Breadcrumb bar — tap any segment to jump
- Back / forward / up with full history
- Go-to-path sheet with recents
- Favorites (bookmark any folder)
- Hidden (dot) files toggle
- Sort by name / size / date, ascending or descending
- List and grid view
- Pull to refresh
- Filter in-folder + recursive search
- Multi-select with batch share / copy / cut / compress / delete
- New folder, new file, new symlink
- Rename, duplicate
- Copy / cut / paste with conflict-safe naming
- Recursive delete with confirmation (symlinks are never followed)
- Info sheet: size, dates, owner, **chmod editor**, symlink target
- Calculate folder size (recursive, off the main thread)
- Text editor with save
- QuickLook preview for anything iOS can render
- **Compress to ZIP** and **Extract ZIP** (STORE + DEFLATE via Apple's
  Compression framework, symlink- and traversal-safe extraction)

### Apps
- Every installed app through LaunchServices (bundle id, version, type)
- Real icons read from each bundle
- Data-container paths shown; containers open into Files when iOS allows it
  and are clearly marked locked when it does not

### Logs
- Timestamped activity log with a bounded buffer
- Filter, share, clear
- **Credits** — the author's GitHub profile and avatar

## Build

The IPA is built automatically on every push to `main`
(GitHub Actions, macOS 26 / Xcode 26, XcodeGen for project generation).
To build locally:

```bash
brew install xcodegen
xcodegen generate
./build-ipa.sh Release
# → build/Bile.ipa
```

## Credits

Made by [**@d3vin4**](https://github.com/d3vin4)
<img src="https://github.com/d3vin4.png" width="24" alt="d3vin4" style="border-radius: 12px" />
— find the project and every release on
[GitHub](https://github.com/d3vin4/Readipa).

## License

MIT — see [LICENSE](LICENSE).
