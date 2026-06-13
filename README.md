# Zenon Puzzle Test

This branch runs the full BIP39 four-word tail search: all `2048^4` ordered missing-word combinations.

The earlier exact-18-byte theory searched only the words that can fit this constraint:

```text
B + A = 34 bytes
34 bytes = 18-byte payload + 16-byte AES-GCM-sized tag
missing words = word9 word10 word11 word12
len("word9 word10 word11 word12") == 18
```

Known seed prefix:

```text
oblige dilemma hurry disorder happy spoil shiver key
```

Target Zenon address:

```text
z1qrn3jeapt848zxg3akf2ewhrxxwsa945sj798s
```

The full wordlist search is much larger:

```text
participating BIP39 words: 2,048
ordered four-word tails: 17,592,186,044,416
expected BIP39-checksum-valid phrases: 1,099,511,627,776
```

## Current Status

What works now:

- CPU scripts can reproduce the puzzle analysis and run bounded brute-force searches.
- The target Zenon address derivation is implemented in Python.
- The CUDA program can enumerate candidates and run the BIP39 checksum gate on GPU.
- The CUDA program has a validation-gated Zenon address oracle mode.
- The CUDA smoke test is pinned to Python validation vectors.

What is not done yet:

- The address oracle is new and should be validated on RunPod with `bash runpod/run.sh oracle-test`.
- The full target-address run has not been completed in this repo's saved outputs.
- A GPU checksum hit is only a valid BIP39 mnemonic candidate; an address hit requires `address` or `full-address` mode.

## Repo Layout

```text
data/
  bip39_english.txt                    BIP39 English word list
  blockstream/                         cached Bitcoin chain data used in the audit

scripts/
  constrained_seedword_bruteforce.py   main CPU brute-force runner
  prepare_gpu_workload.py              writes out/gpu_workload.json
  emit_cuda_workload_header.py         writes gpu/generated/gpu_workload.h
  aes_gcm_seedword_probe.py            bounded AES-GCM-shaped probe
  model_output_probe.py                deterministic A/B/C/E-to-word model probe
  satoshi_claim_audit.py               Bitcoin-chain attribution audit
  summarize_bruteforce_shards.py       summarizes CPU shard JSON files

gpu/
  zenon_bip39_cuda.cu                  CUDA checksum kernel scaffold
  crypto_oracle.cuh                    CUDA address-oracle crypto primitives
  CMakeLists.txt                       CUDA build file
  README.md                            GPU-specific setup and run instructions
  generated/gpu_workload.h             generated CUDA constant tables

out/
  *.md and *.json                      saved analysis reports and run outputs
```

## Local Python Setup

Use Python 3.10 or newer.

```sh
git clone --branch codex/full-wordlist-gpu-search https://github.com/0x3639/puzzle-test.git
cd puzzle-test

python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

If this branch has been merged into the repository default branch, the normal clone command also works:

```sh
git clone https://github.com/0x3639/puzzle-test.git
cd puzzle-test
```

## Quick CPU Checks

Dry-run the default clue-derived search. This prints pool size, length patterns, candidate counts, and the direct `C` tail candidate.

```sh
python3 scripts/constrained_seedword_bruteforce.py --dry-run
```

Run a small default clue-derived search:

```sh
python3 scripts/constrained_seedword_bruteforce.py --max-combos 100000
```

Run a pure byte-length-constrained dry run over the full participating BIP39 length pool:

```sh
python3 scripts/constrained_seedword_bruteforce.py \
  --pool length \
  --dry-run \
  --max-combos 0 \
  --output-stem constrained_seedword_bruteforce_length_dry_run
```

Expected scale for the full exact-18-byte CPU theory:

```text
total_exact_length_combinations: 69026912600
estimated_checksum_valid: 4314182037.5
```

## CPU Brute Force

The CPU runner checks:

```text
candidate four words
exact 18-byte plaintext length
BIP39 checksum
BIP39 seed
SLIP-10 Ed25519 path m/44'/73404'/account'
Zenon address
target address match
```

The default pool is clue-derived and intentionally smaller:

```sh
python3 scripts/constrained_seedword_bruteforce.py \
  --max-combos 1000000 \
  --output-stem constrained_seedword_bruteforce
```

The full length-constrained pool is much larger and requires `--allow-large`:

```sh
python3 scripts/constrained_seedword_bruteforce.py \
  --pool length \
  --allow-large \
  --max-combos 100000 \
  --output-stem length_benchmark_100k
```

For full CPU sharding, split the global exact-length space:

```sh
python3 scripts/constrained_seedword_bruteforce.py \
  --pool length \
  --allow-large \
  --shard-count 64 \
  --shard-index 0 \
  --max-combos 0 \
  --output-stem length_shard_0
```

Run one command per shard index from `0` to `shard-count - 1`.

Summarize shard outputs:

```sh
python3 scripts/summarize_bruteforce_shards.py \
  --glob 'out/length_shard_*.json' \
  --shard-count 64 \
  --output out/bruteforce_shard_summary.md
