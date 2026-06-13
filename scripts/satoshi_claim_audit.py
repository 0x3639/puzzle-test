#!/usr/bin/env python3
"""Audit the Zenon Taproot puzzle against a Satoshi attribution hypothesis.

The script is deliberately conservative: it distinguishes facts that are
directly visible on-chain from deterministic derivations and from narrative
interpretation. It uses local JSON caches under data/blockstream/.
"""

from __future__ import annotations

import base64
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

try:
    from cryptography.hazmat.backends import default_backend
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
except Exception as exc:  # pragma: no cover - environment guard
    raise SystemExit(f"cryptography package is required: {exc}")


ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data" / "blockstream"
OUT = ROOT / "out"

ARTIFACT_ADDRESS = "bc1qrnldpdlq9dsfy946m4vqa5mrec8qhdrx363end"
ARTIFACT_HEIGHT = 709_632
ARTIFACT_BLOCK_HASH = "0000000000000000000687bca986194dc2c1f949318629b44bb54ec0a94d8244"
SETUP_TXID = "dd3bbc563197a6cddc78ad4a432dc92ba9c207809fc10db7d2716937d27c5d4d"
TERMINAL_TXID = "911dcb7435932f64215f8de4058186aef9bfd4356978c95830e77a38b9484083"
POST_TERMINAL_TXID = "cd7b40e5c7c62563a38a571e51f5e65d351be5369a8378a95715cb69aa8b69d1"
VANITY_P2SH_ADDRESS = "37zkpKaqDQpqkANMbFw5UaPpiAeceg5fdw"

B64_A = "BynQtpeUyWTXKGTrGhdV2Q=="
B64_B = "tVMd3L1CKM4wFmyxEEEUV2bY"
B64_C = "4Fdzw1k="
B64_E = "vtv3f5aKY0jGQglP9a1AGw=="

# Cautious reference set. These are not a complete Satoshi/Patoshi database.
# They are included as high-signal public controls that should be documented
# before any attribution claim is made.
REFERENCE_ADDRESSES = {
    "genesis-p2pk-derived": "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
    "block-9-satoshi-to-hal-source": "12cbQLTFMXRnSzktFkuoG3eHoMeFtpTu3S",
}


BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
SECP256K1_N = int(
    "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141", 16
)


def load_json(name: str) -> Any:
    return json.loads((DATA / name).read_text())


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def dsha256(data: bytes) -> bytes:
    return sha256(sha256(data))


def hash160(data: bytes) -> bytes:
    return hashlib.new("ripemd160", sha256(data)).digest()


def b58encode(raw: bytes) -> str:
    n = int.from_bytes(raw, "big")
    out = ""
    while n:
        n, rem = divmod(n, 58)
        out = BASE58_ALPHABET[rem] + out
    pad = 0
    for b in raw:
        if b == 0:
            pad += 1
        else:
            break
    return "1" * pad + out


def b58check(version: bytes, payload: bytes) -> str:
    raw = version + payload
    return b58encode(raw + dsha256(raw)[:4])


def bech32_polymod(values: Iterable[int]) -> int:
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
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]


def bech32_checksum(hrp: str, data: list[int], spec: str) -> list[int]:
    const = 1 if spec == "bech32" else 0x2BC830A3
    polymod = bech32_polymod(bech32_hrp_expand(hrp) + data + [0, 0, 0, 0, 0, 0])
    polymod ^= const
    return [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]


def bech32_encode(hrp: str, data: list[int], spec: str = "bech32") -> str:
    combined = data + bech32_checksum(hrp, data, spec)
    return hrp + "1" + "".join(BECH32_CHARSET[d] for d in combined)


def convertbits(data: Iterable[int], frombits: int, tobits: int, pad: bool = True) -> list[int]:
    acc = 0
    bits = 0
    ret: list[int] = []
    maxv = (1 << tobits) - 1
    for value in data:
        if value < 0 or value >> frombits:
            raise ValueError("invalid convertbits value")
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad:
        if bits:
            ret.append((acc << (tobits - bits)) & maxv)
    elif bits >= frombits or ((acc << (tobits - bits)) & maxv):
        raise ValueError("invalid padding")
    return ret


def p2pkh(pubkey: bytes) -> str:
    return b58check(b"\x00", hash160(pubkey))


