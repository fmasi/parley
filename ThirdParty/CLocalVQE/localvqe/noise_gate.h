#ifndef LOCALVQE_NOISE_GATE_H
#define LOCALVQE_NOISE_GATE_H

/**
 * Hard frame-level noise gate.
 *
 * Header-only so the C API and the standalone unit test can share one
 * implementation. Treating the gate as a small reusable utility (rather
 * than a method on the API context) keeps the API call site honest:
 * `apply_noise_gate(...)` is one line and reads as exactly that.
 */

#include <cmath>
#include <cstring>

namespace localvqe {

/**
 * Replace `x[0..n)` with zeros if its RMS, expressed in dBFS, sits at
 * or below `threshold_dbfs`. Otherwise leave it unchanged.
 *
 * The 1e-30 epsilon on the energy keeps log10 finite for an all-zero
 * input. That frame would already be silent so the result is irrelevant,
 * but we still want to avoid -inf propagating out of the comparison.
 */
inline void apply_noise_gate(float* x, int n, float threshold_dbfs) {
    if (n <= 0) return;
    double sumsq = 0.0;
    for (int i = 0; i < n; i++) sumsq += static_cast<double>(x[i]) * x[i];
    double mean_sq = sumsq / static_cast<double>(n);
    // 20 log10(rms) = 10 log10(rms^2).
    double rms_db = 10.0 * std::log10(mean_sq + 1e-30);
    if (rms_db <= static_cast<double>(threshold_dbfs)) {
        std::memset(x, 0, static_cast<size_t>(n) * sizeof(float));
    }
}

} // namespace localvqe

#endif /* LOCALVQE_NOISE_GATE_H */
