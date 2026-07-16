import Foundation
import Testing
@testable import TranscriberCore

/// #133: the LM Studio provider used to send `context_length` on every request, forcing LM Studio
/// to RELOAD the model — even when it was already loaded with a huge context. That reload OOMs on
/// a busy machine ("insufficient system resources") and the summary silently fails. The fix: check
/// whether the model is already loaded with enough context and, if so, use it as-is (no reload).
struct LMStudioPreloadTests {

    // MARK: - contextDecision

    @Test func usesLoadedModelWhenContextIsSufficient() {
        let state = LMStudioSummaryProvider.ModelState(isLoaded: true, loadedContextLength: 262144)
        #expect(LMStudioSummaryProvider.contextDecision(state: state, neededContext: 5000, maxContext: 32768)
                == .useLoadedAsIs)
    }

    @Test func requestsContextWhenLoadedContextTooSmall() {
        let state = LMStudioSummaryProvider.ModelState(isLoaded: true, loadedContextLength: 4000)
        #expect(LMStudioSummaryProvider.contextDecision(state: state, neededContext: 5000, maxContext: 32768)
                == .request(contextLength: 5000))
    }

    @Test func requestsContextWhenModelNotLoaded() {
        let notLoaded = LMStudioSummaryProvider.ModelState(isLoaded: false, loadedContextLength: nil)
        #expect(LMStudioSummaryProvider.contextDecision(state: notLoaded, neededContext: 5000, maxContext: 32768)
                == .request(contextLength: 5000))
    }

    @Test func requestsContextWhenStateUnknown() {
        // Could not determine state (endpoint down / model absent) — fall back to the old behavior.
        #expect(LMStudioSummaryProvider.contextDecision(state: nil, neededContext: 5000, maxContext: 32768)
                == .request(contextLength: 5000))
    }

    @Test func capsRequestedContextAtMax() {
        #expect(LMStudioSummaryProvider.contextDecision(state: nil, neededContext: 999_999, maxContext: 32768)
                == .request(contextLength: 32768))
    }

    // MARK: - parseModelState

    @Test func parsesLoadedModelState() {
        let json = """
        {"data":[
          {"id":"gemma-4-26b-a4b-it-mlx","state":"loaded","loaded_context_length":262144,"max_context_length":262144},
          {"id":"gemma-4-e4b-it","state":"not-loaded"}
        ]}
        """.data(using: .utf8)!
        #expect(LMStudioSummaryProvider.parseModelState(json, model: "gemma-4-26b-a4b-it-mlx")
                == LMStudioSummaryProvider.ModelState(isLoaded: true, loadedContextLength: 262144))
    }

    @Test func parsesNotLoadedModelState() {
        let json = """
        {"data":[{"id":"gemma-4-e4b-it","state":"not-loaded"}]}
        """.data(using: .utf8)!
        #expect(LMStudioSummaryProvider.parseModelState(json, model: "gemma-4-e4b-it")
                == LMStudioSummaryProvider.ModelState(isLoaded: false, loadedContextLength: nil))
    }

    @Test func matchesPublisherPrefixedConfigModel() {
        // config.json carries "lmstudio-community/gemma-4-26b-a4b-it-mlx"; /api/v0/models reports
        // id "gemma-4-26b-a4b-it-mlx" + publisher "lmstudio-community" separately. Must still match,
        // or the provider thinks the model is unloaded and forces the reload this fix exists to avoid.
        let json = """
        {"data":[{"id":"gemma-4-26b-a4b-it-mlx","publisher":"lmstudio-community","state":"loaded","loaded_context_length":262144}]}
        """.data(using: .utf8)!
        #expect(LMStudioSummaryProvider.parseModelState(json, model: "lmstudio-community/gemma-4-26b-a4b-it-mlx")
                == LMStudioSummaryProvider.ModelState(isLoaded: true, loadedContextLength: 262144))
    }

    @Test func parseModelStateReturnsNilForAbsentModel() {
        let json = """
        {"data":[{"id":"other","state":"loaded","loaded_context_length":8192}]}
        """.data(using: .utf8)!
        #expect(LMStudioSummaryProvider.parseModelState(json, model: "gemma-4-e4b-it") == nil)
    }

    // MARK: - buildRequest honors the decision

    private func fixture() -> ([SummarySegment], SummaryMetadata) {
        ([SummarySegment(start: 0, end: 10, speaker: "A", text: "hello there")],
         SummaryMetadata(sessionName: "s", date: Date(timeIntervalSince1970: 0), durationSeconds: 60, speakers: ["A"]))
    }

    @Test func buildRequestOmitsContextLengthWhenModelLoadedSufficiently() async throws {
        let provider = LMStudioSummaryProvider(endpoint: "http://127.0.0.1:1234", apiKey: "", model: "m")
        let (segs, meta) = fixture()
        let state = LMStudioSummaryProvider.ModelState(isLoaded: true, loadedContextLength: 262144)
        let (request, _, _) = try await provider.buildRequest(segments: segs, metadata: meta, loadedState: state)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["context_length"] == nil, "must not force a reload when the model is already loaded big enough")
        #expect(body["model"] as? String == "m")
    }

    @Test func buildRequestIncludesContextLengthWhenNotLoaded() async throws {
        let provider = LMStudioSummaryProvider(endpoint: "http://127.0.0.1:1234", apiKey: "", model: "m")
        let (segs, meta) = fixture()
        let state = LMStudioSummaryProvider.ModelState(isLoaded: false, loadedContextLength: nil)
        let (request, _, _) = try await provider.buildRequest(segments: segs, metadata: meta, loadedState: state)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["context_length"] != nil, "must request a context when the model needs loading")
    }
}
