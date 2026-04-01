import Foundation
import os
import WhisperKit

public struct ModelInfo: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let huggingFaceRepo: String
    public let approximateSizeMB: Int
}

@MainActor
@Observable
public final class ModelManager {
    public let storagePath: URL
    public var downloadProgress: Double = 0
    public var isDownloading = false
    public var downloadError: String?

    public static let availableModels: [ModelInfo] = [
        ModelInfo(
            id: "large-v3-turbo",
            displayName: "Fast (recommended)",
            huggingFaceRepo: "argmaxinc/whisperkit-coreml",
            approximateSizeMB: 1600
        ),
        ModelInfo(
            id: "large-v3",
            displayName: "High Quality",
            huggingFaceRepo: "argmaxinc/whisperkit-coreml",
            approximateSizeMB: 3000
        ),
    ]

    public init(storagePath: URL? = nil) {
        self.storagePath = storagePath ?? Self.resolveStoragePath("~/.audio-transcribe/models")
    }

    public nonisolated static func resolveStoragePath(_ path: String) -> URL {
        if path.hasPrefix("~") {
            let expanded = NSString(string: path).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
        return URL(fileURLWithPath: path)
    }

    public nonisolated func isModelDownloaded(_ modelId: String) -> Bool {
        let modelDir = storagePath.appendingPathComponent(modelId)
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    public func downloadModel(_ modelId: String) async throws {
        guard let info = Self.availableModels.first(where: { $0.id == modelId }) else {
            throw ModelManagerError.unknownModel(modelId)
        }

        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        Logger.transcription.info("Starting model download: \(modelId, privacy: .public) from \(info.huggingFaceRepo, privacy: .public)")

        do {
            // WhisperKit.download returns the path to the downloaded model folder.
            // We pass storagePath as downloadBase so WhisperKit places files under our directory.
            let downloadedURL = try await WhisperKit.download(
                variant: modelId,
                downloadBase: storagePath,
                from: info.huggingFaceRepo,
                progressCallback: { progress in
                    Task { @MainActor in
                        self.downloadProgress = progress.fractionCompleted
                    }
                }
            )

            // WhisperKit returns the folder that contains the model files.
            // Ensure it ended up at storagePath/modelId; move if needed.
            let targetDir = storagePath.appendingPathComponent(modelId)
            if downloadedURL.standardizedFileURL != targetDir.standardizedFileURL {
                try FileManager.default.createDirectory(
                    at: storagePath, withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: targetDir.path) {
                    try FileManager.default.removeItem(at: targetDir)
                }
                try FileManager.default.moveItem(at: downloadedURL, to: targetDir)
            }

            Logger.transcription.info("Model downloaded successfully: \(modelId, privacy: .public)")
            isDownloading = false
            downloadProgress = 1.0
        } catch {
            Logger.transcription.error("Model download failed: \(modelId, privacy: .public) — \(error, privacy: .public)")
            isDownloading = false
            downloadError = error.localizedDescription
            throw error
        }
    }

    public func modelPath(for modelId: String) -> URL {
        storagePath.appendingPathComponent(modelId)
    }

    public enum ModelManagerError: LocalizedError {
        case unknownModel(String)

        public var errorDescription: String? {
            switch self {
            case .unknownModel(let id): return "Unknown model: \(id)"
            }
        }
    }
}
