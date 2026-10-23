import AppKit

/// `koma://play?project=<path>&start=<s>&end=<s>` or `&marker=<name or id>`; see docs/markers-and-play-range.md.
@MainActor
final class KomaURLHandler: NSObject {
    static let shared = KomaURLHandler()

    private var pending: [URL] = []
    private var isReady = false

    func install() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    /// Call once the home window and services are up; replays URLs that arrived during launch.
    func launchFinished() {
        isReady = true
        let queued = pending
        pending.removeAll()
        queued.forEach(handle)
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        if isReady { handle(url) } else { pending.append(url) }
    }

    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "koma" else { return }
        switch url.host?.lowercased() {
        case "play":
            let request = Self.playRequest(from: url)
            Log.project.notice("url play project=\(request.project ?? "active") marker=\(request.marker ?? "-")")
            Task { @MainActor in
                do {
                    _ = try await RangePlayback.perform(request)
                } catch {
                    Self.presentFailure(error)
                }
            }
        default:
            Log.project.warning("url ignored: \(url.absoluteString)")
        }
    }

    /// `+` reads as a space, as in form encoding; a literal plus must be sent as `%2B`.
    static func playRequest(from url: URL) -> RangePlayback.Request {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        components.percentEncodedQuery = query
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value, !value.isEmpty { values[item.name.lowercased()] = value }
        }
        return RangePlayback.Request(
            project: values["project"],
            start: values["start"].map { Double($0) ?? .nan },
            end: values["end"].map { Double($0) ?? .nan },
            marker: values["marker"]
        )
    }

    private static func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Can't Play Range"
        alert.informativeText = (error as? ToolError)?.message ?? error.localizedDescription
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
