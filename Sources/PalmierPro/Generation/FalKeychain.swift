import Foundation

extension Notification.Name {
    static let falAPIKeyChanged = Notification.Name("falAPIKeyChanged")
}

/// Bring-your-own fal.ai key for direct AI generation (no Palmier backend / subscription).
/// Mirrors `AnthropicKeychain`: stored in the macOS Keychain; in DEBUG, `FAL_KEY` from the
/// environment takes precedence so it can be injected for testing.
enum FalKeychain {
    private static let account = "fal-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .falAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["FAL_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .falAPIKeyChanged, object: nil)
    }

    static var hasKey: Bool { !(load() ?? "").isEmpty }
}
