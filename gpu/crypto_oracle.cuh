#pragma once

#include <cstdint>

#include "gpu_workload.h"

namespace zenon_crypto {
namespace zw = zenon_gpu_workload;

using u128 = unsigned __int128;

__device__ __forceinline__ uint64_t rotr64(uint64_t value, int bits) {
    return (value >> bits) | (value << (64 - bits));
}

__device__ __forceinline__ uint64_t load64_be(const uint8_t* data) {
    uint64_t value = 0;
    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        value = (value << 8) | uint64_t(data[i]);
    }
    return value;
}

__device__ __forceinline__ void store64_be(uint8_t* out, uint64_t value) {
    #pragma unroll
    for (int i = 7; i >= 0; --i) {
        out[i] = uint8_t(value);
        value >>= 8;
    }
}

__device__ __constant__ uint64_t kSha512K[80] = {
    0x428a2f98d728ae22ULL, 0x7137449123ef65cdULL, 0xb5c0fbcfec4d3b2fULL, 0xe9b5dba58189dbbcULL,
    0x3956c25bf348b538ULL, 0x59f111f1b605d019ULL, 0x923f82a4af194f9bULL, 0xab1c5ed5da6d8118ULL,
    0xd807aa98a3030242ULL, 0x12835b0145706fbeULL, 0x243185be4ee4b28cULL, 0x550c7dc3d5ffb4e2ULL,
    0x72be5d74f27b896fULL, 0x80deb1fe3b1696b1ULL, 0x9bdc06a725c71235ULL, 0xc19bf174cf692694ULL,
    0xe49b69c19ef14ad2ULL, 0xefbe4786384f25e3ULL, 0x0fc19dc68b8cd5b5ULL, 0x240ca1cc77ac9c65ULL,
    0x2de92c6f592b0275ULL, 0x4a7484aa6ea6e483ULL, 0x5cb0a9dcbd41fbd4ULL, 0x76f988da831153b5ULL,
    0x983e5152ee66dfabULL, 0xa831c66d2db43210ULL, 0xb00327c898fb213fULL, 0xbf597fc7beef0ee4ULL,
    0xc6e00bf33da88fc2ULL, 0xd5a79147930aa725ULL, 0x06ca6351e003826fULL, 0x142929670a0e6e70ULL,
    0x27b70a8546d22ffcULL, 0x2e1b21385c26c926ULL, 0x4d2c6dfc5ac42aedULL, 0x53380d139d95b3dfULL,
    0x650a73548baf63deULL, 0x766a0abb3c77b2a8ULL, 0x81c2c92e47edaee6ULL, 0x92722c851482353bULL,
    0xa2bfe8a14cf10364ULL, 0xa81a664bbc423001ULL, 0xc24b8b70d0f89791ULL, 0xc76c51a30654be30ULL,
    0xd192e819d6ef5218ULL, 0xd69906245565a910ULL, 0xf40e35855771202aULL, 0x106aa07032bbd1b8ULL,
    0x19a4c116b8d2d0c8ULL, 0x1e376c085141ab53ULL, 0x2748774cdf8eeb99ULL, 0x34b0bcb5e19b48a8ULL,
    0x391c0cb3c5c95a63ULL, 0x4ed8aa4ae3418acbULL, 0x5b9cca4f7763e373ULL, 0x682e6ff3d6b2b8a3ULL,
    0x748f82ee5defb2fcULL, 0x78a5636f43172f60ULL, 0x84c87814a1f0ab72ULL, 0x8cc702081a6439ecULL,
    0x90befffa23631e28ULL, 0xa4506cebde82bde9ULL, 0xbef9a3f7b2c67915ULL, 0xc67178f2e372532bULL,
    0xca273eceea26619cULL, 0xd186b8c721c0c207ULL, 0xeada7dd6cde0eb1eULL, 0xf57d4f7fee6ed178ULL,
    0x06f067aa72176fbaULL, 0x0a637dc5a2c898a6ULL, 0x113f9804bef90daeULL, 0x1b710b35131c471bULL,
    0x28db77f523047d84ULL, 0x32caab7b40c72493ULL, 0x3c9ebe0a15c9bebcULL, 0x431d67c49c100d4cULL,
    0x4cc5d4becb3e42b6ULL, 0x597f299cfc657e2aULL, 0x5fcb6fab3ad6faecULL, 0x6c44198c4a475817ULL,
};

