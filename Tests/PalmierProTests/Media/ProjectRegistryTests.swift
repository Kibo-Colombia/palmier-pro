import Foundation
import Testing
@testable import PalmierPro

@Suite("ProjectRegistry")
@MainActor
struct ProjectRegistryTests {

    /// Fresh registry backed by a unique temp file per test — never touches the singleton's
    /// production storage.
    private func makeRegistry() -> ProjectRegistry {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("registry-\(UUID().uuidString).json")
        return ProjectRegistry(fileURL: url)
    }

    private func makeProjectURL(_ name: String = "Test") -> URL {
        URL(fileURLWithPath: "/tmp/\(name)-\(UUID().uuidString).palmier")
    }

    // MARK: - register

    @Test func registerAddsNewProject() {
        let reg = makeRegistry()
        let url = makeProjectURL()
        reg.register(url)
        #expect(reg.entries.count == 1)
        #expect(reg.entries[0].url.standardizedFileURL == url.standardizedFileURL)
    }

    @Test func registerDeduplicatesByStandardizedURL() {
        // Same project URL registered twice → one entry, lastOpenedDate updated.
        let reg = makeRegistry()
        let url = makeProjectURL()
        reg.register(url)
        let firstOpened = reg.entries[0].lastOpenedDate

        // Sleep briefly to ensure the timestamps differ.
        Thread.sleep(forTimeInterval: 0.01)
        reg.register(url)
        #expect(reg.entries.count == 1)
        #expect(reg.entries[0].lastOpenedDate > firstOpened)
    }

    @Test func registerTreatsPathsWithExtraSlashesAsTheSameProject() {
        // standardizedFileURL collapses redundant slashes, so /tmp/foo and /tmp//foo dedupe.
        let reg = makeRegistry()
        let url1 = URL(fileURLWithPath: "/tmp/dedupe-\(UUID().uuidString).palmier")
        let url2 = URL(string: "file://\(url1.path)")! // same path, different URL form
        reg.register(url1)
        reg.register(url2)
        #expect(reg.entries.count == 1)
    }

    // MARK: - remove

    @Test func removeDropsMatchingEntry() {
        let reg = makeRegistry()
        let a = makeProjectURL("A")
        let b = makeProjectURL("B")
        reg.register(a)
        reg.register(b)
        reg.remove(a)
        #expect(reg.entries.count == 1)
        #expect(reg.entries[0].url.standardizedFileURL == b.standardizedFileURL)
    }

    @Test func removeIsNoOpForUnknownURL() {
        let reg = makeRegistry()
        let a = makeProjectURL("A")
        reg.register(a)
        reg.remove(makeProjectURL("Ghost"))
        #expect(reg.entries.count == 1)
    }

    // MARK: - updateURL (rename / move)

    @Test func updateURLChangesURLAndBumpsLastOpenedDate() {
        let reg = makeRegistry()
        let oldURL = makeProjectURL("OldName")
        reg.register(oldURL)
        let oldDate = reg.entries[0].lastOpenedDate

        let newURL = makeProjectURL("NewName")
        Thread.sleep(forTimeInterval: 0.01)
        reg.updateURL(from: oldURL, to: newURL)

        #expect(reg.entries.count == 1)
        #expect(reg.entries[0].url.standardizedFileURL == newURL.standardizedFileURL)
        #expect(reg.entries[0].lastOpenedDate > oldDate)
    }

    @Test func updateURLIsNoOpWhenSourceUnknown() {
        let reg = makeRegistry()
        let a = makeProjectURL("A")
        reg.register(a)
        reg.updateURL(from: makeProjectURL("Ghost"), to: makeProjectURL("Phantom"))
        #expect(reg.entries.count == 1)
        #expect(reg.entries[0].url.standardizedFileURL == a.standardizedFileURL)
    }

    // MARK: - sortedEntries

