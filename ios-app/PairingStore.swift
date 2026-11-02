import Foundation
import Security

/// Keeps the pairing credentials in two places so a relaunch — or a
/// re-sign/reinstall that wipes the app container — never loses the pairing.
///
/// * Documents copy: what `al_pairing_run_host` reads and writes.
/// * Keychain copy: restored automatically when the Documents copy is gone.
enum PairingStore {

    static let fileName = "readipa_pairing.plist"
    static let legacyFileNames = ["aircard_pairing.plist", "airlift_pairing.plist"]

    private static let service = "com.d3vin4.readipa"
    private static let account = "pairing-file"

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var canonicalURL: URL {
        documentsDirectory.appendingPathComponent(fileName)
    }

    // MARK: - Files

    /// Writes the credentials to Documents and mirrors them into the Keychain.
    @discardableResult
    static func write(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        do {
            try data.write(to: canonicalURL, options: .atomic)
        } catch {
            return false
        }
        saveToKeychain(data)
        return true
    }

    /// Returns the credentials, restoring from the Keychain (or a legacy file)
    /// when the canonical file is missing.
    static func read() -> Data? {
        if let data = try? Data(contentsOf: canonicalURL), !data.isEmpty {
            return data
        }
        // Migrate a legacy file name.
        for legacy in legacyFileNames {
            let url = documentsDirectory.appendingPathComponent(legacy)
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                _ = write(data)
                return data
            }
        }
        // Restore from the Keychain.
        if let data = loadFromKeychain(), !data.isEmpty {
            try? data.write(to: canonicalURL, options: .atomic)
            return data
        }
        return nil
    }

    static func exists() -> Bool {
        read() != nil
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: canonicalURL)
        for legacy in legacyFileNames {
            try? FileManager.default.removeItem(at: documentsDirectory.appendingPathComponent(legacy))
        }
        clearKeychain()
    }

    // MARK: - Keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func saveToKeychain(_ data: Data) {
        SecItemDelete(baseQuery() as CFDictionary)
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func loadFromKeychain() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else {
            return nil
        }
        return out as? Data
    }

    private static func clearKeychain() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
