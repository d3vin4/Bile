import Foundation
import AirliftFFI

enum RustBridge {
    static func free(_ p: UnsafeMutablePointer<CChar>?) {
        if let p = p { al_string_free(p) }
    }

    static func catalog(pairingPath: String, log: @escaping (String) -> Void) throws -> (apps: [[String: Any]], groups: [[String: Any]]) {
        var outJson: UnsafeMutablePointer<CChar>?
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            al_container_catalog(pp, { _, msg in
                if let msg = msg { log(String(cString: msg)) }
            }, nil, &outJson, &outErr)
        }
        defer { RustBridge.free(outJson); RustBridge.free(outErr) }
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

    static func bridgeOpen(pairingPath: String, containerPath: String, log: @escaping (String) -> Void) throws -> (bridge: String, mode: String) {
        var outJson: UnsafeMutablePointer<CChar>?
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(containerPath) { cp in
                al_bridge_open(pp, cp, { _, msg in
                    if let msg = msg { log(String(cString: msg)) }
                }, nil, &outJson, &outErr)
            }
        }
        defer { RustBridge.free(outJson); RustBridge.free(outErr) }
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
        return (bridge, mode)
    }

    static func bridgeClose(pairingPath: String, bridge: String, log: @escaping (String) -> Void) {
        var outErr: UnsafeMutablePointer<CChar>?
        withCString(pairingPath) { pp in
            withCString(bridge) { bp in
                _ = al_bridge_close(pp, bp, { _, msg in
                    if let msg = msg { log(String(cString: msg)) }
                }, nil, &outErr)
            }
        }
        RustBridge.free(outErr)
    }

    static func list(pairingPath: String, bundleId: String, containerPath: String, relPath: String, bridge: String, log: @escaping (String) -> Void) throws -> [[String: Any]] {
        var outJson: UnsafeMutablePointer<CChar>?
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(relPath) { rp in
                        withCString(bridge) { bp in
                            al_fs_list(pp, bi, cp, rp, bp, { _, msg in
                                if let msg = msg { log(String(cString: msg)) }
                            }, nil, &outJson, &outErr)
                        }
                    }
                }
            }
        }
        defer { RustBridge.free(outJson); RustBridge.free(outErr) }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "list failed"
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

    static func stat(pairingPath: String, bundleId: String, containerPath: String, relPath: String, bridge: String, log: @escaping (String) -> Void) throws -> [String: Any] {
        var outJson: UnsafeMutablePointer<CChar>?
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(relPath) { rp in
                        withCString(bridge) { bp in
                            al_fs_stat(pp, bi, cp, rp, bp, { _, msg in
                                if let msg = msg { log(String(cString: msg)) }
                            }, nil, &outJson, &outErr)
                        }
                    }
                }
            }
        }
        defer { RustBridge.free(outJson); RustBridge.free(outErr) }
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

    static func read(pairingPath: String, bundleId: String, containerPath: String, relPath: String, bridge: String, destLocalPath: String, log: @escaping (String) -> Void) throws {
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(relPath) { rp in
                        withCString(bridge) { bp in
                            withCString(destLocalPath) { dp in
                                al_fs_read(pp, bi, cp, rp, bp, dp, { _, msg in
                                    if let msg = msg { log(String(cString: msg)) }
                                }, nil, &outErr)
                            }
                        }
                    }
                }
            }
        }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "read failed"
            RustBridge.free(outErr)
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        RustBridge.free(outErr)
    }

    static func write(pairingPath: String, bundleId: String, containerPath: String, relPath: String, bridge: String, srcLocalPath: String, log: @escaping (String) -> Void) throws {
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(relPath) { rp in
                        withCString(bridge) { bp in
                            withCString(srcLocalPath) { sp in
                                al_fs_write(pp, bi, cp, rp, bp, sp, { _, msg in
                                    if let msg = msg { log(String(cString: msg)) }
                                }, nil, &outErr)
                            }
                        }
                    }
                }
            }
        }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "write failed"
            RustBridge.free(outErr)
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        RustBridge.free(outErr)
    }

    static func mkdir(pairingPath: String, bundleId: String, containerPath: String, relPath: String, bridge: String, log: @escaping (String) -> Void) throws {
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(relPath) { rp in
                        withCString(bridge) { bp in
                            al_fs_mkdir(pp, bi, cp, rp, bp, { _, msg in
                                if let msg = msg { log(String(cString: msg)) }
                            }, nil, &outErr)
                        }
                    }
                }
            }
        }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "mkdir failed"
            RustBridge.free(outErr)
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        RustBridge.free(outErr)
    }

    static func remove(pairingPath: String, bundleId: String, containerPath: String, relPath: String, bridge: String, log: @escaping (String) -> Void) throws {
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(relPath) { rp in
                        withCString(bridge) { bp in
                            al_fs_remove(pp, bi, cp, rp, bp, { _, msg in
                                if let msg = msg { log(String(cString: msg)) }
                            }, nil, &outErr)
                        }
                    }
                }
            }
        }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "remove failed"
            RustBridge.free(outErr)
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        RustBridge.free(outErr)
    }

    static func rename(pairingPath: String, bundleId: String, containerPath: String, oldRel: String, newRel: String, bridge: String, log: @escaping (String) -> Void) throws {
        var outErr: UnsafeMutablePointer<CChar>?
        let rc = withCString(pairingPath) { pp in
            withCString(bundleId) { bi in
                withCString(containerPath) { cp in
                    withCString(oldRel) { or in
                        withCString(newRel) { nr in
                            withCString(bridge) { bp in
                                al_fs_rename(pp, bi, cp, or, nr, bp, { _, msg in
                                    if let msg = msg { log(String(cString: msg)) }
                                }, nil, &outErr)
                            }
                        }
                    }
                }
            }
        }
        if rc != 0 {
            let msg = outErr.map { String(cString: $0) } ?? "rename failed"
            RustBridge.free(outErr)
            throw NSError(domain: "Rust", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        RustBridge.free(outErr)
    }
}

// Helper
func withCString<T>(_ s: String, _ body: (UnsafePointer<CChar>) -> T) -> T {
    return s.withCString { body($0) }
}
