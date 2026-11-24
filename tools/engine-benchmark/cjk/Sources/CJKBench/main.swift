// CJK + automatic-language benchmark (#339).
//
// Runs ONE engine over the FLEURS clips named in a ground-truth.json (written by fetch-fleurs.py) and appends one JSON
// line per clip: the hypothesis, the language tag the engine emitted (SenseVoice, Whisper LID), the time it took, and
// the process's peak memory so far. CER is computed afterwards by score.py, the same way for every engine.
//
// One engine per process, so the peak memory is that engine's:
//   swift run -c release CJKBench --engine sensevoice --gt <dir>/ground-truth.json --langs ja_jp,ko_kr --out r.jsonl
//
// Engines: sensevoice | sensevoice-int8 | paraformer | parakeet-ja | cohere (needs --cohere-dir) | speech
//          | whisper-lid:<model> (e.g. whisper-lid:openai_whisper-base; language ID only, no transcript)

import AVFoundation
import CoreML
import FluidAudio
import Foundation
import Speech
import WhisperKit

// MARK: - Arguments

struct Args {
    var engine = ""
    var gt = ""
    var langs: [String] = []
    var out = ""
    var cohereDir = ""
    var limit = Int.max
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let k = it.next() {
        switch k {
        case "--engine": a.engine = it.next() ?? ""
        case "--gt": a.gt = it.next() ?? ""
        case "--langs": a.langs = (it.next() ?? "").split(separator: ",").map(String.init)
        case "--out": a.out = it.next() ?? ""
        case "--cohere-dir": a.cohereDir = it.next() ?? ""
        case "--limit": a.limit = Int(it.next() ?? "") ?? Int.max
        default: FileHandle.standardError.write("ignoring \(k)\n".data(using: .utf8)!)
        }
    }
    return a
}

// MARK: - Memory

/// Physical footprint (what Activity Monitor calls Memory), in MB.
func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

/// Peak resident size of the process so far, in MB (ru_maxrss is bytes on macOS).
func maxRSSMB() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_maxrss) / 1_048_576
}

// MARK: - Language codes

/// FLEURS config -> (Apple locale, Cohere language code).
func codes(_ fleurs: String) -> (apple: String, cohere: String) {
    switch fleurs {
    case "ja_jp": return ("ja_JP", "ja")
    case "ko_kr": return ("ko_KR", "ko")
    case "cmn_hans_cn": return ("zh_CN", "zh")
    case "yue_hant_hk": return ("yue_CN", "zh")
    case "en_us": return ("en_US", "en")
    case "fr_fr": return ("fr_FR", "fr")
    case "es_419": return ("es_MX", "es")
    case "pt_br": return ("pt_BR", "pt")
    case "de_de": return ("de_DE", "de")
    case "it_it": return ("it_IT", "it")
    default: return ("en_US", "en")
    }
}

// MARK: - Engines

struct Output {
    var text: String
    var tag: String? = nil
    var tags: [String]? = nil
}

protocol Engine {
    func run(file: URL, lang: String) async throws -> Output
}

func samples16k(_ url: URL) throws -> [Float] {
    try AudioConverter(sampleRate: 16_000).resampleAudioFile(url)
}

struct SenseVoiceEngine: Engine {
    let manager: SenseVoiceManager
    func run(file: URL, lang: String) async throws -> Output {
        let r = try await manager.transcribeDetailed(audio: try samples16k(file))
        return Output(text: r.text, tag: r.language, tags: r.tags)
    }
}

struct ParaformerEngine: Engine {
    let manager: ParaformerManager
    func run(file: URL, lang: String) async throws -> Output {
        Output(text: try await manager.transcribe(audio: try samples16k(file)))
    }
}

struct ParakeetJaEngine: Engine {
    let manager: AsrManager
    func run(file: URL, lang: String) async throws -> Output {
        var state = try TdtDecoderState(decoderLayers: 2)
        let r = try await manager.transcribe(file, decoderState: &state)
        return Output(text: r.text)
    }
}

