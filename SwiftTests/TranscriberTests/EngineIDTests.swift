import Testing
import Foundation
@testable import TranscriberCore

struct EngineIDTests {

    @Test func allCasesContainsTwoEngines() {
        #expect(EngineID.allCases.count == 2)
        #expect(EngineID.allCases.contains(.speechAnalyzer))
        #expect(EngineID.allCases.contains(.fluidAudio))
    }

    @Test func defaultIsSpeechAnalyzer() {
        #expect(EngineID.default == .speechAnalyzer)
    }

    @Test func codableRoundTrip() throws {
        for id in EngineID.allCases {
            let data = try JSONEncoder().encode(id)
            let decoded = try JSONDecoder().decode(EngineID.self, from: data)
            #expect(decoded == id)
        }
    }

    @Test func rawValuesAreSnakeCase() {
        #expect(EngineID.speechAnalyzer.rawValue == "speech_analyzer")
        #expect(EngineID.fluidAudio.rawValue == "fluid_audio")
    }

    @Test func descriptorExistsForEveryEngine() {
        for id in EngineID.allCases {
            let d = id.descriptor
            #expect(!d.displayName.isEmpty)
            #expect(!d.description.isEmpty)
        }
    }

    @Test func speechAnalyzerDescriptorNoDownload() {
        let d = EngineID.speechAnalyzer.descriptor
        #expect(d.requiresModelDownload == false)
        #expect(d.approximateSizeMB == 0)
        #expect(d.minimumMacOS == "26.0")
    }

    @Test func fluidAudioDescriptorDetails() {
        let d = EngineID.fluidAudio.descriptor
        #expect(d.requiresModelDownload == true)
        #expect(d.minimumMacOS == "15.0")
    }

    @Test func availableEnginesExcludeUnavailable() {
        let available = EngineID.availableEngines
        // On any macOS version, at least FluidAudio is available
        #expect(available.contains(.fluidAudio))
    }

    @Test func resolvedDefaultFallsBackWhenUnavailable() {
        // resolvedDefault should return an engine that is available on this OS
        let resolved = EngineID.resolvedDefault
        #expect(EngineID.availableEngines.contains(resolved))
    }

    @Test func decodesUnknownEngineToResolvedDefault() throws {
        let json = Data("\"some_future_engine\"".utf8)
        let decoded = try JSONDecoder().decode(EngineID.self, from: json)
        #expect(decoded == .resolvedDefault)
    }

    @Test func speechAnalyzerNeverRequiresDownload() {
        // SpeechAnalyzer uses the system framework — no model gate needed
        #expect(EngineID.speechAnalyzer.descriptor.requiresModelDownload == false)
    }

    @Test func fluidAudioRequiresDownload() {
        // FluidAudio must be gated on model download in Setup/Settings
        #expect(EngineID.fluidAudio.descriptor.requiresModelDownload == true)
        #expect(EngineID.fluidAudio.descriptor.approximateSizeMB > 0)
    }
}
