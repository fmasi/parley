import Testing
@testable import TranscriberCore

struct ChunkRecoveryPlanTests {
    @Test func indexZeroProducesAdjacentNames() {
        let plan = chunkRecoveryPlan(sessionBaseName: "110851-Andrew", currentChunkIndex: 0)
        #expect(plan.orphanIndex == 0)
        #expect(plan.recoveryIndex == 1)
        #expect(plan.orphanBaseName == "110851-Andrew-0")
        #expect(plan.recoveryBaseName == "110851-Andrew-1")
    }

    @Test func orphanUsesLiveIndexNotStaleZero() {
        // The regression the adversarial verifier caught: after one or more rotations the orphan
        // must be the CURRENT index (-3), never the stale sentinel-derived -0.
        let plan = chunkRecoveryPlan(sessionBaseName: "110851-Andrew", currentChunkIndex: 3)
        #expect(plan.orphanBaseName == "110851-Andrew-3")
        #expect(plan.recoveryBaseName == "110851-Andrew-4")
    }

    @Test func recoveryIndexIsAlwaysOrphanPlusOne() {
        for i in 0..<20 {
            let plan = chunkRecoveryPlan(sessionBaseName: "S", currentChunkIndex: i)
            #expect(plan.recoveryIndex == plan.orphanIndex + 1)
        }
    }

    @Test func planIsEquatable() {
        #expect(
            chunkRecoveryPlan(sessionBaseName: "S", currentChunkIndex: 2)
                == chunkRecoveryPlan(sessionBaseName: "S", currentChunkIndex: 2)
        )
    }
}
