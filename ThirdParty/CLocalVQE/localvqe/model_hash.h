#ifndef LOCALVQE_MODEL_HASH_H
#define LOCALVQE_MODEL_HASH_H

namespace localvqe {

// SHA-256 the file at `path` and check the digest against the
// compiled-in allowlist of released LocalVQE GGUFs (mirrors the
// hashes in ggml/CMakeLists.txt). Returns true on a match.
//
// When LOCALVQE_ALLOW_UNHASHED=1 is set in the environment, this
// returns true unconditionally (intended for development workflows
// using locally-built GGUFs that aren't on the released list).
//
// On mismatch or read error, returns false and prints a diagnostic
// (including the file's actual SHA-256) to stderr.
bool verify_model_hash(const char* path);

}  // namespace localvqe

#endif
