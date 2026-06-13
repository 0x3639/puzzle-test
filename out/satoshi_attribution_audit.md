# Satoshi Attribution Audit: Zenon Taproot Puzzle

## Bottom Line

No cryptographic or chain-provenance evidence currently supports the Satoshi attribution claim. The artifact is deliberate and technically staged, but the observed signing key is a modern P2WPKH key for the artifact address, deterministic puzzle-derived key candidates do not match the observed or reference Satoshi addresses, and no embedded verifiable signature was found.

Hypothesis ratings:

| Hypothesis | Result | Confidence |
|---|---|---|
| H1: Satoshi authored or funded the artifact | Not supported by current evidence | Low |
| H2: The artifact leads to a Satoshi-linked signature | Not found | Low |
| H3: The artifact was signed with a Satoshi-original key/address | Falsified for the artifact transactions inspected here | High |

## Evidence Standard

Strong evidence would be a verifiable signature from a historically accepted Satoshi key, a direct spend from a Satoshi-linked coin/key, or a simple deterministic derivation from the artifact to such a key. Symbolic resemblance or Taproot-block placement is not enough.

Reference controls used here:

- `genesis-p2pk-derived`: `1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa`
- `block-9-satoshi-to-hal-source`: `12cbQLTFMXRnSzktFkuoG3eHoMeFtpTu3S`

These are not a complete Patoshi database. They are high-signal public controls used to prevent accidental self-confirming interpretation.

## Source Cache

This audit uses Blockstream API JSON cached locally under `data/blockstream/`. The report is reproducible from these cached files:

- `data/blockstream/address_37zkp_txs.json`
- `data/blockstream/artifact_address_txs.json`
- `data/blockstream/tx_post_terminal_to_37zkp.json`
- `data/blockstream/tx_setup_fanout.json`
- `data/blockstream/tx_source_61a990.json`
- `data/blockstream/tx_source_61a990_parent.json`
- `data/blockstream/tx_source_eac1.json`
- `data/blockstream/tx_source_eac1_parent.json`
- `data/blockstream/tx_terminal.json`

## Canonical Artifact

- Artifact block: `709632`
- Block hash: `0000000000000000000687bca986194dc2c1f949318629b44bb54ec0a94d8244`
- Artifact address: `bc1qrnldpdlq9dsfy946m4vqa5mrec8qhdrx363end`
- Reconstructed OP_RETURN row count: `19` plus terminal marker
- Artifact text SHA256: `10fba0e9bcfaed5f16e06b891acfc7fb44ace54d5c2a4da0efe8bdb9c7643421`

Rows reconstructed from the setup transaction output indexes:

```text
00: `      ;BynQtpeUyWTXKGTrGhdV2Q==;`
01: `      ;tVMd3L1CKM4wFmyxEEEUV2bY;`
02: `      ;4Fdzw1k=zzzzzzzzzzzzzzzz;`
03: `                  .:1zzzzzzzzz.`
04: `                .:qqzzzzqqq,`
05: `             ,;1zzzzzqqq,`
06: `          ,;1zzzzzqqq,`
07: `       ,;qzzzzz1qq,`
08: `      ,vtv3f5aKY0jGQglP9a1AGw==.`
09: `      ,zzzzzzzzzzzzzzzzzzzzzzzz,`
10: `      ,zzzzzzzzzzzzzzzzzzzzzzzz,`
11: `      ,zzzzzq;.           1zzzz,`
12: `      ,zzzzzzzzq,         1zzzz,`
13: `      ,zzzzzzzzzz1:       1zzzz,`
14: `      ,zzzzq:1zzzzzq;.    1zzzz,`
15: `      ,zzzzq  ,qzzzzzz1,  1zzzz,`
16: `      ,zzzzq    .;qzzzzzq:1zzzz,`
17: `      ,zzzzq       ,qzzzzzzzzzz,`
18: `      ,zzzzq         .;qzzzzzzz,`
terminal: `ZENON NETWORK`
```