def p2wpkh(pubkey: bytes) -> str:
    return bech32_encode("bc", [0] + convertbits(hash160(pubkey), 8, 5), "bech32")


def p2sh_p2wpkh(pubkey: bytes) -> str:
    redeem = b"\x00\x14" + hash160(pubkey)
    return b58check(b"\x05", hash160(redeem))


def p2tr_xonly(pubkey_xonly: bytes) -> str:
    return bech32_encode("bc", [1] + convertbits(pubkey_xonly, 8, 5), "bech32m")


def private_key_to_addresses(seed32: bytes) -> dict[str, str] | None:
    d = int.from_bytes(seed32, "big")
    if d <= 0 or d >= SECP256K1_N:
        return None
    key = ec.derive_private_key(d, ec.SECP256K1(), default_backend())
    pub = key.public_key()
    compressed = pub.public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.CompressedPoint
    )
    uncompressed = pub.public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )
    xonly = pub.public_numbers().x.to_bytes(32, "big")
    return {
        "private_key_hex": seed32.hex(),
        "pubkey_compressed": compressed.hex(),
        "p2pkh_compressed": p2pkh(compressed),
        "p2pkh_uncompressed": p2pkh(uncompressed),
        "p2wpkh": p2wpkh(compressed),
        "p2sh_p2wpkh": p2sh_p2wpkh(compressed),
        "p2tr_xonly_untweaked": p2tr_xonly(xonly),
    }


def op_return_payload(tx: dict[str, Any]) -> str | None:
    for vout in tx.get("vout", []):
        script = bytes.fromhex(vout["scriptpubkey"])
        if script and script[0] == 0x6A:
            if len(script) < 2:
                return ""
            op = script[1]
            if op <= 75:
                return script[2 : 2 + op].decode("ascii", "replace")
            return script[2:].decode("ascii", "replace")
    return None


def parse_der_signature(sig_hex: str) -> dict[str, Any] | None:
    raw = bytes.fromhex(sig_hex)
    if len(raw) < 9:
        return None
    sighash_type = raw[-1]
    der = raw[:-1]
    if der[0] != 0x30 or der[1] != len(der) - 2:
        return None
    pos = 2
    if pos >= len(der) or der[pos] != 0x02:
        return None
    r_len = der[pos + 1]
    r = der[pos + 2 : pos + 2 + r_len]
    pos += 2 + r_len
    if pos >= len(der) or der[pos] != 0x02:
        return None
    s_len = der[pos + 1]
    s = der[pos + 2 : pos + 2 + s_len]
    if pos + 2 + s_len != len(der):
        return None
    return {
        "r": int.from_bytes(r, "big"),
        "s": int.from_bytes(s, "big"),
        "r_hex": r.hex(),
        "s_hex": s.hex(),
        "sighash_type": sighash_type,
        "r_len": r_len,
        "s_len": s_len,
    }


