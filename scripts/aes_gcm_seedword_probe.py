#!/usr/bin/env python3
"""Bounded AES-GCM probe for the Zenon seed-word hunt.

This keeps the search inside the concrete shape suggested by the forum post:

  B + A = 34 bytes = 18-byte ciphertext + 16-byte GCM tag

The probe varies only small, clue-derived password / nonce / AAD choices. It
does not brute-force the full BIP39 missing-word space.
"""

from __future__ import annotations

import base64
import hashlib
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out"
WORDLIST = ROOT / "data" / "bip39_english.txt"

B64_A = "BynQtpeUyWTXKGTrGhdV2Q=="
B64_B = "tVMd3L1CKM4wFmyxEEEUV2bY"
B64_C = "4Fdzw1k="
B64_E = "vtv3f5aKY0jGQglP9a1AGw=="


@dataclass(frozen=True)
class ProbeCase:
    cipher_label: str
    split_label: str
    kdf_label: str
    password: str
    nonce_label: str
    aad_label: str
    plaintext_hex: str
    plaintext_text: str | None
    four_bip39_words: bool


def decoded_fields() -> dict[str, bytes]:
    return {
        "A": base64.b64decode(B64_A),
        "B": base64.b64decode(B64_B),
        "C": base64.b64decode(B64_C),
        "E": base64.b64decode(B64_E),
    }


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def try_text(data: bytes) -> str | None:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if all(ch in "\t\n\r" or 32 <= ord(ch) <= 126 for ch in text):
        return text
    return None


def wordlist() -> set[str]:
    return set(WORDLIST.read_text().splitlines())


def is_four_bip39_words(text: str | None, words: set[str]) -> bool:
    if text is None:
        return False
    parts = text.strip().split()
    return len(parts) == 4 and all(part in words for part in parts)


def openssl_argon2id_key(password: str, salt: bytes) -> bytes | None:
    """Derive the Zenon keyfile-style Argon2id key using local OpenSSL.

    Zenon keyfiles use Argon2id with timeCost=1, memoryCost=64*1024,
    hashLength=32, type=Argon2id, parallelism/lanes=4. OpenSSL's CLI cannot
    use worker threads in this sandbox, but lanes=4 with no explicit threads
    derives successfully and matches the intended Argon2id parameter family.
    """

    try:
        output = subprocess.check_output(
            [
                "openssl",
                "kdf",
                "-keylen",
                "32",
                "-kdfopt",
                f"pass:{password}",
                "-kdfopt",
                f"hexsalt:{salt.hex()}",
                "-kdfopt",
                "iter:1",
                "-kdfopt",
                "memcost:65536",
                "-kdfopt",
                "lanes:4",
                "ARGON2ID",
            ],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        return None
    return bytes.fromhex(output.replace(":", ""))


def key_candidates(passwords: list[str], salt: bytes, include_argon2: bool) -> list[tuple[str, str, bytes]]:
    rows: list[tuple[str, str, bytes]] = []
    for password in passwords:
        rows.append(("sha256(password)", password, sha256(password.encode())))
        rows.append(("sha256(password+salt)", password, sha256(password.encode() + salt)))
        rows.append(("sha256(salt+password)", password, sha256(salt + password.encode())))
        rows.append(("pbkdf2_sha256_1000", password, hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 1000, 32)))
        if include_argon2:
            key = openssl_argon2id_key(password, salt)
            if key is not None:
                rows.append(("argon2id_zenon_params", password, key))
    return rows


def nonce_candidates(c: bytes, a: bytes, b: bytes, e: bytes) -> list[tuple[str, bytes]]:
    z_pad = b"z" * 16
    decoded_z_pad = base64.b64decode(z_pad)
    materials = {
        "A": a,
        "B": b,
        "C": c,
        "E": e,
        "B_plus_A": b + a,
        "A_plus_B": a + b,
        "z_pad_ascii": z_pad,
        "z_pad_base64_decoded": decoded_z_pad,
        "C_plus_z_pad_ascii": c + z_pad,
        "raw_fields": a + b + c + e,
    }
    rows: dict[str, bytes] = {}

    def add(label: str, nonce: bytes) -> None:
        if len(nonce) == 12:
            rows.setdefault(label, nonce)

    add("C_plus_7_zero", c + b"\x00" * 7)
    add("C_plus_7_ascii_z", c + b"z" * 7)
    add("C_plus_7_0xff", c + b"\xff" * 7)
    add("C_plus_E_first7", c + e[:7])
    add("C_plus_A_first7", c + a[:7])
    add("C_plus_B_first7", c + b[:7])
    add("base64_z_pad_decoded_12", decoded_z_pad)

    for label, material in materials.items():
        if len(material) >= 12:
            add(f"{label}_first12", material[:12])
            add(f"{label}_last12", material[-12:])
            for index in range(len(material) - 11):
                add(f"{label}_window_{index}", material[index : index + 12])
        digest = sha256(material)
        add(f"sha256_{label}_first12", digest[:12])
        add(f"sha256_{label}_last12", digest[-12:])
    return sorted(rows.items())


def cipher_splits(a: bytes, b: bytes) -> list[tuple[str, str, bytes, bytes]]:
    variants = {
        "B_plus_A": b + a,
        "A_plus_B": a + b,
    }
    rows: list[tuple[str, str, bytes, bytes]] = []
    for label, data in variants.items():
        rows.append((label, "tag_last", data[:-16], data[-16:]))
        rows.append((label, "tag_first", data[16:], data[:16]))
    return rows


