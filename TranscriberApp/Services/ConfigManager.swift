import Foundation

final class ConfigManager {
    static let shared = ConfigManager()

    private let configDir: URL
    private let configFile: URL

    private(set) var config: Config

    init(configDir: URL? = nil) {
        let dir = configDir ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".audio-transcribe")
        self.configDir = dir
        self.configFile = dir.appendingPathComponent("config.json")
        self.config = Self.load(from: self.configFile)
    }

    private static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else {
            return .default
        }
        return config
    }

    func save() {
        try? FileManager.default.createDirectory(
            at: configDir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configFile, options: .atomic)
    }

    func update(_ transform: (inout Config) -> Void) {
        transform(&config)
        save()
    }
}
