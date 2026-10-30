#!/usr/bin/env python3
"""Builds ThirdParty/LocalVQE-CoreML: the Core ML half of Parley's mic echo canceller (#342).

LocalVQE v1.4-AEC is an adaptive filter (C++, ThirdParty/CLocalVQE) followed by a 200K-parameter
residual mask. The mask comes from soniqo's Core ML export of the upstream model, which this script
downloads at a pinned revision and checks file by file. That export keeps its streaming memory in seven
Core ML states, and macOS 27.0.1 refuses to load a stateful model with more than one state, or with one
state and more than one output (Core ML's MIL->EIR translation throws std::bad_cast). So the script
rebuilds the same program, op for op and with the same fp16 weights, with the seven states packed into
one flat state, then compiles it.

It also writes the adaptive filter's inputs: its 2,742 controller weights, taken from the upstream GGUF
in the order ThirdParty/CLocalVQE/localvqe_daf.cpp expects, and the codec's analysis window, both as
little-endian float32. MANIFEST.json records every input and output by SHA-256.

Needs coremltools, numpy and gguf, in a conda env (never on the host):
    conda create -n localvqe-coreml python=3.12 && conda run -n localvqe-coreml \
        pip install coremltools==9.0 numpy gguf
    conda run -n localvqe-coreml python -I scripts/build-localvqe-coreml.py
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

import coremltools as ct
import gguf
import numpy as np
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import types
from coremltools.libmilstoragepython import _BlobStorageReader

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEST = os.path.join(ROOT, "ThirdParty", "LocalVQE-CoreML")
MASK = "LocalVQEAECResidualMask"

SONIQO_REPO = "aufklarer/LocalVQE-v1.4-AEC-200K-CoreML"
SONIQO_REV = "10e904d53a1303bb46eb17950b1c840543d0af75"
SONIQO_FILES = {  # file -> sha256 (the export's own checksums.json at that revision)
    f"{MASK}.mlmodelc/model.mil": "7e252ad7629afe25940ea11ddcc60b1a1e4f402c07a588e806dbdcced9957749",
    f"{MASK}.mlmodelc/weights/weight.bin": "f49a23b35e91c871f39f1137d29c5614f52fc62179b95733c5f2dd88a6fe91ea",
    f"{MASK}.mlmodelc/coremldata.bin": "f53fbc56039439ab79501bbc010ca65ef3a9940c54cb67c6566ab3c321829624",
    "LocalVQEAECFrontend.npz": "cf388c0027fd0f3672ae2464907f8d1ac0b9ece7ea968b96c5f06e403ac96b80",
}
UPSTREAM_REPO = "LocalAI-io/LocalVQE"
UPSTREAM_REV = "29ca38495cba9d6393a92a4dd890f28dd81f758d"
GGUF_FILE = "localvqe-v1.4-aec-200K-f32.gguf"
GGUF_SHA = "b6e43138588a83bfe903ab5e143b4020b91c1e1629f5a575ac5855ff0003c731"  # also the export's source

# localvqe_daf.cpp's kTensors, in order.
DAF_TENSORS = [
    ("daf.glob.norm.ln.weight", 6), ("daf.glob.norm.ln.bias", 6), ("daf.glob.gru.weight_ih", 240),
    ("daf.glob.gru.weight_hh", 192), ("daf.glob.gru.bias_ih", 24), ("daf.glob.gru.bias_hh", 24),
    ("daf.bins.norm.ln.weight", 6), ("daf.bins.norm.ln.bias", 6), ("daf.bins.gru.weight_ih", 864),
    ("daf.bins.gru.weight_hh", 768), ("daf.bins.gru.bias_ih", 48), ("daf.bins.gru.bias_hh", 48),
    ("daf.part.ln.weight", 2), ("daf.part.ln.bias", 2), ("daf.part.gru.weight_ih", 240),
    ("daf.part.gru.weight_hh", 192), ("daf.part.gru.bias_ih", 24), ("daf.part.gru.bias_hh", 24),
    ("daf.head.weight", 16), ("daf.head.bias", 1), ("daf.part.head.weight", 8), ("daf.part.head.bias", 1),
]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fetch(repo, rev, name, expected, into):
    path = os.path.join(into, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    urllib.request.urlretrieve(f"https://huggingface.co/{repo}/resolve/{rev}/{name}", path)
    got = sha256(path)
    if got != expected:
        sys.exit(f"{repo}/{name}: sha256 {got}, expected {expected}")
    return path


# ── the mask: parse the export's MIL text, rebuild it with one state ─────────────────────────────────

DT = {"fp16": np.float16, "fp32": np.float32, "int32": np.int32, "uint64": np.uint64}
OP = re.compile(r"^(?:(.+?)\s+(\w+)\s+=\s+)?(\w+)\((.*)\)\[name = string\(\"([^\"]+)\"\)(?:, val = (.*))?\]$", re.S)


def hexfloat(s):
    return float.fromhex(s) if "0x" in s else float(s)


def parse_value(v, blob):
    v = v.strip()
    if v.startswith("string("):
        return re.match(r'string\("(.*)"\)', v).group(1)
    m = re.match(r"(fp16|fp32|int32|bool|uint64)\((.*)\)$", v)
    if m:
        t, x = m.groups()
        if t == "bool":
            return np.bool_(x == "true")
        return DT[t](hexfloat(x)) if t in ("fp16", "fp32") else DT[t](int(x))
    m = re.match(r"tensor<(\w+), \[([\d, ]*)\]>\((.*)\)$", v, re.S)
    t, x = m.group(1), m.group(3)
    shape = tuple(int(s) for s in m.group(2).split(",") if s.strip())
    b = re.match(r"BLOBFILE\(path = string\(\"[^\"]+\"\), offset = uint64\((\d+)\)\)", x)
    if b:
        offset = int(b.group(1))
        if t == "fp16":  # the reader returns the raw half-precision bits
            return np.asarray(blob.read_fp16_data(offset), dtype=np.uint16).view(np.float16).reshape(shape)
        return np.asarray(blob.read_float_data(offset), dtype=np.float32).reshape(shape)
    items = re.findall(r"[^\[\],\s]+", x)
    if t == "bool":
        return np.array([i == "true" for i in items]).reshape(shape)
    if t in ("fp16", "fp32"):
        return np.array([hexfloat(i) for i in items], dtype=DT[t]).reshape(shape)
    return np.array([int(i) for i in items], dtype=DT[t]).reshape(shape)


def split_args(a):
    out, depth, cur = [], 0, ""
    for ch in a:
        depth += (ch == "(") - (ch == ")")
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [tuple(x.strip().split(" = ", 1)) for x in out]


def rebuild_mask(mlmodelc, out_package):
    text = open(os.path.join(mlmodelc, "model.mil")).read()
    blob = _BlobStorageReader(os.path.join(mlmodelc, "weights", "weight.bin"))
    sig = re.search(r"func main<ios18>\((.*?)\) \{\n", text, re.S)
    params = []
    for p in re.split(r",\s*(?=(?:state<|tensor<))", sig.group(1)):
        m = re.match(r"(state<)?tensor<fp16, \[([\d, ]+)\]>>?\s+(\w+)", p.strip())
        params.append((m.group(3), bool(m.group(1)), tuple(int(x) for x in m.group(2).split(","))))
    states = [(n, s) for n, is_state, s in params if is_state]
    inputs = [(n, s) for n, is_state, s in params if not is_state]
    body = text[sig.end():text.index("} -> (")]
    output = re.search(r"\} -> \((\w+)\);", text).group(1)
    lines = [l.strip() for l in body.split(";\n") if l.strip()]
    total = sum(int(np.prod(s)) for _, s in states)

    def program(*args):
        env = {n: args[i] for i, (n, _) in enumerate(inputs)}
        state = args[len(inputs)]
        whole = mb.read_state(input=state, name="packed_state_read")
        current, offset = {}, 0
        for n, s in states:  # unpack: each original state is a slice of the packed one
            k = int(np.prod(s))
            piece = mb.slice_by_index(x=whole, begin=[0, offset], end=[1, offset + k], name=f"{n}_slice")
            current[n] = mb.reshape(x=piece, shape=list(s), name=f"{n}_initial")
            offset += k

        def ref(x):
            x = x.strip()
            return [ref(y) for y in x[1:-1].split(",")] if x.startswith("(") else env[x]

        for line in lines:
            m = OP.match(line)
            if not m:
                sys.exit(f"unparsed MIL line: {line[:160]}")
            _, name, op, a, opname, val = m.groups()
            if op == "const":
                env[name] = mb.const(val=parse_value(val, blob), name=opname)
            elif op == "read_state":  # the latest value written to that state in this call
                env[name] = current[dict(split_args(a))["input"]]
            elif op == "write_state":
                kw = dict(split_args(a))
                current[kw["input"]] = ref(kw["data"])
            else:
                env[name] = getattr(mb, op)(**{k: ref(v) for k, v in split_args(a)}, name=opname)
        result = mb.identity(x=env[output], name=output)
        packed = [mb.reshape(x=current[n], shape=[1, int(np.prod(s))], name=f"{n}_final") for n, s in states]
        mb.coreml_update_state(state=state, value=mb.concat(values=packed, axis=1, name="packed_state_new"),
                               name="packed_state_write")
        return result

    names = [n for n, _ in inputs] + ["state"]
    scope = {"program": program}
    exec("def main(%s):\n    return program(%s)\n" % (", ".join(names), ", ".join(names)), scope)
    specs = [mb.TensorSpec(shape=s, dtype=types.fp16) for _, s in inputs]
    specs.append(mb.StateTensorSpec(shape=(1, total), dtype=types.fp16))
    prog = mb.program(input_specs=specs, opset_version=ct.target.macOS15)(scope["main"])
    model = ct.convert(prog, minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT32,
                       compute_units=ct.ComputeUnit.CPU_ONLY, skip_model_load=True)
    model.short_description = ("LocalVQE v1.4-AEC residual echo mask (soniqo's Core ML export, states packed "
                               "into one for macOS 27; Apache-2.0)")
    model.save(out_package)
    return states, total


# ── the filter's controller weights and the codec window ─────────────────────────────────────────────

def host_arrays(gguf_path, npz_path):
    tensors = {t.name: np.array(t.data, dtype=np.float32).ravel() for t in gguf.GGUFReader(gguf_path).tensors}
    npz = np.load(npz_path)
    controller = []
    for name, size in DAF_TENSORS:
        w = tensors[name]
        if w.size != size:
            sys.exit(f"{name}: {w.size} values, expected {size}")
        if not np.array_equal(w, npz[name].astype(np.float32).ravel()):
            sys.exit(f"{name}: the GGUF and the Core ML export's front-end archive disagree")
        controller.append(w)
    window = npz["analysis_window"].astype(np.float32).ravel()
    # The model's analysis transform is that window times the DFT: |encoder row pair| is the window.
    enc = tensors["encoder.conv.weight"].reshape(512, 512)
    from_encoder = np.hypot(enc[2], enc[3])
    if window.size != 512 or np.abs(window - from_encoder).max() > 1e-4:
        sys.exit("analysis window does not match the model's encoder")
    return np.concatenate(controller).astype("<f4"), window.astype("<f4")


def main():
    with tempfile.TemporaryDirectory() as work:
        for name, digest in SONIQO_FILES.items():
            fetch(SONIQO_REPO, SONIQO_REV, name, digest, work)
        gguf_path = fetch(UPSTREAM_REPO, UPSTREAM_REV, GGUF_FILE, GGUF_SHA, work)
        package = os.path.join(work, f"{MASK}.mlpackage")
        states, total = rebuild_mask(os.path.join(work, f"{MASK}.mlmodelc"), package)

        shutil.rmtree(DEST, ignore_errors=True)
        os.makedirs(DEST)
        compiled = os.path.join(work, "compiled")
        subprocess.run(["xcrun", "coremlcompiler", "compile", package, compiled], check=True,
                       stdout=subprocess.DEVNULL)
        shutil.copytree(os.path.join(compiled, f"{MASK}.mlmodelc"), os.path.join(DEST, f"{MASK}.mlmodelc"))
        controller, window = host_arrays(gguf_path, os.path.join(work, "LocalVQEAECFrontend.npz"))
        controller.tofile(os.path.join(DEST, "daf_controller.f32"))
        window.tofile(os.path.join(DEST, "analysis_window.f32"))

        shutil.copy(os.path.join(ROOT, "ThirdParty", "CLocalVQE", "upstream", "LICENSE-LocalVQE"),
                    os.path.join(DEST, "LICENSE"))
        with open(os.path.join(DEST, "NOTICE"), "w") as f:
            f.write("LocalVQE v1.4-AEC (https://github.com/localai-org/LocalVQE, Apache-2.0).\n"
                    f"Residual mask: Core ML export by soniqo (https://huggingface.co/{SONIQO_REPO}, Apache-2.0),\n"
                    "rebuilt by Parley's scripts/build-localvqe-coreml.py with its seven states packed into one.\n"
                    f"Controller weights and analysis window: from {UPSTREAM_REPO}/{GGUF_FILE}.\n")

        outputs = {}
        for base, _, files in os.walk(DEST):
            for f in sorted(files):
                path = os.path.join(base, f)
                outputs[os.path.relpath(path, DEST)] = sha256(path)
        manifest = {
            "mask_source": {"repo": SONIQO_REPO, "revision": SONIQO_REV, "files": SONIQO_FILES},
            "upstream_model": {"repo": UPSTREAM_REPO, "revision": UPSTREAM_REV, "file": GGUF_FILE,
                               "sha256": GGUF_SHA},
            "packed_state": {"values": total, "layout": [[n, list(s)] for n, s in states]},
            "coremltools": ct.__version__,
            "files": dict(sorted(outputs.items())),
        }
        with open(os.path.join(DEST, "MANIFEST.json"), "w") as f:
            json.dump(manifest, f, indent=2)
            f.write("\n")
    print(f"wrote {DEST}: packed state of {total} values, {len(outputs)} files")


if __name__ == "__main__":
    main()