__device__ void sha512_compress(uint64_t state[8], const uint8_t block[128]) {
    uint64_t w[80];
    #pragma unroll
    for (int i = 0; i < 16; ++i) {
        w[i] = load64_be(block + i * 8);
    }
    for (int i = 16; i < 80; ++i) {
        const uint64_t s0 = rotr64(w[i - 15], 1) ^ rotr64(w[i - 15], 8) ^ (w[i - 15] >> 7);
        const uint64_t s1 = rotr64(w[i - 2], 19) ^ rotr64(w[i - 2], 61) ^ (w[i - 2] >> 6);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    uint64_t a = state[0];
    uint64_t b = state[1];
    uint64_t c = state[2];
    uint64_t d = state[3];
    uint64_t e = state[4];
    uint64_t f = state[5];
    uint64_t g = state[6];
    uint64_t h = state[7];

    for (int i = 0; i < 80; ++i) {
        const uint64_t s1 = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41);
        const uint64_t ch = (e & f) ^ ((~e) & g);
        const uint64_t t1 = h + s1 + ch + kSha512K[i] + w[i];
        const uint64_t s0 = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39);
        const uint64_t maj = (a & b) ^ (a & c) ^ (b & c);
        const uint64_t t2 = s0 + maj;
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }

    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
}

__device__ void sha512_bytes(const uint8_t* data, int len, uint8_t out[64]) {
    uint64_t state[8] = {
        0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL,
        0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
        0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL,
        0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL,
    };

    int offset = 0;
    while (len - offset >= 128) {
        sha512_compress(state, data + offset);
        offset += 128;
    }

    uint8_t block[128];
    #pragma unroll
    for (int i = 0; i < 128; ++i) {
        block[i] = 0;
    }
    const int remaining = len - offset;
    for (int i = 0; i < remaining; ++i) {
        block[i] = data[offset + i];
    }
    block[remaining] = 0x80;

    if (remaining > 111) {
        sha512_compress(state, block);
        #pragma unroll
        for (int i = 0; i < 128; ++i) {
            block[i] = 0;
        }
    }

    const uint64_t bit_len = uint64_t(len) * 8ULL;
    store64_be(block + 120, bit_len);
    sha512_compress(state, block);

    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        store64_be(out + i * 8, state[i]);
    }
}

__device__ void hmac_sha512_pads(const uint8_t* key, int key_len, uint8_t ipad[128], uint8_t opad[128]) {
    #pragma unroll
    for (int i = 0; i < 128; ++i) {
        ipad[i] = 0x36;
        opad[i] = 0x5c;
    }
    for (int i = 0; i < key_len; ++i) {
        ipad[i] ^= key[i];
        opad[i] ^= key[i];
    }
}

__device__ void hmac_sha512_precomputed(
    const uint8_t ipad[128],
    const uint8_t opad[128],
    const uint8_t* msg,
    int msg_len,
    uint8_t out[64]
) {
    uint8_t buffer[256];
    uint8_t inner[64];
    #pragma unroll
    for (int i = 0; i < 128; ++i) {
        buffer[i] = ipad[i];
    }
    for (int i = 0; i < msg_len; ++i) {
        buffer[128 + i] = msg[i];
    }
    sha512_bytes(buffer, 128 + msg_len, inner);

    #pragma unroll
    for (int i = 0; i < 128; ++i) {
        buffer[i] = opad[i];
    }
    #pragma unroll
    for (int i = 0; i < 64; ++i) {
        buffer[128 + i] = inner[i];
    }
    sha512_bytes(buffer, 192, out);
}

__device__ void hmac_sha512(const uint8_t* key, int key_len, const uint8_t* msg, int msg_len, uint8_t out[64]) {
    uint8_t ipad[128];
    uint8_t opad[128];
    hmac_sha512_pads(key, key_len, ipad, opad);
    hmac_sha512_precomputed(ipad, opad, msg, msg_len, out);
}

