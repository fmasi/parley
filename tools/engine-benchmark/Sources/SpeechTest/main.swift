// Standalone SpeechAnalyzer locale test
// Usage: swift run --package-path tools/engine-benchmark SpeechTest <audio.wav> <locale>
// Example: swift run --package-path tools/engine-benchmark SpeechTest fr-00.wav fr-FR

import Foundation
import AVFoundation
import Speech

@available(macOS 26.0, *)
func testSpeechAnalyzer(audioPath: URL, localeId: String) async {
    let locale = Locale(identifier: localeId)

    print("=== SpeechAnalyzer Locale Test ===")
    print("Audio: \(audioPath.lastPathComponent)")
    print("Locale: \(locale.identifier)")
    print("")

    // Step 1: Check installed locales
    print("[1] Checking installed locales...")
    let installed = await SpeechTranscriber.installedLocales
    print("    Installed: \(installed.map(\.identifier).sorted())")
    print("    \(localeId) installed: \(installed.contains(locale))")
    print("")

    // Step 2: Create transcriber
    print("[2] Creating SpeechTranscriber(\(localeId))...")
    let transcriber = SpeechTranscriber(
        locale: locale,
        preset: SpeechTranscriber.Preset(
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    )
    print("    Created OK")
    print("")

    // Step 4: Try to download model if not installed
    if !installed.contains(locale) {
        print("[4] Attempting model download via AssetInventory...")
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                print("    Download request obtained, downloading...")
                try await request.downloadAndInstall()
                print("    Download complete")
            } else {
                print("    No download request returned (model may not exist for this locale)")
            }
        } catch {
            print("    Download error: \(error)")
        }

        // Re-check
        let installed2 = await SpeechTranscriber.installedLocales
        print("    \(localeId) now installed: \(installed2.contains(locale))")
        print("")
    }

    // Step 5: Try transcription with hard 15s timeout via DispatchQueue
    print("[5] Starting transcription (15s hard timeout)...")
    let start = ContinuousClock.now

    // Hard timeout using DispatchQueue
    let timedOut = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
    timedOut.pointee = false
    DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
        if !timedOut.pointee {
            timedOut.pointee = true
            print("    *** HARD TIMEOUT at 15s — SpeechAnalyzer hung ***")
            print("    This locale is not usable.")
            Foundation.exit(1)
        }
    }

    do {
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: audioPath)
        print("    Audio file opened: \(audioFile.length) frames, \(audioFile.processingFormat.sampleRate)Hz")

        print("    Calling analyzeSequence...")
        let analysisTask = Task {
            do {
                if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                    print("    analyzeSequence returned lastSample, calling finalizeAndFinish...")
                    try await analyzer.finalizeAndFinish(through: lastSample)
                    print("    finalizeAndFinish complete")
                } else {
                    print("    analyzeSequence returned nil, calling cancelAndFinishNow...")
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                print("    analyzeSequence error: \(error)")
                await analyzer.cancelAndFinishNow()
                throw error
            }
        }

        print("    Waiting for results...")
        var allText = ""
        var segCount = 0
        for try await result in transcriber.results {
            if result.isFinal {
                segCount += 1
                let text = String(result.text.characters)
                allText += text + " "
                print("    Segment \(segCount): \(text.prefix(60))")
            }
        }
        try await analysisTask.value
        timedOut.pointee = true  // cancel the timeout

        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("")
        print("=== SUCCESS ===")
        print("Time: \(String(format: "%.1f", seconds))s")
        print("Segments: \(segCount)")
        print("Text: \(allText.trimmingCharacters(in: .whitespaces))")
    } catch {
        timedOut.pointee = true
        print("    ERROR: \(error)")
    }

    timedOut.deallocate()
}

// Entry point
@main
struct SpeechTest {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("Usage: SpeechTest <audio.wav> <locale>")
            print("Example: SpeechTest ~/Library/Application Support/Parley/benchmark/test-audio/fr-00.wav fr-FR")
            Foundation.exit(1)
        }

        let audioPath = URL(fileURLWithPath: args[1])
        let localeId = args[2]

        if #available(macOS 26.0, *) {
            await testSpeechAnalyzer(audioPath: audioPath, localeId: localeId)
        } else {
            print("Requires macOS 26.0+")
        }
    }
}
