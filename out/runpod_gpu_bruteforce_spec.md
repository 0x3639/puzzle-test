# RunPod GPU Brute Force Spec

## Bottom Line

Yes, the brute force can be rewritten for a RunPod GPU, but it is not a simple Python/CuPy port.

The current Python script is slow because every checksum-valid candidate performs:

```text
BIP39 PBKDF2-HMAC-SHA512, 2048 iterations
SLIP-10 Ed25519 hardened derivation: m/44'/73404'/0'
Ed25519 public key generation
SHA3-256(public_key)
Zenon address core comparison
```

A useful GPU implementation must keep that whole address oracle on the GPU. Moving only candidate enumeration or only checksum filtering to the GPU would not materially solve the runtime problem.

## Current CPU Baseline

Measured on the local machine:

```text
100,000 exact-length combinations: 6.911 seconds
candidate rate: ~14,470 combinations/sec
Zenon derivation rate: ~906 derivations/sec
full exact-length combinations: 69,026,912,600
estimated checksum-valid derivations: ~4,314,182,038
single-process CPU runtime: ~55 days
```

## Why GPU Can Help

The search is embarrassingly parallel:

```text
candidate N -> checksum -> BIP39 seed -> Zenon address -> compare target
candidate N+1 -> checksum -> BIP39 seed -> Zenon address -> compare target
...
```

There is no dependency between candidates, and a GPU can run many candidate checks at once.

## Why This Is Not A Trivial Rewrite

The hard parts are cryptographic kernels, not loop mechanics.

The GPU kernel needs implementations of:

```text
SHA-256               for BIP39 checksum
HMAC-SHA512           for PBKDF2 and SLIP-10
PBKDF2-HMAC-SHA512    2048 iterations
SLIP-10 Ed25519       hardened child key derivation
Ed25519 basepoint scalar multiplication
SHA3-256 / Keccak     Zenon public-key hash
target-core compare   compare 20-byte Zenon address core
```

The Ed25519 public key step is the most annoying part. It is not enough to derive the private key; the Zenon address is based on:

```text
0x00 || first_19_bytes(SHA3-256(public_key))
```

So the GPU either has to compute the Ed25519 public key or transfer billions of private keys back to the CPU, which would defeat the point.

## Candidate Space To Encode On GPU

Known seed prefix:

```text
oblige dilemma hurry disorder happy spoil shiver key
```

Target address:

```text
z1qrn3jeapt848zxg3akf2ewhrxxwsa945sj798s
```

Full theory constraint:

```text
len("word9 word10 word11 word12") == 18
```

Therefore:

```text
len(word9) + len(word10) + len(word11) + len(word12) = 15
```

Allowed BIP39 word lengths:

```text
3, 4, 5, 6
```

Search space:

```text
participating words: 1,608
ordered exact-length tails: 69,026,912,600
checksum-valid expected: ~4,314,182,038
```

Valid ordered length patterns:

```text
3 3 3 6
3 3 4 5
3 3 5 4
3 3 6 3
3 4 3 5
3 4 4 4
3 4 5 3
3 5 3 4
3 5 4 3
3 6 3 3
4 3 3 5
4 3 4 4
4 3 5 3
4 4 3 4
4 4 4 3
4 5 3 3
5 3 3 4
5 3 4 3
5 4 3 3
6 3 3 3
```

## Recommended GPU Architecture

### Host CPU

The host should:

1. Load the BIP39 English word list.
2. Build arrays of participating words by length.
3. Precompute BIP39 word indices.
4. Decode the target Zenon address to its 20-byte core.
5. Split the global candidate range into GPU batches.
6. Launch CUDA kernels.
7. Stop all workers if any kernel reports a hit.
8. Write the found mnemonic and metadata to disk.

### GPU Kernel

Each thread should:

1. Convert a global candidate offset into `(word9, word10, word11, word12)`.
2. Build the four 11-bit BIP39 indices.
3. Combine them with the known 8-word prefix.
4. Run the BIP39 checksum test.
5. If checksum fails, return immediately.
6. Build the fixed-length 71-byte mnemonic.
7. Run PBKDF2-HMAC-SHA512 with:

```text
password = mnemonic
salt = "mnemonic"
iterations = 2048
dkLen = 64
```

8. Run SLIP-10 Ed25519 hardened derivation:

```text
m
m/44'
m/44'/73404'
m/44'/73404'/0'
```

9. Compute the Ed25519 public key.
10. Compute `SHA3-256(public_key)`.
11. Compare:

```text
candidate_core = 0x00 || digest[0:19]
candidate_core == target_core
```

12. If equal, atomically write the hit record.

## Target Comparison Optimization

The kernel does not need to generate a Bech32 `z1...` string.