struct CohereEngine: Engine {
    let models: CoherePipeline.LoadedModels
    func run(file: URL, lang: String) async throws -> Output {
        guard let language = CohereAsrConfig.Language(rawValue: codes(lang).cohere) else {
            throw NSError(domain: "bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "no cohere language"])
        }
        let r = try await CoherePipeline().transcribeLong(
            audio: try samples16k(file), models: models, language: language,
            maxNewTokens: 108, repetitionPenalty: 1.1, noRepeatNgram: 3)
        return Output(text: r.text)
    }
}

/// SpeechAnalyzer exactly as Parley's SpeechAnalyzerEngine drives it (same preset), one locale per FLEURS config.
struct SpeechEngine: Engine {
    func run(file: URL, lang: String) async throws -> Output {
        let locale = Locale(identifier: codes(lang).apple)
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: SpeechTranscriber.Preset(
                transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange]))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: file)
        let task = Task {
            if let last = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        }
        var text = ""
        for try await r in transcriber.results where r.isFinal {
            text += String(r.text.characters) + " "
        }
        try await task.value
        return Output(text: text.trimmingCharacters(in: .whitespaces))
    }

    /// Install each needed locale ONCE, serially (concurrent installs fail, 2026-07-16 caveat 2).
    static func install(_ langs: [String]) async throws {
        let installed = await SpeechTranscriber.installedLocales
        for l in langs {
            let locale = Locale(identifier: codes(l).apple)
            if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { continue }
            let t = SpeechTranscriber(locale: locale, preset: .transcription)
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                FileHandle.standardError.write("installing \(locale.identifier)\n".data(using: .utf8)!)
                try await req.downloadAndInstall()
            }
        }
    }
}

struct WhisperLIDEngine: Engine {
    let kit: WhisperKit
    /// Only the first N seconds of each clip (nil: up to Whisper's 30 s window) — how much speech the tag needs.
    var seconds: Double? = nil
    func run(file: URL, lang: String) async throws -> Output {
        guard let seconds else {
            let r = try await kit.detectLanguage(audioPath: file.path)
            return Output(text: "", tag: r.language)
        }
        let audio = try samples16k(file)
        let r = try await kit.detectLangauge(audioArray: Array(audio.prefix(Int(seconds * 16_000))))
        return Output(text: "", tag: r.language)
    }
}

let modelsRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("FluidAudio/Models")

func loadCompiled(_ dir: URL, _ name: String, _ units: MLComputeUnits) throws -> MLModel {
    let c = MLModelConfiguration()
    c.computeUnits = units
    return try MLModel(contentsOf: dir.appendingPathComponent("\(name).mlmodelc"), configuration: c)
}

func loadVocab(_ dir: URL) throws -> [Int: String] {
    let data = try Data(contentsOf: dir.appendingPathComponent("vocab.json"))
    if let arr = try JSONSerialization.jsonObject(with: data) as? [String] {
        return Dictionary(uniqueKeysWithValues: arr.enumerated().map { ($0.offset, $0.element) })
    }
    let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] ?? [:]
    return Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in Int(k).map { ($0, v) } })
}

/// SenseVoice with an explicit encoder, compute units and text normalisation (14 = with ITN, 15 = without).
func senseVoice(encoder: String, units: MLComputeUnits, textNorm: Int32) async throws -> SenseVoiceManager {
    _ = try await SenseVoiceManager.load(precision: encoder.hasSuffix("fp32") ? .fp32 : .fp16)   // download
    let dir = modelsRoot.appendingPathComponent("sensevoice-small")
    let models = SenseVoiceModels(
        preprocessor: try loadCompiled(dir, ModelNames.SenseVoice.preprocessor, .cpuOnly),
        encoder: try loadCompiled(dir, encoder, units), vocabulary: try loadVocab(dir))
    return SenseVoiceManager(models: models, textNorm: textNorm)
}

