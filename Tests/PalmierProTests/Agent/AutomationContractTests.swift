import Foundation
import Testing
@testable import PalmierPro

@Suite("Automation discovery")
@MainActor
struct AutomationContractTests {
    @Test func everyAdvertisedToolHasOneDefinition() {
        let names = ToolDefinitions.all.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(Set(names) == Set(ToolName.allCases))
    }

    @Test func capabilitiesWorkWithoutAnEditor() async throws {
        let executor = ToolExecutor(editorProvider: { nil })
        let result = await executor.execute(name: "get_capabilities", args: [:])
        #expect(!result.isError)
        let object = try JSONSerialization.jsonObject(with: Data(ToolHarness.textOf(result).utf8))
        let receipt = try #require(object as? [String: Any])
        #expect(receipt["apiVersion"] as? Int == 1)
        #expect((receipt["tools"] as? [String])?.contains("apply_edit") == true)
        #expect((receipt["schemaFingerprint"] as? String)?.count == 64)
        let units = receipt["audioUnits"] as? [String: Any]
        #expect(units?["projectVolumeTrack"] as? String == "db")
    }

    @Test func discoveryRejectsUnknownArguments() async {
        let executor = ToolExecutor(editorProvider: { nil })
        let result = await executor.execute(name: "get_capabilities", args: ["typo": true])
        #expect(result.isError)
    }
}
