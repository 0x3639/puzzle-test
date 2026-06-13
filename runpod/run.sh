#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEFAULT_BENCH_COUNT=100000000
DEFAULT_RANGE_START=0
DEFAULT_RANGE_COUNT=10000

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf '\nWARNING: %s\n' "$*" >&2
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    return 1
  fi
}

install_system_deps() {
  local missing=0
  for cmd in git cmake python3; do
    if ! have "$cmd"; then
      missing=1
    fi
  done

  if ! have c++ && ! have g++; then
    missing=1
  fi

  if have python3; then
    if ! python3 -m venv --help >/dev/null 2>&1; then
      missing=1
    fi
    if ! python3 -m pip --version >/dev/null 2>&1; then
      missing=1
    fi
  fi

  if [ "$missing" -eq 0 ]; then
    log "System dependencies look present"
    return
  fi

  if ! have apt-get; then
    warn "Some system dependencies are missing, and apt-get is not available."
    warn "Install git, cmake, build-essential, python3, python3-venv, and python3-pip in your RunPod image."
    return
  fi

  log "Installing system dependencies with apt-get"
  run_privileged apt-get update
  run_privileged apt-get install -y git cmake build-essential python3 python3-venv python3-pip
}

ensure_cuda() {
  if have nvcc; then
    log "CUDA compiler found: $(nvcc --version | tail -n 1)"
    return
  fi

  cat >&2 <<'EOF'

ERROR: nvcc was not found.

Use a RunPod CUDA "devel" template/image, not a "runtime" image.
Good choices:

  NVIDIA CUDA 12.x devel Ubuntu image
  RunPod PyTorch image with CUDA devel tools

Then rerun:

  bash runpod/run.sh smoke

EOF
  exit 1
}

detect_cuda_arch() {
  if [ -n "${CUDA_ARCH:-}" ]; then
    printf '%s\n' "$CUDA_ARCH"
    return
  fi

  if have nvidia-smi; then
    local cap
    cap="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '.[:space:]')"
    if [ -n "$cap" ]; then
      printf '%s\n' "$cap"
      return
    fi
  fi

  warn "Could not detect CUDA architecture with nvidia-smi. Defaulting to 89."
  warn "Override with CUDA_ARCH=90 for H100, CUDA_ARCH=89 for RTX 4090/L40S, or CUDA_ARCH=80 for A100."
  printf '89\n'
}

ensure_python_env() {
  if [ "${SKIP_VENV:-0}" = "1" ]; then
    log "Skipping virtualenv because SKIP_VENV=1"
    PYTHON_BIN="python3"
    return
  fi

  if [ ! -d .venv ]; then
    log "Creating Python virtualenv"
    python3 -m venv .venv
  fi

  PYTHON_BIN=".venv/bin/python"
  log "Installing Python requirements"
  "$PYTHON_BIN" -m pip install --upgrade pip
  "$PYTHON_BIN" -m pip install -r requirements.txt
}

generate_workload() {
  log "Generating GPU workload JSON and CUDA header"
  "$PYTHON_BIN" scripts/prepare_gpu_workload.py
  "$PYTHON_BIN" scripts/emit_cuda_workload_header.py
}

configure_build() {
  local arch
  arch="$(detect_cuda_arch)"
  log "Configuring CUDA build for architecture ${arch}"
  cmake -S gpu -B gpu/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES="$arch"
}

build_binary() {
  log "Building CUDA runner"
  cmake --build gpu/build -j
}

ensure_ready() {
  install_system_deps
  ensure_cuda
  ensure_python_env
  generate_workload
  configure_build
  build_binary
}

run_smoke() {
  ensure_ready

  log "Running smoke test"
  local output
  output="$(./gpu/build/zenon_bip39_cuda --start 0 --count 10000)"
  printf '%s\n' "$output"

  printf '%s\n' "$output" | grep -q '"checksum_valid": 643' || die "Smoke test failed: expected checksum_valid 643"
  printf '%s\n' "$output" | grep -q '"first_valid_global": 9' || die "Smoke test failed: expected first_valid_global 9"
  printf '%s\n' "$output" | grep -q '"first_valid_tail_indices": \[19, 19, 19, 28\]' || die "Smoke test failed: expected tail indices [19, 19, 19, 28]"

  log "Smoke test passed"
}

run_benchmark() {
  local count="${1:-$DEFAULT_BENCH_COUNT}"
  local start="${2:-0}"
  ensure_ready

  log "Running checksum benchmark: start=${start}, count=${count}"
  ./gpu/build/zenon_bip39_cuda --start "$start" --count "$count"
}

run_range() {
  local start="${1:-$DEFAULT_RANGE_START}"
  local count="${2:-$DEFAULT_RANGE_COUNT}"
  ensure_ready

  log "Running checksum range: start=${start}, count=${count}"
  ./gpu/build/zenon_bip39_cuda --start "$start" --count "$count"
}

run_setup() {
  ensure_ready
  log "Setup/build complete"
}

print_usage() {
  cat <<'EOF'
Usage:
  bash runpod/run.sh smoke
  bash runpod/run.sh setup
  bash runpod/run.sh benchmark [count] [start]
  bash runpod/run.sh range [start] [count]
  bash runpod/run.sh help

Recommended first RunPod command:
  bash runpod/run.sh smoke

Examples:
  bash runpod/run.sh benchmark
  bash runpod/run.sh benchmark 100000000
  bash runpod/run.sh range 500000000 100000000

Environment overrides:
  CUDA_ARCH=90 bash runpod/run.sh smoke     # H100
  CUDA_ARCH=89 bash runpod/run.sh smoke     # RTX 4090 / L40S
  CUDA_ARCH=80 bash runpod/run.sh smoke     # A100
  SKIP_VENV=1 bash runpod/run.sh smoke      # use system Python

Current CUDA stage:
  exact-length candidate enumeration + BIP39 checksum validation only.
  This does not yet perform the full Zenon address match.
EOF
}

main() {
  local command="${1:-smoke}"
  shift || true

  case "$command" in
    smoke)
      run_smoke "$@"
      ;;
    setup|build)
      run_setup "$@"
      ;;
    benchmark|bench)
      run_benchmark "$@"
      ;;
    range|run)
      run_range "$@"
      ;;
    help|-h|--help)
      print_usage
      ;;
    *)
      print_usage
      die "Unknown command: $command"
      ;;
  esac
}

main "$@"
