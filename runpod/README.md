# RunPod Quick Start

Use this if you just want to run the CUDA checksum runner with as little ceremony as possible.

## One-Command Smoke Test

On a RunPod CUDA devel pod:

```sh
git clone --branch codex/zenon-cuda-kernel https://github.com/0x3639/puzzle-test.git
cd puzzle-test
bash runpod/run.sh smoke
```

That command will:

```text
install missing apt packages when possible
create .venv
install Python requirements
generate out/gpu_workload.json
generate gpu/generated/gpu_workload.h
detect CUDA architecture
configure CMake
build gpu/build/zenon_bip39_cuda
run the 10,000-candidate smoke test
verify expected output
```

Expected smoke-test fields:

```text
"checksum_valid": 643
"first_valid_global": 9
"first_valid_tail_indices": [19, 19, 19, 28]
```

## Pick The Right RunPod Image

Use a CUDA `devel` image. A CUDA `runtime` image usually will not include `nvcc`, which is required to build the `.cu` file.

Good choices:

```text
NVIDIA CUDA 12.x devel Ubuntu image
RunPod PyTorch image with CUDA devel tools
```

Check:

```sh
nvcc --version
nvidia-smi
```

## Commands

Setup and build only:

```sh
bash runpod/run.sh setup
```

Smoke test:

```sh
bash runpod/run.sh smoke
```

Default benchmark, 100,000,000 candidates from offset 0:

```sh
bash runpod/run.sh benchmark
```

Custom benchmark count:

```sh
bash runpod/run.sh benchmark 500000000
```

Custom range:

```sh
bash runpod/run.sh range 500000000 100000000
```

That means:

```text
start = 500,000,000
count = 100,000,000
```

## Full Checksum Batch

Run the entire exact-length candidate space through the current GPU checksum stage:

```sh
bash runpod/run.sh full
```

This scans:

```text
69,026,912,600 candidates
```

By default it runs in `100,000,000`-candidate chunks and appends one compact JSON record per chunk to:

```text
out/runpod_full_<timestamp>.jsonl
```

Use a larger chunk if your GPU is stable and you want less loop overhead:

```sh
bash runpod/run.sh full 500000000
```

Write to a predictable output file:

```sh
FULL_OUTPUT=out/full_checksum.jsonl bash runpod/run.sh full
```

Resume from a known offset:

```sh
FULL_OUTPUT=out/full_checksum.jsonl FULL_START=1000000000 bash runpod/run.sh full
```

Run only a bounded window:

```sh
bash runpod/run.sh full 100000000 1000000000 2000000000
```

Arguments are:

```text
full [chunk_size] [start] [stop]
```

Important: this is still the checksum-only GPU stage. It does not yet perform the final Zenon address derivation.

## After Full Completes

Summarize the newest full-batch output:

```sh
bash runpod/run.sh summarize
```

Or summarize a specific file:

```sh
bash runpod/run.sh summarize out/full_checksum.jsonl
```

You want:

```text
"full_space_covered": true
"candidate_count_sum": 69026912600
"gap_count": 0
"overlap_count": 0
```

The `checksum_valid` value should be close to:

```text
4314182037.5
```

That value is an expectation, not an exact required count.

## GPU Architecture Overrides

The script tries to detect compute capability with `nvidia-smi`.

Override it if needed:

```sh
CUDA_ARCH=90 bash runpod/run.sh smoke           # H100 with matching toolkit
CUDA_ARCH=90-virtual bash runpod/run.sh smoke   # newer GPU, older toolkit
CUDA_ARCH=89 bash runpod/run.sh smoke           # RTX 4090 / L40S
CUDA_ARCH=80 bash runpod/run.sh smoke           # A100
```

If you see `Unsupported gpu architecture 'compute_120'`, your GPU is newer than the installed CUDA toolkit. Pull the latest script and rerun:

```sh
git pull
bash runpod/run.sh smoke
```

If you need an immediate manual override, try:

```sh
CUDA_ARCH=90-virtual bash runpod/run.sh smoke
```

If that still fails on an older toolkit:

```sh
CUDA_ARCH=89-virtual bash runpod/run.sh smoke
CUDA_ARCH=86-virtual bash runpod/run.sh smoke
```

## Important Limit

The CUDA binary currently validates candidate enumeration and BIP39 checksums only.

It does not yet run:

```text
PBKDF2-HMAC-SHA512
SLIP-10 Ed25519
Ed25519 public key
SHA3-256
Zenon target-address comparison
```

So a passing RunPod benchmark tells us the GPU candidate/checksum stage works. It does not yet mean the final four words have been searched against the target address on GPU.
