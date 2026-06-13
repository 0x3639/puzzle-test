# Zenon Taproot Puzzle Analysis

I can get the puzzle to the repo's strongest defensible endpoint, but I would not call it "solved" as a plaintext/key puzzle.

## Reproducible Core

The real extract is:

```text
G3 = 16 6c b1
kernel mask = 07
kernel out  = 6b
```

I verified the repo's machine script locally: `28 passed, 0 failed`.

The path is reproducible:

1. The four Base64 fields decode to A/B/C/E.
2. B is partitioned into `Hdr, G1..G5`.
3. The only E byte that is a valid direct index into B is `E[10] = 0x09`.
4. That points at `B[9:12]`, i.e. `G3 = 16 6c b1`.
5. The published kernel then gives:

```text
(0x16 XOR 0xb1) & 0x07 = 0x07
0x6c XOR 0x07 = 0x6b
```

The bridge checks are:

```text
0x6b XOR 0x14 = 0x7f
0x09 XOR 0x14 = 0x1d
```

## What Is Not Proven

I do not think the puzzle currently proves:

- A final plaintext.
- A private key.
- A protocol-level meaning.
- A unique derivation of the kernel rule.

The repo itself says the artifact is still unsolved and that no private key, plaintext, or protocol meaning has been validated. Its machine spec also lists the kernel origin, selector uniqueness, external endpoint, and C-field role as unresolved.

## Caution On Opcode Interpretation

Part of the "Bitcoin-semantic" argument in the partial solve looks shaky. Bitcoin Core's opcode table has:

```text
0x6c = OP_FROMALTSTACK
0x6e = OP_2DUP
0x57 = OP_7
0x66 = OP_VERNOTIF
0x71 = OP_2ROT
0x7c = OP_SWAP
```

So the claimed opcode reading of `G3` and neighboring triplets is not reliable enough to turn this into a full solve.

## Conclusion

The puzzle's reproducible core is:

```text
16 6c b1 -> 07 -> 6b
```

I do not see a defensible external solution beyond that.

I also checked the obvious escape routes:

- Concatenated Base64 as an 80-byte block-header analogue.
- Simple XORs.
- BIP39-style entropy.
- Natural private-key candidates.
- ECDSA nonce reuse in the artifact signatures.

None produced a confirmed endpoint.
