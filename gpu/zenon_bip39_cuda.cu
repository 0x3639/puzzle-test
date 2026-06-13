#include <cuda_runtime.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "crypto_oracle.cuh"
#include "gpu_workload.h"

namespace zw = zenon_gpu_workload;
namespace zc = zenon_crypto;

struct KernelResult {
    unsigned long long checksum_valid;
    unsigned long long address_derivations;
    unsigned long long first_valid_global;
    uint16_t first_valid_tail[4];
    unsigned int hit_found;
    unsigned int self_test_pass;
    unsigned long long hit_global;
    uint16_t hit_tail[4];
    uint8_t hit_core[20];
    uint8_t hit_mnemonic[zc::MAX_MNEMONIC_BYTES + 1];
    int hit_mnemonic_len;
    unsigned int queue_overflow;
    uint8_t self_test_core[20];
    uint8_t self_test_mnemonic[zc::MAX_MNEMONIC_BYTES + 1];
    int self_test_mnemonic_len;
};

#define CUDA_CHECK(call)                                                        \
    do {                                                                        \
        cudaError_t err__ = (call);                                             \
        if (err__ != cudaSuccess) {                                             \
            std::fprintf(stderr, "CUDA error %s:%d: %s\n", __FILE__, __LINE__, \
                         cudaGetErrorString(err__));                            \
            std::exit(1);                                                       \
        }                                                                       \
    } while (0)

__device__ __constant__ uint32_t kSha256K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

__device__ __forceinline__ uint32_t rotr32(uint32_t value, int bits) {
    return (value >> bits) | (value << (32 - bits));
}

