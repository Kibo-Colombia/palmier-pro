import CryptoKit
import Foundation

/// Content-based file identity: the key every sidecar store is filed under.
///
/// The key is a fingerprint of the file's *bytes* (size + first/last 1 MiB), never its
/// path — so a clip keeps its embeddings, labels, transcript, and paid summaries when
/// the user renames it or drags it anywhere in Finder. A persistent `stat → contentKey`
/// map makes the common case (unchanged file, known path) a dictionary hit; only a file
/// seen at a new path/mtime pays the one 2 MiB read to rediscover its identity.
final class AssetIdentity: @unchecked Sendable {
    static let shared = AssetIdentity()

    /// Hot path used by every store. Same signature/semantics as the old path-keyed
    /// function: nil when the file can't be statted.
    static func key(for url: URL) -> String? { shared.key(for: url) }

    // MARK: - Lookup

    private let lock = NSLock()
    private var map: [String: String] = [:]   // statIdentity → contentKey
    private var loaded = false
    private var saveScheduled = false
    private let saveQueue = DispatchQueue(label: "co.kibo.koma.asset-identity", qos: .utility)

    func key(for url: URL) -> String? {
        guard let stat = Self.statIdentity(for: url) else { return nil }
        lock.lock()
        loadIfNeededLocked()
        if let known = map[stat] {
            lock.unlock()
            return known
        }
        lock.unlock()

        guard let content = Self.fingerprint(url: url) else { return nil }
        lock.lock()
        map[stat] = content
        lock.unlock()
        scheduleSave()
        return content
    }

    /// Record a move performed by the app itself (the organizer), so the destination
    /// resolves without even the fingerprint read.
    func noteMoved(from oldURL: URL, to newURL: URL) {
        guard let newStat = Self.statIdentity(for: newURL) else { return }
        lock.lock()
        loadIfNeededLocked()
        let known = map[Self.statIdentity(path: oldURL.path, stat: newStat)] ?? nil
        // Same volume moves preserve mtime+size, so the old entry (old path, same
        // mtime|size tail) carries the contentKey; fall back to fingerprinting.
        if let known { map[newStat] = known }
        lock.unlock()
        if known == nil { _ = key(for: newURL) } else { scheduleSave() }
    }

    // MARK: - Identity primitives

    /// `path|mtime|size` — the old cache key's preimage, now just the map's lookup key.
    static func statIdentity(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return "\(url.path)|\(mtime.timeIntervalSince1970)|\(size)"
    }

    private static func statIdentity(path: String, stat: String) -> String {
        // Swap the path prefix of an existing identity string (its mtime|size tail is
        // volume-move invariant).
        guard let bar = stat.firstIndex(of: "|") else { return stat }
        return path + stat[bar...]
    }

    /// SHA-256 over (size ‖ first 1 MiB ‖ last 1 MiB), truncated to 32 hex chars to keep
    /// the sidecar filename format identical to the legacy keys. Reads at most 2 MiB no
    /// matter how large the clip is; the trailing MiB covers the `moov` atom, so any real
    /// re-encode or edit changes the key.
    static func fingerprint(url: URL) -> String? {
        let chunk = 1 << 20
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        var sizeLE = UInt64(size).littleEndian
        withUnsafeBytes(of: &sizeLE) { hasher.update(bufferPointer: $0) }
        do {
            if size <= Int64(2 * chunk) {
                if let data = try handle.readToEnd() { hasher.update(data: data) }
            } else {
                if let head = try handle.read(upToCount: chunk) { hasher.update(data: head) }
                try handle.seek(toOffset: UInt64(size) - UInt64(chunk))
                if let tail = try handle.read(upToCount: chunk) { hasher.update(data: tail) }
            }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    // MARK: - Persistence

    private static let mapURL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/identity-map.json")

    private func loadIfNeededLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.mapURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        map = decoded
    }

    /// Losing the map is harmless (identities re-fingerprint lazily), so persistence is
    /// best-effort: debounced, off the hot path.
    private func scheduleSave() {
        lock.lock()
        let alreadyScheduled = saveScheduled
        saveScheduled = true
        lock.unlock()
        guard !alreadyScheduled else { return }
        saveQueue.asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock()
            saveScheduled = false
            let snapshot = map
            lock.unlock()
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: Self.mapURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: Self.mapURL, options: .atomic)
        }
    }
}
