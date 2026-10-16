import Foundation
import Testing
@testable import TranscriberCore

/// H2 round 2 (council B-M14a): the helper's ring resets per SESSION, not only its events — the
/// out-of-ring dedup keys otherwise grow for the helper's whole lifetime.
@Suite struct LockedDiagnosticsTests {
    private func event(_ kind: CaptureEventKind, at t: TimeInterval) -> CaptureEvent {
        CaptureEvent(timestamp: Date(timeIntervalSinceReferenceDate: t), origin: .helper, kind: kind, severity: .anomaly)
    }

    @Test func aSessionResetEmptiesTheRing() {
        let ring = LockedDiagnostics()
        ring.record(event(.livenessGap, at: 1))
        ring.record(event(.writeFailure, at: 2))
        ring.resetSession()
        #expect(CaptureDiagnostics.events(from: ring.drainData()).isEmpty)
    }

    @Test func theSameEventInTheNextSessionIsRecordedAgain() {
        let ring = LockedDiagnostics()
        ring.record(event(.livenessGap, at: 1))
        ring.resetSession()
        ring.record(event(.livenessGap, at: 1))
        #expect(CaptureDiagnostics.events(from: ring.drainData()).count == 1)
    }
}