__device__ void sha256_16bytes(const uint8_t input[16], uint8_t digest[32]) {
    uint32_t w[64];

    w[0] = (uint32_t(input[0]) << 24) | (uint32_t(input[1]) << 16) |
           (uint32_t(input[2]) << 8) | uint32_t(input[3]);
    w[1] = (uint32_t(input[4]) << 24) | (uint32_t(input[5]) << 16) |
           (uint32_t(input[6]) << 8) | uint32_t(input[7]);
    w[2] = (uint32_t(input[8]) << 24) | (uint32_t(input[9]) << 16) |
           (uint32_t(input[10]) << 8) | uint32_t(input[11]);
    w[3] = (uint32_t(input[12]) << 24) | (uint32_t(input[13]) << 16) |
           (uint32_t(input[14]) << 8) | uint32_t(input[15]);
    w[4] = 0x80000000u;
    for (int i = 5; i < 15; ++i) {
        w[i] = 0;
    }
    w[15] = 16u * 8u;

    for (int i = 16; i < 64; ++i) {
        const uint32_t s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        const uint32_t s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    uint32_t a = 0x6a09e667u;
    uint32_t b = 0xbb67ae85u;
    uint32_t c = 0x3c6ef372u;
    uint32_t d = 0xa54ff53au;
    uint32_t e = 0x510e527fu;
    uint32_t f = 0x9b05688cu;
    uint32_t g = 0x1f83d9abu;
    uint32_t h = 0x5be0cd19u;

    for (int i = 0; i < 64; ++i) {
        const uint32_t s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        const uint32_t ch = (e & f) ^ ((~e) & g);
        const uint32_t temp1 = h + s1 + ch + kSha256K[i] + w[i];
        const uint32_t s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        const uint32_t temp2 = s0 + maj;

        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }

    uint32_t state[8] = {
        0x6a09e667u + a,
        0xbb67ae85u + b,
        0x3c6ef372u + c,
        0xa54ff53au + d,
        0x510e527fu + e,
        0x9b05688cu + f,
        0x1f83d9abu + g,
        0x5be0cd19u + h,
    };

    for (int i = 0; i < 8; ++i) {
        digest[i * 4 + 0] = uint8_t(state[i] >> 24);
        digest[i * 4 + 1] = uint8_t(state[i] >> 16);
        digest[i * 4 + 2] = uint8_t(state[i] >> 8);
        digest[i * 4 + 3] = uint8_t(state[i]);
    }
}

__device__ __forceinline__ const uint16_t* device_words_for_length(int length) {
    return zw::words_for_length(length);
}

__device__ __forceinline__ int device_count_for_length(int length) {
    return zw::count_for_length(length);
}

__device__ bool tail_for_global_offset(
    uint64_t global_offset,
    uint16_t tail[4]
) {
    if (zw::kSearchModeAllWords) {
        if (global_offset >= zw::kTotalCombinations) {
            return false;
        }
        tail[0] = uint16_t((global_offset >> 33) & 0x7ffULL);
        tail[1] = uint16_t((global_offset >> 22) & 0x7ffULL);
        tail[2] = uint16_t((global_offset >> 11) & 0x7ffULL);
        tail[3] = uint16_t(global_offset & 0x7ffULL);
        return true;
    }

    int pattern_index = -1;
    uint64_t pattern_start = 0;
    for (int i = 0; i < zw::kPatternCount; ++i) {
        const uint64_t start = zw::kPatternStarts[i];
        const uint64_t stop = start + zw::kPatternCombinations[i];
        if (global_offset >= start && global_offset < stop) {
            pattern_index = i;
            pattern_start = start;
            break;
        }
    }
    if (pattern_index < 0) {
        return false;
    }

    const int l0 = zw::kPatternLengths[pattern_index * 4 + 0];
    const int l1 = zw::kPatternLengths[pattern_index * 4 + 1];
    const int l2 = zw::kPatternLengths[pattern_index * 4 + 2];
    const int l3 = zw::kPatternLengths[pattern_index * 4 + 3];

    const int n0 = device_count_for_length(l0);
    const int n1 = device_count_for_length(l1);
    const int n2 = device_count_for_length(l2);
    const int n3 = device_count_for_length(l3);
    if (!n0 || !n1 || !n2 || !n3) {
        return false;
    }

    const uint64_t stride0 = uint64_t(n1) * uint64_t(n2) * uint64_t(n3);
    const uint64_t stride1 = uint64_t(n2) * uint64_t(n3);
    uint64_t local = global_offset - pattern_start;

    const uint64_t i0 = local / stride0;
    local %= stride0;
    const uint64_t i1 = local / stride1;
    local %= stride1;
    const uint64_t i2 = local / uint64_t(n3);
    const uint64_t i3 = local % uint64_t(n3);

    const uint16_t* w0 = device_words_for_length(l0);
    const uint16_t* w1 = device_words_for_length(l1);
    const uint16_t* w2 = device_words_for_length(l2);
    const uint16_t* w3 = device_words_for_length(l3);

    tail[0] = w0[i0];
    tail[1] = w1[i1];
    tail[2] = w2[i2];
    tail[3] = w3[i3];
    return true;
}

__device__ bool bip39_checksum_valid(const uint16_t tail[4]) {
    uint8_t entropy[16];
    uint8_t digest[32];

    // First 88 bits are the known 8 BIP39 words, prepacked by the workload
    // generator to avoid doing 88-bit bitstream work in every thread.
    #pragma unroll
    for (int i = 0; i < 11; ++i) {
        entropy[i] = zw::kKnownPrefixEntropyBytes[i];
    }

    uint64_t tail44 = 0;
    tail44 = (tail44 << 11) | uint64_t(tail[0]);
    tail44 = (tail44 << 11) | uint64_t(tail[1]);
    tail44 = (tail44 << 11) | uint64_t(tail[2]);
    tail44 = (tail44 << 11) | uint64_t(tail[3]);

    const uint64_t tail_entropy40 = tail44 >> 4;
    entropy[11] = uint8_t(tail_entropy40 >> 32);
    entropy[12] = uint8_t(tail_entropy40 >> 24);
    entropy[13] = uint8_t(tail_entropy40 >> 16);
    entropy[14] = uint8_t(tail_entropy40 >> 8);
    entropy[15] = uint8_t(tail_entropy40);

    sha256_16bytes(entropy, digest);
    const uint8_t expected_checksum = digest[0] >> 4;
    const uint8_t actual_checksum = uint8_t(tail44 & 0x0fu);
    return expected_checksum == actual_checksum;
}

__global__ void checksum_kernel(
    uint64_t start,
    uint64_t count,
    KernelResult* result
) {
    const uint64_t tid = uint64_t(blockIdx.x) * uint64_t(blockDim.x) + uint64_t(threadIdx.x);
    const uint64_t stride = uint64_t(blockDim.x) * uint64_t(gridDim.x);

    for (uint64_t local = tid; local < count; local += stride) {
        const uint64_t global = start + local;
        uint16_t tail[4];
        if (!tail_for_global_offset(global, tail)) {
            continue;
        }
        if (!bip39_checksum_valid(tail)) {
            continue;
        }

        atomicAdd(&result->checksum_valid, 1ULL);
        const unsigned long long old = atomicMin(&result->first_valid_global, (unsigned long long)global);
        if ((unsigned long long)global < old) {
            result->first_valid_tail[0] = tail[0];
            result->first_valid_tail[1] = tail[1];
            result->first_valid_tail[2] = tail[2];
            result->first_valid_tail[3] = tail[3];
        }
    }
}

__global__ void address_kernel(
    uint64_t start,
    uint64_t count,
    KernelResult* result
) {
    const uint64_t tid = uint64_t(blockIdx.x) * uint64_t(blockDim.x) + uint64_t(threadIdx.x);
    const uint64_t stride = uint64_t(blockDim.x) * uint64_t(gridDim.x);

    for (uint64_t local = tid; local < count; local += stride) {
        if (result->hit_found) {
            return;
        }

        const uint64_t global = start + local;
        uint16_t tail[4];
        if (!tail_for_global_offset(global, tail)) {
            continue;
        }
        if (!bip39_checksum_valid(tail)) {
            continue;
        }

        atomicAdd(&result->checksum_valid, 1ULL);
        const unsigned long long old = atomicMin(&result->first_valid_global, (unsigned long long)global);
        if ((unsigned long long)global < old) {
            result->first_valid_tail[0] = tail[0];
            result->first_valid_tail[1] = tail[1];
            result->first_valid_tail[2] = tail[2];
            result->first_valid_tail[3] = tail[3];
        }

        atomicAdd(&result->address_derivations, 1ULL);
        uint8_t core[20];
        uint8_t mnemonic[zc::MAX_MNEMONIC_BYTES + 1];
        int mnemonic_len = 0;
        zc::derive_zenon_core(tail, core, mnemonic, &mnemonic_len);
        if (!zc::core_matches_target(core)) {
            continue;
        }

        if (atomicCAS(&result->hit_found, 0u, 1u) == 0u) {
            result->hit_global = global;
            result->hit_tail[0] = tail[0];
            result->hit_tail[1] = tail[1];
            result->hit_tail[2] = tail[2];
            result->hit_tail[3] = tail[3];
            #pragma unroll
            for (int i = 0; i < 20; ++i) {
                result->hit_core[i] = core[i];
            }
            for (int i = 0; i < mnemonic_len; ++i) {
                result->hit_mnemonic[i] = mnemonic[i];
            }
            result->hit_mnemonic[mnemonic_len] = 0;
            result->hit_mnemonic_len = mnemonic_len;
        }
        return;
    }
}

__global__ void collect_valid_offsets_kernel(
    uint64_t start,
    uint64_t count,
    uint64_t* valid_offsets,
    uint64_t valid_capacity,
    KernelResult* result
) {
    const uint64_t tid = uint64_t(blockIdx.x) * uint64_t(blockDim.x) + uint64_t(threadIdx.x);
    const uint64_t stride = uint64_t(blockDim.x) * uint64_t(gridDim.x);

    for (uint64_t local = tid; local < count; local += stride) {
        const uint64_t global = start + local;
        uint16_t tail[4];
        if (!tail_for_global_offset(global, tail)) {
            continue;
        }
        if (!bip39_checksum_valid(tail)) {
            continue;
        }

        const unsigned long long slot = atomicAdd(&result->checksum_valid, 1ULL);
        const unsigned long long old = atomicMin(&result->first_valid_global, (unsigned long long)global);
        if ((unsigned long long)global < old) {
            result->first_valid_tail[0] = tail[0];
            result->first_valid_tail[1] = tail[1];
            result->first_valid_tail[2] = tail[2];
            result->first_valid_tail[3] = tail[3];
        }

        if (slot < valid_capacity) {
            valid_offsets[slot] = global;
        } else {
            result->queue_overflow = 1u;
        }
    }
}

__global__ void address_compact_kernel(
    const uint64_t* valid_offsets,
    uint64_t valid_count,
    KernelResult* result
) {
    const uint64_t tid = uint64_t(blockIdx.x) * uint64_t(blockDim.x) + uint64_t(threadIdx.x);
    const uint64_t stride = uint64_t(blockDim.x) * uint64_t(gridDim.x);

    for (uint64_t local = tid; local < valid_count; local += stride) {
        if (result->hit_found) {
            return;
        }

        const uint64_t global = valid_offsets[local];
        uint16_t tail[4];
        if (!tail_for_global_offset(global, tail)) {
            continue;
        }

        atomicAdd(&result->address_derivations, 1ULL);
        uint8_t core[20];
        uint8_t mnemonic[zc::MAX_MNEMONIC_BYTES + 1];
        int mnemonic_len = 0;
        zc::derive_zenon_core(tail, core, mnemonic, &mnemonic_len);
        if (!zc::core_matches_target(core)) {
            continue;
        }

        if (atomicCAS(&result->hit_found, 0u, 1u) == 0u) {
            result->hit_global = global;
            result->hit_tail[0] = tail[0];
            result->hit_tail[1] = tail[1];
            result->hit_tail[2] = tail[2];
            result->hit_tail[3] = tail[3];
            #pragma unroll
            for (int i = 0; i < 20; ++i) {
                result->hit_core[i] = core[i];
            }
            for (int i = 0; i < mnemonic_len; ++i) {
                result->hit_mnemonic[i] = mnemonic[i];
            }
            result->hit_mnemonic[mnemonic_len] = 0;
            result->hit_mnemonic_len = mnemonic_len;
        }
        return;
    }
}

__global__ void address_self_test_kernel(KernelResult* result) {
    uint16_t tail[4] = {19, 19, 19, 28};
    if (!bip39_checksum_valid(tail)) {
        result->self_test_pass = 0;
        return;
    }

    uint8_t core[20];
    uint8_t mnemonic[zc::MAX_MNEMONIC_BYTES + 1];
    int mnemonic_len = 0;
    zc::derive_zenon_core(tail, core, mnemonic, &mnemonic_len);
    result->checksum_valid = 1;
    result->address_derivations = 1;
    result->first_valid_global = 9;
    result->first_valid_tail[0] = tail[0];
    result->first_valid_tail[1] = tail[1];
    result->first_valid_tail[2] = tail[2];
    result->first_valid_tail[3] = tail[3];
    #pragma unroll
    for (int i = 0; i < 20; ++i) {
        result->self_test_core[i] = core[i];
    }
    for (int i = 0; i < mnemonic_len; ++i) {
        result->self_test_mnemonic[i] = mnemonic[i];
    }
    result->self_test_mnemonic[mnemonic_len] = 0;
    result->self_test_mnemonic_len = mnemonic_len;
    result->self_test_pass = zc::core_matches_first_valid_vector(core) ? 1u : 0u;
}

enum class Mode {
    Checksum,
    Address,
    AddressCompact,
    SelfTest,
};

struct Options {
    uint64_t start = 0;
    uint64_t count = 10000;
    uint64_t valid_capacity = 0;
    int threads = 256;
    int blocks = 0;
    Mode mode = Mode::Checksum;
};

uint64_t parse_u64(const char* value) {
    char* end = nullptr;
    const unsigned long long parsed = std::strtoull(value, &end, 10);
    if (!end || *end != '\0') {
        std::fprintf(stderr, "invalid integer: %s\n", value);
        std::exit(2);
    }
    return uint64_t(parsed);
}

int parse_i32(const char* value) {
    char* end = nullptr;
    const long parsed = std::strtol(value, &end, 10);
    if (!end || *end != '\0') {
        std::fprintf(stderr, "invalid integer: %s\n", value);
        std::exit(2);
    }
    return int(parsed);
}

Options parse_args(int argc, char** argv) {
    Options options;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto require_value = [&](const char* name) -> const char* {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "missing value for %s\n", name);
                std::exit(2);
            }
            return argv[++i];
        };
        if (arg == "--start") {
            options.start = parse_u64(require_value("--start"));
        } else if (arg == "--count") {
            options.count = parse_u64(require_value("--count"));
        } else if (arg == "--valid-capacity") {
            options.valid_capacity = parse_u64(require_value("--valid-capacity"));
        } else if (arg == "--threads") {
            options.threads = parse_i32(require_value("--threads"));
        } else if (arg == "--blocks") {
            options.blocks = parse_i32(require_value("--blocks"));
        } else if (arg == "--mode") {
            const std::string mode = require_value("--mode");
            if (mode == "checksum") {
                options.mode = Mode::Checksum;
            } else if (mode == "address") {
                options.mode = Mode::Address;
            } else if (mode == "address-compact") {
                options.mode = Mode::AddressCompact;
            } else if (mode == "self-test") {
                options.mode = Mode::SelfTest;
            } else {
                std::fprintf(stderr, "unknown mode: %s\n", mode.c_str());
                std::exit(2);
            }
        } else if (arg == "--address") {
            options.mode = Mode::Address;
        } else if (arg == "--self-test-address") {
            options.mode = Mode::SelfTest;
        } else if (arg == "--help" || arg == "-h") {
            std::printf(
                "Usage: zenon_bip39_cuda [--mode checksum|address|address-compact|self-test] [--start N] [--count N] [--threads N] [--blocks N] [--valid-capacity N]\n"
                "\n"
                "Modes:\n"
                "  checksum         candidate enumeration + BIP39 checksum validation\n"
                "  address          single-pass checksum + Zenon address target comparison\n"
                "  address-compact  gather checksum-valid offsets, then run the address oracle densely\n"
                "  self-test        derive the known first-valid candidate and compare to Python vector\n"
            );
            std::exit(0);
        } else {
            std::fprintf(stderr, "unknown argument: %s\n", arg.c_str());
            std::exit(2);
        }
    }
    if (options.threads <= 0) {
        std::fprintf(stderr, "--threads must be positive\n");
        std::exit(2);
    }
    if (options.mode == Mode::SelfTest) {
        options.start = 0;
        options.count = 1;
        return options;
    }
    if (options.start >= zw::kTotalCombinations) {
        std::fprintf(stderr, "--start is outside the search space\n");
        std::exit(2);
    }
    if (options.count > zw::kTotalCombinations - options.start) {
        options.count = zw::kTotalCombinations - options.start;
    }
    return options;
}

