# ANE vs GPU Performance for Whisper/Transformer Models on Apple Silicon

**Date:** 2026-04-01
**Context:** mlx-whisper (GPU) is 3.5x faster than WhisperKit (ANE) for Whisper large-v3 on M5 Pro

---

## 1. Why ANE Is Slower Than GPU for Large Transformers

### Root Cause: Bandwidth-Boundness

Apple's own research paper ["Deploying Transformers on the Apple Neural Engine"](https://machinelearning.apple.com/research/neural-engine-transformers) (WWDC 2022) explains the core issue directly:

> "Even after all the optimizations, many Transformer configurations become **bandwidth-bound** on the ANE when the sequence length is relatively short. This is due to the fact that large parameter tensors are being fetched from memory, only to be applied on too few inputs before the next parameter tensor is fetched. Fetching from memory dominates overall latency in these cases."

For Whisper large-v3 (1.5B parameters), this is devastating:
- The decoder processes **one token at a time** (sequence length = 1 per step)
- Each step requires loading enormous weight matrices from memory
- The ANE spends most of its time waiting for memory, not computing

### ANE Architecture Constraints

The ANE is a fixed-function accelerator optimized for:
1. **Conv2d/Conv1d operations** in channels-first (B, C, 1, S) format
2. **Small-to-medium models** where weights fit in ANE's local caches
3. **Batch inference** or longer sequences that amortize weight-loading cost

The ANE is NOT well-suited for:
1. **Large transformer attention** — reshape/transpose operations trigger memory copies (ANE buffers have at least one unpacked axis)
2. **Autoregressive decoding** — seq_len=1 means the compute/memory ratio is terrible
3. **Models >~500M params** — weights exceed ANE cache, causing constant memory fetches
4. **Standard transformer implementations** — most use nn.Linear (channels-last), but ANE needs nn.Conv2d (channels-first)

### Why GPU Is Better for Large Models

The GPU (via Metal/MLX) benefits from:
- **Higher memory bandwidth utilization** — GPU can better pipeline memory accesses
- **Flexible compute** — no restriction on data format or operation types
- **Shared unified memory** — MLX accesses the same memory pool without copies
- **Better handling of attention** — standard matmul operations run natively

### Model Size Crossover Point

Based on Apple's own data (distilbert ~66M params, 10x speedup on ANE) and community reports:
- **< ~300M params**: ANE wins (especially for well-optimized models)
- **300M-500M params**: Roughly equivalent, depends on optimization
- **> 500M params**: GPU increasingly wins
- **1.5B params (Whisper large-v3)**: GPU dominates, ANE is 3-4x slower

The crossover is not purely about param count — it's about whether the model is **compute-bound** (ANE wins) or **bandwidth-bound** (GPU wins). Autoregressive decoders are almost always bandwidth-bound for large models.

---

## 2. CoreML Compute Units

### Available Options

```swift
public enum MLComputeUnits {
    case cpuOnly           // CPU only (BNNS/Accelerate)
    case cpuAndGPU         // CPU + GPU (Metal Performance Shaders)
    case all               // CPU + GPU + ANE (CoreML decides)
    case cpuAndNeuralEngine // CPU + ANE (no GPU)
}
```

### How `.all` Works

When you set `.all`, CoreML creates a **hybrid execution plan**:
- CoreML's compiler analyzes the model graph
- Operations are assigned to CPU, GPU, or ANE based on internal heuristics
- **Individual layers** can run on different hardware
- The split is opaque — you cannot control which layer goes where
- CoreML tries to minimize data transfers between compute units

### Model Splitting Behavior

**Yes, CoreML can and does split models across compute units.** When `.all` is specified:
- Some operations may run on ANE (e.g., convolutions)
- Others may fall back to GPU or CPU (e.g., unsupported ops, operations that would be slow on ANE)
- Data transfers between engines add overhead ("inter-engine context-transfer overhead" per Apple)

However, **you cannot force specific layers to specific hardware** with standard CoreML APIs. The assignment is fully automatic.

### Per-Submodel Control in WhisperKit

