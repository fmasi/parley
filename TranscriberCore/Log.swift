import os

public extension Logger {
    private static let subsystem = "eu.fmasi.parley"

    /// Audio capture: stream lifecycle, format detection, device selection
    static let audio = Logger(subsystem: subsystem, category: "audio")
    /// Transcription: engine lifecycle, transcription timing, diarization
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    /// App state: phase transitions, error message lifecycle
    static let state = Logger(subsystem: subsystem, category: "state")
    /// Config: load, save, parse failures
    static let config = Logger(subsystem: subsystem, category: "config")
    /// Permissions: check results, grant/deny
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    /// Files: WAV lifecycle, output path resolution
    static let files = Logger(subsystem: subsystem, category: "files")
}
