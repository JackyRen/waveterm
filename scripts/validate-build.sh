#!/usr/bin/env bash
set -u

# Stable build verification script for local/dev CI usage.
# - Runs checks in phases
# - Uses per-step timeout
# - Always writes logs per step
# - Continues execution after step failures and reports a final summary

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/.tmp/build-verify-logs}"
TIMEOUT_SEC="${TIMEOUT_SEC:-300}"
RUN_FRONTEND="1"
RUN_GO="1"
RUN_TESTS="1"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --timeout <seconds>     Per-step timeout (default: ${TIMEOUT_SEC})
  --log-dir <path>        Log directory (default: ${LOG_DIR})
  --skip-frontend         Skip frontend build phase
  --skip-go               Skip Go build phase
  --skip-tests            Skip test phase
  -h, --help              Show help

Examples:
  scripts/validate-build.sh
  scripts/validate-build.sh --timeout 180
  scripts/validate-build.sh --skip-frontend
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --timeout)
        TIMEOUT_SEC="$2"
        shift 2
        ;;
    --log-dir)
        LOG_DIR="$2"
        shift 2
        ;;
    --skip-frontend)
        RUN_FRONTEND="0"
        shift
        ;;
    --skip-go)
        RUN_GO="0"
        shift
        ;;
    --skip-tests)
        RUN_TESTS="0"
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        usage
        exit 2
        ;;
    esac
done

if ! [[ "$TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_SEC" -le 0 ]]; then
    echo "Invalid timeout: ${TIMEOUT_SEC}" >&2
    exit 2
fi

mkdir -p "$LOG_DIR"

PASS_STEPS=()
FAIL_STEPS=()
SKIP_STEPS=()

run_step() {
    local step_name="$1"
    local log_file="$2"
    shift 2

    echo
    echo "==> [${step_name}]"
    echo "    log: ${log_file}"

    set +e
    timeout "${TIMEOUT_SEC}s" "$@" >"${log_file}" 2>&1
    local exit_code=$?
    set -e

    case "$exit_code" in
    0)
        echo "    result: PASS"
        PASS_STEPS+=("${step_name}")
        ;;
    124)
        echo "    result: FAIL (timeout after ${TIMEOUT_SEC}s)"
        FAIL_STEPS+=("${step_name} [timeout]")
        ;;
    *)
        echo "    result: FAIL (exit ${exit_code})"
        FAIL_STEPS+=("${step_name} [exit ${exit_code}]")
        ;;
    esac
}

set -e
cd "$ROOT_DIR"

echo "Build verification root: ${ROOT_DIR}"
echo "Logs directory: ${LOG_DIR}"
echo "Per-step timeout: ${TIMEOUT_SEC}s"

if [[ "$RUN_GO" == "1" ]]; then
    run_step "go-build-core" "${LOG_DIR}/go-build-core.log" go build ./cmd/server ./cmd/wsh
else
    SKIP_STEPS+=("go-build-core")
fi

if [[ "$RUN_FRONTEND" == "1" ]]; then
    run_step "frontend-build-dev" "${LOG_DIR}/frontend-build-dev.log" npm run build:dev
else
    SKIP_STEPS+=("frontend-build-dev")
fi

if [[ "$RUN_TESTS" == "1" ]]; then
    run_step "go-test-suggestions-rpc" "${LOG_DIR}/go-test-suggestions-rpc.log" go test ./pkg/suggestion ./pkg/wshrpc/...
    run_step "vitest-smoke" "${LOG_DIR}/vitest-smoke.log" npm run test -- --run frontend/app/store/global-atoms.test.ts
else
    SKIP_STEPS+=("go-test-suggestions-rpc" "vitest-smoke")
fi

echo
printf 'Summary:\n'
printf '  PASS: %s\n' "${#PASS_STEPS[@]}"
for s in "${PASS_STEPS[@]}"; do
    printf '    - %s\n' "$s"
done
printf '  FAIL: %s\n' "${#FAIL_STEPS[@]}"
for s in "${FAIL_STEPS[@]}"; do
    printf '    - %s\n' "$s"
done
printf '  SKIP: %s\n' "${#SKIP_STEPS[@]}"
for s in "${SKIP_STEPS[@]}"; do
    printf '    - %s\n' "$s"
done

echo
if [[ ${#FAIL_STEPS[@]} -gt 0 ]]; then
    echo "Build verification failed. Inspect logs under: ${LOG_DIR}" >&2
    exit 1
fi

echo "Build verification passed."