WhisperKit works around this by splitting Whisper into **separate CoreML models** (encoder, decoder, mel spectrogram, prefill), each loaded with its own `MLComputeUnits` setting. This gives per-component control:

```swift
// From WhisperKit Models.swift - ModelComputeOptions
public struct ModelComputeOptions: Sendable {
    public var melCompute: MLComputeUnits        // default: .cpuAndGPU
    public var audioEncoderCompute: MLComputeUnits // default: .cpuAndNeuralEngine (macOS 14+)
    public var textDecoderCompute: MLComputeUnits  // default: .cpuAndNeuralEngine
    public var prefillCompute: MLComputeUnits      // default: .cpuOnly
}
```

---

## 3. Using ANE and GPU Simultaneously

### Can ANE and GPU Run Concurrently?

**Yes**, on Apple Silicon the ANE and GPU are independent hardware units that can operate in parallel. However:
- **CoreML does not expose an API** to explicitly pipeline work across them
- When CoreML splits a single model (`.all`), it executes sequentially per layer — a layer on ANE completes before the next layer on GPU starts
- **Different models** can run on different compute units simultaneously (e.g., encoder on GPU while decoder runs on ANE), but you must manage this yourself

### MLX Approach to Parallelism

MLX provides explicit stream-based parallelism:
```python
# CPU and GPU can run truly in parallel
c = mx.add(a, b, stream=mx.cpu)
d = mx.matmul(e, f, stream=mx.gpu)
# These run concurrently if no data dependencies
```

MLX does NOT support ANE — it's GPU-only via Metal compute shaders. But it achieves high throughput because:
1. Direct Metal GPU access without CoreML overhead
2. Lazy evaluation enables operation fusion
3. Unified memory means zero-copy between CPU and GPU
4. Custom Metal kernels optimized for transformers

### Pipelining Possibility

Theoretically, you could:
- Run the **encoder** on GPU (compute-dense, big batch of mel features)
- Run the **decoder** on ANE (many sequential small operations)

But in practice the decoder is the bottleneck for large models, and it's the part that's slowest on ANE. So this doesn't help — you'd want the decoder on GPU too.

---

## 4. WhisperKit Compute Unit Configuration

### WhisperKit Fully Supports Choosing Compute Units

From the source code (`Sources/WhisperKit/Core/Models.swift`):

```swift
public struct ModelComputeOptions: Sendable {
    public init(
        melCompute: MLComputeUnits = .cpuAndGPU,
        audioEncoderCompute: MLComputeUnits? = nil,  // defaults to .cpuAndNeuralEngine on macOS 14+
        textDecoderCompute: MLComputeUnits = .cpuAndNeuralEngine,
        prefillCompute: MLComputeUnits = .cpuOnly
    )
}
```

**To force GPU for everything:**
```swift
let config = WhisperKitConfig(
    model: "openai_whisper-large-v3",
    computeOptions: ModelComputeOptions(
        melCompute: .cpuAndGPU,
        audioEncoderCompute: .cpuAndGPU,
        textDecoderCompute: .cpuAndGPU,
        prefillCompute: .cpuAndGPU
    )
)
let whisperKit = try await WhisperKit(config)
```

### Default Configuration Analysis

WhisperKit's defaults route BOTH encoder and decoder to ANE:
- `audioEncoderCompute`: `.cpuAndNeuralEngine` (macOS 14+)
- `textDecoderCompute`: `.cpuAndNeuralEngine`

This is optimized for **small models on mobile devices** (iPhone), not for large models on Mac.

### Known Issues with `.cpuAndGPU`

- **Issue #265**: Memory leak when using `.cpuAndGPU` with Turbo model on M1 (macOS 14.6). This was a CoreML bug, reportedly fixed in later macOS versions.
- **Issue #301**: WhisperKit with `.cpuAndGPU` on all components = 1:50 for a 3:08 file on M1 Pro. whisper.cpp GPU = 0:29 for the same file. WhisperKit is ~3.7x slower even with GPU compute units.
- **Issue #264**: Crashes on startup with certain compute unit configurations on older devices.

