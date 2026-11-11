// Parley's C interface over LocalVQE's daf_frontend (see include/localvqe_daf.h).
//
// Upstream's source is compiled as part of this file (Package.swift excludes it from the target), so the
// whole-clip delay estimate (#361) runs upstream's own file-local gcc_update and the vendored code stays
// exactly as scripts/vendor-localvqe.sh writes it.
#include "localvqe_daf.h"
#include "upstream/daf_frontend.cpp"

#include <algorithm>
#include <cstring>
#include <new>
#include <utility>

namespace {
// The controller's tensors in the order of the flat weight file. Names and sizes are upstream's
// (the "daf.*" tensors of localvqe-v1.4-aec-200K-f32.gguf).
const std::pair<const char *, size_t> kTensors[] = {
    {"daf.glob.norm.ln.weight", 6},   {"daf.glob.norm.ln.bias", 6},   {"daf.glob.gru.weight_ih", 240},
    {"daf.glob.gru.weight_hh", 192},  {"daf.glob.gru.bias_ih", 24},   {"daf.glob.gru.bias_hh", 24},
    {"daf.bins.norm.ln.weight", 6},   {"daf.bins.norm.ln.bias", 6},   {"daf.bins.gru.weight_ih", 864},
    {"daf.bins.gru.weight_hh", 768},  {"daf.bins.gru.bias_ih", 48},   {"daf.bins.gru.bias_hh", 48},
    {"daf.part.ln.weight", 2},        {"daf.part.ln.bias", 2},        {"daf.part.gru.weight_ih", 240},
    {"daf.part.gru.weight_hh", 192},  {"daf.part.gru.bias_ih", 24},   {"daf.part.gru.bias_hh", 24},
    {"daf.head.weight", 16},          {"daf.head.bias", 1},           {"daf.part.head.weight", 8},
    {"daf.part.head.bias", 1},
};
constexpr size_t kTensorCount = sizeof(kTensors) / sizeof(kTensors[0]);
}  // namespace

struct localvqe_daf {
    daf_frontend fe;
    // The whole-clip delay estimate (localvqe_daf_prime_*): input short of a whole block, and the best
    // shift so far within the bound.
    std::vector<float> prime_mic, prime_ref;
    int32_t prime_max_delay = 0;
    int prime_best_shift = 0;
    float prime_best_conf = 0.0f;
};

namespace {
// One M-sample block of upstream's daf_prime_delay loop, with the bound on the shift.
void prime_block(localvqe_daf *daf, const float *mic, const float *ref) {
    daf_frontend &fe = daf->fe;
    const int M = daf_frontend::M, W = daf_frontend::G_WIN;
    std::memmove(fe.mic_ring.data(), fe.mic_ring.data() + M, (W - M) * sizeof(float));
    std::memcpy(fe.mic_ring.data() + W - M, mic, M * sizeof(float));
    std::memmove(fe.ref_ring.data(), fe.ref_ring.data() + M, (W - M) * sizeof(float));
    std::memcpy(fe.ref_ring.data() + W - M, ref, M * sizeof(float));
    fe.n_seen += M;
    if (fe.n_seen >= W && ((fe.n_seen - W) % daf_frontend::G_HOP) < M) {
        gcc_update(fe);
        fe.gcc_locked = false;  // keep refining over the entire signal
        if (fe.gcc_conf > daf->prime_best_conf && fe.cur_shift <= daf->prime_max_delay) {
            daf->prime_best_conf = fe.gcc_conf;
            daf->prime_best_shift = fe.cur_shift;
        }
    }
}
}  // namespace