## Puzzle Core

The reproducible internal core still matches the prior analysis:

```text
A = 0729d0b69794c964d72864eb1a1755d9
B = b5531ddcbd4228ce30166cb11041145766d8
C = e05773c359
E = bedbf77f968a6348c642094ff5ad401b

B groups = dcbd42, 28ce30, 166cb1, 104114, 5766d8
legal E selectors = [{'index': 10, 'value': 9}]
selected slice = {'start': 9, 'hex': '166cb1'}
kernel mask = 0x07
kernel out  = 0x6b
```

This supports an internal puzzle core, not a Satoshi attribution.

## Funding Graph

The setup transaction created 19 equal outputs of 75,000 sats:

- Setup txid: `dd3bbc563197a6cddc78ad4a432dc92ba9c207809fc10db7d2716937d27c5d4d`
- Setup height: `709594`
- Input sum: `1450000` sats
- Fee: `25000` sats
- Outputs are 19 x 75,000 sats: `True`

Setup inputs:

- `500000` sats from `bc1qrnldpdlq9dsfy946m4vqa5mrec8qhdrx363end` (v0_p2wpkh) via `61a9906aec4b0e4dba47ad3ba0666d3132d69a0f847b5d804ff48f9737d2ee02:0`
- `950000` sats from `bc1qrnldpdlq9dsfy946m4vqa5mrec8qhdrx363end` (v0_p2wpkh) via `eac1d93cd6f3391a018d72854ef15c8b2d9f58c89052f83bdecd17757001ae84:32`

Immediate parent funding:

- `61a9906aec4b0e4dba47ad3ba0666d3132d69a0f847b5d804ff48f9737d2ee02` is funded by `1120000` sats from `bc1qjnjuqtngn7zpdam62g8gx0hse350x92sfchn6f` (v0_p2wpkh)
- `eac1d93cd6f3391a018d72854ef15c8b2d9f58c89052f83bdecd17757001ae84` is funded by `215701289` sats from `1NDyJtNTjmwk5xPNhjgAMu4HDHigtobu1s` (p2pkh)

This is modern SegWit-era/P2PKH/P2WPKH funding behavior, not an observed direct spend from a known Satoshi-original address.

## Artifact And Terminal Spend

Artifact rows:

- Row transaction count: `19`
- Row fees: `[5760]`
- Row change values: `[69240]`

Terminal transaction:

- Txid: `911dcb7435932f64215f8de4058186aef9bfd4356978c95830e77a38b9484083`
- Height: `709632`
- Input count: `19`
- Input sum: `1315560` sats
- Fee: `1008000` sats

The terminal transaction consumes the row change outputs and emits the `ZENON NETWORK` OP_RETURN plus a change output back to the artifact address.

Post-terminal transaction:

- Txid: `cd7b40e5c7c62563a38a571e51f5e65d351be5369a8378a95715cb69aa8b69d1`
- Height: `720498`
- Sends to: `37zkpKaqDQpqkANMbFw5UaPpiAeceg5fdw` for `316250` sats

The later `37zkp...` P2SH output was spent in a large consolidation transaction:

```json
[
  {
    "spending_txid": "39a0ee08ef332c6e9a7d3b139d489f16c2c8c1d0f516adc14ce717790a056316",
    "height": 720633,
    "vin": 684,
    "value": 316250,
    "input_count": 843,
    "fee": 76858
  }
]
```

That makes it interesting wallet color, but not a standalone Satoshi proof.

## Signature Audit

- Artifact-related signatures parsed: `42`
- Unique signing pubkeys: `1`
- Sighash types: `[1]`
- Repeated ECDSA `r` groups: `0`

Observed P2WPKH signing address(es):

- `bc1qrnldpdlq9dsfy946m4vqa5mrec8qhdrx363end`

The single observed public key for the artifact address is:

```text
0398cf668fe678cc6d8e2b20b5f574c9f398c7f031a1e91e9b85029e4cde597ad7
```

No repeated ECDSA nonce was found among the artifact-related signatures. The signatures look like ordinary SegWit P2WPKH spends from the artifact address, not a Satoshi-original P2PK/P2PKH spend.

## Deterministic Key-Derivation Tests

I tested simple, publishable private-key candidates from the puzzle bytes. None matched the observed artifact addresses or the Satoshi-reference controls.

| Candidate | P2PKH compressed | P2WPKH | P2SH-P2WPKH | P2TR x-only | Observed match | Reference match |
|---|---|---|---|---|---|---|
| sha256(decoded_A_B_C_E) | 14R6aDYKjwz8DweRHp9t7CpmaMRKSDftKo | bc1qy4msxfgsc6hl25a4pvuv579wpmh03xe2eyc5a6 | 3EMUdu2m4S7WxxFzDN3koYm8ZizaggkSex | bc1pk2adqsc7peqt22f2359209fcw40p09h052w86v8fznup23jzs9mqk9v6e4 |  |  |
| double_sha256(decoded_A_B_C_E) | 14E6aN5ZdNXHWnd4rfMhoHUroRK8mcTX2f | bc1qyd38q44m67fcclf2nfvmer9nugd2zgkmgjfahw | 32uMUiyqfGfDsTFNfME2jrAuBK1WEFiJzh | bc1p78kz0tnqgzp8nwxrx7u22gmcjzwa0cyucx4lutdrac5xzqjuttkqcxh50p |  |  |
| sha256(concat_base64_ascii) | 1HcEPgLGWVSyP83twzJF9Sc3XNYhtu8NXH | bc1qkc4mlklrx6hzn7e0c2z8sjjzpt22q032fx2k2t | 33LFMZ4MqxeGZFfXLgjaan1iSu9e1q3E5t | bc1pj6zkcvmt7pe63jdznrlytd9u4x8yrcarx05kcjm86u8zs9hjg4aqx8cfm0 |  |  |
| double_sha256(concat_base64_ascii) | 14fR52S3SKieX6z4KxBjrwg2zta1Hve3po | bc1q9qkyd28wcdpwr2wsznlthl7yv3d2neha996660 | 3KjBaNRZdJFDL7yi5rTYJodGstTupy2dP4 | bc1p5mc3kycty67lkskjnf4yl228pqr3ndr4qxtx7qklk4c69lju5uzqhxckrf |  |  |
| A_plus_E | 1FPtnBfryrtpv8dwqdcAGmawGBQqjUHyiA | bc1qnhnz99t4t3l2juw6mam7x4nmfqn8wrufnujvk8 | 36YVmRGV5Y4Nmi1tsBt82cuHYbt2CbTREL | bc1ps4egkc8el78clqaxdhlya7l5amw0l8fs4xeplzuyvhhwnqnuqqcq4z9ssn |  |  |
| E_plus_A | 1AGeWw9YpBA2NNxr7zVE2Vni5GjBKEWhDG | bc1qvkhtqdcelhpkx6daadvc8q9emvm9xav2gj9rrr | 39dA8nGt8idEuJ7yvor8rz2FrWHr5k17ok | bc1pl6mzqj9w6ftnxahrp84g72z4nmgltvmh8wpkksuuy2qfwq9gcuys9cq9kd |  |  |
| A_xor_E_repeated | 1B4zjiBfRnw76ZspKNZ3mkcQcL1ykwbKRX | bc1qdeet88wfahqad0726c0hf88ujec2cyq2h70kz7 | 3B3CmTGe7h34pPk49aW7AocJTJDhjgnE2J | bc1psahk9cxu9nslq83wgqz6pcckwdchxhrxuqczpj7lsmaz2fj39v5s6897w9 |  |  |
| sha256(G3) | 1FkmdtH8hUsW2U6DwkoiV1zNJxCbBt6X7a | bc1q58vws5l94g36u4fa34gfwat8amqn0l74wsc7ym | 3CVLVo8w6hWZoFMALcunENubNTv1zoc7sj | bc1ppny42c48l38ptw0w2pfwh46slcvqmj5d59k6sfpse7l3j3s6cnhqzflfws |  |  |
| G3_zero_padded | 18dsFzwnf4Jsbg194sF1DjkPFemubDnUbF | bc1q20qu7yk324qc8v5l4m04fjxwamyy6wwkv3nfsz | 368ReLtR7GH5jBbuUefNvrUWsujtLFMp5R | bc1p0stzstgc7qw6vhdgx2qj09drve4xhgccx4nfkuwnkswxg7ctgg6qr908ay |  |  |
| G3_mask_out_zero_padded | 1GjF9NAD1TBJ7F1DqJN1G6MKaDPZaLNkdk | bc1q4jrj5p0fmut7m7a7al0g7jqc7c4g72h32zk5r6 | 3CMUkMinKSyo14BkQSeBo8Kzs4vtcE8qL5 | bc1p8alkh7u670yfr9mvrmsedcl6wzdl3lzz8lfv2n8z93jr0cw6fqmswusd2d |  |  |
| kernel_mask_out_zero_padded | 1D7BZFnXqrZZSR5iwThLRs3AvL1czP8jg | bc1qqf9zd65504l4g9gea4nk3zelw6qk7zhrxllcxw | 39fVx8jX297tBpGFxhbhPBKh9pd9igZ7yb | bc1p6dk2hups5uc05m5j0gwpu825avas9mqan0y7hegngqhyk8y9d57qp7n4nx |  |  |