### Model Variants

The `argmaxinc/whisperkit-coreml` HuggingFace repo contains pre-compiled CoreML models. Key variants:
- `openai_whisper-large-v3` — full size (~3GB)
- `openai_whisper-large-v3_947MB` — compressed/quantized
- `openai_whisper-large-v3-v20240930_turbo` — Turbo architecture (faster decoder)
- `openai_whisper-large-v3-v20240930_turbo_632MB` — compressed Turbo

The CoreML models are compiled as **mlmodelc** packages that support any compute unit — the `.computeUnits` choice happens at load time, not compile time.

---

## 5. MLX vs CoreML Performance Analysis

### Why MLX (GPU-Only) Is Faster Than CoreML

| Factor | MLX | CoreML (ANE) |
|--------|-----|-------------|
| Hardware | GPU via Metal compute shaders | ANE fixed-function unit |
| Memory access | Direct unified memory, zero-copy | ANE has its own memory subsystem, copies needed |
| Operation support | Any operation expressible in Metal | Limited to supported ops, fallbacks add overhead |
| Data format | Standard row-major tensors | Requires channels-first 4D tensors |
| Overhead | Minimal runtime, lazy eval | Model compilation, execution plan, scheduling |
| Attention | Native matmul | Requires reformulation as conv2d + einsum tricks |
| Batched decode | Efficient | Bandwidth-bound at seq_len=1 |

### The CoreML Overhead Problem

Even when you set CoreML to `.cpuAndGPU` (skipping ANE entirely), WhisperKit is still slower than mlx-whisper or whisper.cpp because:
1. **CoreML's runtime overhead** — model loading, graph optimization, scheduling
2. **MPS (Metal Performance Shaders) vs custom Metal kernels** — MLX and whisper.cpp use highly optimized custom kernels
3. **No operation fusion** — CoreML executes operations individually; MLX fuses operations via lazy evaluation
4. **Data format constraints** — CoreML's internal representations may not be optimal

### Community Consensus

This is a well-known issue. The Hollance neural-engine documentation states:
> "I would often get email from people who are confused why their model doesn't appear to be running on the Neural Engine, or **why it is so slow** when the ANE is supposed to be way faster than the GPU..."
> "Not every Core ML model can make full use of the ANE."

---

## 6. M5 Pro Specifications

### M5 Pro (16-inch MacBook Pro)

| Component | Spec |
|-----------|------|
| CPU | 18-core (6 super + 12 performance) |
| GPU | 16 or 20 cores |
| Neural Engine | 16-core |
| Memory Bandwidth | 307 GB/s |
| Unified Memory | Up to 48GB |

### Why M5 Pro GPU >> ANE for Whisper Large-v3

Apple does not publish ANE TOPS for M5 Pro specifically. Historical data:
- A15 (iPhone 13 Pro): 15.8 TFLOPS ANE
- M1: ~11 TFLOPS ANE (estimated)
- M5 Pro: Likely 35-40+ TOPS ANE (estimated from generational improvements)

But the M5 Pro GPU is a **monster**:
- 16-20 GPU cores at high clock speeds
- 307 GB/s unified memory bandwidth (shared with GPU)
- Estimated 8-12+ TFLOPS GPU FP16

The key insight: **memory bandwidth matters more than peak TFLOPS for large autoregressive models.** The GPU shares the full 307 GB/s memory bandwidth, while the ANE has its own (likely smaller) memory subsystem. For bandwidth-bound workloads like Whisper decoder, the GPU wins decisively.

---

## 7. Practical Solutions

### Solution 1: Force GPU in WhisperKit (Immediate)

```swift
let computeOptions = ModelComputeOptions(
    melCompute: .cpuAndGPU,
    audioEncoderCompute: .cpuAndGPU,
    textDecoderCompute: .cpuAndGPU,
    prefillCompute: .cpuAndGPU
)
```

**Caveat**: Based on issue #301, even with GPU, WhisperKit may still be ~3x slower than whisper.cpp/mlx-whisper due to CoreML runtime overhead. Test on M5 Pro to verify — newer hardware and macOS versions may have improved this.