def password_candidates() -> list[str]:
    words = [
        "taproot",
        "Taproot",
        "TAPROOT",
        "bitcoin",
        "Bitcoin",
        "schnorr",
        "Schnorr",
        "zenon",
        "Zenon",
        "alphanet",
        "Alphanet",
        "quantum",
        "history",
        "momentum",
        "smart contracts",
        "smartcontracts",
        "oblige",
        "dilemma",
        "hurry",
        "disorder",
        "happy",
        "spoil",
        "shiver",
        "key",
    ]
    return list(dict.fromkeys(words))


def aad_candidates() -> list[tuple[str, bytes | None]]:
    return [
        ("zenon_sdk_aad", b"zenon"),
        ("empty_aad", b""),
        ("no_aad", None),
        ("taproot_aad", b"taproot"),
        ("bitcoin_aad", b"bitcoin"),
    ]


def run_probe(include_argon2: bool) -> dict:
    fields = decoded_fields()
    a, b, c, e = fields["A"], fields["B"], fields["C"], fields["E"]
    bip39_words = wordlist()
    hits: list[ProbeCase] = []
    attempts = 0
    split_rows = cipher_splits(a, b)
    nonce_rows = nonce_candidates(c, a, b, e)
    key_rows = key_candidates(password_candidates(), e, include_argon2)
    aad_rows = aad_candidates()

    for cipher_label, split_label, ciphertext, tag in split_rows:
        combined = ciphertext + tag
        for nonce_label, nonce in nonce_rows:
            for kdf_label, password, key in key_rows:
                aesgcm = AESGCM(key)
                for aad_label, aad in aad_rows:
                    attempts += 1
                    try:
                        plaintext = aesgcm.decrypt(nonce, combined, aad)
                    except Exception:
                        continue
                    text = try_text(plaintext)
                    hits.append(
                        ProbeCase(
                            cipher_label=cipher_label,
                            split_label=split_label,
                            kdf_label=kdf_label,
                            password=password,
                            nonce_label=nonce_label,
                            aad_label=aad_label,
                            plaintext_hex=plaintext.hex(),
                            plaintext_text=text,
                            four_bip39_words=is_four_bip39_words(text, bip39_words),
                        )
                    )

    return {
        "shape": {
            "B_len": len(b),
            "A_len": len(a),
            "B_plus_A_len": len(b + a),
            "ciphertext_len_if_16_byte_tag": len(b + a) - 16,
            "tag_len": 16,
        },
        "parameters": {
            "cipher_splits": len(split_rows),
            "nonce_candidates": len(nonce_rows),
            "passwords": len(password_candidates()),
            "keys": len(key_rows),
            "aad_candidates": len(aad_rows),
            "include_argon2": include_argon2,
        },
        "attempts": attempts,
        "hits": [case.__dict__ for case in hits],
        "bip39_word_hits": [case.__dict__ for case in hits if case.four_bip39_words],
    }


def write_report(findings: dict) -> None:
    hits = findings["hits"]
    word_hits = findings["bip39_word_hits"]
    lines = [
        "# AES-GCM Seed-Word Probe",
        "",
        "## Scope",
        "",
        "This search keeps the crypto shape constrained to `B + A = 34 bytes`: 18 bytes of ciphertext plus a 16-byte AES-GCM authentication tag.",
        "",
        "It varies only clue-derived password, nonce, KDF, and AAD choices. It does not brute-force the four missing seed words.",
        "",
        "## Shape",
        "",
        "```json",
        json.dumps(findings["shape"], indent=2),
        "```",
        "",
        "## Parameters",
        "",
        "```json",
        json.dumps(findings["parameters"], indent=2),
        "```",
        "",
        f"Total authenticated-decrypt attempts: `{findings['attempts']}`",
        "",
        "## Result",
        "",
    ]
    if hits:
        lines.extend(
            [
                "At least one authenticated AES-GCM decrypt succeeded:",
                "",
                "```json",
                json.dumps(hits, indent=2),
                "```",
            ]
        )
    else:
        lines.append("No authenticated AES-GCM decrypt succeeded in this bounded search.")
    lines.extend(
        [
            "",
            "## Four-Word Plaintext Hits",
            "",
            "```json",
            json.dumps(word_hits, indent=2),
            "```",
            "",
            "## Notes",
            "",
            "- The Zenon SDK keyfile format uses AES-256-GCM with AAD `zenon` and an Argon2id-derived key.",
            "- The forum post's `cipherData`, `salt`, `nonce`, and `password` terminology matches Zenon keyfile vocabulary, so Argon2id and AAD `zenon` are included.",
            "- A miss here does not disprove AES-GCM generally; it only rules out this bounded set of clue-derived parameters.",
        ]
    )
    (OUT / "aes_gcm_seedword_probe.md").write_text("\n".join(lines) + "\n")


def main() -> None:
    OUT.mkdir(exist_ok=True)
    findings = run_probe(include_argon2=True)
    (OUT / "aes_gcm_seedword_probe.json").write_text(json.dumps(findings, indent=2) + "\n")
    write_report(findings)
    print(json.dumps({k: findings[k] for k in ("shape", "parameters", "attempts", "hits", "bip39_word_hits")}, indent=2))
    print("Wrote out/aes_gcm_seedword_probe.json")
    print("Wrote out/aes_gcm_seedword_probe.md")


if __name__ == "__main__":
    main()