Candidate rows with any match:

```json
[]
```

BIP39-like readings of 16-byte fields produce grammatical mnemonics because any 128-bit value does. They did not produce an independent address match in this audit:

- `A_as_entropy`: already excess color connect erode raven frequent arrive twelve spawn step rate
- `E_as_entropy`: salute text that code plate piece boil donkey exit pulp exotic current
- `A_xor_E_as_entropy`: rigid muffin venture acquire turkey bid east ethics pilot lava lyrics love

## Embedded Signature Scan

```json
{
  "decoded_length": 55,
  "base64_ascii_length": 80,
  "der_signature_offsets_decoded": [],
  "der_signature_offsets_base64_ascii": [],
  "pubkey_offsets_decoded": {
    "compressed_prefix_33_byte_windows": [],
    "uncompressed_prefix_65_byte_windows": []
  },
  "pubkey_offsets_base64_ascii": {
    "compressed_prefix_33_byte_windows": [],
    "uncompressed_prefix_65_byte_windows": []
  },
  "has_room_for_schnorr_signature_decoded": false,
  "has_room_for_schnorr_signature_base64_ascii": true
}
```

No DER ECDSA signature structure was found in the decoded artifact bytes or the concatenated Base64 ASCII. The decoded artifact bytes are only 55 bytes, so they cannot directly contain a 64-byte Schnorr signature.

## Interpretation

The artifact is deliberate:

- It is staged through 19 equal setup outputs.
- The OP_RETURN rows reconstruct a coherent visual artifact.
- The terminal transaction consumes the row outputs and writes `ZENON NETWORK`.
- The internal Base64 machine yields the reproducible core `16 6c b1 -> 07 -> 6b`.

But the Satoshi claim needs cryptographic linkage, not deliberateness. Current evidence points to a modern wallet construction around a SegWit address, with no match to the small high-signal Satoshi reference controls and no embedded verifiable signature.

## Next Work

The remaining serious path would be a full Patoshi coinbase comparison using a curated Patoshi output dataset, not a hand-picked list. If a reputable Patoshi dataset is available, rerun the deterministic derivation comparison and funding ancestry checks against that dataset.