### Solution 2: Use Turbo Model Variant

The `openai_whisper-large-v3-v20240930_turbo` model uses a much smaller decoder (4 layers instead of 32), dramatically reducing decoder latency while keeping the same encoder quality. This is the single biggest performance win available in WhisperKit.

### Solution 3: Stick with mlx-whisper (Recommended for Mac)

For a Mac-only app, mlx-whisper is the clear winner:
- Direct GPU access via Metal, no CoreML overhead
- Optimized for Apple Silicon unified memory
- Already proven 3.5x faster in your benchmarks
- Python integration is already working in your app
- Supports all Whisper models including large-v3

### Solution 4: Quantized Models

Quantization helps with bandwidth-bound workloads on ANY compute unit:
- The `_947MB` and `_632MB` model variants use weight compression
- Smaller weights = less memory to fetch = faster on both GPU and ANE
- May slightly reduce accuracy, but usually negligible for Whisper

For ANE specifically, Apple states: "reduce the parameter tensor size by quantization or pruning such that memory fetching becomes cheaper and faster."

### Solution 5: Hybrid Approach (Advanced)

If you want to use both ANE and GPU simultaneously:
```swift
// Encoder on GPU (compute-dense), Decoder on... also GPU (bandwidth-bound)
let computeOptions = ModelComputeOptions(
    melCompute: .cpuAndGPU,
    audioEncoderCompute: .cpuAndGPU,     // GPU for compute-dense encoder
    textDecoderCompute: .cpuAndGPU,      // GPU for bandwidth-bound decoder
    prefillCompute: .cpuOnly             // CPU for small prefill
)
```

There is no practical benefit to putting the decoder on ANE for large models.

### Solution 6: whisper.cpp as Alternative

whisper.cpp uses Metal GPU directly (like MLX) and achieves similar performance. It's available as a C library with Swift bindings. However, it doesn't have the same speaker diarization pipeline you're using with pyannote.

---

## Summary / Recommendation

**For your Transcriber app on Mac: stay with mlx-whisper.** The performance advantage is real and structural — it's not a bug in WhisperKit, it's a fundamental architectural mismatch between large transformer decoders and the ANE.

If you ever want to move to a Swift-native solution:
1. WhisperKit with `.cpuAndGPU` compute options is the starting point
2. Use the Turbo model variant to reduce decoder overhead
3. Test on your specific hardware (M5 Pro may have CoreML improvements)
4. But expect it to still be slower than mlx-whisper due to CoreML overhead

The ANE is designed for power-efficient inference on mobile (iPhone/iPad) with small-to-medium models. For Mac with large models and unlimited power, GPU wins every time.

---

## Sources

1. [Apple ML Research: "Deploying Transformers on the Apple Neural Engine"](https://machinelearning.apple.com/research/neural-engine-transformers) — WWDC 2022
2. [apple/ml-ane-transformers](https://github.com/apple/ml-ane-transformers) — Apple's ANE-optimized transformer reference implementation
3. [WhisperKit Models.swift](https://github.com/argmaxinc/WhisperKit/blob/main/Sources/WhisperKit/Core/Models.swift) — ModelComputeOptions source code
4. [WhisperKit Issue #301](https://github.com/argmaxinc/WhisperKit/issues/301) — Performance degradation vs whisper.cpp (3.7x slower even with GPU)
5. [WhisperKit Issue #265](https://github.com/argmaxinc/WhisperKit/issues/265) — Memory leak with .cpuAndGPU on M1
6. [WhisperKit Issue #328](https://github.com/argmaxinc/WhisperKit/issues/328) — ANE contention with video effects during transcription
7. [hollance/neural-engine](https://github.com/hollance/neural-engine) — Community documentation on ANE limitations
8. [MLX Unified Memory docs](https://ml-explore.github.io/mlx/build/html/usage/unified_memory.html) — GPU direct memory access
9. [Apple MacBook Pro Specs](https://www.apple.com/macbook-pro/specs/) — M5 Pro hardware specifications
10. [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) — Pre-compiled CoreML model variants
