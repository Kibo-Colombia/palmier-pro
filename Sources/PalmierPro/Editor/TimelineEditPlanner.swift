import CryptoKit
import Foundation

struct TimelineEditRequest: DecodableToolArgs {
    var projectId: String?
    let expectedRevision: String
    let operationId: String
    var dryRun: Bool?
    var collisionPolicy: String?
    var operations: [TimelineEditOperation]

    static let allowedKeys: Set<String> = ["projectId", "expectedRevision", "operationId", "dryRun", "collisionPolicy", "operations"]
}

struct TimelineEditOperation: Decodable {
    let type: String
    var clipId: String?
    var trackId: String?
    var startFrame: Int?
    var endFrame: Int?
    var durationFrames: Int?
    var volume: Double?
    var opacity: Double?
    var fadeInFrames: Int?
    var fadeOutFrames: Int?
    var clearVolumeAutomation: Bool?
    var transform: ParsedTransform?
    var muted: Bool?
    var hidden: Bool?
    var syncLocked: Bool?
    var clips: [BeatEditMember]?
    var rippleTrackIds: [String]?

    static func allowedKeys(for type: String) throws -> Set<String> {
        switch type {
        case "move_clip": return ["type", "clipId", "trackId", "startFrame"]
        case "resize_clip": return ["type", "clipId", "durationFrames"]
        case "set_clip": return ["type", "clipId", "volume", "opacity", "fadeInFrames", "fadeOutFrames", "clearVolumeAutomation", "transform"]
        case "set_track": return ["type", "trackId", "muted", "hidden", "syncLocked"]
        case "remove_clip": return ["type", "clipId"]
        case "resize_beat": return ["type", "startFrame", "endFrame", "durationFrames", "clips", "rippleTrackIds"]
        default: throw ToolError("Unknown edit operation: \(type)")
        }
    }
}

struct BeatEditMember: Decodable {
    let clipId: String
    let role: String
}

struct ClipEditChange: Encodable {
    let clipId: String
    let beforeTrackId: String?
    let afterTrackId: String?
    let before: Clip?
    let after: Clip?
}

struct TrackEditChange: Encodable {
    let trackId: String
    let beforeMuted: Bool
    let afterMuted: Bool
    let beforeHidden: Bool
    let afterHidden: Bool
    let beforeSyncLocked: Bool
    let afterSyncLocked: Bool
}

struct TimelineEditPlan {
    let timeline: Timeline
    let clipChanges: [ClipEditChange]
    let trackChanges: [TrackEditChange]
}

struct TimelineEditReceipt {
    let payloadHash: String
    let resultJSON: String
}

