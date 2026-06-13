#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEFAULT_BENCH_COUNT=100000000
DEFAULT_RANGE_START=0
DEFAULT_RANGE_COUNT=10000
DEFAULT_FULL_CHUNK=100000000
DEFAULT_ADDRESS_CHUNK=100000000
DEFAULT_WORD_MODE=all
DEFAULT_ADDRESS_MODE=address-compact

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

detect_gpu_arch() {
  if have nvidia-smi; then
    local cap
    cap="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '.[:space:]')"
    if [ -n "$cap" ]; then
      printf '%s\n' "$cap"
      return
    fi
  fi

  return 1
}

nvcc_supports_compute() {
  local arch="$1"
  local tmp_base="${TMPDIR:-/tmp}/zenon_cuda_arch_test_$$"
  local source="${tmp_base}.cu"
  local object="${tmp_base}.o"

  printf '__global__ void k() {}\nint main() { return 0; }\n' > "$source"
  if nvcc -c "$source" -o "$object" -gencode="arch=compute_${arch},code=compute_${arch}" >/dev/null 2>&1; then
    rm -f "$source" "$object"
    return 0
  fi
  rm -f "$source" "$object"
  return 1
}

select_cuda_arch() {
  if [ -n "${CUDA_ARCH:-}" ]; then
    printf '%s\n' "$CUDA_ARCH"
    return
  fi

  local detected=""
  if detected="$(detect_gpu_arch)"; then
    if nvcc_supports_compute "$detected"; then
      printf '%s\n' "$detected"
      return
    fi

    warn "GPU reports compute capability ${detected}, but this nvcc cannot compile compute_${detected}."
    warn "Selecting the newest PTX architecture this toolkit supports for driver JIT."
  else
    warn "Could not detect CUDA architecture with nvidia-smi."
  fi

  local arch
  for arch in 120 100 90 89 86 80 75 70 61 52; do
    if [ -n "$detected" ] && [ "$arch" -gt "$detected" ]; then
      continue
    fi
    if nvcc_supports_compute "$arch"; then
      printf '%s-virtual\n' "$arch"
      return
    fi
  done

  die "Could not find any CUDA architecture supported by nvcc. Try a newer CUDA devel image."
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
  local word_mode="${WORD_MODE:-$DEFAULT_WORD_MODE}"
  log "Generating GPU workload JSON and CUDA header with word mode ${word_mode}"
  "$PYTHON_BIN" scripts/prepare_gpu_workload.py --word-mode "$word_mode"
  "$PYTHON_BIN" scripts/emit_cuda_workload_header.py
}

workload_mode() {
  "$PYTHON_BIN" -c 'import json; print(json.load(open("out/gpu_workload.json")).get("search_mode", "exact18"))'
}

configure_build() {
  local arch
  arch="$(select_cuda_arch)"
  log "Configuring CUDA build for architecture ${arch}"
  cmake -S gpu -B gpu/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES="$arch"
}

build_binary() {
  log "Building CUDA runner"
  cmake --build gpu/build -j
}

run_cuda() {
  local args=("$@")
  if [ -n "${CUDA_THREADS:-}" ]; then
    args+=(--threads "$CUDA_THREADS")
  fi
  if [ -n "${CUDA_BLOCKS:-}" ]; then
    args+=(--blocks "$CUDA_BLOCKS")
  fi
  if [ -n "${VALID_CAPACITY:-}" ]; then
    args+=(--valid-capacity "$VALID_CAPACITY")
  fi
  ./gpu/build/zenon_bip39_cuda "${args[@]}"
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
  output="$(run_cuda --start 0 --count 10000)"
  printf '%s\n' "$output"

  local mode
  mode="$(workload_mode)"
  if [ "$mode" = "all" ]; then
    printf '%s\n' "$output" | grep -q '"checksum_valid": 625' || die "Smoke test failed: expected checksum_valid 625 for full-wordlist mode"
    printf '%s\n' "$output" | grep -q '"first_valid_global": 0' || die "Smoke test failed: expected first_valid_global 0 for full-wordlist mode"
    printf '%s\n' "$output" | grep -q '"first_valid_tail_indices": \[0, 0, 0, 0\]' || die "Smoke test failed: expected tail indices [0, 0, 0, 0]"
  else
    printf '%s\n' "$output" | grep -q '"checksum_valid": 643' || die "Smoke test failed: expected checksum_valid 643 for exact18 mode"
    printf '%s\n' "$output" | grep -q '"first_valid_global": 9' || die "Smoke test failed: expected first_valid_global 9 for exact18 mode"
    printf '%s\n' "$output" | grep -q '"first_valid_tail_indices": \[19, 19, 19, 28\]' || die "Smoke test failed: expected tail indices [19, 19, 19, 28]"
  fi

  log "Smoke test passed"
}

run_benchmark() {
  local count="${1:-$DEFAULT_BENCH_COUNT}"
  local start="${2:-0}"
  ensure_ready

  log "Running checksum benchmark: start=${start}, count=${count}"
  run_cuda --start "$start" --count "$count"
}

