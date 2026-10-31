import CryptoKit
import Foundation
import Security

/// Keychain-backed secrets + AES-GCM encrypted files with iOS complete file protection.
enum Keychain {
    static let service = "ai.worldtree.app"

    static func set(_ value: Data, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }

    static func string(_ key: String) -> String? { get(key).flatMap { String(data: $0, encoding: .utf8) } }
    static func setString(_ s: String, _ key: String) { set(Data(s.utf8), for: key) }
}

enum EncryptedStore {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorldTree", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var key: SymmetricKey {
        if let raw = Keychain.get("data-key") { return SymmetricKey(data: raw) }
        let k = SymmetricKey(size: .bits256)
        Keychain.set(k.withUnsafeBytes { Data($0) }, for: "data-key")
        return k
    }

    static func write(_ data: Data, name: String) throws {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        try combined.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
    }

    static func read(name: String) -> Data? {
        guard let blob = try? Data(contentsOf: directory.appendingPathComponent(name)),
              let box = try? AES.GCM.SealedBox(combined: blob) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
        Keychain.delete("data-key")
    }
}