extern "C" {

size_t localvqe_daf_tensor_count(void) { return kTensorCount; }

const char *localvqe_daf_tensor_name(size_t index) {
    return index < kTensorCount ? kTensors[index].first : nullptr;
}

size_t localvqe_daf_tensor_size(size_t index) { return index < kTensorCount ? kTensors[index].second : 0; }

size_t localvqe_daf_weight_count(void) {
    size_t n = 0;
    for (const auto &t : kTensors) n += t.second;
    return n;
}

localvqe_daf *localvqe_daf_create(const float *weights, size_t count) {
    if (weights == nullptr || count != localvqe_daf_weight_count()) return nullptr;
    std::map<std::string, NpyArray> tensors;
    size_t offset = 0;
    for (const auto &t : kTensors) {
        NpyArray a;
        a.data.assign(weights + offset, weights + offset + t.second);
        a.shape = {static_cast<int64_t>(t.second)};
        tensors[t.first] = std::move(a);
        offset += t.second;
    }
    auto *daf = new (std::nothrow) localvqe_daf();
    if (daf == nullptr) return nullptr;
    if (!daf_init_tensors(daf->fe, tensors)) {
        delete daf;
        return nullptr;
    }
    daf->fe.enable_prealign = true;  // online GCC-PHAT acquisition, as upstream's v1.4 cascade runs it
    return daf;
}

void localvqe_daf_destroy(localvqe_daf *daf) { delete daf; }

void localvqe_daf_reset(localvqe_daf *daf) {
    if (daf != nullptr) daf_reset(daf->fe);
}

bool localvqe_daf_process(localvqe_daf *daf, const float *mic, const float *reference, size_t count,
                          float *residual, float *echo_estimate) {
    if (daf == nullptr || mic == nullptr || reference == nullptr || residual == nullptr ||
        echo_estimate == nullptr || count % daf_frontend::M != 0)
        return false;
    daf_process(daf->fe, mic, reference, static_cast<int>(count), residual, echo_estimate);
    return true;
}

void localvqe_daf_prime_begin(localvqe_daf *daf, int32_t max_delay) {
    if (daf == nullptr) return;
    daf_reset(daf->fe);
    daf->prime_mic.clear();
    daf->prime_ref.clear();
    daf->prime_max_delay = std::max<int32_t>(0, max_delay);
    daf->prime_best_shift = 0;
    daf->prime_best_conf = 0.0f;
}

void localvqe_daf_prime_push(localvqe_daf *daf, const float *mic, const float *reference, size_t count) {
    if (daf == nullptr || mic == nullptr || reference == nullptr) return;
    const size_t M = daf_frontend::M;
    size_t offset = 0;
    if (!daf->prime_mic.empty()) {  // complete the partial block first
        const size_t take = std::min(M - daf->prime_mic.size(), count);
        daf->prime_mic.insert(daf->prime_mic.end(), mic, mic + take);
        daf->prime_ref.insert(daf->prime_ref.end(), reference, reference + take);
        offset = take;
        if (daf->prime_mic.size() < M) return;
        prime_block(daf, daf->prime_mic.data(), daf->prime_ref.data());
        daf->prime_mic.clear();
        daf->prime_ref.clear();
    }
    for (; offset + M <= count; offset += M) prime_block(daf, mic + offset, reference + offset);
    daf->prime_mic.assign(mic + offset, mic + count);
    daf->prime_ref.assign(reference + offset, reference + count);
}

int32_t localvqe_daf_prime_end(localvqe_daf *daf, float *confidence) {
    if (confidence != nullptr) *confidence = 0.0f;
    if (daf == nullptr) return -1;
    if (confidence != nullptr) *confidence = daf->prime_best_conf;
    // As daf_prime_delay: a trailing partial block is not estimated over.
    daf->prime_mic.clear();
    daf->prime_ref.clear();
    daf_reset(daf->fe);
    const bool confident = daf->prime_best_conf > daf_frontend::G_CONF_THR;
    daf->fe.cur_shift = confident ? daf->prime_best_shift : 0;
    daf->fe.gcc_locked = true;  // freeze: no online re-estimation
    return confident ? daf->prime_best_shift : -1;
}

int32_t localvqe_daf_upstream_prime_delay(localvqe_daf *daf, const float *mic, const float *reference, size_t count) {
    if (daf == nullptr || mic == nullptr || reference == nullptr) return -1;
    daf_prime_delay(daf->fe, mic, reference, static_cast<int>(count));
    const int32_t shift = daf->fe.gcc_locked ? daf->fe.cur_shift : -1;
    daf_reset(daf->fe);
    return shift;
}

int32_t localvqe_daf_delay_samples(const localvqe_daf *daf) { return daf != nullptr ? daf->fe.cur_shift : 0; }

}  // extern "C"