__device__ void pbkdf2_hmac_sha512_mnemonic(const uint8_t mnemonic[71], uint8_t seed[64]) {
    uint8_t ipad[128];
    uint8_t opad[128];
    hmac_sha512_pads(mnemonic, 71, ipad, opad);

    uint8_t msg[12] = {'m', 'n', 'e', 'm', 'o', 'n', 'i', 'c', 0, 0, 0, 1};
    uint8_t u[64];
    hmac_sha512_precomputed(ipad, opad, msg, 12, u);
    #pragma unroll
    for (int i = 0; i < 64; ++i) {
        seed[i] = u[i];
    }

    for (int round = 2; round <= 2048; ++round) {
        hmac_sha512_precomputed(ipad, opad, u, 64, u);
        #pragma unroll
        for (int i = 0; i < 64; ++i) {
            seed[i] ^= u[i];
        }
    }
}

__device__ void slip10_master(const uint8_t seed[64], uint8_t key[32], uint8_t chain_code[32]) {
    const uint8_t master_key[12] = {'e', 'd', '2', '5', '5', '1', '9', ' ', 's', 'e', 'e', 'd'};
    uint8_t digest[64];
    hmac_sha512(master_key, 12, seed, 64, digest);
    #pragma unroll
    for (int i = 0; i < 32; ++i) {
        key[i] = digest[i];
        chain_code[i] = digest[32 + i];
    }
}

__device__ void slip10_ckd_priv(uint8_t key[32], uint8_t chain_code[32], uint32_t index) {
    uint8_t msg[37];
    msg[0] = 0;
    #pragma unroll
    for (int i = 0; i < 32; ++i) {
        msg[1 + i] = key[i];
    }
    const uint32_t hardened = index + 0x80000000u;
    msg[33] = uint8_t(hardened >> 24);
    msg[34] = uint8_t(hardened >> 16);
    msg[35] = uint8_t(hardened >> 8);
    msg[36] = uint8_t(hardened);

    uint8_t digest[64];
    hmac_sha512(chain_code, 32, msg, 37, digest);
    #pragma unroll
    for (int i = 0; i < 32; ++i) {
        key[i] = digest[i];
        chain_code[i] = digest[32 + i];
    }
}

struct Fe {
    uint64_t v[5];
};

static constexpr uint64_t FE_MASK = (1ULL << 51) - 1ULL;

__device__ __forceinline__ void fe_copy(Fe& out, const Fe& in) {
    #pragma unroll
    for (int i = 0; i < 5; ++i) {
        out.v[i] = in.v[i];
    }
}

__device__ __forceinline__ Fe fe_const(uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    Fe out{{a0, a1, a2, a3, a4}};
    return out;
}

__device__ __forceinline__ Fe fe_zero() {
    return fe_const(0, 0, 0, 0, 0);
}

__device__ __forceinline__ Fe fe_one() {
    return fe_const(1, 0, 0, 0, 0);
}

__device__ void fe_reduce(Fe& x) {
    uint64_t c;
    c = x.v[0] >> 51; x.v[0] &= FE_MASK; x.v[1] += c;
    c = x.v[1] >> 51; x.v[1] &= FE_MASK; x.v[2] += c;
    c = x.v[2] >> 51; x.v[2] &= FE_MASK; x.v[3] += c;
    c = x.v[3] >> 51; x.v[3] &= FE_MASK; x.v[4] += c;
    c = x.v[4] >> 51; x.v[4] &= FE_MASK; x.v[0] += c * 19ULL;
    c = x.v[0] >> 51; x.v[0] &= FE_MASK; x.v[1] += c;
}

__device__ Fe fe_add(const Fe& a, const Fe& b) {
    Fe out;
    #pragma unroll
    for (int i = 0; i < 5; ++i) {
        out.v[i] = a.v[i] + b.v[i];
    }
    fe_reduce(out);
    return out;
}

__device__ Fe fe_sub(const Fe& a, const Fe& b) {
    const uint64_t two_p[5] = {
        4503599627370458ULL, 4503599627370494ULL, 4503599627370494ULL,
        4503599627370494ULL, 4503599627370494ULL,
    };
    Fe out;
    #pragma unroll
    for (int i = 0; i < 5; ++i) {
        out.v[i] = a.v[i] + two_p[i] - b.v[i];
    }
    fe_reduce(out);
    return out;
}

__device__ Fe fe_neg(const Fe& a) {
    return fe_sub(fe_zero(), a);
}

