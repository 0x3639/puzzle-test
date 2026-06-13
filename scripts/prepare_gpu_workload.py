#!/usr/bin/env python3
"""Prepare a compact JSON workload for a future GPU brute-force runner."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORDLIST = ROOT / "data" / "bip39_english.txt"
OUT = ROOT / "out"

KNOWN_WORDS = "oblige dilemma hurry disorder happy spoil shiver key".split()
TARGET_ADDRESS = "z1qrn3jeapt848zxg3akf2ewhrxxwsa945sj798s"
BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def load_words() -> list[str]:
    words = WORDLIST.read_text().splitlines()
    if len(words) != 2048:
        raise SystemExit(f"expected 2048 BIP39 words, found {len(words)}")
    return words


def bech32_polymod(values: list[int]) -> int:
    generators = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    chk = 1
    for value in values:
        top = chk >> 25
        chk = ((chk & 0x1FFFFFF) << 5) ^ value
        for i, generator in enumerate(generators):
            if (top >> i) & 1:
                chk ^= generator
    return chk


def bech32_hrp_expand(hrp: str) -> list[int]:
    return [ord(char) >> 5 for char in hrp] + [0] + [ord(char) & 31 for char in hrp]


def convertbits(data: list[int], frombits: int, tobits: int, pad: bool) -> list[int]:
    acc = 0
    bits = 0
    ret: list[int] = []
    maxv = (1 << tobits) - 1
    max_acc = (1 << (frombits + tobits - 1)) - 1
    for value in data:
        if value < 0 or value >> frombits:
            raise ValueError("invalid bech32 data value")
        acc = ((acc << frombits) | value) & max_acc
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad:
        if bits:
            ret.append((acc << (tobits - bits)) & maxv)
    elif bits >= frombits or ((acc << (tobits - bits)) & maxv):
        raise ValueError("invalid bech32 padding")
    return ret


def decode_zenon_core(address: str) -> bytes:
    if "1" not in address:
        raise ValueError("missing bech32 separator")
    hrp, payload = address.rsplit("1", 1)
    if hrp != "z":
        raise ValueError(f"unexpected Zenon HRP {hrp!r}")
    values = [BECH32_CHARSET.index(char) for char in payload]
    if bech32_polymod(bech32_hrp_expand(hrp) + values) != 1:
        raise ValueError("invalid bech32 checksum")
    core = bytes(convertbits(values[:-6], 5, 8, False))
    if len(core) != 20:
        raise ValueError(f"expected 20-byte Zenon core, got {len(core)}")
    return core


def participating_words(words: list[str], plaintext_bytes: int) -> dict[int, list[dict]]:
    target_sum = plaintext_bytes - 3
    lengths = sorted({len(word) for word in words})
    participating_lengths = {
        length
        for length in lengths
        for a_len in lengths
        for b_len in lengths
        if target_sum - length - a_len - b_len in lengths
    }
    word_to_index = {word: index for index, word in enumerate(words)}
    grouped: dict[int, list[dict]] = {length: [] for length in sorted(participating_lengths)}
    for word in words:
        if len(word) in grouped:
            grouped[len(word)].append({"word": word, "index": word_to_index[word]})
    return grouped


def length_patterns(grouped: dict[int, list[dict]], plaintext_bytes: int) -> list[dict]:
    target_sum = plaintext_bytes - 3
    lengths = sorted(grouped)
    patterns = []
    for a_len in lengths:
        for b_len in lengths:
            for c_len in lengths:
                d_len = target_sum - a_len - b_len - c_len
                if d_len not in grouped:
                    continue
                combinations = (
                    len(grouped[a_len])
                    * len(grouped[b_len])
                    * len(grouped[c_len])
                    * len(grouped[d_len])
                )
                patterns.append(
                    {
                        "index": len(patterns),
                        "lengths": [a_len, b_len, c_len, d_len],
                        "combinations": combinations,
                    }
                )
    return patterns


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plaintext-bytes", type=int, default=18)
    parser.add_argument("--target-address", default=TARGET_ADDRESS)
    parser.add_argument("--output", default=str(OUT / "gpu_workload.json"))
    args = parser.parse_args()

    words = load_words()
    word_to_index = {word: index for index, word in enumerate(words)}
    grouped = participating_words(words, args.plaintext_bytes)
    patterns = length_patterns(grouped, args.plaintext_bytes)
    target_core = decode_zenon_core(args.target_address)

    workload = {
        "known_words": KNOWN_WORDS,
        "known_indices": [word_to_index[word] for word in KNOWN_WORDS],
        "target_address": args.target_address,
        "target_core_hex": target_core.hex(),
        "plaintext_bytes": args.plaintext_bytes,
        "words_by_length": grouped,
        "length_distribution": {length: len(items) for length, items in grouped.items()},
        "length_patterns": patterns,
        "total_exact_length_combinations": sum(pattern["combinations"] for pattern in patterns),
        "expected_checksum_valid": sum(pattern["combinations"] for pattern in patterns) / 16,
        "validation_vectors": {
            "c_tail_mnemonic": (
                "oblige dilemma hurry disorder happy spoil shiver key "
                "theory romance valid raw"
            ),
            "c_tail_expected_address": "z1qpzrf4jk0s3lt76kw4h8rp4sm4y6vf3jspcyda",
            "empty_address": "z1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsggv2f",
            "empty_address_core_hex": "00" * 20,
            "python_first_10000_checksum_valid": 643,
            "python_first_10000_first_valid_global": 9,
            "python_first_10000_first_valid_tail_indices": [19, 19, 19, 28],
            "python_first_10000_first_valid_tail_words": ["act", "act", "act", "adjust"],
            "python_first_10000_first_valid_entropy_hex": "9827c5be9fb68fa4b18bd002604c0981",
        },
    }

    output = Path(args.output)
    if not output.is_absolute():
        output = ROOT / output
    output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps(workload, indent=2) + "\n")
    print(json.dumps({k: workload[k] for k in (
        "target_address",
        "target_core_hex",
        "plaintext_bytes",
        "length_distribution",
        "total_exact_length_combinations",
        "expected_checksum_valid",
    )}, indent=2))
    print(f"Wrote {output.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
