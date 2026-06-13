# AES-GCM Seed-Word Probe

## Scope

This search keeps the crypto shape constrained to `B + A = 34 bytes`: 18 bytes of ciphertext plus a 16-byte AES-GCM authentication tag.

It varies only clue-derived password, nonce, KDF, and AAD choices. It does not brute-force the four missing seed words.

## Shape

```json
{
  "B_len": 18,
  "A_len": 16,
  "B_plus_A_len": 34,
  "ciphertext_len_if_16_byte_tag": 18,
  "tag_len": 16
}
```

## Parameters

```json
{
  "cipher_splits": 4,
  "nonce_candidates": 168,
  "passwords": 24,
  "keys": 120,
  "aad_candidates": 5,
  "include_argon2": true
}
```

Total authenticated-decrypt attempts: `403200`

## Result

No authenticated AES-GCM decrypt succeeded in this bounded search.

## Four-Word Plaintext Hits

```json
[]
```

## Notes

- The Zenon SDK keyfile format uses AES-256-GCM with AAD `zenon` and an Argon2id-derived key.
- The forum post's `cipherData`, `salt`, `nonce`, and `password` terminology matches Zenon keyfile vocabulary, so Argon2id and AAD `zenon` are included.
- A miss here does not disprove AES-GCM generally; it only rules out this bounded set of clue-derived parameters.