__device__ Fe fe_mul(const Fe& a, const Fe& b) {
    const u128 a0 = a.v[0], a1 = a.v[1], a2 = a.v[2], a3 = a.v[3], a4 = a.v[4];
    const u128 b0 = b.v[0], b1 = b.v[1], b2 = b.v[2], b3 = b.v[3], b4 = b.v[4];

    u128 c0 = a0*b0 + 19ULL*(a1*b4 + a2*b3 + a3*b2 + a4*b1);
    u128 c1 = a0*b1 + a1*b0 + 19ULL*(a2*b4 + a3*b3 + a4*b2);
    u128 c2 = a0*b2 + a1*b1 + a2*b0 + 19ULL*(a3*b4 + a4*b3);
    u128 c3 = a0*b3 + a1*b2 + a2*b1 + a3*b0 + 19ULL*(a4*b4);
    u128 c4 = a0*b4 + a1*b3 + a2*b2 + a3*b1 + a4*b0;

    Fe out;
    out.v[0] = uint64_t(c0) & FE_MASK; c1 += c0 >> 51;
    out.v[1] = uint64_t(c1) & FE_MASK; c2 += c1 >> 51;
    out.v[2] = uint64_t(c2) & FE_MASK; c3 += c2 >> 51;
    out.v[3] = uint64_t(c3) & FE_MASK; c4 += c3 >> 51;
    out.v[4] = uint64_t(c4) & FE_MASK; c0 = (c4 >> 51) * 19ULL + out.v[0];
    out.v[0] = uint64_t(c0) & FE_MASK; out.v[1] += uint64_t(c0 >> 51);
    fe_reduce(out);
    return out;
}

__device__ __forceinline__ Fe fe_sq(const Fe& a) {
    return fe_mul(a, a);
}

__device__ Fe fe_invert(const Fe& z) {
    Fe result = fe_one();
    Fe base;
    fe_copy(base, z);
    for (int bit = 254; bit >= 0; --bit) {
        result = fe_sq(result);
        const bool set = (bit >= 5) || bit == 0 || bit == 1 || bit == 3;
        if (set) {
            result = fe_mul(result, base);
        }
    }
    return result;
}

__device__ bool fe_ge_p(const Fe& x) {
    const uint64_t p[5] = {
        2251799813685229ULL, 2251799813685247ULL, 2251799813685247ULL,
        2251799813685247ULL, 2251799813685247ULL,
    };
    for (int i = 4; i >= 0; --i) {
        if (x.v[i] > p[i]) return true;
        if (x.v[i] < p[i]) return false;
    }
    return true;
}

__device__ Fe fe_sub_p(const Fe& x) {
    const uint64_t p[5] = {
        2251799813685229ULL, 2251799813685247ULL, 2251799813685247ULL,
        2251799813685247ULL, 2251799813685247ULL,
    };
    Fe out;
    uint64_t borrow = 0;
    #pragma unroll
    for (int i = 0; i < 5; ++i) {
        const uint64_t sub = p[i] + borrow;
        if (x.v[i] >= sub) {
            out.v[i] = x.v[i] - sub;
            borrow = 0;
        } else {
            out.v[i] = (1ULL << 51) + x.v[i] - sub;
            borrow = 1;
        }
    }
    return out;
}

__device__ void fe_to_bytes(const Fe& in, uint8_t out[32]) {
    Fe x;
    fe_copy(x, in);
    fe_reduce(x);
    fe_reduce(x);
    if (fe_ge_p(x)) {
        x = fe_sub_p(x);
    }

    #pragma unroll
    for (int i = 0; i < 32; ++i) {
        out[i] = 0;
    }
    for (int bit = 0; bit < 255; ++bit) {
        if ((x.v[bit / 51] >> (bit % 51)) & 1ULL) {
            out[bit >> 3] |= uint8_t(1u << (bit & 7));
        }
    }
}

struct Ge {
    Fe X;
    Fe Y;
    Fe Z;
    Fe T;
};

__device__ Ge ge_identity() {
    Ge p;
    p.X = fe_zero();
    p.Y = fe_one();
    p.Z = fe_one();
    p.T = fe_zero();
    return p;
}

