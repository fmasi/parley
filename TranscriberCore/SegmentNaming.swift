import Foundation

/// Strip any trailing `-N` segment suffix from a filename (without extension).
/// Example: "recording-2" -> "recording", "recording" -> "recording"
public func stripSegmentSuffix(_ path: String) -> String {
    URL(fileURLWithPath: path)
        .deletingPathExtension().lastPathComponent
        .replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression)
}

/// Compute the base name for a new recording segment.
/// Strips any existing `-N` suffix from the original path's filename,
/// then appends the new segment number.
///
/// Example: segmentBaseName(originalPath: "/tmp/recording-2.wav", segment: 3) → "recording-3"
public func segmentBaseName(originalPath: String, segment: Int) -> String {
    let cleanBase = stripSegmentSuffix(originalPath)
    return "\(cleanBase)-\(segment)"
}
