import Foundation
import Security

/// One-time relocation of everything the app persisted under its Palmier-era names
/// (bundle id `io.palmier.pro`, folder names "Palmier Pro"/"PalmierPro") to the Koma
/// names. Runs as the very first thing in `main.swift` — before `Log.bootstrap()` and
/// before any singleton lazily creates the *new* directories — so each move is a plain
/// rename with nothing racing it. Every step is idempotent: a move is skipped when the
/// source is gone or the destination already exists, so a crash mid-migration self-repairs
/// on the next launch.
enum KomaMigration {
    private static let defaultsMarker = "koma.migration.v1.done"

    static func run() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        let moves: [(from: URL, to: URL)] = [
            (caches.appendingPathComponent("io.palmier.pro"), caches.appendingPathComponent("co.kibo.koma")),
            (caches.appendingPathComponent("PalmierPro"), caches.appendingPathComponent("Koma")),
            (home.appendingPathComponent("Documents/Palmier Pro"), home.appendingPathComponent("Documents/Koma")),
            (appSupport.appendingPathComponent("PalmierPro"), appSupport.appendingPathComponent("Koma")),
            (appSupport.appendingPathComponent("io.palmier.pro"), appSupport.appendingPathComponent("co.kibo.koma")),
            (home.appendingPathComponent("Library/Logs/PalmierPro"), home.appendingPathComponent("Library/Logs/Koma")),
        ]
        for move in moves { relocate(from: move.from, to: move.to) }

        migrateDefaultsIfNeeded()
        migrateKeychainIfNeeded()
    }

    /// Move `from` → `to` when the old location exists. If the new location already exists
    /// too (created by a newer launch before old data was noticed), merge entry-by-entry
    /// without overwriting anything the new location already has.
    private static func relocate(from: URL, to: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path) else { return }
        if !fm.fileExists(atPath: to.path) {
            try? fm.createDirectory(
                at: to.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            do {
                try fm.moveItem(at: from, to: to)
            } catch {
                warn("move \(from.path) → \(to.path): \(error.localizedDescription)")
            }
            return
        }
        guard let entries = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) else { return }
        var allMoved = true
        for entry in entries {
            let dest = to.appendingPathComponent(entry.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { allMoved = false; continue }
            do {
                try fm.moveItem(at: entry, to: dest)
            } catch {
                allMoved = false
                warn("merge \(entry.path) → \(dest.path): \(error.localizedDescription)")
            }
        }
        if allMoved { try? fm.removeItem(at: from) }
    }

    /// Copy the old bundle id's UserDefaults domain into the new one (which
    /// `UserDefaults.standard` now points at), renaming the palmier-prefixed keys.
    /// Values already set under the new domain win.
    private static func migrateDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultsMarker) else { return }
        defer { defaults.set(true, forKey: defaultsMarker) }
        guard let old = defaults.persistentDomain(forName: "io.palmier.pro") else { return }
        for (key, value) in old {
            let newKey = key.hasPrefix("io.palmier.pro.")
                ? "co.kibo.koma." + key.dropFirst("io.palmier.pro.".count)
                : key
            if defaults.object(forKey: newKey) == nil {
                defaults.set(value, forKey: newKey)
            }
        }
    }

    /// Re-save every generic-password item from the old keychain service under the new
    /// one (the BYO Anthropic/fal keys). Old items are left in place — harmless, and
    /// deleting credentials during a migration is not worth the risk.
    private static func migrateKeychainIfNeeded() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.palmier.pro",
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let value = String(data: data, encoding: .utf8) else { continue }
            if KeychainStore.load(account: account) == nil {
                KeychainStore.save(value, account: account)
            }
        }
    }

    /// `Log` isn't bootstrapped yet when this runs — mirror straight to stderr.
    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("[migration] WARN: \(message)\n".utf8))
    }
}
