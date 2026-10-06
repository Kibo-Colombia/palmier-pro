import CryptoKit
import Foundation

struct ExportJobReceipt: Codable, Sendable, Equatable {
    enum State: String, Codable { case queued, running, cancelling, completed, cancelled, failed }

    let jobId: String
    let path: String
    let format: String
    let resolution: String
    let sourceRevision: String
    let totalFrames: Int
    let fps: Int
    let createdAt: Date
    let idempotencyKey: String?
    let requestFingerprint: String
    var state: State = .queued
    var progress: Double = 0
    var finishedAt: Date?
    var bytes: Int64?
    var error: String?

    var isFinished: Bool { state == .completed || state == .cancelled || state == .failed }
}

@MainActor
final class ExportJobService {
    static let shared = ExportJobService(storageURL: DiskCache(named: "export-jobs").directory)

    private let storageURL: URL
    private var receipts: [String: ExportJobReceipt] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var services: [String: ExportService] = [:]

    init(storageURL: URL) {
        self.storageURL = storageURL
        try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: storageURL, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var receipt = try? JSONDecoder().decode(ExportJobReceipt.self, from: data),
                  UUID(uuidString: receipt.jobId) != nil, receipt.fps > 0, receipt.progress.isFinite else { continue }
            if !receipt.isFinished {
                receipt.state = .failed
                receipt.error = "Export interrupted when Koma closed. Start a new export with a new idempotency key."
                receipt.finishedAt = Date()
            }
            receipts[receipt.jobId] = receipt
            persistUpdate(receipt)
        }
    }

    func start(timeline: Timeline, manifest: MediaManifest, projectURL: URL?,
               path: String, formatName: String, resolutionName: String,
               overwrite: Bool, idempotencyKey: String?) throws -> ExportJobReceipt {
        let format = try Self.format(formatName)
        let resolution = try Self.resolution(resolutionName)
        let output = try ProjectAutomationFiles.outputURL(path, extension: format.fileExtension)
        guard timeline.fps > 0, timeline.width > 0, timeline.height > 0 else {
            throw ToolError("Timeline dimensions and fps must be positive")
        }
        let revision = try TimelineEditPlanner.revision(timeline: timeline, manifest: manifest)
        if let key = idempotencyKey, key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key.count > 256 {
            throw ToolError("idempotencyKey must contain 1...256 characters")
        }
        let request: [String: Any] = ["path": output.path, "format": formatName,
                                     "resolution": resolution.rawValue, "overwrite": overwrite,
                                     "sourceRevision": revision, "projectURL": projectURL?.path ?? ""]
        let requestData = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let fingerprint = SHA256.hash(data: requestData).map { String(format: "%02x", $0) }.joined()
        if let key = idempotencyKey, let previous = receipts.values.first(where: { $0.idempotencyKey == key }) {
            guard previous.requestFingerprint == fingerprint else {
                throw ToolError("idempotencyKey already identifies a different export request")
            }
            return previous
        }
        guard !receipts.values.contains(where: { !$0.isFinished && $0.path == output.path }) else {
            throw ToolError("An export already owns this output path")
        }
        if !overwrite && FileManager.default.fileExists(atPath: output.path) {
            throw ToolError("Destination already exists: \(output.path). Set overwrite=true to replace it.")
        }
        let missing = Self.missingTimelineMedia(timeline: timeline, manifest: manifest, projectURL: projectURL)
        guard missing.isEmpty else { throw ToolError("Missing timeline media: \(missing.joined(separator: ", "))") }
        guard timeline.totalFrames > 0 else { throw ToolError("Timeline is empty") }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let receipt = ExportJobReceipt(jobId: UUID().uuidString, path: output.path, format: formatName,
                                       resolution: resolution.rawValue, sourceRevision: revision,
                                       totalFrames: timeline.totalFrames, fps: timeline.fps,
                                       createdAt: Date(), idempotencyKey: idempotencyKey,
                                       requestFingerprint: fingerprint)
        try persist(receipt)
        receipts[receipt.jobId] = receipt
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { projectURL })
        tasks[receipt.jobId] = Task { [weak self] in
            await self?.run(jobId: receipt.jobId, timeline: timeline, resolver: resolver,
                            format: format, resolution: resolution, output: output, overwrite: overwrite)
        }
        return receipt
    }

    func receipt(jobId: String) throws -> ExportJobReceipt {
        guard let receipt = receipts[jobId] else { throw ToolError("Export job not found: \(jobId)") }
        return receipt
    }

    func cancel(jobId: String) throws -> ExportJobReceipt {
        var receipt = try receipt(jobId: jobId)
        guard !receipt.isFinished else { return receipt }
        receipt.state = .cancelling
        receipts[jobId] = receipt
        persistUpdate(receipt)
        tasks[jobId]?.cancel()
        services[jobId]?.cancel()
        return receipt
    }

    func wait(jobId: String) async throws -> ExportJobReceipt {
        await tasks[jobId]?.value
        return try receipt(jobId: jobId)
    }

    private func run(jobId: String, timeline: Timeline, resolver: MediaResolver,
                     format: ExportFormat, resolution: ExportResolution, output: URL, overwrite: Bool) async {
        let staging = output.deletingLastPathComponent()
            .appendingPathComponent(".koma-export-\(jobId).\(format.fileExtension)")
        let service = ExportService()
        services[jobId] = service
        defer {
            services[jobId] = nil
            tasks[jobId] = nil
            try? FileManager.default.removeItem(at: staging)
        }
        if Task.isCancelled {
            finish(jobId, state: .cancelled, error: nil)
            return
        }
        update(jobId, state: .running, progress: 0)
        let progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.update(jobId, progress: service.progress)
            }
        }
        defer { progressTask.cancel() }
        await service.export(timeline: timeline, resolver: resolver, format: format,
                             resolution: resolution, outputURL: staging, strictSourceValidation: true)
        if Task.isCancelled {
            finish(jobId, state: .cancelled, error: nil)
        } else if let error = service.error {
            finish(jobId, state: .failed, error: error)
        } else {
            do {
                let size = (try FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0 else { throw ToolError("Export produced an empty file") }
                try ProjectAutomationFiles.commit(staging: staging, to: output, overwrite: overwrite)
                receipts[jobId]?.bytes = size
                finish(jobId, state: .completed, error: nil)
            } catch {
                finish(jobId, state: .failed, error: (error as? ToolError)?.message ?? error.localizedDescription)
            }
        }
    }

    private func update(_ jobId: String, state: ExportJobReceipt.State? = nil, progress: Double) {
        guard var receipt = receipts[jobId], !receipt.isFinished else { return }
        if let state { receipt.state = state }
        receipt.progress = min(1, max(0, progress))
        receipts[jobId] = receipt
        persistUpdate(receipt)
    }

    private func finish(_ jobId: String, state: ExportJobReceipt.State, error: String?) {
        guard var receipt = receipts[jobId] else { return }
        receipt.state = state
        receipt.error = error
        receipt.finishedAt = Date()
        if state == .completed { receipt.progress = 1 }
        receipts[jobId] = receipt
        persistUpdate(receipt)
    }

    private func persist(_ receipt: ExportJobReceipt) throws {
        let data = try JSONEncoder().encode(receipt)
        try data.write(to: storageURL.appendingPathComponent("\(receipt.jobId).json"), options: .atomic)
    }

    private func persistUpdate(_ receipt: ExportJobReceipt) {
        do { try persist(receipt) }
        catch { Log.export.error("export receipt write failed: \(error.localizedDescription)") }
    }

    static func missingTimelineMedia(timeline: Timeline, manifest: MediaManifest, projectURL: URL?) -> [String] {
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { projectURL })
        let ids = Set(timeline.tracks.filter { !$0.hidden && !$0.muted }.flatMap(\.clips)
            .filter { $0.mediaType.buildsCompositionTrack }.map(\.mediaRef))
        return ids.filter { resolver.resolveURL(for: $0) == nil }.sorted()
    }

    static func format(_ name: String) throws -> ExportFormat {
        switch name {
        case "h264": .h264
        case "h265": .h265
        case "prores": .prores
        default: throw ToolError("Unknown format '\(name)' — use h264, h265, or prores")
        }
    }

    static func resolution(_ name: String) throws -> ExportResolution {
        guard let value = ExportResolution(rawValue: name == "4k" ? "4K" : name) else {
            throw ToolError("Unknown resolution '\(name)' — use 720p, 1080p, or 4K")
        }
        return value
    }
}