```

## GPU Setup

The GPU code lives in `gpu/`. It has both checksum and address-oracle modes.

Generate the workload files:

```sh
python3 scripts/prepare_gpu_workload.py
python3 scripts/emit_cuda_workload_header.py
```

Build on a CUDA machine:

```sh
cmake -S gpu -B gpu/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=89
cmake --build gpu/build -j
```

Use architecture `89` for RTX 4090 and `90` for H100.

Run the smoke test:

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

Run a larger checksum benchmark:

```sh
./gpu/build/zenon_bip39_cuda --start 0 --count 100000000 --threads 256
```

See [gpu/README.md](gpu/README.md) for RunPod-specific setup.

## RunPod Quick Start

Use a CUDA devel image, for example an Ubuntu CUDA 12 devel image. A CUDA runtime image usually does not include `nvcc`, so use a devel image.

On a fresh pod, this is the easiest path:

```sh
git clone --branch codex/full-wordlist-gpu-search https://github.com/0x3639/puzzle-test.git
cd puzzle-test
bash runpod/run.sh smoke
```

The script installs missing apt packages when possible, creates `.venv`, installs Python requirements, generates the CUDA workload header, detects the GPU architecture, builds the binary, and verifies the smoke test.

Expected smoke-test fields:

```text
"checksum_valid": 625
"first_valid_global": 0
"first_valid_tail_indices": [0, 0, 0, 0]
```

Run a default 100,000,000-candidate checksum benchmark:

```sh
bash runpod/run.sh benchmark
```

Run a custom range:

```sh
bash runpod/run.sh range 500000000 100000000
```

This branch defaults to full-wordlist mode. Run the address-oracle validation vector:

```sh
bash runpod/run.sh oracle-test
```

Run a small real target-address search range:

```sh
bash runpod/run.sh address 0 100000
```

Run the full address search in chunks:

```sh
bash runpod/run.sh full-address
```

A target hit will print `"hit_found": true` and a `hit_mnemonic`.

Full-wordlist ETA depends on `address_derivations_per_second` from your own Blackwell benchmark:

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

Run the full checksum batch in chunks:

```sh
bash runpod/run.sh full
```

This scans all `17,592,186,044,416` candidates through the current checksum-only GPU stage and writes chunk results to `out/runpod_full_<timestamp>.jsonl`.

Resume from an offset:

```sh
FULL_OUTPUT=out/full_checksum.jsonl FULL_START=1000000000 bash runpod/run.sh full
```

After it completes, summarize the output:

```sh
bash runpod/run.sh summarize
```

Good coverage looks like:

```text
"full_space_covered": true
"candidate_count_sum": 17592186044416
"gap_count": 0
"overlap_count": 0
```

For H100, if auto-detection fails:

```sh
CUDA_ARCH=90 bash runpod/run.sh smoke
```

If RunPod reports `Unsupported gpu architecture 'compute_120'`, the GPU is newer than the installed CUDA toolkit. Update the repo and rerun:

```sh
git pull
bash runpod/run.sh smoke
```

The script will now fall back to a supported PTX target automatically. Manual fallback:

```sh
CUDA_ARCH=90-virtual bash runpod/run.sh smoke
```

See [runpod/README.md](runpod/README.md) for the shortest RunPod-focused guide.

## Other Probes

AES-GCM-shaped bounded probe:

```sh
python3 scripts/aes_gcm_seedword_probe.py
```

That probe uses the local `openssl` command for Argon2id key candidates when available. If OpenSSL does not support Argon2id in your environment, the probe still runs the non-Argon2 candidates.

Deterministic model-output probe from A/B/C/E material:

```sh
python3 scripts/model_output_probe.py
```

Satoshi attribution audit:

```sh
python3 scripts/satoshi_claim_audit.py
```

## Outputs

Most scripts write both JSON and Markdown reports under `out/`.

Typical pattern:

```text
out/<output-stem>.json
out/<output-stem>.md
```

The JSON files are machine-readable. The Markdown files are easier to skim.

## Reading Results

For brute-force JSON outputs:

- `combos_seen`: four-word tails tested.
- `checksum_valid_phrases`: candidates that passed BIP39 checksum.
- `address_derivations`: Zenon address derivations performed.
- `hits`: matching target-address candidates. Empty means no hit in that run.

For CUDA output:

- `count`: candidates assigned to the GPU run.
- `checksum_valid`: BIP39-checksum-valid candidates in that range.
- `first_valid_global`: first global candidate offset in the range that passed checksum.
- `first_valid_tail_indices`: BIP39 indices of that first valid tail.

## Important Notes

The full theory is still unproven. Current results did not find a target-address match in the smaller clue-derived searches or deterministic A/B/C/E probes.

If a real target hit is found, treat the mnemonic as sensitive. Do not publish a live mnemonic until you have decided exactly how to handle the puzzle funds and attribution.
