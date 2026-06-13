# Zenon BIP39 CUDA Runner

This directory contains the RunPod-oriented CUDA implementation scaffold for the Zenon 12-word treasure hunt.

The current binary has two GPU modes:

```text
checksum mode: global offset -> tail words -> BIP39 checksum validation
address mode:  checksum-valid mnemonic -> Zenon target-address comparison
```

It validates GPU candidate ordering and BIP39 checksum filtering against Python vectors, and it includes a self-tested wallet oracle for the expensive crypto stages:

```text
PBKDF2-HMAC-SHA512 -> SLIP-10 Ed25519 -> Ed25519 public key -> SHA3-256 -> target core compare
```

## What This Tests

The encoded search shape is:

```text
known words = oblige dilemma hurry disorder happy spoil shiver key
word9..word12 = any BIP39 English word
target = z1qrn3jeapt848zxg3akf2ewhrxxwsa945sj798s
```

The generated workload contains:

```text
participating BIP39 words: 2,048
ordered tails: 17,592,186,044,416
expected checksum-valid phrases: about 1.10T
```

## RunPod Setup

Start with a CUDA devel image. The easiest path from the repo root is:

```sh
git clone --branch codex/full-wordlist-gpu-search https://github.com/0x3639/puzzle-test.git
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

The full-wordlist workload has `625` checksum-valid phrases in the first `10,000` candidates.

```sh
./gpu/build/zenon_bip39_cuda --start 0 --count 10000
```

Expected output fields:

```text
"stage": "bip39_checksum_only"
"checksum_valid": 625
"first_valid_global": 0
"first_valid_tail_indices": [0, 0, 0, 0]
```

The first valid tail indices correspond to:

```text
abandon abandon abandon abandon
```

## Larger Checksum Benchmark

```sh
./gpu/build/zenon_bip39_cuda --start 0 --count 100000000 --threads 256
```

This command only benchmarks enumeration and BIP39 checksum filtering. Use address mode for the target-address brute force.

Useful options:

```text
--start N     global candidate offset
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
17592186044416
```

From the repo root, the easier full-space wrapper is:

```sh
bash runpod/run.sh full
```

It runs the full space in chunks and writes JSONL progress under `out/`.

## Address Oracle

The CUDA binary now also has an address mode:

```sh
./gpu/build/zenon_bip39_cuda --mode self-test
./gpu/build/zenon_bip39_cuda --mode address --start 0 --count 100000
./gpu/build/zenon_bip39_cuda --mode address-compact --start 0 --count 100000000
```

From the repo root, prefer the wrapper:

```sh
bash runpod/run.sh oracle-test
bash runpod/run.sh address 0 100000
bash runpod/run.sh full-address
```

A hit prints `hit_found: true` and `hit_mnemonic`.

For full-wordlist search, prefer `address-compact`. It first gathers checksum-valid candidate offsets into a dense GPU queue, then runs the wallet oracle over that dense queue. The older single-pass `address` mode is still available for comparison, but it wastes most warp lanes during wallet derivation because only about 1 in 16 candidates passes the BIP39 checksum.

## Full Oracle Notes

The address oracle runs:

```text
1. HMAC-SHA512 / PBKDF2-HMAC-SHA512, 2048 iterations
2. SLIP-10 Ed25519 hardened derivation
3. Ed25519 public-key generation
4. SHA3-256 public-key hash
5. 20-byte target-core compare
```

The highest-risk piece is Ed25519 public-key generation on GPU, so run `oracle-test` before trusting a long search.

## Throughput Tuning

Use `address_derivations_per_second` as the main metric. `nvidia-smi` utilization can be misleading for the old single-pass mode because the sparse checksum branch leaves most lanes inactive during PBKDF2.

Suggested Blackwell sweep from the repo root:

```sh
bash runpod/run.sh address 0 100000000
CUDA_THREADS=128 bash runpod/run.sh address 0 100000000
CUDA_THREADS=256 bash runpod/run.sh address 0 100000000
CUDA_THREADS=512 bash runpod/run.sh address 0 100000000
CUDA_BLOCKS=4096 CUDA_THREADS=128 bash runpod/run.sh address 0 100000000
CUDA_BLOCKS=8192 CUDA_THREADS=128 bash runpod/run.sh address 0 100000000
```

Then run the full search with the best setting:

```sh
CUDA_BLOCKS=4096 CUDA_THREADS=128 ADDRESS_CHUNK=1000000000 bash runpod/run.sh full-address
```

If compact mode reports `"queue_overflow": true`, lower `ADDRESS_CHUNK` or raise `VALID_CAPACITY`.

## Troubleshooting

If `cmake` cannot find CUDA, confirm `nvcc` is available:

```sh
nvcc --version
```

If the binary builds but the smoke test does not report `checksum_valid: 625`, stop and compare:

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