Decode the target address once on the host:

```text
z1qrn3jeapt848zxg3akf2ewhrxxwsa945sj798s -> 20-byte core
```

Then the GPU only compares 20 bytes:

```text
0x00 || first_19_bytes(SHA3-256(public_key))
```

This saves a lot of formatting work.

## Practical Implementation Options

### Option A: Custom CUDA Program

Best performance, most work.

Files to build:

```text
gpu/zenon_bip39_cuda.cu
gpu/sha256.cuh
gpu/sha512_hmac_pbkdf2.cuh
gpu/ed25519.cuh
gpu/sha3.cuh
gpu/CMakeLists.txt
```

Pros:

- Fastest path on NVIDIA RunPod.
- Full control over batching and checkpointing.
- No Python overhead.

Cons:

- Requires careful crypto implementation.
- Needs test vectors for every primitive.
- Ed25519 scalar multiplication is nontrivial.

### Option B: Adapt BTCRecover

BTCRecover is relevant prior art because it supports seed recovery and GPU acceleration for BIP39/Electrum seeds, but Zenon is not listed as a supported target in its README.

Pros:

- Existing recovery framework.
- Existing GPU recovery concepts.

Cons:

- Needs a custom Zenon address target.
- Still needs Ed25519 path `m/44'/73404'/0'` and Zenon address core.
- May take as much work as a focused custom tool.

### Option C: Hybrid GPU/CPU

GPU handles checksum and PBKDF2; CPU handles Ed25519/SHA3.

Pros:

- Easier than full CUDA.

Cons:

- Likely still too slow because billions of checksum-valid candidates remain.
- Large GPU-to-CPU transfer volume.
- CPU Ed25519 becomes the bottleneck.

Not recommended unless used only as an intermediate benchmark.

## RunPod Workflow

1. Start an NVIDIA CUDA RunPod image.
2. Upload this repo.
3. Prepare the GPU workload JSON.
4. Build the GPU binary.
5. Run a tiny known-vector test.
6. Run a 1M-candidate benchmark.
7. Estimate full runtime from actual RunPod rate.
8. Launch full shard set.
9. Periodically copy result JSON/checkpoints off the pod.

Prepare workload:

```sh
python3 scripts/prepare_gpu_workload.py
```

This writes:

```text
out/gpu_workload.json
```

The generated workload includes:

```text
target_core_hex = 00e71967a159ea711911ed92acbae3319d0e96b4
total_exact_length_combinations = 69026912600
expected_checksum_valid = 4314182037.5
```

Example intended command shape:

```sh
./zenon_bip39_cuda \
  --workload out/gpu_workload.json \
  --account 0 \
  --passphrase "" \
  --shard-count 1 \
  --shard-index 0 \
  --batch-size 1048576 \
  --checkpoint out/gpu_checkpoint.json \
  --output out/gpu_hits.json
```

## Validation Tests Required

Before trusting a GPU run, verify these exact cases against the Python script:

### C-Tail Candidate

Mnemonic:

```text
oblige dilemma hurry disorder happy spoil shiver key theory romance valid raw
```

Expected address:

```text
z1qpzrf4jk0s3lt76kw4h8rp4sm4y6vf3jspcyda
```

### Empty Zenon Address Decode

Address:

```text
z1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsggv2f
```

Expected core:

```text
0000000000000000000000000000000000000000
```

### Python Smoke-Test Agreement

The GPU and Python runner must agree on:

```text
first 10,000 candidates
checksum-valid count: 643
hits: 0
```

## Expected Speed

Actual speed depends heavily on the GPU and the Ed25519 implementation.

The CPU baseline is:

```text
~906 full Zenon derivations/sec
```

If a large GPU achieves:

```text
100,000 derivations/sec -> ~12 hours for 4.31B derivations
500,000 derivations/sec -> ~2.4 hours
1,000,000 derivations/sec -> ~1.2 hours
```

Those are not promises. They are targets to benchmark on RunPod after the CUDA kernel exists.

## Recommendation

Build the GPU version as a focused CUDA program, not a Python GPU script.

Implementation order:

1. Create a host-side C++ enumerator that matches Python candidate ordering.
2. Add target address core decoding on the host.
3. Add GPU checksum-only kernel and verify counts.
4. Add PBKDF2-HMAC-SHA512 and benchmark.
5. Add SLIP-10 Ed25519 derivation.
6. Add Ed25519 public key generation.
7. Add SHA3-256 and target-core compare.
8. Run Python/GPU equivalence tests on the first 10k, 100k, and 1M candidates.
9. Run full RunPod search.

The biggest engineering risk is Ed25519 public-key generation on GPU. That is the part to spike first.