run_range() {
  local start="${1:-$DEFAULT_RANGE_START}"
  local count="${2:-$DEFAULT_RANGE_COUNT}"
  ensure_ready

  log "Running checksum range: start=${start}, count=${count}"
  run_cuda --start "$start" --count "$count"
}

run_oracle_test() {
  ensure_ready

  log "Running Zenon address oracle self-test"
  local output
  output="$(run_cuda --mode self-test)"
  printf '%s\n' "$output"
  printf '%s\n' "$output" | grep -q '"self_test_pass": true' || die "Address oracle self-test failed"
  log "Address oracle self-test passed"
}

run_address_range() {
  local start="${1:-$DEFAULT_RANGE_START}"
  local count="${2:-$DEFAULT_RANGE_COUNT}"
  ensure_ready

  local address_mode="${ADDRESS_MODE:-$DEFAULT_ADDRESS_MODE}"
  log "Running Zenon address oracle range: mode=${address_mode}, start=${start}, count=${count}"
  local output
  output="$(run_cuda --mode "$address_mode" --start "$start" --count "$count")"
  printf '%s\n' "$output"
  printf '%s\n' "$output" | grep -q '"queue_overflow": true' && die "Address compact queue overflowed; rerun with a smaller ADDRESS_CHUNK or larger --valid-capacity"
}

total_combinations() {
  "$PYTHON_BIN" -c 'import json; w=json.load(open("out/gpu_workload.json")); print(w.get("total_combinations", w["total_exact_length_combinations"]))'
}

json_compact() {
  "$PYTHON_BIN" -c 'import json,sys; print(json.dumps(json.load(sys.stdin), separators=(",", ":")))'
}

progress_percent() {
  "$PYTHON_BIN" -c 'import sys; done=int(sys.argv[1]); total=int(sys.argv[2]); print(f"{done / total:.2%}")' "$1" "$2"
}

run_full() {
  local chunk="${1:-${FULL_CHUNK:-$DEFAULT_FULL_CHUNK}}"
  local start="${2:-${FULL_START:-0}}"
  local stop="${3:-${FULL_STOP:-}}"
  local output_file="${FULL_OUTPUT:-}"

  ensure_ready

  local total
  total="$(total_combinations)"
  if [ -z "$stop" ]; then
    stop="$total"
  fi
  if [ -z "$output_file" ]; then
    output_file="out/runpod_full_$(date -u +%Y%m%dT%H%M%SZ).jsonl"
  fi

  if [ "$chunk" -le 0 ]; then
    die "full chunk size must be positive"
  fi
  if [ "$start" -lt 0 ] || [ "$stop" -lt 0 ] || [ "$start" -ge "$stop" ] || [ "$stop" -gt "$total" ]; then
    die "invalid full range: start=${start}, stop=${stop}, total=${total}"
  fi

  mkdir -p "$(dirname "$output_file")"

  log "Running full checksum batch"
  printf 'total=%s\nstart=%s\nstop=%s\nchunk=%s\noutput=%s\n' "$total" "$start" "$stop" "$chunk" "$output_file"

  local current="$start"
  while [ "$current" -lt "$stop" ]; do
    local remaining=$((stop - current))
    local count="$chunk"
    if [ "$remaining" -lt "$count" ]; then
      count="$remaining"
    fi

    log "Chunk start=${current}, count=${count}"
    local output
    output="$(run_cuda --start "$current" --count "$count")"
    printf '%s\n' "$output"
    printf '%s\n' "$output" | json_compact >> "$output_file"

    current=$((current + count))
    local done=$((current - start))
    local span=$((stop - start))
    log "Progress $(progress_percent "$done" "$span") (${current}/${stop})"
  done

  log "Full checksum batch complete"
  printf 'Wrote %s\n' "$output_file"
}

