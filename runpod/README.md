# RunPod Quick Start

Use this if you just want to run the CUDA runner with as little ceremony as possible.

This branch defaults to full-wordlist mode:

```text
2048^4 = 17,592,186,044,416 candidate tails
expected checksum-valid address derivations = 1,099,511,627,776
```

## One-Command Smoke Test

On a RunPod CUDA devel pod:

```sh
git clone --branch codex/full-wordlist-gpu-search https://github.com/0x3639/puzzle-test.git
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
"checksum_valid": 625
"first_valid_global": 0
"first_valid_tail_indices": [0, 0, 0, 0]
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

## Address Oracle

The address oracle is the part that can actually find the four words. It runs:

```text
BIP39 checksum
PBKDF2-HMAC-SHA512
SLIP-10 Ed25519 path m/44'/73404'/0'
Ed25519 public key
SHA3-256
target-core comparison
```

First run the validation vector:

```sh
bash runpod/run.sh oracle-test
```

You want:

```text
"self_test_pass": true
```

Then try a small range:

```sh
bash runpod/run.sh address 0 100000
```

A real hit will print:

```text
"hit_found": true
"hit_mnemonic": "oblige dilemma hurry disorder happy spoil shiver key ... ... ... ..."
```

Run the full address search in chunks:

```sh
bash runpod/run.sh full-address
```

By default, address mode uses `1,000,000`-candidate chunks because each checksum-valid candidate performs expensive wallet derivation. Use a larger chunk only after you see stable timings:

```sh
bash runpod/run.sh full-address 10000000
```

Resume from an offset:

```sh
ADDRESS_OUTPUT=out/address.jsonl ADDRESS_START=1000000000 bash runpod/run.sh full-address
```

## Full-Wordlist ETA

The full address search has:

```text
17,592,186,044,416 candidate tails
1,099,511,627,776 expected checksum-valid address derivations
```

Run this first to measure your actual Blackwell rate:

```sh
bash runpod/run.sh address 0 1000000
```

Then use:

```text
ETA seconds = 1,099,511,627,776 / address_derivations_per_second
```

Reference table:

```text
1,000 derivations/sec      about 34.9 years
10,000 derivations/sec     about 3.5 years
100,000 derivations/sec    about 127 days
1,000,000 derivations/sec  about 12.7 days
10,000,000 derivations/sec about 30.5 hours
```

## Full Checksum Batch

Run the entire full-wordlist candidate space through the current GPU checksum stage:

```sh
bash runpod/run.sh full
```

This scans:

```text
17,592,186,044,416 candidates
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

Important: this is the checksum-only GPU stage. Use `full-address` to run the full target-address oracle.

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
"candidate_count_sum": 17592186044416
"gap_count": 0
"overlap_count": 0
```

The `checksum_valid` value should be close to:

```text
1099511627776.0
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

The address oracle is new and should be treated as validation-first code. Always run `bash runpod/run.sh oracle-test` after pulling changes or switching GPU images.