__device__ Ge ge_basepoint() {
    Ge p;
    p.X = fe_const(1738742601995546ULL, 1146398526822698ULL, 2070867633025821ULL, 562264141797630ULL, 587772402128613ULL);
    p.Y = fe_const(1801439850948184ULL, 1351079888211148ULL, 450359962737049ULL, 900719925474099ULL, 1801439850948198ULL);
    p.Z = fe_one();
    p.T = fe_const(1841354044333475ULL, 16398895984059ULL, 755974180946558ULL, 900171276175154ULL, 1821297809914039ULL);
    return p;
}

__device__ Ge ge_double(const Ge& p) {
    const Fe A = fe_sq(p.X);
    const Fe B = fe_sq(p.Y);
    const Fe C = fe_add(fe_sq(p.Z), fe_sq(p.Z));
    const Fe D = fe_neg(A);
    const Fe E = fe_sub(fe_sub(fe_sq(fe_add(p.X, p.Y)), A), B);
    const Fe G = fe_add(D, B);
    const Fe F = fe_sub(G, C);
    const Fe H = fe_sub(D, B);
    Ge r;
    r.X = fe_mul(E, F);
    r.Y = fe_mul(G, H);
    r.T = fe_mul(E, H);
    r.Z = fe_mul(F, G);
    return r;
}

__device__ Ge ge_add(const Ge& p, const Ge& q) {
    const Fe d2 = fe_const(1859910466990425ULL, 932731440258426ULL, 1072319116312658ULL, 1815898335770999ULL, 633789495995903ULL);
    const Fe A = fe_mul(fe_sub(p.Y, p.X), fe_sub(q.Y, q.X));
    const Fe B = fe_mul(fe_add(p.Y, p.X), fe_add(q.Y, q.X));
    const Fe C = fe_mul(fe_mul(p.T, q.T), d2);
    const Fe D = fe_add(fe_mul(p.Z, q.Z), fe_mul(p.Z, q.Z));
    const Fe E = fe_sub(B, A);
    const Fe F = fe_sub(D, C);
    const Fe G = fe_add(D, C);
    const Fe H = fe_add(B, A);
    Ge r;
    r.X = fe_mul(E, F);
    r.Y = fe_mul(G, H);
    r.T = fe_mul(E, H);
    r.Z = fe_mul(F, G);
    return r;
}

__device__ void ed25519_public_from_seed(const uint8_t seed[32], uint8_t public_key[32]) {
    uint8_t digest[64];
    sha512_bytes(seed, 32, digest);
    digest[0] &= 248;
    digest[31] &= 63;
    digest[31] |= 64;

    Ge q = ge_identity();
    const Ge b = ge_basepoint();
    for (int bit = 254; bit >= 0; --bit) {
        q = ge_double(q);
        if ((digest[bit >> 3] >> (bit & 7)) & 1u) {
            q = ge_add(q, b);
        }
    }

    const Fe zinv = fe_invert(q.Z);
    const Fe x = fe_mul(q.X, zinv);
    const Fe y = fe_mul(q.Y, zinv);
    fe_to_bytes(y, public_key);
    if (x.v[0] & 1ULL) {
        public_key[31] |= 0x80;
    }
}

__device__ __constant__ uint64_t kKeccakRoundConstants[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL, 0x8000000080008000ULL,
    0x000000000000808bULL, 0x0000000080000001ULL, 0x8000000080008081ULL, 0x8000000000008009ULL,
    0x000000000000008aULL, 0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL, 0x8000000000008003ULL,
    0x8000000000008002ULL, 0x8000000000000080ULL, 0x000000000000800aULL, 0x800000008000000aULL,
    0x8000000080008081ULL, 0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL,
};

__device__ __constant__ int kKeccakRot[24] = {
    1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14,
    27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44,
};

__device__ __constant__ int kKeccakPiln[24] = {
    10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4,
    15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1,
};

__device__ __forceinline__ uint64_t rotl64(uint64_t value, int bits) {
    return (value << bits) | (value >> (64 - bits));
}

