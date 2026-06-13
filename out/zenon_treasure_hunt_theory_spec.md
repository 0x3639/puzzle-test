# Zenon Treasure Hunt Theory Spec

## 1. Purpose

This document ties together the Taproot puzzle repository, the 12-word Zenon wallet hunt, the 8 known seed words, and the brute-force test we are running.

The immediate test is narrow and falsifiable:

> Do the missing 4 BIP39 words, when appended to the known 8 words, produce the target Zenon address, while also fitting the 18-byte plaintext shape implied by the puzzle bytes?

This is not yet a Satoshi proof. If the missing words are found, a separate test is needed to determine whether the same mnemonic also opens or signs for any Satoshi-era Bitcoin wallet.

## 2. Source Trail

### 2.1 Taproot Puzzle Repository

Source: https://github.com/TminusZ/zenon-developer-commons/tree/main/puzzle

The puzzle repo documents an on-chain Bitcoin artifact at Taproot activation:

- Bitcoin block: `709632`
- Date: `2021-11-14`
- Artifact source address: `bc1qrnldpdlq9dsfy946m4vqa5mrec8qhdrx363end`
- Artifact structure: OP_RETURN rows plus terminal marker `ZENON NETWORK`
- Repo status: unsolved; no confirmed private key, plaintext, or protocol-level meaning

The four Base64 hint fields in the repo artifact are:

```text
A = BynQtpeUyWTXKGTrGhdV2Q==
B = tVMd3L1CKM4wFmyxEEEUV2bY
C = 4Fdzw1k=
E = vtv3f5aKY0jGQglP9a1AGw==
```

Decoded:

```text
A = 0729d0b69794c964d72864eb1a1755d9  (16 bytes)
B = b5531ddcbd4228ce30166cb11041145766d8  (18 bytes)
C = e05773c359  (5 bytes)
E = bedbf77f968a6348c642094ff5ad401b  (16 bytes)
```

The repo's reproducible internal puzzle core is:

```text
B[9:12] = 166cb1
(0x16 XOR 0xb1) & 0x07 = 0x07
0x6c XOR 0x07 = 0x6b
```

That gives a real internal structure, but not a complete solution.

### 2.2 12-Word Wallet Hunt

Source: https://forum.hypercore.one/t/12-seed-word-treasure-hunt/421

The HyperCore thread frames the wallet hunt as:

```text
Known seed words:
oblige dilemma hurry disorder happy spoil shiver key

Missing:
word9 word10 word11 word12

Target Zenon address:
z1qrn3jeapt848zxg3akf2ewhrxxwsa945sj798s
```

The forum post repeats the same four puzzle hints:

```text
;tVMd3L1CKM4wFmyxEEEUV2bY;
;BynQtpeUyWTXKGTrGhdV2Q==;
,vtv3f5aKY0jGQglP9a1AGw==,
;4Fdzw1k=zzzzzzzzzzzzzzzz;
```

It also ties the hunt to the Taproot activation block via the clue:

```text
Look for the final piece of the puzzle in block 709.632
```

## 3. Key Observation

The concrete crypto shape is:

```text
B + A = 18 bytes + 16 bytes = 34 bytes
```

AES-GCM commonly stores:

```text
ciphertext || 16-byte authentication tag
```

So if `B + A` is interpreted as AES-GCM material, it can naturally be split as:

```text
ciphertext = B  (18 bytes)
tag        = A  (16 bytes)
```

That leaves an 18-byte plaintext.

If the plaintext is the missing four seed words written with single spaces, then:

```text
len("word9 word10 word11 word12") == 18
```

Because there are three spaces, the word lengths must sum to:

```text
len(word9) + len(word10) + len(word11) + len(word12) = 15
```

Since BIP39 English words are at least 3 characters, the only participating word lengths are:

```text
3, 4, 5, 6
```

This is the full length-constrained theory.

## 4. What We Already Tested

### 4.1 Bounded AES-GCM Probe

File: `out/aes_gcm_seedword_probe.md`

We tested the direct AES-GCM interpretation using clue-derived password, nonce, KDF, and AAD choices, including the Zenon keyfile shape:

- AES-256-GCM
- possible Argon2id-derived keys
- AAD candidate `zenon`
- forum-suggested password candidate `taproot`
- nonce candidates derived from `C`
- `B + A` as `18-byte ciphertext + 16-byte tag`

Result:

```text
403,200 authenticated decrypt attempts
0 authenticated hits
0 four-word plaintext hits
```

This does not disprove AES-GCM generally. It only rules out that bounded parameter set.

### 4.2 C-Tail BIP39 Candidate

`C` is exactly 5 bytes, or 40 bits. For a 12-word BIP39 mnemonic:

```text
12 words = 132 bits
128 entropy bits + 4 checksum bits
first 8 words = 88 bits
remaining entropy bits before checksum = 40 bits
```

