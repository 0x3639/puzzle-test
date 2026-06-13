# RunPod Quick Start

Use this if you just want to run the CUDA checksum runner with as little ceremony as possible.

## One-Command Smoke Test

On a RunPod CUDA devel pod:

```sh
git clone --branch codex/zenon-cuda-kernel https://github.com/0x3639/puzzle-test.git
cd puzzle-test
bash runpod/run.sh smoke
```

That command will:

```text
install missing apt packages when possible
create .venv
install Python requirements
generate out/gpu_workload.json
generate gpu/generated/gpu_workload.h
detect CUDA architecture
configure CMake
build gpu/build/zenon_bip39_cuda
run the 10,000-candidate smoke test
verify expected output
```

Expected smoke-test fields:

```text
"checksum_valid": 643
"first_valid_global": 9
"first_valid_tail_indices": [19, 19, 19, 28]
```

## Pick The Right RunPod Image

Use a CUDA `devel` image. A CUDA `runtime` image usually will not include `nvcc`, which is required to build the `.cu` file.

Good choices:

```text
NVIDIA CUDA 12.x devel Ubuntu image
RunPod PyTorch image with CUDA devel tools
```

Check:

```sh
nvcc --version
nvidia-smi
```

## Commands

Setup and build only:

```sh
bash runpod/run.sh setup
```

Smoke test:

```sh
bash runpod/run.sh smoke
```

Default benchmark, 100,000,000 candidates from offset 0:

```sh
bash runpod/run.sh benchmark
```

Custom benchmark count:

```sh
bash runpod/run.sh benchmark 500000000
```

Custom range:

```sh
bash runpod/run.sh range 500000000 100000000
```

That means:

```text
start = 500,000,000
count = 100,000,000
```

## GPU Architecture Overrides

The script tries to detect compute capability with `nvidia-smi`.

Override it if needed:

```sh
CUDA_ARCH=90 bash runpod/run.sh smoke   # H100
CUDA_ARCH=89 bash runpod/run.sh smoke   # RTX 4090 / L40S
CUDA_ARCH=80 bash runpod/run.sh smoke   # A100
```

## Important Limit

The CUDA binary currently validates candidate enumeration and BIP39 checksums only.

It does not yet run:

```text
PBKDF2-HMAC-SHA512
SLIP-10 Ed25519
Ed25519 public key
SHA3-256
Zenon target-address comparison
```

So a passing RunPod benchmark tells us the GPU candidate/checksum stage works. It does not yet mean the final four words have been searched against the target address on GPU.