func makeEngine(_ a: Args, langs: [String]) async throws -> Engine {
    switch a.engine {
    case "sensevoice": return SenseVoiceEngine(manager: try await SenseVoiceManager.load(precision: .fp16))
    case "sensevoice-int8": return SenseVoiceEngine(manager: try await SenseVoiceManager.load(precision: .int8))
    case "sensevoice-fp32":
        return SenseVoiceEngine(manager: try await senseVoice(encoder: ModelNames.SenseVoice.encoderFp32, units: .cpuOnly, textNorm: 15))
    case "sensevoice-fp32-itn":
        return SenseVoiceEngine(manager: try await senseVoice(encoder: ModelNames.SenseVoice.encoderFp32, units: .cpuOnly, textNorm: 14))
    case "sensevoice-itn":
        return SenseVoiceEngine(manager: try await senseVoice(encoder: ModelNames.SenseVoice.encoder, units: .cpuAndNeuralEngine, textNorm: 14))
    case "paraformer": return ParaformerEngine(manager: try await ParaformerManager.load(precision: .fp16))
    case "paraformer-int8": return ParaformerEngine(manager: try await ParaformerManager.load(precision: .int8))
    case "paraformer-cpu":
        _ = try await ParaformerManager.load(precision: .fp16)
        let dir = modelsRoot.appendingPathComponent("paraformer-large-zh")
        let models = ParaformerModels(
            preprocessor: try loadCompiled(dir, ModelNames.ParaformerZh.preprocessor, .cpuOnly),
            encoder: try loadCompiled(dir, ModelNames.ParaformerZh.encoder, .cpuOnly),
            cifAlphas: try loadCompiled(dir, ModelNames.ParaformerZh.cifAlphas, .cpuOnly),
            decoder: try loadCompiled(dir, ModelNames.ParaformerZh.decoder, .cpuOnly), vocabulary: try loadVocab(dir))
        return ParaformerEngine(manager: ParaformerManager(models: models))
    case "parakeet-ja":
        let models = try await AsrModels.downloadAndLoad(version: .tdtJa)
        return ParakeetJaEngine(manager: AsrManager(models: models))
    case "cohere":
        let dir = URL(fileURLWithPath: a.cohereDir)
        let models = try await CoherePipeline.loadModels(
            encoderDir: dir, decoderDir: dir, vocabDir: dir.deletingLastPathComponent())
        return CohereEngine(models: models)
    case "speech":
        try await SpeechEngine.install(langs)
        return SpeechEngine()
    case let e where e.hasPrefix("whisper-lid"):
        // whisper-lid:<model>, or whisper-lid@<seconds>:<model> for the first N seconds only.
        let head = e.split(separator: ":", maxSplits: 1)
        let model = head.count > 1 ? String(head[1]) : "openai_whisper-base"
        let seconds = head[0].split(separator: "@").dropFirst().first.flatMap { Double($0) }
        let kit = try await WhisperKit(WhisperKitConfig(model: model, verbose: false, logLevel: .none, download: true))
        return WhisperLIDEngine(kit: kit, seconds: seconds)
    default:
        throw NSError(domain: "bench", code: 2, userInfo: [NSLocalizedDescriptionKey: "unknown engine \(a.engine)"])
    }
}

// MARK: - Main

struct GTRow: Decodable { let file: String; let seconds: Double }

let args = parseArgs()
let gtURL = URL(fileURLWithPath: args.gt)
let audioDir = gtURL.deletingLastPathComponent()
let gt = try JSONDecoder().decode([String: [GTRow]].self, from: Data(contentsOf: gtURL))
let langs = args.langs.isEmpty ? gt.keys.sorted() : args.langs

let memBefore = physFootprintMB()
let loadStart = ContinuousClock.now
let engine = try await makeEngine(args, langs: langs)
let loadSeconds = (ContinuousClock.now - loadStart) / .seconds(1)
var peakFootprint = physFootprintMB()

FileManager.default.createFile(atPath: args.out, contents: nil)
let out = try FileHandle(forWritingTo: URL(fileURLWithPath: args.out))

func emit(_ obj: [String: Any]) {
    let d = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    out.write(d)
    out.write("\n".data(using: .utf8)!)
}

emit(["kind": "load", "engine": args.engine, "load_seconds": loadSeconds,
      "footprint_mb_before": memBefore, "footprint_mb_after_load": peakFootprint])

var totalAudio = 0.0, totalCompute = 0.0
for lang in langs {
    for row in (gt[lang] ?? []).prefix(args.limit) {
        let file = audioDir.appendingPathComponent(row.file)
        let start = ContinuousClock.now
        var rec: [String: Any] = ["kind": "item", "engine": args.engine, "lang": lang, "file": row.file,
                                  "audio_seconds": row.seconds]
        do {
            let o = try await engine.run(file: file, lang: lang)
            rec["text"] = o.text
            if let t = o.tag { rec["tag"] = t }
            if let t = o.tags { rec["tags"] = t }
        } catch {
            rec["error"] = "\(error)"
        }
        let secs = (ContinuousClock.now - start) / .seconds(1)
        rec["seconds"] = secs
        totalAudio += row.seconds
        totalCompute += secs
        peakFootprint = max(peakFootprint, physFootprintMB())
        emit(rec)
    }
}
emit(["kind": "summary", "engine": args.engine, "audio_seconds": totalAudio, "compute_seconds": totalCompute,
      "rtfx": totalAudio / max(totalCompute, 1e-9), "peak_footprint_mb": peakFootprint, "max_rss_mb": maxRSSMB()])
try out.close()
print("done \(args.engine): rtfx \(String(format: "%.1f", totalAudio / max(totalCompute, 1e-9))), peak \(Int(peakFootprint)) MB")