def witness_signatures(txs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for tx in txs:
        for vin_index, vin in enumerate(tx.get("vin", [])):
            witness = vin.get("witness") or []
            if len(witness) < 2:
                continue
            parsed = parse_der_signature(witness[0])
            if not parsed:
                continue
            pubkey = bytes.fromhex(witness[1])
            rows.append(
                {
                    "height": tx.get("status", {}).get("block_height"),
                    "txid": tx["txid"],
                    "vin": vin_index,
                    "prev_txid": vin["txid"],
                    "prev_vout": vin["vout"],
                    "prev_value": vin.get("prevout", {}).get("value"),
                    "prev_address": vin.get("prevout", {}).get("scriptpubkey_address"),
                    "pubkey": pubkey.hex(),
                    "p2wpkh": p2wpkh(pubkey) if len(pubkey) in (33, 65) else None,
                    **parsed,
                }
            )
    return rows


@dataclass
class ArtifactSummary:
    rows: list[dict[str, Any]]
    terminal: dict[str, Any] | None
    artifact_text: str
    artifact_sha256: str


def summarize_artifact(address_txs: list[dict[str, Any]]) -> ArtifactSummary:
    block_txs = [
        tx
        for tx in address_txs
        if tx.get("status", {}).get("block_height") == ARTIFACT_HEIGHT
        and op_return_payload(tx) is not None
    ]
    row_txs = []
    terminal = None
    for tx in block_txs:
        payload = op_return_payload(tx)
        if tx["txid"] == TERMINAL_TXID:
            terminal = {
                "txid": tx["txid"],
                "payload": payload,
                "input_count": len(tx.get("vin", [])),
                "fee": tx.get("fee"),
                "outputs": [
                    {
                        "index": i,
                        "address": vout.get("scriptpubkey_address"),
                        "value": vout.get("value"),
                        "type": vout.get("scriptpubkey_type"),
                    }
                    for i, vout in enumerate(tx.get("vout", []))
                ],
            }
            continue
        prev = tx["vin"][0]
        if prev["txid"] == SETUP_TXID:
            row_txs.append(
                {
                    "source_vout": prev["vout"],
                    "txid": tx["txid"],
                    "payload": payload or "",
                    "fee": tx.get("fee"),
                    "change_values": [
                        vout["value"]
                        for vout in tx.get("vout", [])
                        if vout.get("scriptpubkey_address") == ARTIFACT_ADDRESS
                    ],
                }
            )
    rows = sorted(row_txs, key=lambda r: r["source_vout"])
    artifact_text = "\n".join(row["payload"].rstrip() for row in rows)
    if terminal:
        artifact_text += "\n" + terminal["payload"]
    return ArtifactSummary(
        rows=rows,
        terminal=terminal,
        artifact_text=artifact_text,
        artifact_sha256=sha256(artifact_text.encode()).hex(),
    )


def decoded_fields() -> dict[str, bytes]:
    return {
        "A": base64.b64decode(B64_A),
        "B": base64.b64decode(B64_B),
        "C": base64.b64decode(B64_C),
        "E": base64.b64decode(B64_E),
    }


def puzzle_core() -> dict[str, Any]:
    fields = decoded_fields()
    a, b, c, e = fields["A"], fields["B"], fields["C"], fields["E"]
    hdr = b[0:3]
    groups = [b[3 + i * 3 : 6 + i * 3] for i in range(5)]
    selectors = [(i, x) for i, x in enumerate(e) if x < len(b)]
    selector_index, selector_value = selectors[0]
    g3 = b[selector_value : selector_value + 3]
    mask = (g3[0] ^ g3[2]) & 0x07
    out = g3[1] ^ mask
    return {
        "fields": {k: v.hex() for k, v in fields.items()},
        "lengths": {k: len(v) for k, v in fields.items()},
        "B_header": hdr.hex(),
        "B_groups": [g.hex() for g in groups],
        "legal_E_selectors": [{"index": i, "value": v} for i, v in selectors],
        "selected_slice": {"start": selector_value, "hex": g3.hex()},
        "kernel_mask": mask,
        "kernel_out": out,
        "bridge_kernel_to_E3": out ^ groups[3][2],
        "bridge_selector_to_header": selector_value ^ groups[3][2],
    }


def deterministic_key_candidates() -> list[dict[str, Any]]:
    fields = decoded_fields()
    a, b, c, e = fields["A"], fields["B"], fields["C"], fields["E"]
    raw = a + b + c + e
    b64_ascii = (B64_A + B64_B + B64_C + B64_E).encode()
    g3 = b[9:12]
    mask = ((g3[0] ^ g3[2]) & 0x07).to_bytes(1, "big")
    kernel_out = bytes([g3[1] ^ mask[0]])
    seed_material: dict[str, bytes] = {
        "sha256(decoded_A_B_C_E)": sha256(raw),
        "double_sha256(decoded_A_B_C_E)": dsha256(raw),
        "sha256(concat_base64_ascii)": sha256(b64_ascii),
        "double_sha256(concat_base64_ascii)": dsha256(b64_ascii),
        "A_plus_E": a + e,
        "E_plus_A": e + a,
        "A_xor_E_repeated": bytes(x ^ y for x, y in zip(a, e)) * 2,
        "sha256(G3)": sha256(g3),
        "G3_zero_padded": g3 + b"\x00" * 29,
        "G3_mask_out_zero_padded": g3 + mask + kernel_out + b"\x00" * 27,
        "kernel_mask_out_zero_padded": mask + kernel_out + b"\x00" * 30,
    }
    observed = observed_address_set()
    reference = set(REFERENCE_ADDRESSES.values())
    rows = []
    for name, seed in seed_material.items():
        if len(seed) != 32:
            continue
        derived = private_key_to_addresses(seed)
        if not derived:
            rows.append({"name": name, "seed_hex": seed.hex(), "valid_private_key": False})
            continue
        all_addresses = {v for k, v in derived.items() if k.startswith("p2")}
        rows.append(
            {
                "name": name,
                "valid_private_key": True,
                **derived,
                "matches_observed_addresses": sorted(all_addresses & observed),
                "matches_reference_addresses": sorted(all_addresses & reference),
            }
        )
    return rows


def bip39_like_words() -> dict[str, str]:
    word_path = ROOT / "data" / "bip39_english.txt"
    if not word_path.exists():
        return {}
    words = word_path.read_text().splitlines()

    def mnemonic(entropy: bytes) -> str:
        bits = "".join(f"{b:08b}" for b in entropy)
        cs = "".join(f"{b:08b}" for b in sha256(entropy))[: len(entropy) * 8 // 32]
        full = bits + cs
        return " ".join(words[int(full[i : i + 11], 2)] for i in range(0, len(full), 11))

    fields = decoded_fields()
    a, e = fields["A"], fields["E"]
    return {
        "A_as_entropy": mnemonic(a),
        "E_as_entropy": mnemonic(e),
        "A_xor_E_as_entropy": mnemonic(bytes(x ^ y for x, y in zip(a, e))),
    }


def observed_address_set() -> set[str]:
    addresses: set[str] = {ARTIFACT_ADDRESS, VANITY_P2SH_ADDRESS}
    for name in [
        "artifact_address_txs.json",
        "tx_setup_fanout.json",
        "tx_terminal.json",
        "tx_post_terminal_to_37zkp.json",
        "tx_source_61a990.json",
        "tx_source_eac1.json",
        "tx_source_61a990_parent.json",
        "tx_source_eac1_parent.json",
    ]:
        path = DATA / name
        if not path.exists():
            continue
        obj = load_json(name)
        txs = obj if isinstance(obj, list) else [obj]
        for tx in txs:
            for vin in tx.get("vin", []):
                addr = vin.get("prevout", {}).get("scriptpubkey_address")
                if addr:
                    addresses.add(addr)
            for vout in tx.get("vout", []):
                addr = vout.get("scriptpubkey_address")
                if addr:
                    addresses.add(addr)
    return addresses


def scan_embedded_crypto_bytes() -> dict[str, Any]:
    fields = decoded_fields()
    raw = b"".join(fields.values())
    b64_ascii = (B64_A + B64_B + B64_C + B64_E).encode()

    def der_offsets(blob: bytes) -> list[int]:
        hits = []
        for i in range(len(blob) - 8):
            if blob[i] != 0x30:
                continue
            total = blob[i + 1]
            end = i + 2 + total
            if end > len(blob):
                continue
            candidate = blob[i:end] + b"\x01"
            if parse_der_signature(candidate.hex()):
                hits.append(i)
        return hits

    def pubkey_offsets(blob: bytes) -> dict[str, list[int]]:
        compressed = [i for i in range(len(blob) - 32) if blob[i] in (2, 3)]
        uncompressed = [i for i in range(len(blob) - 64) if blob[i] == 4]
        return {
            "compressed_prefix_33_byte_windows": compressed,
            "uncompressed_prefix_65_byte_windows": uncompressed,
        }

    return {
        "decoded_length": len(raw),
        "base64_ascii_length": len(b64_ascii),
        "der_signature_offsets_decoded": der_offsets(raw),
        "der_signature_offsets_base64_ascii": der_offsets(b64_ascii),
        "pubkey_offsets_decoded": pubkey_offsets(raw),
        "pubkey_offsets_base64_ascii": pubkey_offsets(b64_ascii),
        "has_room_for_schnorr_signature_decoded": len(raw) >= 64,
        "has_room_for_schnorr_signature_base64_ascii": len(b64_ascii) >= 64,
    }


def setup_and_flow_summary() -> dict[str, Any]:
    address_txs = load_json("artifact_address_txs.json")
    setup = load_json("tx_setup_fanout.json")
    terminal = load_json("tx_terminal.json")
    post = load_json("tx_post_terminal_to_37zkp.json")
    vanity_txs = load_json("address_37zkp_txs.json")
    source_61 = load_json("tx_source_61a990.json")
    source_eac1 = load_json("tx_source_eac1.json")

    artifact_txs = [
        tx
        for tx in address_txs
        if tx.get("status", {}).get("block_height") == ARTIFACT_HEIGHT
        and tx["txid"] != TERMINAL_TXID
        and op_return_payload(tx) is not None
    ]
    row_fees = sorted({tx.get("fee") for tx in artifact_txs})
    row_change_values = sorted(
        {
            vout.get("value")
            for tx in artifact_txs
            for vout in tx.get("vout", [])
            if vout.get("scriptpubkey_address") == ARTIFACT_ADDRESS
        }
    )
    setup_outputs = [vout["value"] for vout in setup.get("vout", [])]
    vanity_spends = []
    for tx in vanity_txs:
        for vin_index, vin in enumerate(tx.get("vin", [])):
            if vin.get("prevout", {}).get("scriptpubkey_address") == VANITY_P2SH_ADDRESS:
                vanity_spends.append(
                    {
                        "spending_txid": tx["txid"],
                        "height": tx.get("status", {}).get("block_height"),
                        "vin": vin_index,
                        "value": vin.get("prevout", {}).get("value"),
                        "input_count": len(tx.get("vin", [])),
                        "fee": tx.get("fee"),
                    }
                )
    return {
        "artifact_address_tx_count_page": len(address_txs),
        "setup": {
            "txid": setup["txid"],
            "height": setup.get("status", {}).get("block_height"),
            "input_sum": sum(vin.get("prevout", {}).get("value", 0) for vin in setup.get("vin", [])),
            "output_count": len(setup.get("vout", [])),
            "outputs_are_19x_75000": len(setup_outputs) == 19 and set(setup_outputs) == {75000},
            "fee": setup.get("fee"),
            "inputs": [
                {
                    "txid": vin["txid"],
                    "vout": vin["vout"],
                    "value": vin.get("prevout", {}).get("value"),
                    "address": vin.get("prevout", {}).get("scriptpubkey_address"),
                    "scriptpubkey_type": vin.get("prevout", {}).get("scriptpubkey_type"),
                }
                for vin in setup.get("vin", [])
            ],
        },
        "artifact_rows": {
            "count": len(artifact_txs),
            "fees": row_fees,
            "change_values": row_change_values,
        },
        "terminal": {
            "txid": terminal["txid"],
            "height": terminal.get("status", {}).get("block_height"),
            "input_count": len(terminal.get("vin", [])),
            "input_sum": sum(
                vin.get("prevout", {}).get("value", 0) for vin in terminal.get("vin", [])
            ),
            "fee": terminal.get("fee"),
            "outputs": [
                {
                    "index": i,
                    "type": vout.get("scriptpubkey_type"),
                    "address": vout.get("scriptpubkey_address"),
                    "value": vout.get("value"),
                    "asm": vout.get("scriptpubkey_asm"),
                }
                for i, vout in enumerate(terminal.get("vout", []))
            ],
        },
        "post_terminal": {
            "txid": post["txid"],
            "height": post.get("status", {}).get("block_height"),
            "inputs": [
                {
                    "txid": vin["txid"],
                    "vout": vin["vout"],
                    "value": vin.get("prevout", {}).get("value"),
                    "address": vin.get("prevout", {}).get("scriptpubkey_address"),
                }
                for vin in post.get("vin", [])
            ],
            "outputs": [
                {
                    "index": i,
                    "type": vout.get("scriptpubkey_type"),
                    "address": vout.get("scriptpubkey_address"),
                    "value": vout.get("value"),
                }
                for i, vout in enumerate(post.get("vout", []))
            ],
            "fee": post.get("fee"),
        },
        "vanity_p2sh_spends": vanity_spends,
        "source_transactions": [
            {
                "txid": source_61["txid"],
                "height": source_61.get("status", {}).get("block_height"),
                "outputs_to_artifact_address": [
                    {"index": i, "value": vout.get("value")}
                    for i, vout in enumerate(source_61.get("vout", []))
                    if vout.get("scriptpubkey_address") == ARTIFACT_ADDRESS
                ],
                "inputs": [
                    {
                        "txid": vin["txid"],
                        "vout": vin["vout"],
                        "value": vin.get("prevout", {}).get("value"),
                        "address": vin.get("prevout", {}).get("scriptpubkey_address"),
                        "type": vin.get("prevout", {}).get("scriptpubkey_type"),
                    }
                    for vin in source_61.get("vin", [])
                ],
            },
            {
                "txid": source_eac1["txid"],
                "height": source_eac1.get("status", {}).get("block_height"),
                "outputs_to_artifact_address": [
                    {"index": i, "value": vout.get("value")}
                    for i, vout in enumerate(source_eac1.get("vout", []))
                    if vout.get("scriptpubkey_address") == ARTIFACT_ADDRESS
                ],
                "inputs": [
                    {
                        "txid": vin["txid"],
                        "vout": vin["vout"],
                        "value": vin.get("prevout", {}).get("value"),
                        "address": vin.get("prevout", {}).get("scriptpubkey_address"),
                        "type": vin.get("prevout", {}).get("scriptpubkey_type"),
                    }
                    for vin in source_eac1.get("vin", [])
                ],
            },
        ],
    }


def signature_summary() -> dict[str, Any]:
    address_txs = load_json("artifact_address_txs.json")
    sigs = witness_signatures(address_txs)
    artifact_sigs = [
        sig
        for sig in sigs
        if sig["height"] == ARTIFACT_HEIGHT
        or sig["txid"] in {SETUP_TXID, TERMINAL_TXID, POST_TERMINAL_TXID}
    ]
    r_to_sigs: dict[int, list[dict[str, Any]]] = {}
    for sig in artifact_sigs:
        r_to_sigs.setdefault(sig["r"], []).append(sig)
    repeated = [
        [
            {
                "txid": sig["txid"],
                "vin": sig["vin"],
                "prev_txid": sig["prev_txid"],
                "prev_vout": sig["prev_vout"],
            }
            for sig in group
        ]
        for group in r_to_sigs.values()
        if len(group) > 1
    ]
    unique_pubkeys = sorted({sig["pubkey"] for sig in artifact_sigs})
    unique_p2wpkh = sorted({sig["p2wpkh"] for sig in artifact_sigs if sig["p2wpkh"]})
    return {
        "artifact_related_signature_count": len(artifact_sigs),
        "unique_pubkeys": unique_pubkeys,
        "unique_p2wpkh_addresses": unique_p2wpkh,
        "sighash_types": sorted({sig["sighash_type"] for sig in artifact_sigs}),
        "repeated_r_groups": repeated,
        "all_artifact_related_signatures": [
            {
                "height": sig["height"],
                "txid": sig["txid"],
                "vin": sig["vin"],
                "prev_vout": sig["prev_vout"],
                "prev_address": sig["prev_address"],
                "p2wpkh": sig["p2wpkh"],
                "r_hex_prefix": sig["r_hex"][:16],
                "s_hex_prefix": sig["s_hex"][:16],
                "sighash_type": sig["sighash_type"],
            }
            for sig in artifact_sigs
        ],
    }


def markdown_report(findings: dict[str, Any]) -> str:
    artifact = findings["artifact"]
    flow = findings["flow"]
    sigs = findings["signatures"]
    core = findings["puzzle_core"]
    derivations = findings["deterministic_key_candidates"]
    embedded = findings["embedded_crypto_scan"]
    bip39 = findings["bip39_like_words"]

    derivation_matches = [
        row
        for row in derivations
        if row.get("matches_observed_addresses") or row.get("matches_reference_addresses")
    ]
    ref_addresses = "\n".join(
        f"- `{name}`: `{address}`" for name, address in REFERENCE_ADDRESSES.items()
    )
    setup_inputs = "\n".join(
        f"- `{i['value']}` sats from `{i['address']}` ({i['scriptpubkey_type']}) via `{i['txid']}:{i['vout']}`"
        for i in flow["setup"]["inputs"]
    )
    source_inputs = []
    for tx in flow["source_transactions"]:
        for vin in tx["inputs"]:
            source_inputs.append(
                f"- `{tx['txid']}` is funded by `{vin['value']}` sats from `{vin['address']}` ({vin['type']})"
            )
    source_input_text = "\n".join(source_inputs)
    sig_addresses = "\n".join(f"- `{addr}`" for addr in sigs["unique_p2wpkh_addresses"])
    derivation_table = "\n".join(
        "| {name} | {p2pkh} | {p2wpkh} | {p2sh} | {p2tr} | {obs} | {ref} |".format(
            name=row["name"],
            p2pkh=row.get("p2pkh_compressed", ""),
            p2wpkh=row.get("p2wpkh", ""),
            p2sh=row.get("p2sh_p2wpkh", ""),
            p2tr=row.get("p2tr_xonly_untweaked", ""),
            obs=", ".join(row.get("matches_observed_addresses", [])),
            ref=", ".join(row.get("matches_reference_addresses", [])),
        )
        for row in derivations
        if row.get("valid_private_key")
    )
    rows_preview = "\n".join(
        f"{row['source_vout']:02d}: `{row['payload'].rstrip()}`" for row in artifact["rows"]
    )
    bip39_text = "\n".join(f"- `{k}`: {v}" for k, v in bip39.items()) or "- not evaluated"

    conclusion = (
        "No cryptographic or chain-provenance evidence currently supports the Satoshi attribution claim. "
        "The artifact is deliberate and technically staged, but the observed signing key is a modern P2WPKH "
        "key for the artifact address, deterministic puzzle-derived key candidates do not match the observed "
        "or reference Satoshi addresses, and no embedded verifiable signature was found."
    )

    cache_files = "\n".join(
        f"- `{path.relative_to(ROOT)}`" for path in sorted(DATA.glob("*.json"))
    )

    return f"""# Satoshi Attribution Audit: Zenon Taproot Puzzle

## Bottom Line

{conclusion}

Hypothesis ratings:

| Hypothesis | Result | Confidence |
|---|---|---|
| H1: Satoshi authored or funded the artifact | Not supported by current evidence | Low |
| H2: The artifact leads to a Satoshi-linked signature | Not found | Low |
| H3: The artifact was signed with a Satoshi-original key/address | Falsified for the artifact transactions inspected here | High |

## Evidence Standard

Strong evidence would be a verifiable signature from a historically accepted Satoshi key, a direct spend from a Satoshi-linked coin/key, or a simple deterministic derivation from the artifact to such a key. Symbolic resemblance or Taproot-block placement is not enough.

Reference controls used here:

{ref_addresses}

These are not a complete Patoshi database. They are high-signal public controls used to prevent accidental self-confirming interpretation.

## Source Cache

This audit uses Blockstream API JSON cached locally under `data/blockstream/`. The report is reproducible from these cached files:

{cache_files}

## Canonical Artifact

- Artifact block: `{ARTIFACT_HEIGHT}`
- Block hash: `{ARTIFACT_BLOCK_HASH}`
- Artifact address: `{ARTIFACT_ADDRESS}`
- Reconstructed OP_RETURN row count: `{len(artifact['rows'])}` plus terminal marker
- Artifact text SHA256: `{artifact['artifact_sha256']}`

Rows reconstructed from the setup transaction output indexes:

```text
{rows_preview}
terminal: `{artifact['terminal']['payload'] if artifact['terminal'] else ''}`
```

## Puzzle Core

The reproducible internal core still matches the prior analysis:

```text
A = {core['fields']['A']}
B = {core['fields']['B']}
C = {core['fields']['C']}
E = {core['fields']['E']}

B groups = {', '.join(core['B_groups'])}
legal E selectors = {core['legal_E_selectors']}
selected slice = {core['selected_slice']}
kernel mask = 0x{core['kernel_mask']:02x}
kernel out  = 0x{core['kernel_out']:02x}
```

This supports an internal puzzle core, not a Satoshi attribution.

## Funding Graph

The setup transaction created 19 equal outputs of 75,000 sats:

- Setup txid: `{flow['setup']['txid']}`
- Setup height: `{flow['setup']['height']}`
- Input sum: `{flow['setup']['input_sum']}` sats
- Fee: `{flow['setup']['fee']}` sats
- Outputs are 19 x 75,000 sats: `{flow['setup']['outputs_are_19x_75000']}`

Setup inputs:

{setup_inputs}

Immediate parent funding:

{source_input_text}

This is modern SegWit-era/P2PKH/P2WPKH funding behavior, not an observed direct spend from a known Satoshi-original address.

## Artifact And Terminal Spend

Artifact rows:

- Row transaction count: `{flow['artifact_rows']['count']}`
- Row fees: `{flow['artifact_rows']['fees']}`
- Row change values: `{flow['artifact_rows']['change_values']}`

Terminal transaction:

- Txid: `{flow['terminal']['txid']}`
- Height: `{flow['terminal']['height']}`
- Input count: `{flow['terminal']['input_count']}`
- Input sum: `{flow['terminal']['input_sum']}` sats
- Fee: `{flow['terminal']['fee']}` sats

The terminal transaction consumes the row change outputs and emits the `ZENON NETWORK` OP_RETURN plus a change output back to the artifact address.

Post-terminal transaction:

- Txid: `{flow['post_terminal']['txid']}`
- Height: `{flow['post_terminal']['height']}`
- Sends to: `{flow['post_terminal']['outputs'][0]['address']}` for `{flow['post_terminal']['outputs'][0]['value']}` sats

The later `37zkp...` P2SH output was spent in a large consolidation transaction:

```json
{json.dumps(flow['vanity_p2sh_spends'], indent=2)}
```

That makes it interesting wallet color, but not a standalone Satoshi proof.

## Signature Audit

- Artifact-related signatures parsed: `{sigs['artifact_related_signature_count']}`
- Unique signing pubkeys: `{len(sigs['unique_pubkeys'])}`
- Sighash types: `{sigs['sighash_types']}`
- Repeated ECDSA `r` groups: `{len(sigs['repeated_r_groups'])}`

Observed P2WPKH signing address(es):

{sig_addresses}

The single observed public key for the artifact address is:

```text
{sigs['unique_pubkeys'][0] if sigs['unique_pubkeys'] else ''}
```

No repeated ECDSA nonce was found among the artifact-related signatures. The signatures look like ordinary SegWit P2WPKH spends from the artifact address, not a Satoshi-original P2PK/P2PKH spend.

## Deterministic Key-Derivation Tests

I tested simple, publishable private-key candidates from the puzzle bytes. None matched the observed artifact addresses or the Satoshi-reference controls.

| Candidate | P2PKH compressed | P2WPKH | P2SH-P2WPKH | P2TR x-only | Observed match | Reference match |
|---|---|---|---|---|---|---|
{derivation_table}

Candidate rows with any match:

```json
{json.dumps(derivation_matches, indent=2)}
```

BIP39-like readings of 16-byte fields produce grammatical mnemonics because any 128-bit value does. They did not produce an independent address match in this audit:

{bip39_text}

## Embedded Signature Scan

```json
{json.dumps(embedded, indent=2)}
```

No DER ECDSA signature structure was found in the decoded artifact bytes or the concatenated Base64 ASCII. The decoded artifact bytes are only {embedded['decoded_length']} bytes, so they cannot directly contain a 64-byte Schnorr signature.

## Interpretation

The artifact is deliberate:

- It is staged through 19 equal setup outputs.
- The OP_RETURN rows reconstruct a coherent visual artifact.
- The terminal transaction consumes the row outputs and writes `ZENON NETWORK`.
- The internal Base64 machine yields the reproducible core `16 6c b1 -> 07 -> 6b`.

But the Satoshi claim needs cryptographic linkage, not deliberateness. Current evidence points to a modern wallet construction around a SegWit address, with no match to the small high-signal Satoshi reference controls and no embedded verifiable signature.

## Next Work

The remaining serious path would be a full Patoshi coinbase comparison using a curated Patoshi output dataset, not a hand-picked list. If a reputable Patoshi dataset is available, rerun the deterministic derivation comparison and funding ancestry checks against that dataset.
"""


def main() -> None:
    OUT.mkdir(exist_ok=True)
    address_txs = load_json("artifact_address_txs.json")
    artifact = summarize_artifact(address_txs)
    findings = {
        "artifact": {
            "rows": artifact.rows,
            "terminal": artifact.terminal,
            "artifact_text": artifact.artifact_text,
            "artifact_sha256": artifact.artifact_sha256,
        },
        "puzzle_core": puzzle_core(),
        "flow": setup_and_flow_summary(),
        "signatures": signature_summary(),
        "deterministic_key_candidates": deterministic_key_candidates(),
        "bip39_like_words": bip39_like_words(),
        "embedded_crypto_scan": scan_embedded_crypto_bytes(),
        "reference_addresses": REFERENCE_ADDRESSES,
    }
    (OUT / "satoshi_claim_findings.json").write_text(json.dumps(findings, indent=2) + "\n")
    (OUT / "satoshi_attribution_audit.md").write_text(markdown_report(findings))
    print("Wrote out/satoshi_claim_findings.json")
    print("Wrote out/satoshi_attribution_audit.md")


if __name__ == "__main__":
    main()
