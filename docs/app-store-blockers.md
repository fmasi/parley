# App Store blockers

Parley ships outside the Mac App Store (Developer ID / self-signed + Sparkle). Some choices depend
on that. Each one is recorded here, so that if an App Store build is ever considered, the cost is
known up front. **Add an entry in the same PR as any new App Store-incompatible choice.**

| Choice | Where | Why we need it | App Store problem | Alternative if we go there |
|---|---|---|---|---|
| Private TCC SPI `TCCAccessPreflight` / `TCCAccessRequest` for `kTCCServiceAudioCapture` | `TranscriberCore/SystemAudioRecordingPermission.swift` | macOS has no public API to read or request the System Audio Recording permission the Core Audio tap needs. Without it Parley can't tell a denied tap (which records digital zeros) from a silent call (#220). | Private API use: rejected in review. | Drop the up-front check and rely on the exact-zero evidence path only, which detects a denial only once a recording is running with audio playing. |
| Global Core Audio process tap (`CATapDescription(stereoGlobalTapButExcludeProcesses:)`) | `AudioCaptureHelper/XPC/SystemTapSession.swift` | Captures every app's output, including Continuity/iPhone and VoIP calls that ScreenCaptureKit misses (#103). | Needs the App Sandbox audio-capture entitlement story to be validated; a global tap of other apps' audio is likely to draw review scrutiny. | ScreenCaptureKit (being retired in v0.10, #221), which loses Continuity/VoIP calls. |
| LaunchAgent with `KeepAlive` for crash relaunch | `TranscriberCore/LaunchAgentManager.swift` | Relaunches Parley after a crash mid-recording so the session is recovered. | Sandboxed apps can't install LaunchAgents; `SMAppService` login items don't support KeepAlive relaunch semantics. | `SMAppService` login item plus recovery on the next manual launch. |
