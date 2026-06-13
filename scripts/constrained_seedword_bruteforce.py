#!/usr/bin/env python3
"""Constrained brute force for the Zenon 12-word treasure hunt.

The constraint comes from the AES-GCM-shaped clue:

    B + A = 34 bytes = 18-byte plaintext + 16-byte tag

If the plaintext is the missing four seed words separated by single spaces,
then:

    len(word9 + " " + word10 + " " + word11 + " " + word12) == 18

This script searches BIP39 words under that exact byte length constraint,
validates BIP39 checksum before address derivation, and checks the Zenon
address oracle. The default pool is clue-derived so a first run is tractable;
use --pool length for the pure byte-length-constrained BIP39 pool.

It intentionally does not default to all 2048 BIP39 words. The full exact-18
space is still about 69 billion ordered combinations.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import struct
import time
from dataclasses import dataclass
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out"
WORDLIST = ROOT / "data" / "bip39_english.txt"

KNOWN_WORDS = "oblige dilemma hurry disorder happy spoil shiver key".split()
TARGET_ADDRESS = "z1qrn3jeapt848zxg3akf2ewhrxxwsa945sj798s"

B64_A = "BynQtpeUyWTXKGTrGhdV2Q=="
B64_B = "tVMd3L1CKM4wFmyxEEEUV2bY"
B64_C = "4Fdzw1k="
B64_E = "vtv3f5aKY0jGQglP9a1AGw=="

ZENON_COIN_TYPE = 73404
BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


@dataclass(frozen=True)
class SearchHit:
    mnemonic: str
    last4: str
    address: str
    entropy_hex: str
    account: int
    passphrase: str


@dataclass(frozen=True)
class LengthPattern:
    index: int
    lengths: tuple[int, int, int, int]
    combinations: int


def load_words() -> list[str]:
    words = WORDLIST.read_text().splitlines()
    if len(words) != 2048:
        raise SystemExit(f"expected 2048 BIP39 words, found {len(words)}")
    return words


def decoded_fields() -> dict[str, bytes]:
    return {
        "A": base64.b64decode(B64_A),
        "B": base64.b64decode(B64_B),
        "C": base64.b64decode(B64_C),
        "E": base64.b64decode(B64_E),
    }


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def entropy_to_mnemonic(entropy: bytes, words: list[str]) -> str:
    bits = "".join(f"{byte:08b}" for byte in entropy)
    bits += "".join(f"{byte:08b}" for byte in sha256(entropy))[:4]
    return " ".join(words[int(bits[i : i + 11], 2)] for i in range(0, 132, 11))


def mnemonic_to_entropy_if_valid(
    mnemonic_words: tuple[str, ...],
    word_to_index: dict[str, int],
) -> bytes | None:
    if len(mnemonic_words) != 12:
        raise ValueError("expected 12 words")
    try:
        bits = "".join(f"{word_to_index[word]:011b}" for word in mnemonic_words)
    except KeyError:
        return None
    entropy_bits = bits[:128]
    checksum_bits = bits[128:]
    entropy = int(entropy_bits, 2).to_bytes(16, "big")
    expected = "".join(f"{byte:08b}" for byte in sha256(entropy))[:4]
    return entropy if checksum_bits == expected else None


def tail_indices_to_entropy_if_valid(
    tail_indices: tuple[int, int, int, int],
    prefix_int: int,
) -> bytes | None:
    tail44 = 0
    for index in tail_indices:
        tail44 = (tail44 << 11) | index
    entropy_int = (prefix_int << 40) | (tail44 >> 4)
    checksum_bits = tail44 & 0x0F
    entropy = entropy_int.to_bytes(16, "big")
    return entropy if checksum_bits == sha256(entropy)[0] >> 4 else None


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


def convertbits(data: bytes, frombits: int, tobits: int, pad: bool = True) -> list[int]:
    acc = 0
    bits = 0
    ret: list[int] = []
    maxv = (1 << tobits) - 1
    for value in data:
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad and bits:
        ret.append((acc << (tobits - bits)) & maxv)
    return ret


def zenon_bech32(core: bytes) -> str:
    data = convertbits(core, 8, 5)
    expanded = [ord("z") >> 5, 0, ord("z") & 31]
    polymod = bech32_polymod(expanded + data + [0, 0, 0, 0, 0, 0]) ^ 1
    checksum = [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]
    return "z1" + "".join(BECH32_CHARSET[d] for d in data + checksum)


def slip10_master(seed: bytes) -> tuple[bytes, bytes]:
    digest = hmac.new(b"ed25519 seed", seed, hashlib.sha512).digest()
    return digest[:32], digest[32:]


def slip10_ckd_priv(key: bytes, chain_code: bytes, index: int) -> tuple[bytes, bytes]:
    digest = hmac.new(
        chain_code,
        b"\x00" + key + struct.pack(">L", index + 0x80000000),
        hashlib.sha512,
    ).digest()
    return digest[:32], digest[32:]


def derive_zenon_address(mnemonic: str, account: int, passphrase: str) -> str:
    seed = hashlib.pbkdf2_hmac(
        "sha512",
        mnemonic.encode(),
        ("mnemonic" + passphrase).encode(),
        2048,
        64,
    )
    key, chain_code = slip10_master(seed)
    for index in (44, ZENON_COIN_TYPE, account):
        key, chain_code = slip10_ckd_priv(key, chain_code, index)
    public_key = (
        ed25519.Ed25519PrivateKey.from_private_bytes(key)
        .public_key()
        .public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    )
    return zenon_bech32(b"\x00" + hashlib.sha3_256(public_key).digest()[:19])


def known_prefix_entropy(words: list[str]) -> bytes:
    indices = [words.index(word) for word in KNOWN_WORDS]
    prefix_bits = "".join(f"{index:011b}" for index in indices)
    return int(prefix_bits + "0" * 40, 2).to_bytes(16, "big")


def c_tail_candidate(words: list[str]) -> dict[str, str | bool]:
    c = decoded_fields()["C"]
    prefix_bits = "".join(f"{words.index(word):011b}" for word in KNOWN_WORDS)
    entropy = int(prefix_bits + "".join(f"{byte:08b}" for byte in c), 2).to_bytes(16, "big")
    mnemonic = entropy_to_mnemonic(entropy, words)
    address = derive_zenon_address(mnemonic, 0, "")
    return {
        "tail_hex": c.hex(),
        "mnemonic": mnemonic,
        "last4": " ".join(mnemonic.split()[-4:]),
        "address": address,
        "matches_target": address == TARGET_ADDRESS,
    }


def clue_word_pool(words: list[str], limit: int | None) -> list[str]:
    fields = decoded_fields()
    wordset = set(words)
    pool: list[str] = []

    def add(word: str) -> None:
        if word in wordset and word not in pool:
            pool.append(word)

    # Words from direct BIP39 interpretations of the clue bytes.
    seed_entropies = [
        fields["A"],
        fields["E"],
        bytes(a ^ b for a, b in zip(fields["A"], fields["E"])),
    ]
    c_tail = c_tail_candidate(words)["mnemonic"]
    seed_entropies.append(
        int(
            "".join(f"{words.index(word):011b}" for word in KNOWN_WORDS)
            + "".join(f"{byte:08b}" for byte in fields["C"]),
            2,
        ).to_bytes(16, "big")
    )
    for entropy in seed_entropies:
        for word in entropy_to_mnemonic(entropy, words).split():
            add(word)
    for word in c_tail.split():
        add(word)

    # Clue terms that are BIP39 words. Some obvious terms like taproot and
    # bitcoin are not in the BIP39 English list, so they will be ignored.
    clue_text = """
    oblige dilemma hurry disorder happy spoil shiver key theory romance valid
    raw quantum history never doubt make final piece puzzle block reward winner
    takes all secure clue address nonce password salt cipher data smart contract
    contracts zenon network momentum alphanet burn quest mystery brave alien
    aliens
    """
    for token in clue_text.split():
        add(token.lower())

    # Byte-derived BIP39 indices from 11-bit windows across the raw clue bytes.
    raw = fields["A"] + fields["B"] + fields["C"] + fields["E"]
    bits = "".join(f"{byte:08b}" for byte in raw)
    for offset in range(0, min(len(bits) - 10, 220)):
        add(words[int(bits[offset : offset + 11], 2)])

    # Keep words that can participate in an 18-byte four-word plaintext.
    pool = [word for word in pool if 3 <= len(word) <= 8]
    return pool[:limit] if limit is not None else pool


def participating_word_lengths(pool: list[str], plaintext_bytes: int) -> set[int]:
    lengths = sorted({len(word) for word in pool})
    target_sum = plaintext_bytes - 3
    participating: set[int] = set()
    for length in lengths:
        for a_len in lengths:
            for b_len in lengths:
                c_len = target_sum - length - a_len - b_len
                if c_len in lengths:
                    participating.add(length)
                    break
            if length in participating:
                break
    return participating


def length_word_pool(words: list[str], plaintext_bytes: int) -> list[str]:
    lengths = participating_word_lengths(words, plaintext_bytes)
    return [word for word in words if len(word) in lengths]


def load_pool(words: list[str], args: argparse.Namespace) -> list[str]:
    if args.pool_file:
        loaded = [
            line.strip()
            for line in Path(args.pool_file).read_text().splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        missing = [word for word in loaded if word not in words]
        if missing:
            raise SystemExit(f"words not in BIP39 list: {missing[:10]}")
        pool = list(dict.fromkeys(loaded))
    elif args.pool == "length":
        pool = length_word_pool(words, args.plaintext_bytes)
    elif args.pool == "all":
        pool = list(words)
    else:
        pool = clue_word_pool(words, args.pool_limit)
    lengths = participating_word_lengths(pool, args.plaintext_bytes)
    return [word for word in pool if len(word) in lengths]


def length_distribution(pool: list[str]) -> dict[int, int]:
    by_len: dict[int, int] = {}
    for word in pool:
        by_len[len(word)] = by_len.get(len(word), 0) + 1
    return dict(sorted(by_len.items()))


def indexed_words_by_length(
    pool: list[str],
    word_to_index: dict[str, int],
) -> dict[int, list[tuple[str, int]]]:
    by_len: dict[int, list[tuple[str, int]]] = {}
    for word in pool:
        by_len.setdefault(len(word), []).append((word, word_to_index[word]))
    return dict(sorted(by_len.items()))


def length_patterns(
    by_len: dict[int, list[tuple[str, int]]],
    plaintext_bytes: int,
) -> list[LengthPattern]:
    target_sum = plaintext_bytes - 3
    lengths = sorted(by_len)
    patterns: list[LengthPattern] = []
    for a_len in lengths:
        for b_len in lengths:
            for c_len in lengths:
                d_len = target_sum - a_len - b_len - c_len
                if d_len not in by_len:
                    continue
                combinations = (
                    len(by_len[a_len])
                    * len(by_len[b_len])
                    * len(by_len[c_len])
                    * len(by_len[d_len])
                )
                patterns.append(
                    LengthPattern(
                        index=len(patterns),
                        lengths=(a_len, b_len, c_len, d_len),
                        combinations=combinations,
                    )
                )
    return patterns


def count_exact_length(patterns: list[LengthPattern]) -> int:
    return sum(pattern.combinations for pattern in patterns)


def selected_combo_range(args: argparse.Namespace, total_exact: int) -> tuple[int, int]:
    if args.shard_count < 1:
        raise SystemExit("--shard-count must be at least 1")
    if args.shard_index < 0 or args.shard_index >= args.shard_count:
        raise SystemExit("--shard-index must be between 0 and --shard-count - 1")

    shard_start = total_exact * args.shard_index // args.shard_count
    shard_stop = total_exact * (args.shard_index + 1) // args.shard_count
    start = min(shard_stop, shard_start + args.skip)
    stop = shard_stop
    if args.max_combos:
        stop = min(stop, start + args.max_combos)
    return start, stop


def iter_exact_length_range(
    by_len: dict[int, list[tuple[str, int]]],
    patterns: list[LengthPattern],
    start: int,
    stop: int,
):
    pattern_start = 0
    for pattern in patterns:
        pattern_stop = pattern_start + pattern.combinations
        overlap_start = max(start, pattern_start)
        overlap_stop = min(stop, pattern_stop)
        if overlap_start >= overlap_stop:
            pattern_start = pattern_stop
            continue

        lists = [by_len[length] for length in pattern.lengths]
        n0, n1, n2, n3 = (len(items) for items in lists)
        stride0 = n1 * n2 * n3
        stride1 = n2 * n3
        local_start = overlap_start - pattern_start
        local_stop = overlap_stop - pattern_start

        for offset in range(local_start, local_stop):
            i0, rem = divmod(offset, stride0)
            i1, rem = divmod(rem, stride1)
            i2, i3 = divmod(rem, n3)
            entries = (lists[0][i0], lists[1][i1], lists[2][i2], lists[3][i3])
            yield tuple(entry[0] for entry in entries), tuple(entry[1] for entry in entries)

        pattern_start = pattern_stop


def search(args: argparse.Namespace) -> dict:
    words = load_words()
    word_to_index = {word: index for index, word in enumerate(words)}
    prefix_int = 0
    for word in KNOWN_WORDS:
        prefix_int = (prefix_int << 11) | word_to_index[word]
    pool = load_pool(words, args)
    by_len = indexed_words_by_length(pool, word_to_index)
    patterns = length_patterns(by_len, args.plaintext_bytes)
    accounts = range(args.account_min, args.account_max + 1)
    passphrases = args.passphrase
    total_exact = count_exact_length(patterns)
    estimate_checksum = total_exact / 16
    start_combo, stop_combo = selected_combo_range(args, total_exact)

    if args.pool in {"all", "length"} and not args.allow_large and not args.dry_run:
        raise SystemExit(
            "Refusing large BIP39 exact-length search without --allow-large. "
            f"Exact-length combos: {total_exact:,}; expected checksum-valid: {estimate_checksum:,.0f}."
        )

    if args.dry_run:
        return {
            "dry_run": True,
            "pool_size": len(pool),
            "pool": pool,
            "length_distribution": length_distribution(pool),
            "length_patterns": [pattern.__dict__ for pattern in patterns],
            "plaintext_bytes": args.plaintext_bytes,
            "exact_length_combinations": total_exact,
            "estimated_checksum_valid": estimate_checksum,
            "shard_index": args.shard_index,
            "shard_count": args.shard_count,
            "search_start_combo": start_combo,
            "search_stop_combo": stop_combo,
            "assigned_exact_length_combinations": stop_combo - start_combo,
            "c_tail_candidate": c_tail_candidate(words),
        }

    start = time.time()
    combos_seen = 0
    checksum_valid = 0
    derivations = 0
    hits: list[SearchHit] = []
    known = tuple(KNOWN_WORDS)

    for combo, tail_indices in iter_exact_length_range(by_len, patterns, start_combo, stop_combo):
        combos_seen += 1
        entropy = tail_indices_to_entropy_if_valid(tail_indices, prefix_int)
        if entropy is None:
            continue
        checksum_valid += 1
        mnemonic_words = known + combo
        mnemonic = " ".join(mnemonic_words)
        for account in accounts:
            for passphrase in passphrases:
                derivations += 1
                address = derive_zenon_address(mnemonic, account, passphrase)
                if address != TARGET_ADDRESS:
                    continue
                hits.append(
                    SearchHit(
                        mnemonic=mnemonic,
                        last4=" ".join(combo),
                        address=address,
                        entropy_hex=entropy.hex(),
                        account=account,
                        passphrase=passphrase,
                    )
                )
                if args.stop_on_hit:
                    elapsed = time.time() - start
                    return result_dict(
                        args,
                        pool,
                        patterns,
                        total_exact,
                        start_combo,
                        stop_combo,
                        combos_seen,
                        checksum_valid,
                        derivations,
                        elapsed,
                        hits,
                    )

    elapsed = time.time() - start
    return result_dict(
        args,
        pool,
        patterns,
        total_exact,
        start_combo,
        stop_combo,
        combos_seen,
        checksum_valid,
        derivations,
        elapsed,
        hits,
    )


def result_dict(
    args: argparse.Namespace,
    pool: list[str],
    patterns: list[LengthPattern],
    total_exact: int,
    start_combo: int,
    stop_combo: int,
    combos_seen: int,
    checksum_valid: int,
    derivations: int,
    elapsed: float,
    hits: list[SearchHit],
) -> dict:
    return {
        "dry_run": False,
        "target_address": TARGET_ADDRESS,
        "known_words": KNOWN_WORDS,
        "plaintext_bytes": args.plaintext_bytes,
        "pool_size": len(pool),
        "pool": pool,
        "length_distribution": length_distribution(pool),
        "length_patterns": [pattern.__dict__ for pattern in patterns],
        "total_exact_length_combinations": total_exact,
        "estimated_checksum_valid": total_exact / 16,
        "shard_index": args.shard_index,
        "shard_count": args.shard_count,
        "search_start_combo": start_combo,
        "search_stop_combo": stop_combo,
        "assigned_exact_length_combinations": stop_combo - start_combo,
        "skip": args.skip,
        "max_combos": args.max_combos,
        "combos_seen": combos_seen,
        "checksum_valid_phrases": checksum_valid,
        "address_derivations": derivations,
        "elapsed_seconds": round(elapsed, 3),
        "combos_per_second": round(combos_seen / elapsed, 2) if elapsed else 0,
        "derivations_per_second": round(derivations / elapsed, 2) if elapsed else 0,
        "hits": [hit.__dict__ for hit in hits],
    }


def result_for_display(
    result: dict,
    max_pool_words: int = 96,
    json_path: str = "out/constrained_seedword_bruteforce.json",
) -> dict:
    display = dict(result)
    pool = display.get("pool")
    if isinstance(pool, list) and len(pool) > max_pool_words:
        display["pool"] = {
            "count": len(pool),
            f"first_{max_pool_words}": pool[:max_pool_words],
            "note": f"Full pool is preserved in {json_path}.",
        }
    return display


def write_report(result: dict, output_stem: str) -> None:
    if result.get("dry_run"):
        title = "Constrained Seed-Word Brute Force Dry Run"
    else:
        title = "Constrained Seed-Word Brute Force Run"
    json_path = f"out/{output_stem}.json"
    report_result = result_for_display(result, json_path=json_path)
    lines = [
        f"# {title}",
        "",
        "## Constraint",
        "",
        "`B + A` is 34 bytes. If interpreted as AES-GCM, a 16-byte tag leaves an 18-byte plaintext. Four missing BIP39 words separated by spaces must therefore total 18 bytes.",
        "",
        "## Result",
        "",
        "```json",
        json.dumps(report_result, indent=2),
        "```",
        "",
        "## Run Locally",
        "",
        "Default bounded search:",
        "",
        "```sh",
        "python3 scripts/constrained_seedword_bruteforce.py --max-combos 1000000",
        "```",
        "",
        "Dry-run counts only:",
        "",
        "```sh",
        "python3 scripts/constrained_seedword_bruteforce.py --dry-run",
        "```",
        "",
        "Pure word-length-constrained BIP39 dry-run:",
        "",
        "```sh",
        "python3 scripts/constrained_seedword_bruteforce.py --pool length --dry-run --max-combos 0 --output-stem constrained_seedword_bruteforce_length_dry_run",
        "```",
        "",
        "Use a custom BIP39 word pool:",
        "",
        "```sh",
        "python3 scripts/constrained_seedword_bruteforce.py --pool-file candidate_words.txt --max-combos 5000000",
        "```",
        "",
        "Test one full-theory shard. Use one terminal per shard index, from 0 to shard-count - 1:",
        "",
        "```sh",
        "python3 scripts/constrained_seedword_bruteforce.py --pool length --allow-large --shard-count 8 --shard-index 0 --max-combos 0 --output-stem length_shard_0",
        "```",
        "",
        "The full exact-18 BIP39 space is still enormous, so use `--shard-count`, `--shard-index`, and separate `--output-stem` values to split it.",
    ]
    (OUT / f"{output_stem}.md").write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pool", choices=["clue", "length", "all"], default="clue")
    parser.add_argument("--pool-file")
    parser.add_argument("--pool-limit", type=int, default=48)
    parser.add_argument("--plaintext-bytes", type=int, default=18)
    parser.add_argument("--account-min", type=int, default=0)
    parser.add_argument("--account-max", type=int, default=0)
    parser.add_argument("--passphrase", action="append", default=[""])
    parser.add_argument("--max-combos", type=int, default=1_000_000)
    parser.add_argument("--skip", type=int, default=0)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--shard-index", type=int, default=0)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--allow-large", action="store_true")
    parser.add_argument("--output-stem", default="constrained_seedword_bruteforce")
    parser.add_argument("--stop-on-hit", action=argparse.BooleanOptionalAction, default=True)
    args = parser.parse_args()

    OUT.mkdir(exist_ok=True)
    result = search(args)
    json_path = OUT / f"{args.output_stem}.json"
    md_path = OUT / f"{args.output_stem}.md"
    json_path.write_text(json.dumps(result, indent=2) + "\n")
    write_report(result, args.output_stem)
    print(json.dumps(result_for_display(result, json_path=f"out/{args.output_stem}.json"), indent=2))
    print(f"Wrote {json_path.relative_to(ROOT)}")
    print(f"Wrote {md_path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
