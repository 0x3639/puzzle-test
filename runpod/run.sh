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
JOBS_DIR="${JOBS_DIR:-out/runpod_jobs}"
MULTI_DIR="${MULTI_DIR:-${JOBS_DIR}/multi}"

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

status_python() {
  if [ -x .venv/bin/python ]; then
    printf '%s\n' ".venv/bin/python"
  else
    printf '%s\n' "python3"
  fi
}

ensure_runtime_ready() {
  if [ "${SKIP_VENV:-0}" = "1" ]; then
    PYTHON_BIN="python3"
  elif [ -x .venv/bin/python ]; then
    PYTHON_BIN=".venv/bin/python"
  else
    ensure_python_env
  fi

  if [ ! -x gpu/build/zenon_bip39_cuda ]; then
    die "CUDA runner is not built. Run: bash runpod/run.sh setup"
  fi
  if [ ! -s out/gpu_workload.json ]; then
    die "GPU workload is missing. Run: bash runpod/run.sh setup"
  fi
}

ensure_ready() {
  if [ "${RUNPOD_SKIP_SETUP:-0}" = "1" ]; then
    log "Skipping setup/build because RUNPOD_SKIP_SETUP=1"
    ensure_runtime_ready
    return
  fi

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

latest_job_meta() {
  local latest
  latest="$(ls -t "$JOBS_DIR"/*.env 2>/dev/null | head -n 1 || true)"
  if [ -z "$latest" ]; then
    die "No background jobs found under ${JOBS_DIR}"
  fi
  printf '%s\n' "$latest"
}

resolve_job_meta() {
  local job="${1:-latest}"
  if [ "$job" = "latest" ]; then
    latest_job_meta
    return
  fi
  if [ -f "$job" ]; then
    printf '%s\n' "$job"
    return
  fi
  if [ -f "$JOBS_DIR/${job}.env" ]; then
    printf '%s\n' "$JOBS_DIR/${job}.env"
    return
  fi
  die "Background job not found: ${job}"
}

job_state() {
  local pid="$1"
  local status_file="$2"
  if [ -s "$status_file" ]; then
    local exit_code
    exit_code="$(head -n 1 "$status_file")"
    if [ "$exit_code" = "0" ]; then
      printf '%s\n' "completed"
    else
      printf '%s\n' "failed:${exit_code}"
    fi
  elif kill -0 "$pid" >/dev/null 2>&1; then
    printf '%s\n' "running"
  else
    printf '%s\n' "stopped"
  fi
}

write_job_meta() {
  local meta_file="$1"
  local job_id="$2"
  local pid="$3"
  local command="$4"
  local output_file="$5"
  local log_file="$6"
  local status_file="$7"
  local runner_file="$8"
  local child_pid_file="$9"
  local started_at="${10}"
  shift 10

  {
    printf 'JOB_ID=%q\n' "$job_id"
    printf 'PID=%q\n' "$pid"
    printf 'COMMAND=%q\n' "$command"
    printf 'OUTPUT_FILE=%q\n' "$output_file"
    printf 'LOG_FILE=%q\n' "$log_file"
    printf 'STATUS_FILE=%q\n' "$status_file"
    printf 'RUNNER_FILE=%q\n' "$runner_file"
    printf 'CHILD_PID_FILE=%q\n' "$child_pid_file"
    printf 'STARTED_AT=%q\n' "$started_at"
    printf 'ARGS=('
    local arg
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf ' )\n'
  } > "$meta_file"
}

write_job_runner() {
  local runner_file="$1"
  local output_var="$2"
  local output_file="$3"
  local status_file="$4"
  local child_pid_file="$5"
  local command="$6"
  shift 6

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'cd %q\n' "$ROOT"
    printf 'export RUNPOD_BACKGROUND_CHILD=1\n'
    printf 'export %s=%q\n' "$output_var" "$output_file"
    local env_name
    for env_name in \
      CUDA_VISIBLE_DEVICES CUDA_THREADS CUDA_BLOCKS CUDA_ARCH VALID_CAPACITY \
      ADDRESS_MODE ADDRESS_CHUNK ADDRESS_START ADDRESS_STOP \
      FULL_CHUNK FULL_START FULL_STOP WORD_MODE SKIP_VENV RUNPOD_SKIP_SETUP
    do
      if [ -n "${!env_name:-}" ]; then
        printf 'export %s=%q\n' "$env_name" "${!env_name}"
      fi
    done
    printf 'status_file=%q\n' "$status_file"
    printf 'child_pid_file=%q\n' "$child_pid_file"
    printf 'printf '"'"'==> Background job started at %%s\\n'"'"' "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)"\n'
    printf 'printf '"'"'==> Command: bash runpod/run.sh'
    printf ' %q' "$command"
    local arg
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\\n'"'"'\n'
    printf 'finish() {\n'
    printf '  exit_code="$1"\n'
    printf '  printf '"'"'%%s\\n'"'"' "$exit_code" > "$status_file"\n'
    printf '  printf '"'"'\\n==> Background job finished with exit code %%s at %%s\\n'"'"' "$exit_code" "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)"\n'
    printf '  exit "$exit_code"\n'
    printf '}\n'
    printf 'terminate() {\n'
    printf '  printf '"'"'\\n==> Background job received stop signal at %%s\\n'"'"' "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)"\n'
    printf '  if [ -n "${child_pid:-}" ]; then\n'
    printf '    kill "$child_pid" >/dev/null 2>&1 || true\n'
    printf '    wait "$child_pid" >/dev/null 2>&1 || true\n'
    printf '  fi\n'
    printf '  finish 143\n'
    printf '}\n'
    printf 'trap terminate TERM INT\n'
    printf 'set +e\n'
    printf 'bash runpod/run.sh %q' "$command"
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf ' &\n'
    printf 'child_pid=$!\n'
    printf 'printf '"'"'%%s\\n'"'"' "$child_pid" > "$child_pid_file"\n'
    printf 'wait "$child_pid"\n'
    printf 'exit_code=$?\n'
    printf 'trap - TERM INT\n'
    printf 'finish "$exit_code"\n'
  } > "$runner_file"
  chmod +x "$runner_file"
}

