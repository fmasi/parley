import os

public extension Logger {
    private static let subsystem = "com.audio-transcribe.app"

    /// Audio capture: stream lifecycle, format detection, device selection
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    /// Transcription: Python process launch, output forwarding, completion
    public static let transcription = Logger(subsystem: subsystem, category: "transcription")
    /// App state: phase transitions, error message lifecycle
    public static let state = Logger(subsystem: subsystem, category: "state")
    /// Config: load, save, parse failures
    public static let config = Logger(subsystem: subsystem, category: "config")
    /// Permissions: check results, grant/deny
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    /// Files: WAV lifecycle, output path resolution
    public static let files = Logger(subsystem: subsystem, category: "files")
}
