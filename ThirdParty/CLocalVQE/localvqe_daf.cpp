// Parley's C interface over LocalVQE's daf_frontend (see include/localvqe_daf.h).
#include "localvqe_daf.h"
#include "upstream/daf_frontend.h"

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
};

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

int32_t localvqe_daf_delay_samples(const localvqe_daf *daf) { return daf != nullptr ? daf->fe.cur_shift : 0; }

}  // extern "C"
