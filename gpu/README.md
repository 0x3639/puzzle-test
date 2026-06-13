# Zenon BIP39 CUDA Runner

This directory contains the RunPod-oriented CUDA implementation scaffold for the Zenon 12-word treasure hunt.

The current binary is a GPU checksum runner:

```text
global candidate offset -> exact-length tail words -> BIP39 checksum validation
```

It validates GPU candidate ordering and BIP39 checksum filtering against the Python runner. The full wallet oracle still needs the expensive crypto stages:

```text
PBKDF2-HMAC-SHA512 -> SLIP-10 Ed25519 -> Ed25519 public key -> SHA3-256 -> target core compare
```

## What This Tests

The encoded search shape is:

```text
known words = oblige dilemma hurry disorder happy spoil shiver key
len("word9 word10 word11 word12") == 18
target = z1qrn3jeapt848zxg3akf2ewhrxxwsa945sj798s
```

The generated workload contains:

```text
participating BIP39 words: 1,608
ordered exact-length tails: 69,026,912,600
expected checksum-valid phrases: about 4.31B
```

## RunPod Setup

Start with a CUDA devel image. The easiest path from the repo root is:

```sh
git clone --branch codex/zenon-cuda-kernel https://github.com/0x3639/puzzle-test.git
cd puzzle-test
bash runpod/run.sh smoke
```

The helper script installs missing apt packages when possible, creates `.venv`, installs Python requirements, generates the workload, detects `CMAKE_CUDA_ARCHITECTURES`, builds, and verifies the smoke test.

Manual setup is below if you prefer to run each step yourself.

## Generate Workload Header

From repo root:

```sh
python3 scripts/prepare_gpu_workload.py
python3 scripts/emit_cuda_workload_header.py
```

This writes:

```text
gpu/generated/gpu_workload.h
```

Regenerate this header whenever `out/gpu_workload.json`, `scripts/prepare_gpu_workload.py`, or the target search constraints change.

## Build

```sh
cmake -S gpu -B gpu/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=89
cmake --build gpu/build -j
```

CUDA architecture choices:

```text
RTX 4090: 89
L40/L40S: 89
H100: 90
A100: 80
```

For H100:

```sh
cmake -S gpu -B gpu/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=90
cmake --build gpu/build -j
```

For a newer GPU with an older CUDA toolkit, use a virtual PTX target:

```sh
cmake -S gpu -B gpu/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=90-virtual
cmake --build gpu/build -j
```

## Smoke Test

The Python runner measured `643` checksum-valid phrases in the first `10,000` exact-length candidates.

```sh
./gpu/build/zenon_bip39_cuda --start 0 --count 10000
```

Expected output fields:

```text
"stage": "bip39_checksum_only"
"checksum_valid": 643
"first_valid_global": 9
"first_valid_tail_indices": [19, 19, 19, 28]
```

The first valid tail indices correspond to:

```text
act act act adjust
```

## Larger Checksum Benchmark

```sh
./gpu/build/zenon_bip39_cuda --start 0 --count 100000000 --threads 256
```

This only benchmarks enumeration and BIP39 checksum filtering. It is not yet the full address brute force.

Useful options:

```text
--start N     global exact-length candidate offset
--count N     number of candidates to scan
--threads N   CUDA threads per block, default 256
--blocks N    CUDA block count, default is 8 * GPU SM count
```

Example split into two ranges:

```sh
./gpu/build/zenon_bip39_cuda --start 0 --count 100000000
./gpu/build/zenon_bip39_cuda --start 100000000 --count 100000000
```

The total candidate space is:

```text
69026912600
```

## Full Oracle Work Remaining

The remaining CUDA work is in this order:

```text
1. HMAC-SHA512
2. PBKDF2-HMAC-SHA512, 2048 iterations
3. SLIP-10 Ed25519 hardened derivation
4. Ed25519 public-key generation
5. SHA3-256 public-key hash
6. 20-byte target-core compare
```

The highest-risk piece is Ed25519 public-key generation on GPU.

Until those stages are implemented, this binary cannot find the final target address by itself. It is a correctness and throughput foundation for the full GPU brute-force kernel.

## Troubleshooting

If `cmake` cannot find CUDA, confirm `nvcc` is available:

```sh
nvcc --version
```

If the binary builds but the smoke test does not report `checksum_valid: 643`, stop and compare:

```sh
python3 scripts/prepare_gpu_workload.py
python3 scripts/emit_cuda_workload_header.py
./gpu/build/zenon_bip39_cuda --start 0 --count 10000
```

If you switch GPUs, delete the build directory and configure again with the right architecture:

```sh
rm -rf gpu/build
cmake -S gpu -B gpu/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=89
cmake --build gpu/build -j
```
