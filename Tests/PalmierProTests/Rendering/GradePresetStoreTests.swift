import Testing
import Foundation
@testable import PalmierPro

/// The user-preset store against an isolated temp directory (never the real app-support folder).
@Suite("GradePresetStore")
struct GradePresetStoreTests {

    private func makeStore() -> (GradePresetStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grade-presets-\(UUID().uuidString)", isDirectory: true)
        return (GradePresetStore(directory: dir), dir)
    }

    @Test func saveListDeleteRoundTrip() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var grade = ColorGrade(lut: "teal-orange", exposure: 0.5)
        grade.hsl.saturation[1] = -0.4
        grade.curves.rgb = [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 1, y: 0.95)]
        grade.wheels.gain = WheelAdjust(r: 0.2)

        let saved = try store.save(name: "  Moody Teal  ", grade: grade)
        #expect(saved.name == "Moody Teal")   // trimmed
        #expect(store.all().count == 1)
        #expect(store.preset(id: saved.id)?.grade == grade)

        // A fresh store over the same folder re-registers from disk (launch warm()).
        let reloaded = GradePresetStore(directory: dir)
        reloaded.warm()
        #expect(reloaded.preset(id: saved.id)?.grade == grade)

        try store.delete(id: saved.id)
        #expect(store.all().isEmpty)
        let reloaded2 = GradePresetStore(directory: dir)
        reloaded2.warm()
        #expect(reloaded2.all().isEmpty)
    }

    @Test func rejectsEmptyNamesAndUnknownIds() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: GradePresetStore.PresetError.self) {
            try store.save(name: "   ", grade: ColorGrade(exposure: 1))
        }
        #expect(throws: GradePresetStore.PresetError.self) {
            try store.delete(id: "nope")
        }
    }
}
