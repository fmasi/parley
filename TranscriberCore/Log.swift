import os

extension Logger {
    private static let subsystem = "com.audio-transcribe.app"

    /// Audio capture: stream lifecycle, format detection, device selection
    static let audio = Logger(subsystem: subsystem, category: "audio")
    /// Transcription: Python process launch, output forwarding, completion
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