run_bg_start() {
  local command="${1:-full-address}"
  if [ "$#" -gt 0 ]; then
    shift
  fi

  local output_var
  local output_file
  case "$command" in
    full-address|address-full|full-oracle)
      command="full-address"
      output_var="ADDRESS_OUTPUT"
      output_file="${ADDRESS_OUTPUT:-${BG_OUTPUT:-}}"
      ;;
    full|all)
      command="full"
      output_var="FULL_OUTPUT"
      output_file="${FULL_OUTPUT:-${BG_OUTPUT:-}}"
      ;;
    *)
      die "bg-start supports full-address and full, got: ${command}"
      ;;
  esac

  mkdir -p "$JOBS_DIR"
  local safe_command
  safe_command="$(printf '%s' "$command" | tr -c 'A-Za-z0-9' '_')"
  local job_id="${JOB_ID:-$(date -u +%Y%m%dT%H%M%SZ)_${safe_command}}"
  local meta_file="$JOBS_DIR/${job_id}.env"
  local log_file="$JOBS_DIR/${job_id}.log"
  local status_file="$JOBS_DIR/${job_id}.exit"
  local child_pid_file="$JOBS_DIR/${job_id}.child.pid"
  local runner_file="$JOBS_DIR/${job_id}.runner.sh"
  local started_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [ -e "$meta_file" ] || [ -e "$log_file" ] || [ -e "$status_file" ] || [ -e "$child_pid_file" ]; then
    die "Background job id already exists: ${job_id}"
  fi

  if [ -z "$output_file" ]; then
    if [ "$command" = "full-address" ]; then
      output_file="out/runpod_address_${job_id}.jsonl"
    else
      output_file="out/runpod_full_${job_id}.jsonl"
    fi
  fi

  mkdir -p "$(dirname "$output_file")"
  write_job_runner "$runner_file" "$output_var" "$output_file" "$status_file" "$child_pid_file" "$command" "$@"

  local pid
  if have nohup; then
    nohup bash "$runner_file" > "$log_file" 2>&1 < /dev/null &
  else
    bash "$runner_file" > "$log_file" 2>&1 < /dev/null &
  fi
  pid="$!"

  write_job_meta "$meta_file" "$job_id" "$pid" "$command" "$output_file" "$log_file" "$status_file" "$runner_file" "$child_pid_file" "$started_at" "$@"

  log "Started background job"
  printf 'job_id=%s\npid=%s\ncommand=%s\noutput=%s\nlog=%s\n' "$job_id" "$pid" "$command" "$output_file" "$log_file"
  printf '\nCheck status:\n  bash runpod/run.sh bg-status %s\n' "$job_id"
  printf 'Tail log:\n  bash runpod/run.sh bg-tail %s\n' "$job_id"
  printf 'Stop job:\n  bash runpod/run.sh bg-stop %s\n' "$job_id"
}

