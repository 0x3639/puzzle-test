# Constrained Seed-Word Brute Force Run

## Constraint

`B + A` is 34 bytes. If interpreted as AES-GCM, a 16-byte tag leaves an 18-byte plaintext. Four missing BIP39 words separated by spaces must therefore total 18 bytes.

## Result

```json
{
  "dry_run": false,
  "target_address": "z1qrn3jeapt848zxg3akf2ewhrxxwsa945sj798s",
  "known_words": [
    "oblige",
    "dilemma",
    "hurry",
    "disorder",
    "happy",
    "spoil",
    "shiver",
    "key"
  ],
  "plaintext_bytes": 18,
  "pool_size": 77,
  "pool": [
    "excess",
    "color",
    "erode",
    "raven",
    "arrive",
    "twelve",
    "spawn",
    "step",
    "rate",
    "salute",
    "text",
    "that",
    "code",
    "plate",
    "piece",
    "boil",
    "donkey",
    "exit",
    "pulp",
    "exotic",
    "rigid",
    "muffin",
    "turkey",
    "bid",
    "east",
    "ethics",
    "pilot",
    "lava",
    "lyrics",
    "love",
    "oblige",
    "hurry",
    "happy",
    "spoil",
    "shiver",
    "key",
    "theory",
    "valid",
    "raw",
    "never",
    "make",
    "final",
    "puzzle",
    "reward",
    "winner",
    "all",
    "salt",
    "smart",
    "brave",
    "alien",
    "atom",
    "bronze",
    "deer",
    "income",
    "topple",
    "skill",
    "clap",
    "father",
    "point",
    "other",
    "injury",
    "tribe",
    "pause",
    "drift",
    "mad",
    "arena",
    "bitter",
    "forget",
    "repair",
    "honey",
    "surge",
    "regret",
    "spray",
    "planet",
    "nurse",
    "royal",
    "junk"
  ],
  "total_exact_length_combinations": 259160,
  "skip": 0,
  "max_combos": 300000,
  "combos_seen": 259160,
  "checksum_valid_phrases": 16191,
  "address_derivations": 16191,
  "elapsed_seconds": 18.082,
  "combos_per_second": 14332.21,
  "derivations_per_second": 895.4,
  "hits": []
}
```

## Run Locally

Default bounded search:

```sh
python3 scripts/constrained_seedword_bruteforce.py --max-combos 1000000
```

Dry-run counts only:

```sh
python3 scripts/constrained_seedword_bruteforce.py --dry-run
```

Pure word-length-constrained BIP39 dry-run:

```sh
python3 scripts/constrained_seedword_bruteforce.py --pool length --dry-run --output-stem constrained_seedword_bruteforce_length_dry_run
```

Use a custom BIP39 word pool:

```sh
python3 scripts/constrained_seedword_bruteforce.py --pool-file candidate_words.txt --max-combos 5000000
```

Attempt the full exact-18 BIP39 space only if you really mean it:

```sh
python3 scripts/constrained_seedword_bruteforce.py --pool all --allow-large --max-combos 1000000 --skip 0
```

The full exact-18 BIP39 space is still enormous, so use `--skip` and `--max-combos` to shard it.
