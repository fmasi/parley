import Foundation
import os

/// The speaker analysis of the channel the open rename dialog last re-detected (#341): its
/// segmentation and speaker embeddings, so a Re-detect at another count clusters again instead of
/// decoding the audio and running the models over it again. On a long call that is the difference
/// between minutes and seconds, and #265's pass with room for one more voice reuses it too.
///
/// One per rename dialog, closed when the dialog closes (`close`). It holds ONE analysis: a channel
/// or a recording other than the one held releases the held analysis before the new one is decoded
/// (`lookup`), so a long call's audio and embeddings are never in memory twice — an hour of channel audio
/// is about 0.36 GB held (`PreparedSpeakerAnalysis`). A recording's start and memory pressure release
/// it too (`releaseAll`), while the dialog stays open: its next Re-detect then runs a full pass.
///
/// In memory only, never on disk: an analysis never outlives the process, so a FluidAudio update can
/// never be served one its predecessor made.
public actor SpeakerAnalysisCache {
    /// What an analysis was made from. Any difference is a different analysis.
    public struct Key: Hashable, Sendable {
        /// One audio file a channel is decoded from, as it was on disk.
        public struct File: Hashable, Sendable {
            public let path: String
            /// nil when the file could not be read: a key that never matches one made while it could.
            public let size: Int?
            public let modified: Date?

            public init(path: String, size: Int?, modified: Date?) {
                self.path = path
                self.size = size
                self.modified = modified
            }

            /// The file as it is on disk now: a stat, never a URL's cached resource values (a `URL`
            /// keeps those, so a file changed since the same URL last looked would read as unchanged).
            public static func current(_ url: URL) -> File {
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return File(path: url.path, size: (attributes?[.size] as? NSNumber)?.intValue,
                            modified: attributes?[.modificationDate] as? Date)
            }
        }

        public let source: String
        /// `SpeakerAnalysisReusing.preparationIdentity`.
        public let provider: String
        public let files: [File]
        /// Whether the mic was echo-cancelled before the analysis (#342), and by what.
        public let echoCanceller: String?
        /// The transcript's timeline inputs the decode reads: chunk lengths, offsets and capture gaps.
        public let chunkDurations: [Double]
        public let chunkOffsets: [Double]?
        public let gapSeconds: [Double]
        public let hasCaptureGaps: Bool

        public init(source: String, provider: String, files: [File], echoCanceller: String?,
                    chunkDurations: [Double], chunkOffsets: [Double]?, gapSeconds: [Double], hasCaptureGaps: Bool) {
            self.source = source
            self.provider = provider
            self.files = files
            self.echoCanceller = echoCanceller
            self.chunkDurations = chunkDurations
            self.chunkOffsets = chunkOffsets
            self.gapSeconds = gapSeconds
            self.hasCaptureGaps = hasCaptureGaps
        }
    }

    private var held: (key: Key, analysis: PreparedSpeakerAnalysis)?
    private var closed = false
    /// Whether a `store` is taken: false after a release (`release(_:)`, `close`) until the next
    /// `lookup`, so a re-detect that was already running when a recording started does not put back
    /// what the start released.
    private var storeAllowed = true

    public init() {
        Self.register(self)
    }

    /// The analysis made from `key`, or nil. On a miss the analysis held for another key is released
    /// here, before the caller decodes and prepares the new one: never two at once.
    public func lookup(_ key: Key) -> PreparedSpeakerAnalysis? {
        storeAllowed = !closed
        if let held, held.key == key { return held.analysis }
        drop()
        return nil
    }

    /// Keep `analysis` for `key`, in place of whatever was held. Refused once the dialog closed (a
    /// re-detect cancelled by the close can still finish its preparation, and must not leave it held)
    /// and after a release until the next lookup.
    public func store(_ analysis: PreparedSpeakerAnalysis, for key: Key) {
        guard storeAllowed else {
            Logger.transcription.info(
                "Re-detect: speaker analysis not kept (\(self.closed ? "the dialog closed" : "released meanwhile", privacy: .public)) — \(analysis.sampleCount / 16_000, privacy: .public) s of audio, \(analysis.embeddingCount, privacy: .public) embeddings")
            return
        }
        held = (key, analysis)
        Logger.transcription.info(
            "Re-detect: speaker analysis kept for the dialog — \(analysis.sampleCount / 16_000, privacy: .public) s of audio, \(analysis.embeddingCount, privacy: .public) embeddings")
    }

    /// The dialog closed: release the analysis and keep none from now on.
    public func close() {
        closed = true
        storeAllowed = false
        drop()
    }

    /// Why a held analysis is let go while its dialog stays open. The next Re-detect then misses and
    /// runs a full pass, which is all it costs.
    public enum ReleaseReason: String, Sendable {
        /// A recording started: its chunk processing (ASR + diarization, about 1.4 GB per 30-minute
        /// chunk) must not run on top of a dialog's analysis left open from an earlier call (about
        /// 0.72 GB for two hours).
        case recordingStarted = "a recording started"
        /// The system reported memory pressure (warning or critical).
        case memoryPressure = "memory pressure"
    }

    /// Let the analysis go; the dialog stays usable and its next Re-detect misses.
    public func release(_ reason: ReleaseReason) {
        storeAllowed = false
        guard held != nil else { return }
        held = nil
        Logger.transcription.info("Re-detect: speaker analysis released (\(reason.rawValue, privacy: .public))")
    }

    private func drop() {
        guard held != nil else { return }
        held = nil
        Logger.transcription.info("Re-detect: speaker analysis released")
    }

    // MARK: - Every open cache (#341 review)

    private final class Weak: @unchecked Sendable {
        // Set once at init; a weak load is atomic, and the list holding the boxes is behind the lock below.
        weak var cache: SpeakerAnalysisCache?
        init(_ cache: SpeakerAnalysisCache) { self.cache = cache }
    }
    private static let open = OSAllocatedUnfairLock(initialState: [Weak]())

    private nonisolated static func register(_ cache: SpeakerAnalysisCache) {
        open.withLock { list in
            list.removeAll { $0.cache == nil }
            list.append(Weak(cache))
        }
        _ = memoryPressureWatch
    }

    /// Release the analysis of every cache still open, for `reason`. Callable from any thread; each
    /// release runs on its cache's actor shortly after.
    public static func releaseAll(_ reason: ReleaseReason) {
        let caches = open.withLock { list -> [SpeakerAnalysisCache] in
            list.removeAll { $0.cache == nil }
            return list.compactMap(\.cache)
        }
        for cache in caches { Task { await cache.release(reason) } }
    }

    /// Whether a memory-pressure event releases the analyses: a warning or worse does.
    static func releasesOnPressure(_ event: DispatchSource.MemoryPressureEvent) -> Bool {
        !event.intersection([.warning, .critical]).isEmpty
    }

    /// Watches the system's memory pressure for as long as the process runs, from the first cache made.
    private static let memoryPressureWatch: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler {
            if releasesOnPressure(source.data) { releaseAll(.memoryPressure) }
        }
        source.resume()
        return source
    }()

    /// The key of the analysis held, if any (tests).
    var heldKey: Key? { held?.key }
}
