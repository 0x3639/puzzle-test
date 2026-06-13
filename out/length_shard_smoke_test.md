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
  "pool_size": 1608,
  "pool": {
    "count": 1608,
    "first_96": [
      "able",
      "about",
      "above",
      "absent",
      "absorb",
      "absurd",
      "abuse",
      "access",
      "accuse",
      "acid",
      "across",
      "act",
      "action",
      "actor",
      "actual",
      "adapt",
      "add",
      "addict",
      "adjust",
      "admit",
      "adult",
      "advice",
      "affair",
      "afford",
      "afraid",
      "again",
      "age",
      "agent",
      "agree",
      "ahead",
      "aim",
      "air",
      "aisle",
      "alarm",
      "album",
      "alert",
      "alien",
      "all",
      "alley",
      "allow",
      "almost",
      "alone",
      "alpha",
      "also",
      "alter",
      "always",
      "among",
      "amount",
      "amused",
      "anchor",
      "anger",
      "angle",
      "angry",
      "animal",
      "ankle",
      "annual",
      "answer",
      "any",
      "apart",
      "appear",
      "apple",
      "april",
      "arch",
      "arctic",
      "area",
      "arena",
      "argue",
      "arm",
      "armed",
      "armor",
      "army",
      "around",
      "arrest",
      "arrive",
      "arrow",
      "art",
      "artist",
      "ask",
      "aspect",
      "asset",
      "assist",
      "assume",
      "asthma",
      "atom",
      "attack",
      "attend",
      "audit",
      "august",
      "aunt",
      "author",
      "auto",
      "autumn",
      "avoid",
      "awake",
      "aware",
      "away"
    ],
    "note": "Full pool is preserved in out/length_shard_smoke_test.json."
  },
  "length_distribution": {
    "3": 103,
    "4": 442,
    "5": 555,
    "6": 508
  },
  "length_patterns": [
    {
      "index": 0,
      "lengths": [
        3,
        3,
        3,
        6
      ],
      "combinations": 555105316
    },
    {
      "index": 1,
      "lengths": [
        3,
        3,
        4,
        5
      ],
      "combinations": 2602493790
    },
    {
      "index": 2,
      "lengths": [
        3,
        3,
        5,
        4
      ],
      "combinations": 2602493790
    },
    {
      "index": 3,
      "lengths": [
        3,
        3,
        6,
        3
      ],
      "combinations": 555105316
    },
    {
      "index": 4,
      "lengths": [
        3,
        4,
        3,
        5
      ],
      "combinations": 2602493790
    },
    {
      "index": 5,
      "lengths": [
        3,
        4,
        4,
        4
      ],
      "combinations": 8894141464
    },
    {
      "index": 6,
      "lengths": [
        3,
        4,
        5,
        3
      ],
      "combinations": 2602493790
    },
    {
      "index": 7,
      "lengths": [
        3,
        5,
        3,
        4
      ],
      "combinations": 2602493790
    },
    {
      "index": 8,
      "lengths": [
        3,
        5,
        4,
        3
      ],
      "combinations": 2602493790
    },
    {
      "index": 9,
      "lengths": [
        3,
        6,
        3,
        3
      ],
      "combinations": 555105316
    },
    {
      "index": 10,
      "lengths": [
        4,
        3,
        3,
        5
      ],
      "combinations": 2602493790
    },
    {
      "index": 11,
      "lengths": [
        4,
        3,
        4,
        4
      ],
      "combinations": 8894141464
    },
    {
      "index": 12,
      "lengths": [
        4,
        3,
        5,
        3
      ],
      "combinations": 2602493790
    },
    {
      "index": 13,
      "lengths": [
        4,
        4,
        3,
        4
      ],
      "combinations": 8894141464
    },
    {
      "index": 14,
      "lengths": [
        4,
        4,
        4,
        3
      ],
      "combinations": 8894141464
    },
    {
      "index": 15,
      "lengths": [
        4,
        5,
        3,
        3
      ],
      "combinations": 2602493790
    },
    {
      "index": 16,
      "lengths": [
        5,
        3,
        3,
        4
      ],
      "combinations": 2602493790
    },
    {
      "index": 17,
      "lengths": [
        5,
        3,
        4,
        3
      ],
      "combinations": 2602493790
    },
    {
      "index": 18,
      "lengths": [
        5,
        4,
        3,
        3
      ],
      "combinations": 2602493790
    },
    {
      "index": 19,
      "lengths": [
        6,
        3,
        3,
        3
      ],
      "combinations": 555105316
    }
  ],
  "total_exact_length_combinations": 69026912600,
  "estimated_checksum_valid": 4314182037.5,
  "shard_index": 0,
  "shard_count": 69027,
  "search_start_combo": 0,
  "search_stop_combo": 10000,
  "assigned_exact_length_combinations": 10000,
  "skip": 0,
  "max_combos": 10000,
  "combos_seen": 10000,
  "checksum_valid_phrases": 643,
  "address_derivations": 643,
  "elapsed_seconds": 0.764,
  "combos_per_second": 13091.2,
  "derivations_per_second": 841.76,
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
python3 scripts/constrained_seedword_bruteforce.py --pool length --dry-run --max-combos 0 --output-stem constrained_seedword_bruteforce_length_dry_run
```

Use a custom BIP39 word pool:

```sh
python3 scripts/constrained_seedword_bruteforce.py --pool-file candidate_words.txt --max-combos 5000000
```

Test one full-theory shard. Use one terminal per shard index, from 0 to shard-count - 1:

```sh
python3 scripts/constrained_seedword_bruteforce.py --pool length --allow-large --shard-count 8 --shard-index 0 --max-combos 0 --output-stem length_shard_0
```

The full exact-18 BIP39 space is still enormous, so use `--shard-count`, `--shard-index`, and separate `--output-stem` values to split it.
