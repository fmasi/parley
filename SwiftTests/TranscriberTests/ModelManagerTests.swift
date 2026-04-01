import Testing
import Foundation
@testable import TranscriberCore

struct ModelManagerTests {

    @Test func resolveStoragePathExpandsTilde() {
        let path = ModelManager.resolveStoragePath("~/.audio-transcribe/models")
        #expect(!path.path.contains("~"))
        #expect(path.path.contains("audio-transcribe/models"))
    }

    @Test func resolveStoragePathAbsolute() {
        let path = ModelManager.resolveStoragePath("/tmp/models")
        #expect(path.path == "/tmp/models")
    }

    @Test func availableModelsContainsTurboAndLargeV3() {
        let models = ModelManager.availableModels
        #expect(models.contains { $0.id == "large-v3-turbo" })
        #expect(models.contains { $0.id == "large-v3" })
    }

    @Test func modelInfoForTurbo() {
        let info = ModelManager.availableModels.first { $0.id == "large-v3-turbo" }!
        #expect(info.displayName == "Fast (recommended)")
        #expect(info.huggingFaceRepo.contains("whisperkit"))
    }

    @Test func modelInfoForLargeV3() {
        let info = ModelManager.availableModels.first { $0.id == "large-v3" }!
        #expect(info.displayName == "High Quality")
    }

    @Test @MainActor func isModelDownloadedReturnsFalseForMissingDir() {
        let manager = ModelManager(storagePath: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)"))
        #expect(manager.isModelDownloaded("large-v3-turbo") == false)
    }
}