So `C` can be interpreted directly as the missing 40-bit entropy tail.

That yields:

```text
oblige dilemma hurry disorder happy spoil shiver key theory romance valid raw
```

Last four:

```text
theory romance valid raw
```

Derived Zenon address:

```text
z1qpzrf4jk0s3lt76kw4h8rp4sm4y6vf3jspcyda
```

Result:

```text
Does not match target.
```

### 4.3 Clue-Derived Word Pool Brute Force

File: `out/constrained_seedword_bruteforce.md`

We first tested a smaller clue-derived pool, then applied the exact 18-byte constraint and BIP39 checksum filter.

Result:

```text
pool size after length participation filter: 77 words
exact 18-byte combinations: 259,160
BIP39-checksum-valid phrases: 16,191
Zenon address derivations: 16,191
hits: 0
```

This was only a likely-candidate pass. It did not test the full theory.

### 4.4 Bounded Model-Output Probe

File: `out/model_output_probe.md`

We also tested whether small, reproducible model families can derive candidate missing words directly from `A/B/C/E`, before using the Zenon address as a final check.

Models tested:

```text
128-bit entropy chunks from fields, permutations, hashes, and HMACs
40-bit windows as the missing BIP39 entropy tail after the known 8 words
44-bit windows as raw BIP39 indices for the four missing words
XOR streams using B as an 18-byte ciphertext and hash/HMAC material as stream bytes
Direct 18-byte ASCII windows
```

Result:

```text
model attempts: 276,184
exact-18 candidate word outputs: 1,057
valid BIP39 full phrases: 494
target address hits: 0
```

This does not disprove every possible derivation model. It rules out a bounded set of clean, publishable transforms that could have made the four words fall directly out of the puzzle bytes.

## 5. Address Derivation Oracle

The brute force needs a deterministic pass/fail oracle. For each candidate four-word suffix:

1. Append it to the known 8 words.
2. Validate the 12-word phrase against the BIP39 checksum.
3. Derive the Zenon account key.
4. Generate the Zenon `z1...` address.
5. Compare to the target address.

The derivation model follows the public Zenon TypeScript SDK:

Source: https://github.com/DexterLabZ/znn.ts

Relevant derivation facts:

```text
BIP39 seed = PBKDF2-HMAC-SHA512(mnemonic, "mnemonic" + passphrase)
default passphrase = empty string
derivation path = m/44'/73404'/account'
default account = 0
curve = Ed25519 / SLIP-10 hardened derivation
address HRP = z
address core = 0x00 || first_19_bytes(SHA3-256(public_key))
encoding = bech32
```

Target:

```text
z1qrn3jeapt848zxg3akf2ewhrxxwsa945sj798s
```

A candidate passes only if its derived address exactly equals that target.

## 6. Full Brute-Force Theory

The full theory removes clue-derived narrowing. It tests every BIP39 English word that can participate in an exact 18-byte four-word string.

Dry-run file:

```text
out/constrained_seedword_bruteforce_length_dry_run.md
```

Full length-constrained search space:

```text
participating BIP39 words: 1,608
word lengths: 3, 4, 5, 6
length distribution:
  3 chars: 103 words
  4 chars: 442 words
  5 chars: 555 words
  6 chars: 508 words

exact 18-byte ordered four-word strings: 69,026,912,600
estimated BIP39-checksum-valid phrases: 4,314,182,037.5
```

The 20 valid word-length patterns are all ordered four-tuples whose lengths sum to 15:

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

## 7. How To Run The Full Test

### 7.1 Confirm Full Search Space

```sh
cd /Users/dfriestedt/Documents/taproot-puzzle
python3 scripts/constrained_seedword_bruteforce.py \
  --pool length \
  --dry-run \
  --max-combos 0 \
  --output-stem constrained_seedword_bruteforce_length_dry_run
```

### 7.2 Run Parallel Shards

Use one terminal per shard. Example with 8 shards:

```sh
python3 scripts/constrained_seedword_bruteforce.py \
  --pool length \
  --allow-large \
  --shard-count 8 \
  --shard-index 0 \
  --max-combos 0 \
  --output-stem length_shard_0
```

Repeat with:

```text
--shard-index 1 --output-stem length_shard_1
--shard-index 2 --output-stem length_shard_2
--shard-index 3 --output-stem length_shard_3
--shard-index 4 --output-stem length_shard_4
--shard-index 5 --output-stem length_shard_5
--shard-index 6 --output-stem length_shard_6
--shard-index 7 --output-stem length_shard_7
```

### 7.3 Summarize Shard Results

```sh
python3 scripts/summarize_bruteforce_shards.py \
  --glob 'out/length_shard_*.json' \
  --shard-count 8
```

The summary report is written to:

```text
out/bruteforce_shard_summary.md
```