print_job_progress() {
  local output_file="$1"
  local python_bin
  python_bin="$(status_python)"

  "$python_bin" - "$output_file" "out/gpu_workload.json" <<'PY'
import json
import sys
from pathlib import Path

output = Path(sys.argv[1])
workload_path = Path(sys.argv[2])

total = None
if workload_path.exists():
    try:
        workload = json.loads(workload_path.read_text())
        total = workload.get("total_combinations", workload.get("total_exact_length_combinations"))
    except Exception:
        total = None

if not output.exists() or output.stat().st_size == 0:
    print("progress_rows=0")
    print("progress_note=no completed chunks written yet")
    sys.exit(0)
else:
    rows = []
    with output.open() as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass

    if not rows:
        print("progress_rows=0")
        print("progress_note=no parseable completed chunks yet")
    else:
        intervals = sorted((int(row["start"]), int(row["start"]) + int(row["count"]), row) for row in rows)
        range_start = intervals[0][0]
        range_stop = max(stop for _start, stop, _row in intervals)
        count_sum = sum(int(row.get("count", 0)) for row in rows)
        elapsed_sum = sum(float(row.get("elapsed_seconds", 0.0)) for row in rows)
        checksum_sum = sum(int(row.get("checksum_valid", 0)) for row in rows)
        derivation_sum = sum(int(row.get("address_derivations", 0)) for row in rows)
        hit_rows = [row for row in rows if row.get("hit_found") is True]
        last = rows[-1]
        combos_per_second = count_sum / elapsed_sum if elapsed_sum else 0.0
        derivations_per_second = derivation_sum / elapsed_sum if elapsed_sum else 0.0
        progress = (range_stop / total) if total else None
        eta_seconds = ((total - range_stop) / combos_per_second) if total and combos_per_second and range_stop <= total else None

        print(f"progress_rows={len(rows)}")
        print(f"range_start={range_start}")
        print(f"range_stop={range_stop}")
        print(f"candidate_count_sum={count_sum}")
        if total is not None:
            print(f"expected_total_candidates={total}")
        if progress is not None:
            print(f"progress_percent={progress * 100:.6f}")
        print(f"checksum_valid={checksum_sum}")
        print(f"address_derivations={derivation_sum}")
        print(f"weighted_combos_per_second={combos_per_second:.2f}")
        print(f"weighted_address_derivations_per_second={derivations_per_second:.2f}")
        if eta_seconds is not None:
            print(f"eta_seconds={eta_seconds:.0f}")
            print(f"eta_hours={eta_seconds / 3600:.2f}")
        print(f"last_chunk_start={last.get('start')}")
        print(f"last_chunk_count={last.get('count')}")
        print(f"last_chunk_elapsed_seconds={last.get('elapsed_seconds')}")
        if "address_derivations_per_second" in last:
            print(f"last_address_derivations_per_second={last.get('address_derivations_per_second')}")
        if "queue_overflow" in last:
            print(f"last_queue_overflow={str(last.get('queue_overflow')).lower()}")
        if hit_rows:
            hit = hit_rows[-1]
            print("hit_found=true")
            print(f"hit_global={hit.get('hit_global')}")
            print(f"hit_mnemonic={hit.get('hit_mnemonic')}")
        else:
            print("hit_found=false")
PY
}