run_full_address() {
  local chunk="${1:-${ADDRESS_CHUNK:-$DEFAULT_ADDRESS_CHUNK}}"
  local start="${2:-${ADDRESS_START:-0}}"
  local stop="${3:-${ADDRESS_STOP:-}}"
  local output_file="${ADDRESS_OUTPUT:-}"

  ensure_ready

  log "Running address oracle self-test before full address batch"
  local self_test
  self_test="$(run_cuda --mode self-test)"
  printf '%s\n' "$self_test"
  printf '%s\n' "$self_test" | grep -q '"self_test_pass": true' || die "Address oracle self-test failed"

  local total
  total="$(total_combinations)"
  if [ -z "$stop" ]; then
    stop="$total"
  fi
  if [ -z "$output_file" ]; then
    output_file="out/runpod_address_$(date -u +%Y%m%dT%H%M%SZ).jsonl"
  fi

  if [ "$chunk" -le 0 ]; then
    die "address chunk size must be positive"
  fi
  if [ "$start" -lt 0 ] || [ "$stop" -lt 0 ] || [ "$start" -ge "$stop" ] || [ "$stop" -gt "$total" ]; then
    die "invalid address range: start=${start}, stop=${stop}, total=${total}"
  fi

  mkdir -p "$(dirname "$output_file")"

  log "Running full Zenon address batch"
  printf 'total=%s\nstart=%s\nstop=%s\nchunk=%s\noutput=%s\n' "$total" "$start" "$stop" "$chunk" "$output_file"

  local current="$start"
  while [ "$current" -lt "$stop" ]; do
    local remaining=$((stop - current))
    local count="$chunk"
    if [ "$remaining" -lt "$count" ]; then
      count="$remaining"
    fi

    log "Address chunk start=${current}, count=${count}"
    local output
    local address_mode="${ADDRESS_MODE:-$DEFAULT_ADDRESS_MODE}"
    output="$(run_cuda --mode "$address_mode" --start "$current" --count "$count")"
    printf '%s\n' "$output"
    printf '%s\n' "$output" | grep -q '"queue_overflow": true' && die "Address compact queue overflowed; rerun with a smaller ADDRESS_CHUNK or larger --valid-capacity"
    printf '%s\n' "$output" | json_compact >> "$output_file"

    if printf '%s\n' "$output" | grep -q '"hit_found": true'; then
      log "Target hit found"
      printf 'Wrote %s\n' "$output_file"
      return
    fi

    current=$((current + count))
    local done=$((current - start))
    local span=$((stop - start))
    log "Progress $(progress_percent "$done" "$span") (${current}/${stop})"
  done

  log "Full Zenon address batch complete without a hit"
  printf 'Wrote %s\n' "$output_file"
}

run_setup() {
  ensure_ready
  log "Setup/build complete"
}

run_summarize() {
  local python_bin="python3"
  if [ -x .venv/bin/python ]; then
    python_bin=".venv/bin/python"
  fi

  log "Summarizing full checksum output"
  "$python_bin" scripts/summarize_runpod_full.py "$@"
}

print_usage() {
  cat <<'EOF'
Usage:
  bash runpod/run.sh smoke
  bash runpod/run.sh setup
  bash runpod/run.sh benchmark [count] [start]
  bash runpod/run.sh range [start] [count]
  bash runpod/run.sh full [chunk_size] [start] [stop]
  bash runpod/run.sh oracle-test
  bash runpod/run.sh address [start] [count]
  bash runpod/run.sh full-address [chunk_size] [start] [stop]
  bash runpod/run.sh summarize [jsonl_path]
  bash runpod/run.sh help

Recommended first RunPod command:
  bash runpod/run.sh smoke

Examples:
  bash runpod/run.sh benchmark
  bash runpod/run.sh benchmark 100000000
  bash runpod/run.sh range 500000000 100000000
  bash runpod/run.sh full
  bash runpod/run.sh full 500000000
  FULL_OUTPUT=out/full.jsonl bash runpod/run.sh full 100000000
  bash runpod/run.sh oracle-test
  bash runpod/run.sh address 0 100000000
  bash runpod/run.sh full-address
  ADDRESS_OUTPUT=out/address.jsonl bash runpod/run.sh full-address 1000000000
  bash runpod/run.sh summarize
  bash runpod/run.sh summarize out/full.jsonl

Environment overrides:
  CUDA_ARCH=90 bash runpod/run.sh smoke            # H100 with matching toolkit
  CUDA_ARCH=90-virtual bash runpod/run.sh smoke    # newer GPU, older toolkit
  CUDA_ARCH=89 bash runpod/run.sh smoke            # RTX 4090 / L40S
  CUDA_ARCH=80 bash runpod/run.sh smoke            # A100
  SKIP_VENV=1 bash runpod/run.sh smoke             # use system Python
  WORD_MODE=exact18 bash runpod/run.sh smoke       # old 18-byte constrained mode
  WORD_MODE=all bash runpod/run.sh smoke           # full 2048^4 wordlist mode
  ADDRESS_MODE=address bash runpod/run.sh address  # old single-pass oracle
  ADDRESS_MODE=address-compact bash runpod/run.sh address
  CUDA_THREADS=128 bash runpod/run.sh address 0 100000000
  CUDA_BLOCKS=4096 bash runpod/run.sh address 0 100000000
  VALID_CAPACITY=200000000 bash runpod/run.sh address 0 1000000000
  FULL_CHUNK=500000000 bash runpod/run.sh full      # chunk size
  FULL_START=1000000000 bash runpod/run.sh full     # resume offset
  FULL_STOP=2000000000 bash runpod/run.sh full      # stop offset
  ADDRESS_CHUNK=1000000000 bash runpod/run.sh full-address
  ADDRESS_START=1000000000 bash runpod/run.sh full-address

CUDA modes:
  checksum/full      candidate enumeration + BIP39 checksum validation
  address/full-address
                     compacted checksum-valid candidates + Zenon target-address comparison
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
    oracle-test|self-test|address-test)
      run_oracle_test "$@"
      ;;
    address|oracle)
      run_address_range "$@"
      ;;
    full|all)
      run_full "$@"
      ;;
    full-address|address-full|full-oracle)
      run_full_address "$@"
      ;;
    summarize|summary)
      run_summarize "$@"
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