    @Test func sortedEntriesAreNewestFirst() {
        let reg = makeRegistry()
        let oldURL = makeProjectURL("Old")
        let newURL = makeProjectURL("New")
        reg.register(oldURL)
        Thread.sleep(forTimeInterval: 0.01)
        reg.register(newURL)
        let sorted = reg.sortedEntries
        #expect(sorted[0].url.standardizedFileURL == newURL.standardizedFileURL)
        #expect(sorted[1].url.standardizedFileURL == oldURL.standardizedFileURL)
    }

    // MARK: - Persistence

    @Test func registryPersistsAcrossLoadCycles() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("persist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let first = ProjectRegistry(fileURL: url)
            first.register(makeProjectURL("Persisted"))
            #expect(first.entries.count == 1)
        }
        let second = ProjectRegistry(fileURL: url)
        #expect(second.entries.count == 1, "registry should reload from disk")
    }

    @Test func packageDirectoryAndFileURLPreserveIdentityAcrossCreationAndReopen() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("registry-package-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let storage = root.appendingPathComponent("registry.json")
        let path = root.appendingPathComponent("Garden.palmier").path
        let fileURL = URL(fileURLWithPath: path, isDirectory: false)
        let directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        let first = ProjectRegistry(fileURL: storage)
        first.register(fileURL)
        let id = try #require(first.entry(for: fileURL)).id
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        first.register(directoryURL)
        #expect(first.entries.count == 1)
        #expect(first.entry(for: directoryURL)?.id == id)
        let reopened = ProjectRegistry(fileURL: storage)
        #expect(reopened.entry(for: fileURL)?.id == id)
        #expect(reopened.entry(for: directoryURL)?.id == id)
    }

    @Test func movingPackageUsingDirectoryURLPreservesRegisteredUUID() throws {
        let reg = makeRegistry()
        let old = makeProjectURL("Old")
        let directoryOld = URL(fileURLWithPath: old.path, isDirectory: true)
        let new = makeProjectURL("New")
        let directoryNew = URL(fileURLWithPath: new.path, isDirectory: true)
        reg.register(old)
        let id = try #require(reg.entry(for: old)).id
        reg.updateURL(from: directoryOld, to: directoryNew)
        #expect(reg.entry(for: old) == nil)
        #expect(reg.entry(for: new)?.id == id)
        #expect(reg.entry(for: directoryNew)?.id == id)
    }

    @Test func removeDirectoryURLFindsEntryRegisteredAsFileURL() {
        let reg = makeRegistry()
        let url = makeProjectURL()
        reg.register(url)
        reg.remove(URL(fileURLWithPath: url.path, isDirectory: true))
        #expect(reg.entries.isEmpty)
    }

    @Test func symlinkAliasAndPackageURLShareRegisteredIdentity() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("registry-alias-\(UUID().uuidString)")
        let package = root.appendingPathComponent("Garden.palmier", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let alias = root.appendingPathComponent("Alias.palmier", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: package)
        let reg = ProjectRegistry(fileURL: root.appendingPathComponent("registry.json"))
        reg.register(package)
        let id = try #require(reg.entry(for: package)).id
        reg.register(alias)
        #expect(reg.entries.count == 1)
        #expect(reg.entry(for: alias)?.id == id)
        reg.remove(alias)
        #expect(reg.entries.isEmpty)
    }

    // MARK: - ProjectEntry

    @Test func projectEntryDerivesNameFromURL() {
        let entry = ProjectEntry(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/MyProject.palmier"),
            createdDate: Date(),
            lastOpenedDate: Date()
        )
        #expect(entry.name == "MyProject")
    }

    @Test func projectEntryIsAccessibleReflectsFileExistence() throws {
        let real = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("entry-\(UUID().uuidString).palmier")
        FileManager.default.createFile(atPath: real.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: real) }

        let present = ProjectEntry(id: UUID(), url: real, createdDate: Date(), lastOpenedDate: Date())
        let absent = ProjectEntry(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).palmier"),
            createdDate: Date(),
            lastOpenedDate: Date()
        )
        #expect(present.isAccessible)
        #expect(!absent.isAccessible)
    }
}
