// Parley's C interface to LocalVQE v1.4-AEC's adaptive-filter front end (upstream/daf_frontend.*, #342).
// The filter removes the linear part of the echo; the Core ML residual mask (ThirdParty/LocalVQE-CoreML)
// removes what is left. Streaming: 16 kHz mono float, any multiple of 128 samples per call.
#ifndef LOCALVQE_DAF_H
#define LOCALVQE_DAF_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct localvqe_daf localvqe_daf;

/// Number of float32 controller weights `localvqe_daf_create` expects, in the order of
/// `localvqe_daf_weight_name`.
size_t localvqe_daf_weight_count(void);

/// Number of named controller tensors, and each one's upstream name and element count, so the asset
/// builder and the loader agree on the layout of the flat weight file.
size_t localvqe_daf_tensor_count(void);
const char *localvqe_daf_tensor_name(size_t index);
size_t localvqe_daf_tensor_size(size_t index);

/// Creates a filter from the flat controller weights. NULL when `weights` is NULL or `count` is wrong.
localvqe_daf *localvqe_daf_create(const float *weights, size_t count);
void localvqe_daf_destroy(localvqe_daf *daf);

/// Clears all online state (delay estimate, filter, controller): a new recording.
void localvqe_daf_reset(localvqe_daf *daf);

/// Filters `count` samples (a multiple of 128). `residual` receives the echo-cancelled mic and
/// `echo_estimate` receives mic minus residual; each needs room for `count` floats.
/// Returns false, writing nothing, when `count` is not a multiple of 128.
bool localvqe_daf_process(localvqe_daf *daf, const float *mic, const float *reference, size_t count,
                          float *residual, float *echo_estimate);

/// Offline callers (#361): the bulk echo delay estimated over the whole clip before it is filtered, instead of
/// upstream's online estimate, which locks for good at the first confident one 3.5 s in and can lock wrong on a
/// call's opening seconds. The same estimate as upstream's daf_prime_delay (the highest-confidence GCC-PHAT shift
/// over the clip, upstream's own gcc_update), fed a block at a time so the clip is never held: about 2.7 s
/// for a 30-minute chunk.
///
/// `begin` clears all state; `push` feeds any number of samples (the delay estimate only, no filtering);
/// `end` clears the filter and freezes the delay for the `localvqe_daf_process` calls that follow. Only shifts
/// of at most `max_delay` samples count: a shift past the real delay leaves the echo before the filter's
/// window, where it cannot be removed at all, while one short of it is still inside the filter's 1.024 s.
/// `end` returns the frozen delay in samples, or -1 when no estimate within the bound was confident; the delay
/// is then frozen at 0, where the filter's window covers echo delays of 0 to 1.024 s. `confidence`, when not
/// NULL, receives the estimate's GCC-PHAT confidence (its peak over the mean; upstream's threshold is 8).
void localvqe_daf_prime_begin(localvqe_daf *daf, int32_t max_delay);
void localvqe_daf_prime_push(localvqe_daf *daf, const float *mic, const float *reference, size_t count);
int32_t localvqe_daf_prime_end(localvqe_daf *daf, float *confidence);

/// Upstream's own whole-array estimate (daf_prime_delay, no bound) over `count` samples, for tests to hold the
/// streaming estimate's block handling to. Leaves all state reset. Returns the delay, or -1 when none was confident.
int32_t localvqe_daf_upstream_prime_delay(localvqe_daf *daf, const float *mic, const float *reference, size_t count);

/// The reference delay (samples) the filter currently applies: the online GCC-PHAT estimate, or the
/// frozen one after `localvqe_daf_prime_end`.
int32_t localvqe_daf_delay_samples(const localvqe_daf *daf);

#ifdef __cplusplus
}
#endif

#endif
