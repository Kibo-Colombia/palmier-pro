import Foundation
import Combine

/// Direct fal.ai REST client used in BYOK mode (no Palmier/Convex account).
///
/// Mirrors the surface `GenerationService.runJob` expects from `GenerationBackend`:
///  - `submit` enqueues a fal queue request and returns its `request_id` (used as our jobId).
///  - `subscribe` polls the fal queue and emits `BackendGenerationJob?` so the existing
///    pipeline (placeholders → download → import) is unchanged.
///
/// Only text-to-music (audio) is wired today; image/video stay on the Convex path.
@MainActor
enum FalDirectBackend {
    private static let queueBase = "https://queue.fal.run"
    private static let pollInterval: TimeInterval = 2.0
    private static let maxPolls = 300   // ~10 min ceiling at 2s

    // In-flight submissions, keyed by the request_id we hand back as the jobId.
    private static var pending: [String: Submission] = [:]

    private struct Submission {
        let statusURL: URL
        let responseURL: URL
    }

    // MARK: - Submit

    static func submit(model: String, params: BackendGenerationParams) async throws -> String {
        guard let key = FalKeychain.load(), !key.isEmpty else {
            throw GenerationBackendError.notConfigured
        }
        let body = try requestBody(model: model, params: params)
        guard let url = URL(string: "\(queueBase)/\(model)") else {
            throw GenerationBackendError.transport("Invalid fal model id '\(model)'")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try assertHTTPOK(data: data, response: response)

        let queued = try JSONDecoder().decode(QueueSubmitResponse.self, from: data)
        // fal returns absolute status/response URLs; fall back to the canonical shape if absent.
        let statusURL = URL(string: queued.status_url ?? "")
            ?? URL(string: "\(queueBase)/\(model)/requests/\(queued.request_id)/status")
        let responseURL = URL(string: queued.response_url ?? "")
            ?? URL(string: "\(queueBase)/\(model)/requests/\(queued.request_id)")
        guard let statusURL, let responseURL else {
            throw GenerationBackendError.transport("fal response missing status/response URLs")
        }
        pending[queued.request_id] = Submission(statusURL: statusURL, responseURL: responseURL)
        return queued.request_id
    }

    // MARK: - Subscribe (polling publisher)

    /// Emits .running while queued/in-progress, then a terminal .succeeded/.failed, then completes.
    static func subscribe(jobId: String) -> AnyPublisher<BackendGenerationJob?, Never> {
        let subject = PassthroughSubject<BackendGenerationJob?, Never>()
        guard let submission = pending[jobId] else {
            subject.send(makeJob(jobId, status: .failed, errorMessage: "Unknown fal job"))
            subject.send(completion: .finished)
            return subject.eraseToAnyPublisher()
        }

        let task = Task { @MainActor in
            defer { pending[jobId] = nil }
            subject.send(makeJob(jobId, status: .queued))
            do {
                for _ in 0..<maxPolls {
                    if Task.isCancelled { return }
                    let status = try await fetchStatus(submission.statusURL)
                    switch status {
                    case "COMPLETED":
                        let urls = try await fetchResultURLs(submission.responseURL)
                        subject.send(makeJob(jobId, status: .succeeded, resultUrls: urls))
                        subject.send(completion: .finished)
                        return
                    case "IN_QUEUE", "IN_PROGRESS":
                        subject.send(makeJob(jobId, status: .running))
                    default:
                        subject.send(makeJob(jobId, status: .failed, errorMessage: "fal status: \(status)"))
                        subject.send(completion: .finished)
                        return
                    }
                    try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                }
                subject.send(makeJob(jobId, status: .failed, errorMessage: "fal generation timed out"))
                subject.send(completion: .finished)
            } catch {
                subject.send(makeJob(jobId, status: .failed, errorMessage: error.localizedDescription))
                subject.send(completion: .finished)
            }
        }

        return subject
            .handleEvents(receiveCancel: { task.cancel() })
            .eraseToAnyPublisher()
    }

    // MARK: - Polling helpers

    private static func fetchStatus(_ url: URL) async throws -> String {
        let data = try await authedGET(url)
        let parsed = try JSONDecoder().decode(QueueStatusResponse.self, from: data)
        return parsed.status
    }

    private static func fetchResultURLs(_ url: URL) async throws -> [String] {
        let data = try await authedGET(url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GenerationBackendError.transport("fal result was not a JSON object")
        }
        if let urls = audioURLs(from: obj), !urls.isEmpty { return urls }
        throw GenerationBackendError.transport("No audio URL in fal response")
    }

    private static func authedGET(_ url: URL) async throws -> Data {
        guard let key = FalKeychain.load(), !key.isEmpty else {
            throw GenerationBackendError.notConfigured
        }
        var req = URLRequest(url: url)
        req.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try assertHTTPOK(data: data, response: response)
        return data
    }

    // MARK: - Response parsing

    /// Pulls audio URL(s) from the various fal output shapes:
    ///   { "audio_file": { "url": ... } }   (CassetteAI)
    ///   { "audio": { "url": ... } }        (Stable Audio 3 family)
    ///   { "audio": "https://..." }          (Stable Audio 2.5 string form)
    private static func audioURLs(from obj: [String: Any]) -> [String]? {
        for key in ["audio_file", "audio", "output"] {
            switch obj[key] {
            case let s as String where !s.isEmpty:
                return [s]
            case let dict as [String: Any]:
                if let u = dict["url"] as? String, !u.isEmpty { return [u] }
            case let arr as [[String: Any]]:
                let urls = arr.compactMap { $0["url"] as? String }.filter { !$0.isEmpty }
                if !urls.isEmpty { return urls }
            default:
                continue
            }
        }
        return nil
    }

    // MARK: - Request body translation

    /// Translates Palmier params into the fal model's input JSON.
    private static func requestBody(model: String, params: BackendGenerationParams) throws -> [String: Any] {
        guard case .audio(let audio) = params else {
            throw GenerationBackendError.transport("fal BYOK currently supports audio (music) only")
        }
        switch model {
        case FalDirectModels.cassetteMusicId:
            // CassetteAI: prompt + integer duration (10–180s). Instrumental by nature.
            let duration = max(10, min(180, audio.durationSeconds ?? 30))
            return ["prompt": audio.prompt, "duration": duration]
        default:
            throw GenerationBackendError.transport("Unknown fal model '\(model)'")
        }
    }

    // MARK: - Job synthesis

    private static func makeJob(
        _ jobId: String,
        status: BackendGenerationStatus,
        resultUrls: [String]? = nil,
        errorMessage: String? = nil
    ) -> BackendGenerationJob {
        BackendGenerationJob(
            _id: jobId,
            status: status,
            resultUrls: resultUrls,
            errorMessage: errorMessage,
            costCredits: nil,
            completedAt: status == .succeeded ? Date().timeIntervalSince1970 : nil
        )
    }

    private static func assertHTTPOK(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GenerationBackendError.transport("Non-HTTP response from fal")
        }
        if (200..<300).contains(http.statusCode) { return }
        let detail = String(data: data, encoding: .utf8) ?? ""
        // fal error bodies are commonly { "detail": "..." } or { "detail": [{ "msg": ... }] }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let msg = obj["detail"] as? String {
                throw GenerationBackendError.api(status: http.statusCode, code: "fal", message: msg)
            }
            if let arr = obj["detail"] as? [[String: Any]],
               let msg = arr.first?["msg"] as? String {
                throw GenerationBackendError.api(status: http.statusCode, code: "fal", message: msg)
            }
        }
        throw GenerationBackendError.transport("fal HTTP \(http.statusCode): \(detail)")
    }
}

// MARK: - fal queue DTOs

private struct QueueSubmitResponse: Decodable, Sendable {
    let request_id: String
    let status_url: String?
    let response_url: String?
}

private struct QueueStatusResponse: Decodable, Sendable {
    let status: String
}
