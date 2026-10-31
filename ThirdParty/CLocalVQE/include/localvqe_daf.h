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

/// The reference delay (samples) the online GCC-PHAT estimate currently applies.
int32_t localvqe_daf_delay_samples(const localvqe_daf *daf);

#ifdef __cplusplus
}
#endif

#endif
