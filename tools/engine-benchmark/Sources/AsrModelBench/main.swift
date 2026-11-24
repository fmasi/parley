// ASR model comparison for #350 (Encoder_v2) and #338 (Parakeet Ultra).
//
// One configuration per process, so `/usr/bin/time -l` reports that configuration's own peak memory
// footprint. Mirrors the app's FluidAudioEngine path: load the models, then per file a fresh
// TdtDecoderState and `AsrManager.transcribe(url, decoderState:, language: nil)` (the URL overload,
// which goes disk-backed for long files exactly as a recording chunk does). No ITN: the hypothesis is
// FluidAudio's raw text, the same for every configuration.
//
// Models go to a benchmark-only folder (--models-dir), never the app's FluidAudio cache.
//
// Usage:
//   AsrModelBench --config v3-int8|v3-int8v2|ultra --models-dir DIR --out results.json [--download-only] FILE_OR_DIR...
// Output JSON: { config, fluidaudio, loadSeconds, files: [{ file, durationSeconds, seconds, text, error? }] }

import AVFoundation
import FluidAudio
import Foundation

struct Config {
    let name: String
    let version: AsrModelVersion
    let precision: ParakeetEncoderPrecision
}

let configs: [String: Config] = [
    "v3-int8": Config(name: "v3-int8", version: .v3, precision: .int8),
    "v3-int8v2": Config(name: "v3-int8v2", version: .v3, precision: .int8V2),
    "ultra": Config(name: "ultra", version: .ultra, precision: .int8),
]

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(2)
}

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

func audioFiles(_ paths: [String]) -> [URL] {
    let exts: Set<String> = ["wav", "flac", "m4a", "mp3"]
    var out: [URL] = []
    for p in paths {
        let url = URL(fileURLWithPath: p)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { fail("no such file: \(p)") }
        if isDir.boolValue {
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            out += items.filter { exts.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            out.append(url)
        }
    }
    return out
}

@main
struct AsrModelBench {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        var configName: String?
        var modelsDir: String?
        var outPath: String?
        var downloadOnly = false
        var inputs: [String] = []
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--config": configName = args.isEmpty ? nil : args.removeFirst()
            case "--models-dir": modelsDir = args.isEmpty ? nil : args.removeFirst()
            case "--out": outPath = args.isEmpty ? nil : args.removeFirst()
            case "--download-only": downloadOnly = true
            default: inputs.append(a)
            }
        }
        guard let configName, let cfg = configs[configName] else {
            fail("--config must be one of \(configs.keys.sorted().joined(separator: ", "))")
        }
        guard let modelsDir else { fail("--models-dir is required") }

        // Same leaf folder name FluidAudio uses in its own cache, under the benchmark's root.
        let repoDir = URL(fileURLWithPath: modelsDir)
            .appendingPathComponent(AsrModels.defaultCacheDirectory(for: cfg.version).lastPathComponent)

        if downloadOnly || !AsrModels.modelsExist(at: repoDir, version: cfg.version, encoderPrecision: cfg.precision) {
            print("[\(cfg.name)] downloading to \(repoDir.path) ...")
            do {
                try await AsrModels.download(to: repoDir, version: cfg.version, encoderPrecision: cfg.precision)
            } catch {
                fail("download failed for \(cfg.name): \(error)")
            }
            if downloadOnly {
                print("[\(cfg.name)] downloaded")
                return
            }
        }

        let loadStart = ContinuousClock.now
        let manager: AsrManager
        do {
            let models = try await AsrModels.load(from: repoDir, version: cfg.version, encoderPrecision: cfg.precision)
            manager = AsrManager()
            try await manager.loadModels(models)
        } catch {
            fail("load failed for \(cfg.name): \(error)")
        }
        let loadSeconds = seconds(ContinuousClock.now - loadStart)
        print("[\(cfg.name)] loaded in \(String(format: "%.2f", loadSeconds)) s")

        var rows: [[String: Any]] = []
        for url in audioFiles(inputs) {
            var duration = 0.0
            if let f = try? AVAudioFile(forReading: url) {
                duration = Double(f.length) / f.processingFormat.sampleRate
            }
            let start = ContinuousClock.now
            var row: [String: Any] = ["file": url.lastPathComponent, "durationSeconds": duration]
            do {
                var state = try TdtDecoderState()
                let result = try await manager.transcribe(url, decoderState: &state, language: nil)
                row["text"] = result.text
            } catch {
                row["text"] = ""
                row["error"] = "\(error)"
            }
            let s = seconds(ContinuousClock.now - start)
            row["seconds"] = s
            rows.append(row)
            print("[\(cfg.name)] \(url.lastPathComponent) \(String(format: "%.1f", duration)) s audio in \(String(format: "%.2f", s)) s (\(String(format: "%.0f", duration / max(s, 1e-9)))x)")
        }

        let report: [String: Any] = [
            "config": cfg.name, "fluidaudio": "0.17.7", "loadSeconds": loadSeconds, "files": rows,
        ]
        if let outPath {
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: outPath))
            } catch {
                fail("could not write \(outPath): \(error)")
            }
        }
    }
}
