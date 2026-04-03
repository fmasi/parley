import Foundation

/// Compute the base name for a new recording segment.
/// Strips any existing `-N` suffix from the original path's filename,
/// then appends the new segment number.
///
/// Example: segmentBaseName(originalPath: "/tmp/recording-2.wav", segment: 3) → "recording-3"
public func segmentBaseName(originalPath: String, segment: Int) -> String {
    let origBase = URL(fileURLWithPath: originalPath)
        .deletingPathExtension().lastPathComponent
    let cleanBase = origBase.replacingOccurrences(
        of: #"-\d+$"#, with: "", options: .regularExpression
    )
    return "\(cleanBase)-\(segment)"
}
