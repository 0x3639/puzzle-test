#!/usr/bin/env python3
"""Probe bounded derivation models from A/B/C/E to four BIP39 words.

This is not the full word-space brute force. It searches small, publishable
model families that can generate candidate missing words directly from the
puzzle fields, then checks the Zenon target address.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import importlib.util
import itertools
import json
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out"
WORDLIST = ROOT / "data" / "bip39_english.txt"

B64_A = "BynQtpeUyWTXKGTrGhdV2Q=="
B64_B = "tVMd3L1CKM4wFmyxEEEUV2bY"
B64_C = "4Fdzw1k="
B64_E = "vtv3f5aKY0jGQglP9a1AGw=="

KNOWN_WORDS = "oblige dilemma hurry disorder happy spoil shiver key".split()
TARGET_ADDRESS = "z1qrn3jeapt848zxg3akf2ewhrxxwsa945sj798s"
PLAINTEXT_BYTES = 18


@dataclass(frozen=True)
class Candidate:
    model: str
    detail: str
    last4: str
    plaintext_bytes: int
    mnemonic: str
    valid_bip39: bool
    address: str | None
    matches_target: bool


def load_bruteforce_module():
    path = ROOT / "scripts" / "constrained_seedword_bruteforce.py"
    spec = importlib.util.spec_from_file_location("constrained_seedword_bruteforce", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


BF = load_bruteforce_module()


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


def sha512(data: bytes) -> bytes:
    return hashlib.sha512(data).digest()


def entropy_to_mnemonic(entropy: bytes, words: list[str]) -> str:
    bits = "".join(f"{byte:08b}" for byte in entropy)
    bits += "".join(f"{byte:08b}" for byte in sha256(entropy))[:4]
    return " ".join(words[int(bits[i : i + 11], 2)] for i in range(0, 132, 11))


def valid_entropy(mnemonic_words: tuple[str, ...], word_to_index: dict[str, int]) -> bytes | None:
    return BF.mnemonic_to_entropy_if_valid(mnemonic_words, word_to_index)


def try_ascii_words(data: bytes, bip39: set[str]) -> tuple[str, ...] | None:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if len(text) != 18:
        return None
    parts = text.split(" ")
    if len(parts) != 4:
        return None
    if " ".join(parts) != text:
        return None
    if all(part in bip39 for part in parts):
        return tuple(parts)
    return None


def bit_windows(data: bytes, width: int) -> list[tuple[int, int]]:
    bits = "".join(f"{byte:08b}" for byte in data)
    rows = []
    for offset in range(0, len(bits) - width + 1):
        rows.append((offset, int(bits[offset : offset + width], 2)))
    return rows


def field_materials(fields: dict[str, bytes]) -> dict[str, bytes]:
    rows: dict[str, bytes] = {}
    labels = sorted(fields)
    for label in labels:
        rows[label] = fields[label]
        rows[f"{label}_rev"] = fields[label][::-1]
    for perm in itertools.permutations(labels):
        name = "".join(perm)
        data = b"".join(fields[label] for label in perm)
        rows[name] = data
        rows[f"{name}_rev"] = data[::-1]
    rows["B_plus_A"] = fields["B"] + fields["A"]
    rows["A_plus_B"] = fields["A"] + fields["B"]
    return rows


def digest_materials(materials: dict[str, bytes]) -> dict[str, bytes]:
    rows: dict[str, bytes] = {}
    for label, data in materials.items():
        rows[f"sha256({label})"] = sha256(data)
        rows[f"double_sha256({label})"] = sha256(sha256(data))
        rows[f"sha512({label})"] = sha512(data)
        rows[f"hmac_sha256_E({label})"] = hmac.new(materials["E"], data, hashlib.sha256).digest()
        rows[f"hmac_sha512_E({label})"] = hmac.new(materials["E"], data, hashlib.sha512).digest()
        rows[f"hmac_sha256_A({label})"] = hmac.new(materials["A"], data, hashlib.sha256).digest()
    return rows


def candidate_from_tail_words(
    model: str,
    detail: str,
    tail_words: tuple[str, str, str, str],
    words: list[str],
    word_to_index: dict[str, int],
) -> Candidate | None:
    last4 = " ".join(tail_words)
    if len(last4.encode("utf-8")) != PLAINTEXT_BYTES:
        return None
    mnemonic_words = tuple(KNOWN_WORDS) + tail_words
    entropy = valid_entropy(mnemonic_words, word_to_index)
    if entropy is None:
        return Candidate(
            model=model,
            detail=detail,
            last4=last4,
            plaintext_bytes=len(last4.encode("utf-8")),
            mnemonic=" ".join(mnemonic_words),
            valid_bip39=False,
            address=None,
            matches_target=False,
        )
    mnemonic = " ".join(mnemonic_words)
    address = BF.derive_zenon_address(mnemonic, 0, "")
    return Candidate(
        model=model,
        detail=detail,
        last4=last4,
        plaintext_bytes=len(last4.encode("utf-8")),
        mnemonic=mnemonic,
        valid_bip39=True,
        address=address,
        matches_target=address == TARGET_ADDRESS,
    )


def add_candidate(
    candidates: dict[tuple[str, str], Candidate],
    model: str,
    detail: str,
    tail_words: tuple[str, str, str, str],
    words: list[str],
    word_to_index: dict[str, int],
) -> None:
    key = (model, detail)
    if key in candidates:
        return
    candidate = candidate_from_tail_words(model, detail, tail_words, words, word_to_index)
    if candidate is not None:
        candidates[key] = candidate


def probe_entropy_models(
    candidates: dict[tuple[str, str], Candidate],
    materials: dict[str, bytes],
    words: list[str],
    word_to_index: dict[str, int],
) -> int:
    attempts = 0
    for label, data in materials.items():
        entropy_chunks: list[tuple[str, bytes]] = []
        if len(data) >= 16:
            entropy_chunks.append(("first16", data[:16]))
            entropy_chunks.append(("last16", data[-16:]))
            for index in range(0, len(data) - 15):
                entropy_chunks.append((f"window16_{index}", data[index : index + 16]))
        digest = sha256(data)
        entropy_chunks.append(("sha256_first16", digest[:16]))
        entropy_chunks.append(("sha256_last16", digest[-16:]))
        entropy_chunks.append(("double_sha256_first16", sha256(digest)[:16]))
        for chunk_label, entropy in entropy_chunks:
            attempts += 1
            mnemonic = entropy_to_mnemonic(entropy, words)
            tail = tuple(mnemonic.split()[-4:])
            add_candidate(
                candidates,
                "entropy_128_to_mnemonic_tail",
                f"{label}:{chunk_label}:{entropy.hex()}",
                tail,  # type: ignore[arg-type]
                words,
                word_to_index,
            )
    return attempts


def probe_tail_bit_models(
    candidates: dict[tuple[str, str], Candidate],
    materials: dict[str, bytes],
    words: list[str],
    word_to_index: dict[str, int],
) -> int:
    attempts = 0
    prefix_bits = "".join(f"{word_to_index[word]:011b}" for word in KNOWN_WORDS)
    for label, data in materials.items():
        # 40-bit windows as the missing entropy tail; checksum is computed.
        for offset, value in bit_windows(data, 40):
            attempts += 1
            entropy = int(prefix_bits + f"{value:040b}", 2).to_bytes(16, "big")
            mnemonic = entropy_to_mnemonic(entropy, words)
            tail = tuple(mnemonic.split()[-4:])
            add_candidate(
                candidates,
                "known_prefix_plus_40bit_tail",
                f"{label}:bit_offset_{offset}:tail_{value:010x}",
                tail,  # type: ignore[arg-type]
                words,
                word_to_index,
            )

        # 44-bit windows as raw BIP39 indices for the four missing words.
        for offset, value in bit_windows(data, 44):
            attempts += 1
            tail = tuple(words[(value >> shift) & 0x7FF] for shift in (33, 22, 11, 0))
            add_candidate(
                candidates,
                "raw_44bit_bip39_tail",
                f"{label}:bit_offset_{offset}:tail44_{value:011x}",
                tail,  # type: ignore[arg-type]
                words,
                word_to_index,
            )
    return attempts


def probe_xor_stream_models(
    candidates: dict[tuple[str, str], Candidate],
    fields: dict[str, bytes],
    streams: dict[str, bytes],
    words: list[str],
    word_to_index: dict[str, int],
    bip39: set[str],
) -> int:
    attempts = 0
    for cipher_label, ciphertext in {
        "B": fields["B"],
        "B_plus_A_first18": fields["B"] + fields["A"],
        "A_plus_B_first18": fields["A"] + fields["B"],
    }.items():
        block = ciphertext[:18]
        for stream_label, stream in streams.items():
            if len(stream) < 18:
                continue
            for stream_chunk_label, chunk in (
                ("first18", stream[:18]),
                ("last18", stream[-18:]),
            ):
                attempts += 1
                plaintext = bytes(a ^ b for a, b in zip(block, chunk))
                tail = try_ascii_words(plaintext, bip39)
                if tail is None:
                    continue
                add_candidate(
                    candidates,
                    "xor_stream_ascii_words",
                    f"{cipher_label} XOR {stream_label}:{stream_chunk_label}:{plaintext!r}",
                    tail,  # type: ignore[arg-type]
                    words,
                    word_to_index,
                )
    return attempts


def probe_direct_ascii_models(
    candidates: dict[tuple[str, str], Candidate],
    materials: dict[str, bytes],
    words: list[str],
    word_to_index: dict[str, int],
    bip39: set[str],
) -> int:
    attempts = 0
    for label, data in materials.items():
        for index in range(0, max(0, len(data) - 17)):
            attempts += 1
            tail = try_ascii_words(data[index : index + 18], bip39)
            if tail is None:
                continue
            add_candidate(
                candidates,
                "direct_ascii_window",
                f"{label}:byte_window_{index}",
                tail,  # type: ignore[arg-type]
                words,
                word_to_index,
            )
    return attempts


def run_probe() -> dict:
    words = load_words()
    word_to_index = {word: index for index, word in enumerate(words)}
    bip39 = set(words)
    fields = decoded_fields()
    materials = field_materials(fields)
    digests = digest_materials(materials)
    all_materials = {**materials, **digests}
    candidates: dict[tuple[str, str], Candidate] = {}

    attempts = {
        "entropy_models": probe_entropy_models(candidates, all_materials, words, word_to_index),
        "tail_bit_models": probe_tail_bit_models(candidates, all_materials, words, word_to_index),
        "xor_stream_models": probe_xor_stream_models(
            candidates,
            fields,
            {**all_materials, **digests},
            words,
            word_to_index,
            bip39,
        ),
        "direct_ascii_models": probe_direct_ascii_models(
            candidates,
            all_materials,
            words,
            word_to_index,
            bip39,
        ),
    }
    all_candidates = list(candidates.values())
    valid_candidates = [candidate for candidate in all_candidates if candidate.valid_bip39]
    hits = [candidate for candidate in valid_candidates if candidate.matches_target]

    return {
        "scope": {
            "known_words": KNOWN_WORDS,
            "target_address": TARGET_ADDRESS,
            "fields": {key: value.hex() for key, value in fields.items()},
        },
        "attempts": attempts,
        "candidate_count": len(all_candidates),
        "valid_bip39_candidate_count": len(valid_candidates),
        "hit_count": len(hits),
        "hits": [candidate.__dict__ for candidate in hits],
        "valid_bip39_candidates_sample": [
            candidate.__dict__ for candidate in valid_candidates[:100]
        ],
    }


def write_report(findings: dict) -> None:
    lines = [
        "# A/B/C/E Model Output Probe",
        "",
        "## Scope",
        "",
        "This probe searches bounded derivation models that turn the puzzle fields `A/B/C/E` into candidate missing seed words.",
        "",
        "It is different from the full word-space brute force: this tries to derive output words from the puzzle bytes first, then tests the Zenon address.",
        "",
        "## Models",
        "",
        "- 128-bit entropy chunks from fields, permutations, hashes, and HMACs.",
        "- 40-bit windows as the missing BIP39 entropy tail after the known 8 words.",
        "- 44-bit windows as raw BIP39 indices for the four missing words.",
        "- XOR streams where `B` is treated as an 18-byte ciphertext and hash/HMAC material is treated as a stream.",
        "- Direct 18-byte ASCII windows.",
        "",
        "## Result",
        "",
        "```json",
        json.dumps(
            {
                "attempts": findings["attempts"],
                "candidate_count": findings["candidate_count"],
                "valid_bip39_candidate_count": findings["valid_bip39_candidate_count"],
                "hit_count": findings["hit_count"],
                "hits": findings["hits"],
            },
            indent=2,
        ),
        "```",
        "",
        "## Valid Candidate Sample",
        "",
        "```json",
        json.dumps(findings["valid_bip39_candidates_sample"], indent=2),
        "```",
        "",
        "## Notes",
        "",
        "- A hit here would be much stronger than a pure word brute-force hit, because it would identify a reproducible model from `A/B/C/E` to the missing words.",
        "- A miss does not disprove every possible model; it only rules out this bounded family.",
        "- The search intentionally avoids unbounded post-hoc parameter tuning.",
    ]
    (OUT / "model_output_probe.md").write_text("\n".join(lines) + "\n")


def main() -> None:
    OUT.mkdir(exist_ok=True)
    findings = run_probe()
    (OUT / "model_output_probe.json").write_text(json.dumps(findings, indent=2) + "\n")
    write_report(findings)
    print(json.dumps({k: findings[k] for k in ("attempts", "candidate_count", "valid_bip39_candidate_count", "hit_count", "hits")}, indent=2))
    print("Wrote out/model_output_probe.json")
    print("Wrote out/model_output_probe.md")


if __name__ == "__main__":
    main()
