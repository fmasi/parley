import CoreML
import Foundation
import Testing
@testable import TranscriberCore

/// `diarization_compute_units`: where the diarizer's models run. The default keeps FluidAudio's own
/// loading exactly; the Neural Engine measured the same speakers at about half the memory.
@Suite struct DiarizationComputeUnitsTests {
    private func decode(_ value: Any?) throws -> Config {
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config.default)) as? [String: Any])
        json["diarization_compute_units"] = value
        return try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func defaultsToCoreMLsOwnChoice() throws {
        #expect(Config.default.diarizationComputeUnits == .all)
        #expect(try decode(nil).diarizationComputeUnits == .all)
        #expect(FluidAudioDiarizer().computeUnitsSetting == .all)
    }

    @Test func readsTheNeuralEngineAndCPUAndWritesThemBack() throws {
        let ane = try decode("neural_engine")
        #expect(ane.diarizationComputeUnits == .neuralEngine)
        #expect(try decode("cpu_only").diarizationComputeUnits == .cpuOnly)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ane)) as? [String: Any]
        #expect(json?["diarization_compute_units"] as? String == "neural_engine")
    }

    @Test func readsAnUnknownValueAsTheDefaultInsteadOfFailingTheConfig() throws {
        #expect(try decode("gpu_only").diarizationComputeUnits == .all)
    }

    @Test func theDefaultLoadsExactlyAsBefore() {
        #expect(DiarizationComputeUnits.all.modelConfiguration == nil)
    }

    @Test func eachChoiceLoadsOnItsUnits() {
        #expect(DiarizationComputeUnits.neuralEngine.modelConfiguration?.computeUnits == .cpuAndNeuralEngine)
        #expect(DiarizationComputeUnits.cpuOnly.modelConfiguration?.computeUnits == .cpuOnly)
    }

    @Test func theDiarizerCarriesTheChoice() {
        #expect(FluidAudioDiarizer(computeUnits: .neuralEngine).computeUnitsSetting == .neuralEngine)
    }
}