__device__ void keccakf(uint64_t st[25]) {
    for (int round = 0; round < 24; ++round) {
        uint64_t bc[5];
        #pragma unroll
        for (int i = 0; i < 5; ++i) {
            bc[i] = st[i] ^ st[i + 5] ^ st[i + 10] ^ st[i + 15] ^ st[i + 20];
        }
        #pragma unroll
        for (int i = 0; i < 5; ++i) {
            const uint64_t t = bc[(i + 4) % 5] ^ rotl64(bc[(i + 1) % 5], 1);
            for (int j = 0; j < 25; j += 5) {
                st[j + i] ^= t;
            }
        }

        uint64_t t = st[1];
        #pragma unroll
        for (int i = 0; i < 24; ++i) {
            const int j = kKeccakPiln[i];
            const uint64_t tmp = st[j];
            st[j] = rotl64(t, kKeccakRot[i]);
            t = tmp;
        }

        for (int j = 0; j < 25; j += 5) {
            #pragma unroll
            for (int i = 0; i < 5; ++i) {
                bc[i] = st[j + i];
            }
            #pragma unroll
            for (int i = 0; i < 5; ++i) {
                st[j + i] ^= (~bc[(i + 1) % 5]) & bc[(i + 2) % 5];
            }
        }
        st[0] ^= kKeccakRoundConstants[round];
    }
}

__device__ void sha3_256_32bytes(const uint8_t input[32], uint8_t out[32]) {
    uint64_t st[25];
    #pragma unroll
    for (int i = 0; i < 25; ++i) {
        st[i] = 0;
    }
    #pragma unroll
    for (int i = 0; i < 32; ++i) {
        st[i >> 3] ^= uint64_t(input[i]) << (8 * (i & 7));
    }
    st[32 >> 3] ^= uint64_t(0x06) << (8 * (32 & 7));
    st[135 >> 3] ^= uint64_t(0x80) << (8 * (135 & 7));
    keccakf(st);
    #pragma unroll
    for (int i = 0; i < 32; ++i) {
        out[i] = uint8_t(st[i >> 3] >> (8 * (i & 7)));
    }
}

__device__ int append_word(uint16_t index, uint8_t* out, int pos) {
    const int start = zw::kWordOffsets[index];
    const int stop = zw::kWordOffsets[index + 1];
    for (int i = start; i < stop; ++i) {
        out[pos++] = zw::kWordChars[i];
    }
    return pos;
}

__device__ void build_mnemonic(const uint16_t tail[4], uint8_t mnemonic[71]) {
    int pos = 0;
    #pragma unroll
    for (int i = 0; i < zw::kKnownPrefixByteCount; ++i) {
        mnemonic[pos++] = zw::kKnownPrefixBytes[i];
    }
    pos = append_word(tail[0], mnemonic, pos);
    mnemonic[pos++] = ' ';
    pos = append_word(tail[1], mnemonic, pos);
    mnemonic[pos++] = ' ';
    pos = append_word(tail[2], mnemonic, pos);
    mnemonic[pos++] = ' ';
    pos = append_word(tail[3], mnemonic, pos);
}

__device__ void derive_zenon_core(const uint16_t tail[4], uint8_t core[20], uint8_t mnemonic_out[71]) {
    uint8_t mnemonic[71];
    build_mnemonic(tail, mnemonic);
    if (mnemonic_out) {
        #pragma unroll
        for (int i = 0; i < 71; ++i) {
            mnemonic_out[i] = mnemonic[i];
        }
    }

    uint8_t seed[64];
    pbkdf2_hmac_sha512_mnemonic(mnemonic, seed);

    uint8_t key[32];
    uint8_t chain_code[32];
    slip10_master(seed, key, chain_code);
    slip10_ckd_priv(key, chain_code, 44);
    slip10_ckd_priv(key, chain_code, 73404);
    slip10_ckd_priv(key, chain_code, 0);

    uint8_t public_key[32];
    ed25519_public_from_seed(key, public_key);

    uint8_t digest[32];
    sha3_256_32bytes(public_key, digest);
    core[0] = 0;
    #pragma unroll
    for (int i = 0; i < 19; ++i) {
        core[i + 1] = digest[i];
    }
}

__device__ bool core_matches_target(const uint8_t core[20]) {
    #pragma unroll
    for (int i = 0; i < 20; ++i) {
        if (core[i] != zw::kTargetCore[i]) {
            return false;
        }
    }
    return true;
}

__device__ bool core_matches_first_valid_vector(const uint8_t core[20]) {
    #pragma unroll
    for (int i = 0; i < 20; ++i) {
        if (core[i] != zw::kFirstValidCore[i]) {
            return false;
        }
    }
    return true;
}

}  // namespace zenon_crypto