uint64_t default_valid_capacity(uint64_t count) {
    if (count == 0) {
        return 0;
    }
    uint64_t capacity = (count / 8) + 4096;
    if (capacity < 16384) {
        capacity = 16384;
    }
    if (capacity > count) {
        capacity = count;
    }
    return capacity;
}

int main(int argc, char** argv) {
    const Options options = parse_args(argc, argv);

    int device = 0;
    CUDA_CHECK(cudaGetDevice(&device));
    cudaDeviceProp prop{};
    CUDA_CHECK(cudaGetDeviceProperties(&prop, device));

    int blocks = options.blocks;
    if (blocks <= 0) {
        blocks = prop.multiProcessorCount * 8;
    }

    KernelResult host_result{};
    host_result.checksum_valid = 0;
    host_result.address_derivations = 0;
    host_result.first_valid_global = 0xffffffffffffffffULL;
    host_result.first_valid_tail[0] = 0;
    host_result.first_valid_tail[1] = 0;
    host_result.first_valid_tail[2] = 0;
    host_result.first_valid_tail[3] = 0;
    host_result.hit_found = 0;
    host_result.self_test_pass = 0;
    host_result.hit_global = 0xffffffffffffffffULL;
    std::memset(host_result.hit_tail, 0, sizeof(host_result.hit_tail));
    std::memset(host_result.hit_core, 0, sizeof(host_result.hit_core));
    std::memset(host_result.hit_mnemonic, 0, sizeof(host_result.hit_mnemonic));
    host_result.hit_mnemonic_len = 0;
    host_result.queue_overflow = 0;
    std::memset(host_result.self_test_core, 0, sizeof(host_result.self_test_core));
    std::memset(host_result.self_test_mnemonic, 0, sizeof(host_result.self_test_mnemonic));
    host_result.self_test_mnemonic_len = 0;

    KernelResult* device_result = nullptr;
    CUDA_CHECK(cudaMalloc(&device_result, sizeof(KernelResult)));
    CUDA_CHECK(cudaMemcpy(device_result, &host_result, sizeof(KernelResult), cudaMemcpyHostToDevice));

    cudaEvent_t ev_start{};
    cudaEvent_t ev_stop{};
    CUDA_CHECK(cudaEventCreate(&ev_start));
    CUDA_CHECK(cudaEventCreate(&ev_stop));
    CUDA_CHECK(cudaEventRecord(ev_start));

    float collect_milliseconds = 0.0f;
    float oracle_milliseconds = 0.0f;
    uint64_t compact_queue_capacity = 0;

    if (options.mode == Mode::Checksum) {
        checksum_kernel<<<blocks, options.threads>>>(options.start, options.count, device_result);
    } else if (options.mode == Mode::Address) {
        address_kernel<<<blocks, options.threads>>>(options.start, options.count, device_result);
    } else if (options.mode == Mode::AddressCompact) {
        compact_queue_capacity = options.valid_capacity ? options.valid_capacity : default_valid_capacity(options.count);
        uint64_t* valid_offsets = nullptr;
        if (compact_queue_capacity > 0) {
            CUDA_CHECK(cudaMalloc(&valid_offsets, compact_queue_capacity * sizeof(uint64_t)));
        }

        collect_valid_offsets_kernel<<<blocks, options.threads>>>(
            options.start,
            options.count,
            valid_offsets,
            compact_queue_capacity,
            device_result
        );
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaEventRecord(ev_stop));
        CUDA_CHECK(cudaEventSynchronize(ev_stop));
        CUDA_CHECK(cudaEventElapsedTime(&collect_milliseconds, ev_start, ev_stop));
        CUDA_CHECK(cudaMemcpy(&host_result, device_result, sizeof(KernelResult), cudaMemcpyDeviceToHost));

        const uint64_t valid_count = uint64_t(host_result.checksum_valid);
        if (!host_result.queue_overflow && valid_count > 0) {
            CUDA_CHECK(cudaEventRecord(ev_start));
            address_compact_kernel<<<blocks, options.threads>>>(
                valid_offsets,
                valid_count,
                device_result
            );
            CUDA_CHECK(cudaGetLastError());
            CUDA_CHECK(cudaEventRecord(ev_stop));
            CUDA_CHECK(cudaEventSynchronize(ev_stop));
            CUDA_CHECK(cudaEventElapsedTime(&oracle_milliseconds, ev_start, ev_stop));
            CUDA_CHECK(cudaMemcpy(&host_result, device_result, sizeof(KernelResult), cudaMemcpyDeviceToHost));
        }

        if (valid_offsets) {
            CUDA_CHECK(cudaFree(valid_offsets));
        }
    } else {
        address_self_test_kernel<<<1, 1>>>(device_result);
    }

    float milliseconds = 0.0f;
    if (options.mode == Mode::AddressCompact) {
        milliseconds = collect_milliseconds + oracle_milliseconds;
    } else {
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaEventRecord(ev_stop));
        CUDA_CHECK(cudaEventSynchronize(ev_stop));
        CUDA_CHECK(cudaEventElapsedTime(&milliseconds, ev_start, ev_stop));
        CUDA_CHECK(cudaMemcpy(&host_result, device_result, sizeof(KernelResult), cudaMemcpyDeviceToHost));
    }

    CUDA_CHECK(cudaFree(device_result));
    CUDA_CHECK(cudaEventDestroy(ev_start));
    CUDA_CHECK(cudaEventDestroy(ev_stop));

    const double seconds = double(milliseconds) / 1000.0;
    const double combos_per_second = seconds > 0.0 ? double(options.count) / seconds : 0.0;
    const double derivations_per_second = seconds > 0.0 ? double(host_result.address_derivations) / seconds : 0.0;

    std::printf("{\n");
    std::printf("  \"device\": \"%s\",\n", prop.name);
    if (options.mode == Mode::Checksum) {
        std::printf("  \"stage\": \"bip39_checksum_only\",\n");
    } else if (options.mode == Mode::Address) {
        std::printf("  \"stage\": \"zenon_address_oracle\",\n");
    } else if (options.mode == Mode::AddressCompact) {
        std::printf("  \"stage\": \"zenon_address_compact_oracle\",\n");
    } else {
        std::printf("  \"stage\": \"zenon_address_self_test\",\n");
    }
    std::printf("  \"start\": %llu,\n", (unsigned long long)options.start);
    std::printf("  \"count\": %llu,\n", (unsigned long long)options.count);
    std::printf("  \"threads\": %d,\n", options.threads);
    std::printf("  \"blocks\": %d,\n", blocks);
    std::printf("  \"elapsed_seconds\": %.6f,\n", seconds);
    std::printf("  \"combos_per_second\": %.2f,\n", combos_per_second);
    std::printf("  \"checksum_valid\": %llu,\n", host_result.checksum_valid);
    std::printf("  \"address_derivations\": %llu,\n", host_result.address_derivations);
    std::printf("  \"address_derivations_per_second\": %.2f,\n", derivations_per_second);
    if (options.mode == Mode::AddressCompact) {
        std::printf("  \"compact_queue_capacity\": %llu,\n", (unsigned long long)compact_queue_capacity);
        std::printf("  \"queue_overflow\": %s,\n", host_result.queue_overflow ? "true" : "false");
        std::printf("  \"collect_elapsed_seconds\": %.6f,\n", double(collect_milliseconds) / 1000.0);
        std::printf("  \"oracle_elapsed_seconds\": %.6f,\n", double(oracle_milliseconds) / 1000.0);
    }
    if (host_result.first_valid_global != 0xffffffffffffffffULL) {
        std::printf("  \"first_valid_global\": %llu,\n", host_result.first_valid_global);
        std::printf("  \"first_valid_tail_indices\": [%u, %u, %u, %u]\n",
                    unsigned(host_result.first_valid_tail[0]),
                    unsigned(host_result.first_valid_tail[1]),
                    unsigned(host_result.first_valid_tail[2]),
                    unsigned(host_result.first_valid_tail[3]));
    } else {
        std::printf("  \"first_valid_global\": null,\n");
        std::printf("  \"first_valid_tail_indices\": null\n");
    }
    if (options.mode == Mode::Address || options.mode == Mode::AddressCompact) {
        std::printf(",\n");
        std::printf("  \"hit_found\": %s", host_result.hit_found ? "true" : "false");
        if (host_result.hit_found) {
            std::printf(",\n");
            std::printf("  \"hit_global\": %llu,\n", host_result.hit_global);
            std::printf("  \"hit_tail_indices\": [%u, %u, %u, %u],\n",
                        unsigned(host_result.hit_tail[0]),
                        unsigned(host_result.hit_tail[1]),
                        unsigned(host_result.hit_tail[2]),
                        unsigned(host_result.hit_tail[3]));
            std::printf("  \"hit_mnemonic\": \"%s\"", host_result.hit_mnemonic);
        }
        std::printf("\n");
    } else if (options.mode == Mode::SelfTest) {
        std::printf(",\n");
        std::printf("  \"self_test_pass\": %s,\n", host_result.self_test_pass ? "true" : "false");
        std::printf("  \"self_test_mnemonic\": \"%s\",\n", host_result.self_test_mnemonic);
        std::printf("  \"self_test_core_hex\": \"");
        for (int i = 0; i < 20; ++i) {
            std::printf("%02x", host_result.self_test_core[i]);
        }
        std::printf("\"\n");
    }
    std::printf("}\n");

    return 0;
}