## 8. Runtime Estimate

Benchmark file:

```text
out/length_benchmark_100k.md
```

Current Python benchmark on this machine:

```text
100,000 combinations in 6.911 seconds
~14,470 combinations/sec
~906 Zenon address derivations/sec
```

Estimated total runtime:

```text
1 process: about 55 days nonstop
8 processes: about 7 days ideal, likely 7-10 days real-world
10 processes: about 5.5 days ideal, likely 6-8 days real-world
```

The machine reports 10 logical CPUs. For normal usability, 8 shards is the safer run profile.

## 9. Satoshi Attribution Branch

File: `out/satoshi_attribution_audit.md`

We also evaluated the working theory that Satoshi might be involved with the Taproot artifact.

Current result:

```text
No cryptographic or chain-provenance evidence currently supports Satoshi attribution.
```

Findings:

- The artifact is deliberate and strongly staged.
- The observed artifact signer is a modern P2WPKH address:
  `bc1qrnldpdlq9dsfy946m4vqa5mrec8qhdrx363end`
- Observed public key:
  `0398cf668fe678cc6d8e2b20b5f574c9f398c7f031a1e91e9b85029e4cde597ad7`
- No repeated ECDSA `r` values were found.
- Simple deterministic derivations from the puzzle bytes did not match the observed artifact signer or high-signal Satoshi reference addresses.
- No embedded DER signature or direct public key structure was found in the decoded puzzle bytes.

Interpretation:

```text
The artifact may be intentionally placed at Taproot activation, but that does not prove Satoshi involvement.
```

If the missing 12-word phrase is found, the next Satoshi-era wallet test would be separate:

1. Derive Bitcoin keys/addresses from the mnemonic under plausible paths.
2. Compare against curated Satoshi/Patoshi-era output datasets.
3. Look for direct spends, signed messages, or historically accepted Satoshi-linked addresses.
4. Treat symbolic links to Taproot or early Bitcoin as insufficient without cryptographic linkage.

## 10. Pass And Fail Criteria

### Full 18-Byte Theory Passes If

The full length-constrained brute force finds a suffix:

```text
word9 word10 word11 word12
```

such that:

```text
len("word9 word10 word11 word12") == 18
```

and:

```text
derive_zenon_address(
  "oblige dilemma hurry disorder happy spoil shiver key word9 word10 word11 word12"
) == z1qrn3jeapt848zxg3akf2ewhrxxwsa945sj798s
```

### Full 18-Byte Theory Fails If

All `69,026,912,600` exact-length ordered combinations are exhausted and no target address match is found.

That would falsify this specific theory:

```text
The missing four BIP39 words are exactly the 18-byte plaintext implied by B + A.
```

It would not falsify every possible puzzle theory. The missing words could still involve:

- a different plaintext length assumption
- a different separator or casing convention
- non-BIP39 words
- a passphrase
- a nonzero Zenon account index
- a different derivation path
- a transformation before address derivation
- an AES-GCM interpretation that does not map plaintext directly to four words

## 11. Current Working Conclusion

What we know:

- The Taproot artifact exists on-chain and is tied to block `709632`.
- The wallet hunt gives 8 known seed words and a target Zenon address.
- The same four Base64 fields appear in both contexts.
- `B + A` has the exact size of `18-byte ciphertext/plaintext material + 16-byte AES-GCM tag`.
- Four BIP39 words separated by spaces can plausibly occupy 18 bytes.
- The direct `C` entropy-tail candidate does not match the target.
- The clue-derived constrained brute force did not match the target.
- The full length-constrained BIP39 search space is large but finite.

What we are testing now:

```text
The missing four words are BIP39 English words whose single-space-joined string is exactly 18 bytes, and the resulting 12-word mnemonic derives the published Zenon target address.
```

What a hit would mean:

- We found the missing four seed words for the published Zenon address.
- The 18-byte AES-GCM-shaped interpretation becomes much stronger.
- We can then test whether the same phrase has any Bitcoin/Satoshi-era significance.

What no hit would mean:

- This exact 18-byte four-BIP39-word theory is false under account `0`, empty passphrase, and the implemented Zenon derivation.
- The investigation should move to alternate assumptions rather than expanding the same search blindly.

## 12. Local Files

Core scripts:

```text
scripts/constrained_seedword_bruteforce.py
scripts/summarize_bruteforce_shards.py
scripts/aes_gcm_seedword_probe.py
scripts/satoshi_claim_audit.py
```

Key reports:

```text
taproot_puzzle_analysis.md
out/aes_gcm_seedword_probe.md
out/constrained_seedword_bruteforce.md
out/constrained_seedword_bruteforce_length_dry_run.md
out/length_benchmark_100k.md
out/length_shard_smoke_test.md
out/satoshi_attribution_audit.md
```
