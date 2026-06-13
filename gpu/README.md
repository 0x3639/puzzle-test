# Zenon BIP39 CUDA Runner

This is the RunPod-oriented CUDA implementation scaffold for the Zenon 12-word treasure hunt.

Current implemented stage:

```text
global candidate offset -> exact-length tail words -> BIP39 checksum validation
```

This validates the GPU candidate ordering and checksum filter against the Python runner. The full wallet oracle still needs the expensive crypto stages:

```text
PBKDF2-HMAC-SHA512 -> SLIP-10 Ed25519 -> Ed25519 public key -> SHA3-256 -> target core compare
```

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

## Build On RunPod

Use an NVIDIA CUDA image, then:

```sh
cmake -S gpu -B gpu/build -DCMAKE_BUILD_TYPE=Release
cmake --build gpu/build -j
```

For RTX 4090, `CMAKE_CUDA_ARCHITECTURES=89` is appropriate. For H100, use `90`.

## Smoke Test

The Python runner measured `643` checksum-valid phrases in the first `10,000` exact-length candidates.

```sh
./gpu/build/zenon_bip39_cuda --start 0 --count 10000
```

Expected:

```text
checksum_valid=643
first_valid_global=9
first_valid_tail_indices=[19, 19, 19, 28]
```

## Larger Checksum Benchmark

```sh
./gpu/build/zenon_bip39_cuda --start 0 --count 100000000 --threads 256
```

This only benchmarks enumeration and BIP39 checksum filtering. It is not yet the full address brute force.

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