enum TimelineEditPlanner {
    static func revision(timeline: Timeline, manifest: MediaManifest = MediaManifest()) throws -> String {
        struct Snapshot: Encodable { let timeline: Timeline; let manifest: MediaManifest }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return hash(try encoder.encode(Snapshot(timeline: timeline, manifest: manifest)))
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validateShapes(_ args: [String: Any]) throws {
        guard let rawOperations = args["operations"] as? [[String: Any]] else {
            throw ToolError("operations must be an array of objects")
        }
        for (index, operation) in rawOperations.enumerated() {
            let path = "operations[\(index)]"
            let type = try operation.requireString("type")
            try validateUnknownKeys(operation, allowed: TimelineEditOperation.allowedKeys(for: type), path: path)
            if let transform = operation["transform"] as? [String: Any] {
                try validateUnknownKeys(transform, allowed: ["centerX", "centerY", "width", "height", "flipHorizontal", "flipVertical"], path: path + ".transform")
            }
            if let members = operation["clips"] as? [[String: Any]] {
                for (memberIndex, member) in members.enumerated() {
                    try validateUnknownKeys(member, allowed: ["clipId", "role"], path: path + ".clips[\(memberIndex)]")
                }
            }
        }
    }

    static func plan(timeline original: Timeline, operations: [TimelineEditOperation], collisionPolicy: String = "reject") throws -> TimelineEditPlan {
        guard ["reject", "overwrite"].contains(collisionPolicy) else {
            throw ToolError("collisionPolicy must be reject or overwrite; resize_beat supplies explicit ripple tracks")
        }
        guard !operations.isEmpty else { throw ToolError("operations must not be empty") }
        try validateIDs(original)
        try validateLinkedOperations(operations, timeline: original)
        var draft = original
        for operation in operations {
            switch operation.type {
            case "move_clip":
                let id = try required(operation.clipId, "clipId")
                let location = try locate(id, in: draft)
                guard operation.trackId != nil || operation.startFrame != nil else {
                    throw ToolError("move_clip needs trackId or startFrame")
                }
                let target = try operation.trackId.map { try trackIndex($0, in: draft) } ?? location.trackIndex
                guard draft.tracks[target].type.isCompatible(with: draft.tracks[location.trackIndex].type) else {
                    throw ToolError("Incompatible destination track for clip \(id)")
                }
                var clip = draft.tracks[location.trackIndex].clips.remove(at: location.clipIndex)
                if let frame = operation.startFrame { clip.startFrame = frame }
                try validateClip(clip)
                draft.tracks[target].clips.append(clip)
            case "resize_clip":
                let id = try required(operation.clipId, "clipId")
                let location = try locate(id, in: draft)
                guard let duration = operation.durationFrames else { throw ToolError("resize_clip needs durationFrames") }
                try setDuration(duration, at: location, in: &draft)
            case "set_clip":
                let id = try required(operation.clipId, "clipId")
                let location = try locate(id, in: draft)
                var clip = draft.tracks[location.trackIndex].clips[location.clipIndex]
                guard operation.volume != nil || operation.opacity != nil || operation.fadeInFrames != nil || operation.fadeOutFrames != nil || operation.clearVolumeAutomation != nil || operation.transform != nil else {
                    throw ToolError("set_clip needs a property")
                }
                if let volume = operation.volume {
                    guard (0...1).contains(volume) else { throw ToolError("volume must be between 0 and 1") }
                    clip.volume = volume
                }
                if let opacity = operation.opacity { clip.opacity = opacity }
                if let fade = operation.fadeInFrames { clip.fadeInFrames = fade }
                if let fade = operation.fadeOutFrames { clip.fadeOutFrames = fade }
                if operation.clearVolumeAutomation == true { clip.volumeTrack = nil }
                if let transform = operation.transform {
                    let current = clip.transform
                    var next = Transform(center: (transform.centerX ?? current.center.x, transform.centerY ?? current.center.y), width: transform.width ?? current.width, height: transform.height ?? current.height)
                    next.rotation = current.rotation
                    next.flipHorizontal = transform.flipHorizontal ?? current.flipHorizontal
                    next.flipVertical = transform.flipVertical ?? current.flipVertical
                    clip.transform = next
                }
                try validateClip(clip)
                draft.tracks[location.trackIndex].clips[location.clipIndex] = clip
            case "set_track":
                let index = try trackIndex(required(operation.trackId, "trackId"), in: draft)
                guard operation.muted != nil || operation.hidden != nil || operation.syncLocked != nil else {
                    throw ToolError("set_track needs muted, hidden, or syncLocked")
                }
                if let value = operation.muted { draft.tracks[index].muted = value }
                if let value = operation.hidden { draft.tracks[index].hidden = value }
                if let value = operation.syncLocked { draft.tracks[index].syncLocked = value }
            case "remove_clip":
                let location = try locate(required(operation.clipId, "clipId"), in: draft)
                draft.tracks[location.trackIndex].clips.remove(at: location.clipIndex)
            case "resize_beat":
                guard collisionPolicy == "reject" else { throw ToolError("resize_beat requires collisionPolicy reject") }
                try resizeBeat(operation, in: &draft)
            default: throw ToolError("Unknown edit operation: \(operation.type)")
            }
        }
        if collisionPolicy == "overwrite" { try resolveOverwrites(original: original, draft: &draft) }
        try validateIDs(draft)
        try validateCollisions(original: original, draft: draft)
        for index in draft.tracks.indices {
            draft.tracks[index].clips.sort { $0.startFrame == $1.startFrame ? $0.id < $1.id : $0.startFrame < $1.startFrame }
        }
        return makePlan(original: original, draft: draft)
    }

    @MainActor
    static func validateSourceBounds(_ plan: TimelineEditPlan, assets: [MediaAsset], fps: Int) throws {
        for change in plan.clipChanges {
            guard let clip = change.after,
                  clip.mediaType == .video || clip.mediaType == .audio || clip.mediaType == .lottie else { continue }
            let previousSourceEnd = change.before.map { Double($0.trimStartFrame) + Double($0.durationFrames) * $0.speed } ?? 0
            let sourceEnd = Double(clip.trimStartFrame) + Double(clip.durationFrames) * clip.speed
            guard sourceEnd > previousSourceEnd else { continue }
            guard let asset = assets.first(where: { $0.id == clip.mediaRef }), asset.duration > 0 else {
                throw ToolError("Cannot resize unresolved source for clip \(clip.id)")
            }
            guard sourceEnd <= (asset.duration * Double(fps)).rounded() else {
                throw ToolError("Clip \(clip.id) would extend beyond its source media")
            }
        }
    }

    private static func resizeBeat(_ operation: TimelineEditOperation, in draft: inout Timeline) throws {
        guard let start = operation.startFrame, let end = operation.endFrame, let duration = operation.durationFrames,
              start >= 0, end > start, duration > 0 else { throw ToolError("resize_beat needs a valid startFrame/endFrame and positive durationFrames") }
        let (newEnd, overflow) = start.addingReportingOverflow(duration)
        guard !overflow else { throw ToolError("Beat duration overflows frame range") }
        let delta = newEnd - end
        guard let members = operation.clips, !members.isEmpty, let rippleTracks = operation.rippleTrackIds else {
            throw ToolError("resize_beat needs clips with explicit roles and rippleTrackIds")
        }
        guard Set(members.map(\.clipId)).count == members.count, Set(rippleTracks).count == rippleTracks.count else {
            throw ToolError("resize_beat contains duplicate clips or tracks")
        }
        let roleIDs = Set(members.map(\.clipId))
        let rippleIndexes = try rippleTracks.map { try trackIndex($0, in: draft) }
        for member in members {
            let location = try locate(member.clipId, in: draft)
            var clip = draft.tracks[location.trackIndex].clips[location.clipIndex]
            guard clip.startFrame < end, clip.endFrame > start else { throw ToolError("Beat member \(clip.id) does not intersect the beat") }
            switch member.role {
            case "hold":
                guard clip.mediaType == .image || clip.mediaType == .text,
                      clip.endFrame == end else { throw ToolError("hold member \(clip.id) must be an image/text clip ending at endFrame") }
                clip.setDuration(try adding(clip.durationFrames, delta))
            case "sound_start", "sound_end":
                guard clip.mediaType == .audio, clip.startFrame >= start, clip.endFrame <= end else {
                    throw ToolError("Sound member \(clip.id) must fit inside the original beat")
                }
                if member.role == "sound_end" { clip.startFrame = try adding(clip.startFrame, delta) }
                guard clip.startFrame >= start, clip.endFrame <= newEnd else { throw ToolError("Sound member \(clip.id) would no longer fit inside the beat") }
            case "span":
                guard clip.startFrame <= start, clip.endFrame >= end else { throw ToolError("span member \(clip.id) must cover the entire beat") }
                clip.setDuration(try adding(clip.durationFrames, delta))
            default: throw ToolError("Unknown beat role: \(member.role)")
            }
            try validateClip(clip)
            draft.tracks[location.trackIndex].clips[location.clipIndex] = clip
        }
        for index in rippleIndexes {
            for clipIndex in draft.tracks[index].clips.indices {
                var clip = draft.tracks[index].clips[clipIndex]
                guard !roleIDs.contains(clip.id) else { continue }
                if clip.startFrame >= end {
                    clip.startFrame = try adding(clip.startFrame, delta)
                    try validateClip(clip)
                    draft.tracks[index].clips[clipIndex] = clip
                } else if clip.endFrame > start {
                    throw ToolError("Clip \(clip.id) intersects the beat without an explicit role")
                }
            }
        }
    }

    private static func resolveOverwrites(original: Timeline, draft: inout Timeline) throws {
        let changedIDs = Set(makePlan(original: original, draft: draft).clipChanges.compactMap { change in
            guard let after = change.after else { return nil as String? }
            let before = change.before
            return change.beforeTrackId != change.afterTrackId || before?.startFrame != after.startFrame || before?.durationFrames != after.durationFrames ? after.id : nil
        })
        for index in draft.tracks.indices {
            let placements = draft.tracks[index].clips.filter { changedIDs.contains($0.id) }
            for placement in placements {
                let victims = draft.tracks[index].clips.filter { !changedIDs.contains($0.id) && intersects($0, placement) }
                guard !victims.contains(where: { $0.linkGroupId != nil || $0.captionGroupId != nil }) else {
                    throw ToolError("Overwrite would alter linked/caption clips; edit their complete group explicitly")
                }
                let actions = OverwriteEngine.computeOverwrite(clips: victims, regionStart: placement.startFrame, regionEnd: placement.endFrame)
                for action in actions { try applyOverwrite(action, trackIndex: index, draft: &draft) }
            }
        }
    }

    private static func applyOverwrite(_ action: OverwriteEngine.Action, trackIndex: Int, draft: inout Timeline) throws {
        switch action {
        case .remove(let id):
            draft.tracks[trackIndex].clips.removeAll { $0.id == id }
        case .trimEnd(let id, let duration):
            let location = try locate(id, in: draft)
            var clip = draft.tracks[location.trackIndex].clips[location.clipIndex]
            clip.trimEndFrame += Int((Double(clip.durationFrames - duration) * clip.speed).rounded())
            clip.setDuration(duration)
            draft.tracks[location.trackIndex].clips[location.clipIndex] = clip
        case .trimStart(let id, let start, let trim, let duration):
            let location = try locate(id, in: draft)
            var clip = draft.tracks[location.trackIndex].clips[location.clipIndex]
            let offset = start - clip.startFrame
            clip.startFrame = start
            clip.trimStartFrame = trim
            trimHeadAnimations(&clip, offset: offset)
            clip.setDuration(duration)
            draft.tracks[location.trackIndex].clips[location.clipIndex] = clip
        case .split(let id, let leftDuration, _, let start, let trim, let duration):
            let location = try locate(id, in: draft)
            let original = draft.tracks[location.trackIndex].clips[location.clipIndex]
            var left = original
            left.trimEndFrame += Int((Double(original.durationFrames - leftDuration) * original.speed).rounded())
            left.setDuration(leftDuration)
            var right = original
            right.id = deterministicSplitID(id: original.id, start: start, duration: duration, trim: trim)
            right.startFrame = start
            right.trimStartFrame = trim
            trimHeadAnimations(&right, offset: start - original.startFrame)
            right.setDuration(duration)
            draft.tracks[location.trackIndex].clips[location.clipIndex] = left
            draft.tracks[location.trackIndex].clips.append(right)
        }
    }

    private static func validateCollisions(original: Timeline, draft: Timeline) throws {
        for track in draft.tracks {
            let clips = track.clips.sorted { $0.startFrame < $1.startFrame }
            for index in clips.indices {
                try validateClip(clips[index])
                for other in clips.dropFirst(index + 1) {
                    if other.startFrame >= clips[index].endFrame { break }
                    let oldTrack = original.tracks.first { $0.id == track.id }
                    let first = oldTrack?.clips.first { $0.id == clips[index].id }
                    let second = oldTrack?.clips.first { $0.id == other.id }
                    let unchangedOverlap = first?.startFrame == clips[index].startFrame && first?.durationFrames == clips[index].durationFrames && second?.startFrame == other.startFrame && second?.durationFrames == other.durationFrames
                    guard unchangedOverlap else { throw ToolError("Collision on track \(track.id): \(clips[index].id) and \(other.id)") }
                }
            }
        }
    }

    private static func validateIDs(_ timeline: Timeline) throws {
        let tracks = timeline.tracks.map(\.id)
        let clips = timeline.tracks.flatMap(\.clips).map(\.id)
        guard Set(tracks).count == tracks.count, Set(clips).count == clips.count else { throw ToolError("Timeline contains duplicate stable IDs") }
    }

    private static func validateLinkedOperations(_ operations: [TimelineEditOperation], timeline: Timeline) throws {
        let timingTypes: Set<String> = ["move_clip", "resize_clip", "remove_clip"]
        let explicitIDs = Set(operations.filter { timingTypes.contains($0.type) }.compactMap(\.clipId))
            .union(operations.flatMap { $0.clips?.map(\.clipId) ?? [] })
        let clips = timeline.tracks.flatMap(\.clips)
        for operation in operations where timingTypes.contains(operation.type) {
            guard let clip = clips.first(where: { $0.id == operation.clipId }), let group = clip.linkGroupId else { continue }
            let partners = Set(clips.filter { $0.linkGroupId == group }.map(\.id))
            guard partners.isSubset(of: explicitIDs) else { throw ToolError("Timing edit on linked clip \(clip.id) needs explicit operations for every linked partner") }
        }
    }

    private static func validateClip(_ clip: Clip) throws {
        guard clip.startFrame >= 0, clip.durationFrames > 0,
              !clip.startFrame.addingReportingOverflow(clip.durationFrames).overflow else { throw ToolError("Invalid frame range for clip \(clip.id)") }
        guard clip.volume.isFinite, clip.volume >= 0, clip.opacity.isFinite, (0...1).contains(clip.opacity) else { throw ToolError("Clip volume must be nonnegative and opacity must be between 0 and 1") }
        guard clip.fadeInFrames >= 0, clip.fadeInFrames <= clip.durationFrames, clip.fadeOutFrames >= 0, clip.fadeOutFrames <= clip.durationFrames else { throw ToolError("Clip fades must fit inside its duration") }
        let transform = clip.transform
        guard transform.width.isFinite, transform.width > 0, transform.height.isFinite, transform.height > 0,
              transform.center.x.isFinite, transform.center.y.isFinite else { throw ToolError("Clip transform must have finite coordinates and positive dimensions") }
    }

    private static func makePlan(original: Timeline, draft: Timeline) -> TimelineEditPlan {
        var before: [String: (track: String, clip: Clip)] = [:]
        var after: [String: (track: String, clip: Clip)] = [:]
        for track in original.tracks { for clip in track.clips { before[clip.id] = (track.id, clip) } }
        for track in draft.tracks { for clip in track.clips { after[clip.id] = (track.id, clip) } }
        let clipChanges = Set(before.keys).union(after.keys).sorted().compactMap { id -> ClipEditChange? in
            let old = before[id], new = after[id]
            guard old?.track != new?.track || old?.clip != new?.clip else { return nil }
            return ClipEditChange(clipId: id, beforeTrackId: old?.track, afterTrackId: new?.track, before: old?.clip, after: new?.clip)
        }
        let trackChanges = draft.tracks.compactMap { track -> TrackEditChange? in
            guard let old = original.tracks.first(where: { $0.id == track.id }), old.muted != track.muted || old.hidden != track.hidden || old.syncLocked != track.syncLocked else { return nil }
            return TrackEditChange(trackId: track.id, beforeMuted: old.muted, afterMuted: track.muted, beforeHidden: old.hidden, afterHidden: track.hidden, beforeSyncLocked: old.syncLocked, afterSyncLocked: track.syncLocked)
        }
        return TimelineEditPlan(timeline: draft, clipChanges: clipChanges, trackChanges: trackChanges)
    }

    private static func required(_ value: String?, _ field: String) throws -> String {
        guard let value, !value.isEmpty else { throw ToolError("Missing \(field)") }
        return value
    }

    private static func locate(_ id: String, in timeline: Timeline) throws -> ClipLocation {
        for index in timeline.tracks.indices {
            if let clipIndex = timeline.tracks[index].clips.firstIndex(where: { $0.id == id }) { return ClipLocation(trackIndex: index, clipIndex: clipIndex) }
        }
        throw ToolError("Clip not found: \(id)")
    }

    private static func trackIndex(_ id: String, in timeline: Timeline) throws -> Int {
        guard let index = timeline.tracks.firstIndex(where: { $0.id == id }) else { throw ToolError("Track not found: \(id)") }
        return index
    }

    private static func setDuration(_ duration: Int, at location: ClipLocation, in draft: inout Timeline) throws {
        guard duration > 0 else { throw ToolError("durationFrames must be positive") }
        var clip = draft.tracks[location.trackIndex].clips[location.clipIndex]
        clip.setDuration(duration)
        try validateClip(clip)
        draft.tracks[location.trackIndex].clips[location.clipIndex] = clip
    }

    private static func adding(_ frame: Int, _ delta: Int) throws -> Int {
        let (result, overflow) = frame.addingReportingOverflow(delta)
        guard !overflow else { throw ToolError("Edit overflows frame range") }
        return result
    }

    private static func intersects(_ first: Clip, _ second: Clip) -> Bool {
        first.startFrame < second.endFrame && second.startFrame < first.endFrame
    }

    private static func deterministicSplitID(id: String, start: Int, duration: Int, trim: Int) -> String {
        let hexadecimal = hash(Data("\(id):\(start):\(duration):\(trim)".utf8))
        let bytes = Array(hexadecimal.prefix(32))
        return [String(bytes[0..<8]), String(bytes[8..<12]), String(bytes[12..<16]), String(bytes[16..<20]), String(bytes[20..<32])].joined(separator: "-").uppercased()
    }

    private static func trimHeadAnimations(_ clip: inout Clip, offset: Int) {
        clip.opacityTrack = shifted(clip.opacityTrack, offset: offset, fallback: clip.opacity)
        clip.rotationTrack = shifted(clip.rotationTrack, offset: offset, fallback: clip.transform.rotation)
        clip.positionTrack = shifted(clip.positionTrack, offset: offset, fallback: AnimPair(a: clip.transform.center.x - clip.transform.width / 2, b: clip.transform.center.y - clip.transform.height / 2))
        clip.scaleTrack = shifted(clip.scaleTrack, offset: offset, fallback: AnimPair(a: clip.transform.width, b: clip.transform.height))
        clip.cropTrack = shifted(clip.cropTrack, offset: offset, fallback: clip.crop)
        clip.volumeTrack = shifted(clip.volumeTrack, offset: offset, fallback: 0)
        clip.gradeTrack = shifted(clip.gradeTrack, offset: offset, fallback: clip.grade)
        clip.maskTrack = shifted(clip.maskTrack, offset: offset, fallback: clip.mask)
    }

    private static func shifted<V>(_ track: KeyframeTrack<V>?, offset: Int, fallback: V) -> KeyframeTrack<V>? where V: KeyframeInterpolatable {
        guard let track, track.isActive else { return nil }
        let boundary = track.sample(at: offset, fallback: fallback)
        var keyframes = track.keyframes.filter { $0.frame > offset }.map { Keyframe(frame: $0.frame - offset, value: $0.value, interpolationOut: $0.interpolationOut) }
        keyframes.insert(Keyframe(frame: 0, value: boundary), at: 0)
        return KeyframeTrack(keyframes: keyframes)
    }
}
