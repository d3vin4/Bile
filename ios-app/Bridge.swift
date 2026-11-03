import Foundation
import AirliftFFI

private let logCallback: ALLogCallback = { _, msg in
    if let msg = msg {
        let line = String(cString: msg)
        DispatchQueue.main.async { AppState.shared.logLine(line) }
    }
}

enum RustBridge {
    static func free(_ p: UnsafeMutablePointer<CChar>?) {
        if let p = p { al_string_free(p) }
    }

    static func catalog(pairingPath: String) throws -> (apps: [[String: Any]], groups: [[String: Any]]) {
        var outJson: UnsafeMutablePointer<CChar>?
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            al_container_catalog(pp, logCallback, nil, &outJson, &outErr)
        }
        defer { free(outJson); free(outErr) }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "catalog failed"
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let json = outJson.map({ String(cString: $0) }),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Rust", code: -1, userInfo: [NSLocalizedDescriptionKey: "bad catalog json"])
        }
        let apps = (obj["apps"] as? [[String: Any]]) ?? []
        let groups = (obj["appGroups"] as? [[String: Any]]) ?? []
        return (apps, groups)
    }

    static func setAllowRiskyMoves(_ enabled: Bool) {
        al_set_allow_risky_moves(enabled ? 1 : 0)
    }

    static func mediaLeftovers(pairingPath: String) throws -> [[String: Any]] {
        var outJson: UnsafeMutablePointer<CChar>?
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            al_media_leftovers(pp, logCallback, nil, &outJson, &outErr)
        }
        defer { free(outJson); free(outErr) }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "scan failed"
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let json = outJson.map({ String(cString: $0) }),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = obj["entries"] as? [[String: Any]] else {
            return []
        }
        return entries
    }

    static func recoverLeftover(pairingPath: String, leftoverName: String, containerPath: String, relPath: String, bridge: String) throws {
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(leftoverName) { ln in
                withCString(containerPath) { cp in
                    withCString(relPath) { rp in
                        withCString(bridge) { bp in
                            al_recover_leftover(pp, ln, cp, rp, bp, logCallback, nil, &outErr)
                        }
                    }
                }
            }
        }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "recovery failed"
            free(outErr)
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        free(outErr)
    }

    static func backupApp(
        pairingPath: String,
        bundleId: String,
        destDir: String,
        timeoutSecs: UInt32 = 600
    ) throws -> [String: Any] {
        var outJson: UnsafeMutablePointer<CChar>?
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bp in
                withCString(destDir) { dp in
                    al_backup_app(pp, bp, dp, timeoutSecs, logCallback, nil, &outJson, &outErr)
                }
            }
        }
        defer { free(outJson); free(outErr) }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "backup failed"
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let json = outJson.map({ String(cString: $0) }),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    static func zipLocalDir(sourceDir: String, destZipPath: String) throws {
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(sourceDir) { sp in
            withCString(destZipPath) { dp in
                al_zip_local_dir(sp, dp, &outErr)
            }
        }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "zip failed"
            free(outErr)
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        free(outErr)
    }

    static func enableJIT(pairingPath: String, bundleId: String) throws -> [String: Any] {
        var outJson: UnsafeMutablePointer<CChar>?
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bp in
                al_jit_enable(pp, bp, logCallback, nil, &outJson, &outErr)
            }
        }
        defer { free(outJson); free(outErr) }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "JIT enable failed"
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let json = outJson.map({ String(cString: $0) }),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    static func appIcon(pairingPath: String, bundleId: String, destLocalPath: String) throws {
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bp in
                withCString(destLocalPath) { dp in
                    al_app_icon(pp, bp, dp, nil, nil, &outErr)
                }
            }
        }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "icon fetch failed"
            free(outErr)
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        free(outErr)
    }

    static func diagnoseContainer(
        pairingPath: String,
        bundleId: String,
        containerPath: String,
        bridge: String
    ) throws -> [String: Any] {
        var outJson: UnsafeMutablePointer<CChar>?
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(bridge) { bp in
                        al_diagnose_container(pp, bi, cp, bp, logCallback, nil, &outJson, &outErr)
                    }
                }
            }
        }
        defer { free(outJson); free(outErr) }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "diagnosis failed"
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let json = outJson.map({ String(cString: $0) }),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    static func exportLeftover(pairingPath: String, name: String, destLocalPath: String) throws {
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(name) { np in
                withCString(destLocalPath) { dp in
                    al_export_leftover(pp, np, dp, logCallback, nil, &outErr)
                }
            }
        }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "leftover export failed"
            free(outErr)
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        free(outErr)
    }

    static func cleanupLeftovers(pairingPath: String) throws -> [String: Any] {
        var outJson: UnsafeMutablePointer<CChar>?
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            al_cleanup_leftovers(pp, logCallback, nil, &outJson, &outErr)
        }
        defer { free(outJson); free(outErr) }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "cleanup failed"
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let json = outJson.map({ String(cString: $0) }),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    static func deleteLeftover(pairingPath: String, name: String) throws {
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(name) { np in
                al_delete_leftover(pp, np, logCallback, nil, &outErr)
            }
        }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "delete failed"
            free(outErr)
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        free(outErr)
    }

    static func exportContainer(
        pairingPath: String,
        bundleId: String,
        containerPath: String,
        relPath: String,
        bridge: String,
        destZipPath: String,
        rootName: String,
        subtrees: String = ""
    ) throws -> [String: Any] {
        var outJson: UnsafeMutablePointer<CChar>?
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(relPath) { rp in
                        withCString(bridge) { bp in
                            withCString(destZipPath) { zp in
                                withCString(rootName) { rn in
                                    withCString(subtrees) { st in
                                        al_export_container(pp, bi, cp, rp, bp, zp, rn, st, logCallback, nil, &outJson, &outErr)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        defer { free(outJson); free(outErr) }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "export failed"
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let json = outJson.map({ String(cString: $0) }),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    static func bridgeOpen(pairingPath: String, containerPath: String) throws -> (bridge: String, mode: String, requiresRiskyMoves: Bool) {
        var outJson: UnsafeMutablePointer<CChar>?
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(containerPath) { cp in
                al_bridge_open(pp, cp, logCallback, nil, &outJson, &outErr)
            }
        }
        defer { free(outJson); free(outErr) }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "bridge open failed"
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let json = outJson.map({ String(cString: $0) }),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Rust", code: -1, userInfo: [NSLocalizedDescriptionKey: "bad bridge json"])
        }
        let bridge = (obj["bridge"] as? String) ?? ""
        let mode = (obj["mode"] as? String) ?? "unknown"
        let risky = (obj["requiresRiskyMoves"] as? Bool) ?? false
        return (bridge, mode, risky)
    }

    static func bridgeClose(pairingPath: String, bridge: String) {
        var outErr: UnsafeMutablePointer<CChar>?
        withCString(pairingPath) { pp in
            withCString(bridge) { bp in
                _ = al_bridge_close(pp, bp, logCallback, nil, &outErr)
            }
        }
        free(outErr)
    }

    /// Returns the entries plus the bridge the core actually used. The core
    /// recreates a missing bridge on its own, so the caller must adopt the name
    /// it reports back.
    static func list(pairingPath: String, bundleId: String, containerPath: String, relPath: String, bridge: String) throws -> (entries: [[String: Any]], bridge: String) {
        var outJson: UnsafeMutablePointer<CChar>?
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(relPath) { rp in
                        withCString(bridge) { bp in
                            al_fs_list(pp, bi, cp, rp, bp, logCallback, nil, &outJson, &outErr)
                        }
                    }
                }
            }
        }
        defer { free(outJson); free(outErr) }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "list failed"
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let json = outJson.map({ String(cString: $0) }),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = obj["entries"] as? [[String: Any]] else {
            return ([], bridge)
        }
        return (entries, (obj["bridge"] as? String) ?? bridge)
    }

    static func stat(pairingPath: String, bundleId: String, containerPath: String, relPath: String, bridge: String) throws -> [String: Any] {
        var outJson: UnsafeMutablePointer<CChar>?
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(relPath) { rp in
                        withCString(bridge) { bp in
                            al_fs_stat(pp, bi, cp, rp, bp, logCallback, nil, &outJson, &outErr)
                        }
                    }
                }
            }
        }
        defer { free(outJson); free(outErr) }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "stat failed"
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let json = outJson.map({ String(cString: $0) }),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Rust", code: -1, userInfo: [NSLocalizedDescriptionKey: "bad stat json"])
        }
        return obj
    }

    static func read(pairingPath: String, bundleId: String, containerPath: String, relPath: String, bridge: String, destLocalPath: String) throws {
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(relPath) { rp in
                        withCString(bridge) { bp in
                            withCString(destLocalPath) { dp in
                                al_fs_read(pp, bi, cp, rp, bp, dp, logCallback, nil, &outErr)
                            }
                        }
                    }
                }
            }
        }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "read failed"
            free(outErr)
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        free(outErr)
    }

    static func write(pairingPath: String, bundleId: String, containerPath: String, relPath: String, bridge: String, srcLocalPath: String) throws {
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(relPath) { rp in
                        withCString(bridge) { bp in
                            withCString(srcLocalPath) { sp in
                                al_fs_write(pp, bi, cp, rp, bp, sp, logCallback, nil, &outErr)
                            }
                        }
                    }
                }
            }
        }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "write failed"
            free(outErr)
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        free(outErr)
    }

    static func mkdir(pairingPath: String, bundleId: String, containerPath: String, relPath: String, bridge: String) throws {
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(relPath) { rp in
                        withCString(bridge) { bp in
                            al_fs_mkdir(pp, bi, cp, rp, bp, logCallback, nil, &outErr)
                        }
                    }
                }
            }
        }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "mkdir failed"
            free(outErr)
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        free(outErr)
    }

    static func remove(pairingPath: String, bundleId: String, containerPath: String, relPath: String, bridge: String) throws {
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(relPath) { rp in
                        withCString(bridge) { bp in
                            al_fs_remove(pp, bi, cp, rp, bp, logCallback, nil, &outErr)
                        }
                    }
                }
            }
        }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "remove failed"
            free(outErr)
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        free(outErr)
    }

    static func rename(pairingPath: String, bundleId: String, containerPath: String, oldRel: String, newRel: String, bridge: String) throws {
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(oldRel) { or in
                        withCString(newRel) { nr in
                            withCString(bridge) { bp in
                                al_fs_rename(pp, bi, cp, or, nr, bp, logCallback, nil, &outErr)
                            }
                        }
                    }
                }
            }
        }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "rename failed"
            free(outErr)
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        free(outErr)
    }
}

func withCString<T>(_ s: String, _ body: (UnsafePointer<CChar>) -> T) -> T {
    return s.withCString { body($0) }
}