run_bg_status() {
  local meta_file
  meta_file="$(resolve_job_meta "${1:-latest}")"
  # shellcheck disable=SC1090
  source "$meta_file"

  local state
  state="$(job_state "$PID" "$STATUS_FILE")"

  printf 'job_id=%s\n' "$JOB_ID"
  printf 'state=%s\n' "$state"
  printf 'pid=%s\n' "$PID"
  if [ -s "${CHILD_PID_FILE:-}" ]; then
    printf 'child_pid=%s\n' "$(head -n 1 "$CHILD_PID_FILE")"
  fi
  printf 'started_at=%s\n' "$STARTED_AT"
  printf 'command=%s\n' "$COMMAND"
  if [ "${#ARGS[@]}" -gt 0 ]; then
    printf 'args='
    printf '%q ' "${ARGS[@]}"
    printf '\n'
  fi
  printf 'output=%s\n' "$OUTPUT_FILE"
  printf 'log=%s\n' "$LOG_FILE"
  if [ -s "$STATUS_FILE" ]; then
    printf 'exit_code=%s\n' "$(head -n 1 "$STATUS_FILE")"
  fi
  print_job_progress "$OUTPUT_FILE"
}

run_bg_list() {
  mkdir -p "$JOBS_DIR"
  local found=0
  local meta
  for meta in "$JOBS_DIR"/*.env; do
    if [ ! -f "$meta" ]; then
      continue
    fi
    found=1
    (
      # shellcheck disable=SC1090
      source "$meta"
      printf '%s\t%s\t%s\t%s\n' "$JOB_ID" "$(job_state "$PID" "$STATUS_FILE")" "$PID" "$COMMAND"
    )
  done
  if [ "$found" -eq 0 ]; then
    die "No background jobs found under ${JOBS_DIR}"
  fi
}

run_bg_tail() {
  local follow=0
  if [ "${1:-}" = "-f" ] || [ "${1:-}" = "--follow" ]; then
    follow=1
    shift
  fi
  local meta_file
  meta_file="$(resolve_job_meta "${1:-latest}")"
  local lines="${2:-80}"
  # shellcheck disable=SC1090
  source "$meta_file"
  if [ "$follow" -eq 1 ]; then
    tail -n "$lines" -f "$LOG_FILE"
  else
    tail -n "$lines" "$LOG_FILE"
  fi
}

run_bg_stop() {
  local meta_file
  meta_file="$(resolve_job_meta "${1:-latest}")"
  # shellcheck disable=SC1090
  source "$meta_file"

  local state
  state="$(job_state "$PID" "$STATUS_FILE")"
  if [ "$state" != "running" ]; then
    printf 'job_id=%s\nstate=%s\npid=%s\n' "$JOB_ID" "$state" "$PID"
    return
  fi

  log "Stopping background job ${JOB_ID} pid=${PID}"
  kill "$PID"
  sleep 2
  if kill -0 "$PID" >/dev/null 2>&1; then
    warn "Job is still running after SIGTERM. Use bg-kill if you need to force it."
  elif [ -s "${CHILD_PID_FILE:-}" ]; then
    local child_pid
    child_pid="$(head -n 1 "$CHILD_PID_FILE")"
    if kill -0 "$child_pid" >/dev/null 2>&1; then
      warn "Child process is still running after SIGTERM; stopping child pid=${child_pid}."
      kill "$child_pid" >/dev/null 2>&1 || true
    fi
  fi
  run_bg_status "$JOB_ID"
}

run_bg_kill() {
  local meta_file
  meta_file="$(resolve_job_meta "${1:-latest}")"
  # shellcheck disable=SC1090
  source "$meta_file"
  log "Force killing background job ${JOB_ID} pid=${PID}"
  if [ -s "${CHILD_PID_FILE:-}" ]; then
    local child_pid
    child_pid="$(head -n 1 "$CHILD_PID_FILE")"
    kill -9 "$child_pid" >/dev/null 2>&1 || true
  fi
  kill -9 "$PID" >/dev/null 2>&1 || true
  run_bg_status "$JOB_ID"
}

detect_gpu_list() {
  if [ -n "${GPUS:-}" ]; then
    printf '%s\n' "$GPUS"
    return
  fi
  if have nvidia-smi; then
    local detected
    detected="$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | awk 'BEGIN { sep="" } { gsub(/[[:space:]]/, "", $1); if ($1 != "") { printf "%s%s", sep, $1; sep="," } } END { print "" }')"
    if [ -n "$detected" ]; then
      printf '%s\n' "$detected"
      return
    fi
  fi
  die "Could not detect GPUs. Pass --gpus 0,1 or set GPUS=0,1."
}

latest_multi_meta() {
  local latest
  latest="$(ls -t "$MULTI_DIR"/*.env 2>/dev/null | head -n 1 || true)"
  if [ -z "$latest" ]; then
    die "No multi-GPU runs found under ${MULTI_DIR}"
  fi
  printf '%s\n' "$latest"
}

resolve_multi_meta() {
  local multi_id="${1:-latest}"
  if [ "$multi_id" = "latest" ]; then
    latest_multi_meta
    return
  fi
  if [ -f "$multi_id" ]; then
    printf '%s\n' "$multi_id"
    return
  fi
  if [ -f "$MULTI_DIR/${multi_id}.env" ]; then
    printf '%s\n' "$MULTI_DIR/${multi_id}.env"
    return
  fi
  die "Multi-GPU run not found: ${multi_id}"
}

write_multi_meta() {
  local meta_file="$1"
  local multi_id="$2"
  local command="$3"
  local gpus="$4"
  local start="$5"
  local stop="$6"
  local chunk="$7"
  local started_at="$8"
  shift 8

  {
    printf 'MULTI_ID=%q\n' "$multi_id"
    printf 'COMMAND=%q\n' "$command"
    printf 'GPUS=%q\n' "$gpus"
    printf 'START=%q\n' "$start"
    printf 'STOP=%q\n' "$stop"
    printf 'CHUNK=%q\n' "$chunk"
    printf 'STARTED_AT=%q\n' "$started_at"
    printf 'JOB_IDS=('
    local item
    for item in "$@"; do
      printf ' %q' "$item"
    done
    printf ' )\n'
  } > "$meta_file"
}

multi_output_for_job() {
  local job_id="$1"
  local meta_file
  meta_file="$(resolve_job_meta "$job_id")"
  (
    # shellcheck disable=SC1090
    source "$meta_file"
    printf '%s\n' "$OUTPUT_FILE"
  )
}

print_multi_progress() {
  local start="$1"
  local stop="$2"
  shift 2
  local python_bin
  python_bin="$(status_python)"

  "$python_bin" - "$start" "$stop" "$@" <<'PY'
import json
import sys
from pathlib import Path

start = int(sys.argv[1])
stop = int(sys.argv[2])
outputs = [Path(path) for path in sys.argv[3:]]
span = stop - start

rows = []
missing = []
for output in outputs:
    if not output.exists():
        missing.append(str(output))
        continue
    with output.open() as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            row["_path"] = str(output)
            rows.append(row)

if not rows:
    print("progress_rows=0")
    if missing:
        print("missing_outputs=" + ",".join(missing))
    print("progress_note=no completed chunks written yet")
    sys.exit(0)

intervals = sorted((int(row["start"]), int(row["start"]) + int(row["count"]), row) for row in rows)
count_sum = sum(int(row.get("count", 0)) for row in rows)
elapsed_sum = sum(float(row.get("elapsed_seconds", 0.0)) for row in rows)
checksum_sum = sum(int(row.get("checksum_valid", 0)) for row in rows)
derivation_sum = sum(int(row.get("address_derivations", 0)) for row in rows)
hit_rows = [row for row in rows if row.get("hit_found") is True]
combos_per_second = count_sum / elapsed_sum if elapsed_sum else 0.0
derivations_per_second = derivation_sum / elapsed_sum if elapsed_sum else 0.0
progress = count_sum / span if span > 0 else 0.0
eta_seconds = (span - count_sum) / combos_per_second if combos_per_second and count_sum <= span else None

gaps = []
overlaps = []
cursor = start
for interval_start, interval_stop, _row in intervals:
    if interval_stop <= start or interval_start >= stop:
        continue
    clipped_start = max(interval_start, start)
    clipped_stop = min(interval_stop, stop)
    if clipped_start > cursor:
        gaps.append({"start": cursor, "stop": clipped_start, "count": clipped_start - cursor})
    elif clipped_start < cursor:
        overlaps.append({"start": clipped_start, "stop": min(clipped_stop, cursor), "count": min(clipped_stop, cursor) - clipped_start})
    cursor = max(cursor, clipped_stop)
if cursor < stop:
    gaps.append({"start": cursor, "stop": stop, "count": stop - cursor})

print(f"progress_rows={len(rows)}")
print(f"candidate_count_sum={count_sum}")
print(f"range_start={start}")
print(f"range_stop={stop}")
print(f"progress_percent={progress * 100:.6f}")
print(f"checksum_valid={checksum_sum}")
print(f"address_derivations={derivation_sum}")
print(f"weighted_combos_per_second={combos_per_second:.2f}")
print(f"weighted_address_derivations_per_second={derivations_per_second:.2f}")
if eta_seconds is not None:
    print(f"eta_seconds={eta_seconds:.0f}")
    print(f"eta_hours={eta_seconds / 3600:.2f}")
print(f"gap_count={len(gaps)}")
print(f"overlap_count={len(overlaps)}")
if gaps:
    first = gaps[0]
    print(f"first_gap={first['start']}..{first['stop']}")
if overlaps:
    first = overlaps[0]
    print(f"first_overlap={first['start']}..{first['stop']}")
if missing:
    print("missing_outputs=" + ",".join(missing))
if hit_rows:
    hit = hit_rows[-1]
    print("hit_found=true")
    print(f"hit_output={hit.get('_path')}")
    print(f"hit_global={hit.get('hit_global')}")
    print(f"hit_mnemonic={hit.get('hit_mnemonic')}")
else:
    print("hit_found=false")
PY
}

run_multi_start() {
  local command="full-address"
  if [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; then
    command="$1"
    shift
  fi

  case "$command" in
    full-address|address-full|full-oracle)
      command="full-address"
      ;;
    full|all)
      command="full"
      ;;
    *)
      die "multi-start supports full-address and full, got: ${command}"
      ;;
  esac

  local gpus="${GPUS:-}"
  local multi_id="${MULTI_ID:-}"
  local output_dir="${MULTI_OUTPUT_DIR:-out}"
  local start="${MULTI_START:-0}"
  local stop="${MULTI_STOP:-}"
  local chunk=""

  if [ "$command" = "full-address" ]; then
    chunk="${ADDRESS_CHUNK:-$DEFAULT_ADDRESS_CHUNK}"
  else
    chunk="${FULL_CHUNK:-$DEFAULT_FULL_CHUNK}"
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --gpus)
        gpus="$2"
        shift 2
        ;;
      --id|--job-prefix|--prefix)
        multi_id="$2"
        shift 2
        ;;
      --output-dir)
        output_dir="$2"
        shift 2
        ;;
      --start)
        start="$2"
        shift 2
        ;;
      --stop)
        stop="$2"
        shift 2
        ;;
      --chunk)
        chunk="$2"
        shift 2
        ;;
      *)
        die "Unknown multi-start option: $1"
        ;;
    esac
  done

  ensure_ready
  local total
  total="$(total_combinations)"
  if [ -z "$stop" ]; then
    stop="$total"
  fi
  if [ "$start" -lt 0 ] || [ "$stop" -lt 0 ] || [ "$start" -ge "$stop" ] || [ "$stop" -gt "$total" ]; then
    die "invalid multi range: start=${start}, stop=${stop}, total=${total}"
  fi
  if [ "$chunk" -le 0 ]; then
    die "multi chunk size must be positive"
  fi

  if [ -z "$gpus" ]; then
    gpus="$(detect_gpu_list)"
  fi

  local gpu_array
  IFS=',' read -r -a gpu_array <<< "$gpus"
  local gpu_count="${#gpu_array[@]}"
  if [ "$gpu_count" -le 0 ]; then
    die "no GPUs specified"
  fi

  mkdir -p "$MULTI_DIR" "$output_dir"
  if [ -z "$multi_id" ]; then
    multi_id="$(date -u +%Y%m%dT%H%M%SZ)_${command}_multi"
  fi
  local multi_meta="$MULTI_DIR/${multi_id}.env"
  if [ -e "$multi_meta" ]; then
    die "Multi-GPU run already exists: ${multi_id}"
  fi

  local span=$((stop - start))
  local started_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local job_ids=()

  log "Launching multi-GPU ${command} run"
  printf 'multi_id=%s\ngpus=%s\nstart=%s\nstop=%s\nchunk=%s\n' "$multi_id" "$gpus" "$start" "$stop" "$chunk"

  local i
  for ((i = 0; i < gpu_count; i++)); do
    local gpu="${gpu_array[$i]}"
    local shard_start=$((start + (span * i / gpu_count)))
    local shard_stop=$((start + (span * (i + 1) / gpu_count)))
    local safe_gpu
    safe_gpu="$(printf '%s' "$gpu" | tr -c 'A-Za-z0-9' '_')"
    local job_id="${multi_id}_gpu${safe_gpu}"
    local output_file
    if [ "$command" = "full-address" ]; then
      output_file="${output_dir}/runpod_address_${job_id}.jsonl"
      (
        export CUDA_VISIBLE_DEVICES="$gpu"
        export RUNPOD_SKIP_SETUP=1
        export JOB_ID="$job_id"
        export ADDRESS_OUTPUT="$output_file"
        export ADDRESS_START="$shard_start"
        export ADDRESS_STOP="$shard_stop"
        export ADDRESS_CHUNK="$chunk"
        run_bg_start "$command"
      )
    else
      output_file="${output_dir}/runpod_full_${job_id}.jsonl"
      (
        export CUDA_VISIBLE_DEVICES="$gpu"
        export RUNPOD_SKIP_SETUP=1
        export JOB_ID="$job_id"
        export FULL_OUTPUT="$output_file"
        export FULL_START="$shard_start"
        export FULL_STOP="$shard_stop"
        export FULL_CHUNK="$chunk"
        run_bg_start "$command"
      )
    fi
    job_ids+=("$job_id")
    printf 'gpu=%s job_id=%s start=%s stop=%s output=%s\n' "$gpu" "$job_id" "$shard_start" "$shard_stop" "$output_file"
  done

  write_multi_meta "$multi_meta" "$multi_id" "$command" "$gpus" "$start" "$stop" "$chunk" "$started_at" "${job_ids[@]}"

  log "Multi-GPU run started"
  printf 'Check all shards:\n  bash runpod/run.sh multi-status %s\n' "$multi_id"
  printf 'List shard jobs:\n  bash runpod/run.sh multi-list\n'
  printf 'Stop all shards:\n  bash runpod/run.sh multi-stop %s\n' "$multi_id"
}

run_multi_status() {
  local meta_file
  meta_file="$(resolve_multi_meta "${1:-latest}")"
  # shellcheck disable=SC1090
  source "$meta_file"

  printf 'multi_id=%s\n' "$MULTI_ID"
  printf 'command=%s\n' "$COMMAND"
  printf 'gpus=%s\n' "$GPUS"
  printf 'started_at=%s\n' "$STARTED_AT"
  printf 'start=%s\nstop=%s\nchunk=%s\n' "$START" "$STOP" "$CHUNK"
  printf 'shards=%s\n' "${#JOB_IDS[@]}"

  local outputs=()
  local job_id
  for job_id in "${JOB_IDS[@]}"; do
    local job_meta
    job_meta="$(resolve_job_meta "$job_id")"
    (
      # shellcheck disable=SC1090
      source "$job_meta"
      printf 'shard=%s state=%s pid=%s output=%s\n' "$JOB_ID" "$(job_state "$PID" "$STATUS_FILE")" "$PID" "$OUTPUT_FILE"
    )
    outputs+=("$(multi_output_for_job "$job_id")")
  done

  print_multi_progress "$START" "$STOP" "${outputs[@]}"
}

run_multi_list() {
  mkdir -p "$MULTI_DIR"
  local found=0
  local meta
  for meta in "$MULTI_DIR"/*.env; do
    if [ ! -f "$meta" ]; then
      continue
    fi
    found=1
    (
      # shellcheck disable=SC1090
      source "$meta"
      printf '%s\t%s\t%s\t%s\t%s\n' "$MULTI_ID" "$COMMAND" "$GPUS" "$START" "$STOP"
    )
  done
  if [ "$found" -eq 0 ]; then
    die "No multi-GPU runs found under ${MULTI_DIR}"
  fi
}

run_multi_stop() {
  local meta_file
  meta_file="$(resolve_multi_meta "${1:-latest}")"
  # shellcheck disable=SC1090
  source "$meta_file"
  local job_id
  for job_id in "${JOB_IDS[@]}"; do
    run_bg_stop "$job_id"
  done
}

run_multi_kill() {
  local meta_file
  meta_file="$(resolve_multi_meta "${1:-latest}")"
  # shellcheck disable=SC1090
  source "$meta_file"
  local job_id
  for job_id in "${JOB_IDS[@]}"; do
    run_bg_kill "$job_id"
  done
}

run_multi_tail() {
  local meta_file
  meta_file="$(resolve_multi_meta "${1:-latest}")"
  local shard="${2:-0}"
  local lines="${3:-80}"
  # shellcheck disable=SC1090
  source "$meta_file"

  local job_id=""
  if [ "$shard" -ge 0 ] 2>/dev/null && [ "$shard" -lt "${#JOB_IDS[@]}" ]; then
    job_id="${JOB_IDS[$shard]}"
  else
    job_id="$shard"
  fi
  run_bg_tail "$job_id" "$lines"
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
  bash runpod/run.sh bg-start [full-address|full] [command_args...]
  bash runpod/run.sh bg-status [job_id|latest]
  bash runpod/run.sh bg-list
  bash runpod/run.sh bg-tail [-f] [job_id|latest] [lines]
  bash runpod/run.sh bg-stop [job_id|latest]
  bash runpod/run.sh bg-kill [job_id|latest]
  bash runpod/run.sh multi-start [full-address|full] --gpus 0,1 [options]
  bash runpod/run.sh multi-status [multi_id|latest]
  bash runpod/run.sh multi-summary [multi_id|latest]
  bash runpod/run.sh multi-list
  bash runpod/run.sh multi-tail [multi_id|latest] [shard_index|job_id] [lines]
  bash runpod/run.sh multi-stop [multi_id|latest]
  bash runpod/run.sh multi-kill [multi_id|latest]
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
  bash runpod/run.sh bg-start full-address
  bash runpod/run.sh bg-status
  bash runpod/run.sh bg-tail -f
  bash runpod/run.sh multi-start full-address --gpus 0,1 --id full_address_2gpu --chunk 1000000000
  bash runpod/run.sh multi-status full_address_2gpu
  ADDRESS_OUTPUT=out/address.jsonl bash runpod/run.sh full-address 1000000000
  ADDRESS_OUTPUT=out/address.jsonl bash runpod/run.sh bg-start full-address 1000000000
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
  ADDRESS_CHUNK=1000000000 bash runpod/run.sh bg-start full-address
  ADDRESS_START=1000000000 bash runpod/run.sh full-address
  JOB_ID=blackwell_full_search bash runpod/run.sh bg-start full-address
  MULTI_ID=full_address_4gpu bash runpod/run.sh multi-start full-address --gpus 0,1,2,3 --chunk 1000000000

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
    bg-start|background-start|start-bg)
      run_bg_start "$@"
      ;;
    bg-status|background-status|status)
      run_bg_status "$@"
      ;;
    bg-list|background-list|jobs)
      run_bg_list "$@"
      ;;
    bg-tail|background-tail|tail-bg)
      run_bg_tail "$@"
      ;;
    bg-stop|background-stop|stop-bg)
      run_bg_stop "$@"
      ;;
    bg-kill|background-kill|kill-bg)
      run_bg_kill "$@"
      ;;
    multi-start|multi-gpu-start|start-multi)
      run_multi_start "$@"
      ;;
    multi-status|multi-summary|multi-gpu-status|status-multi)
      run_multi_status "$@"
      ;;
    multi-list|multi-gpu-list)
      run_multi_list "$@"
      ;;
    multi-tail|multi-gpu-tail)
      run_multi_tail "$@"
      ;;
    multi-stop|multi-gpu-stop|stop-multi)
      run_multi_stop "$@"
      ;;
    multi-kill|multi-gpu-kill|kill-multi)
      run_multi_kill "$@"
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
