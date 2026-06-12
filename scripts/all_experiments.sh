#!/usr/bin/env bash
set -euo pipefail

# Usage: all_experiments.sh [-n] [-s] [--build] [AGENT] [-- EXTRA_ARGS...]
#
# Runs batch_run.sh for every top-level experiment ID in experiments.json.
# Defaults to running them in parallel; pass -s to run sequentially instead.
# AGENT, if given, is forwarded as `-a AGENT` (codex|claude|fable|gemini).
# Anything after `--` is forwarded verbatim to batch_run.sh (and onward to
# run_intervention.sh), e.g.:
#   all_experiments.sh codex -- -k 2 --some-flag
#   all_experiments.sh fable -- -k 2            # Claude CLI with the claude-fable-5 model

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTS_FILE="${SCRIPT_DIR}/experiments.json"
BATCH_SCRIPT="${SCRIPT_DIR}/batch_run.sh"

DRYRUN=false
BUILD=false
SEQUENTIAL=false
AGENT=""
EXTRA_ARGS=()

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [-n] [-s] [--build] [AGENT] [-- EXTRA_ARGS...]" >&2
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) DRYRUN=true; shift ;;
        -s) SEQUENTIAL=true; shift ;;
        --build) BUILD=true; shift ;;
        -h|--help)
            echo "Usage: $0 [-n] [-s] [--build] [AGENT] [-- EXTRA_ARGS...]" >&2
            exit 0
            ;;
        --)
            shift
            EXTRA_ARGS=( "$@" )
            break
            ;;
        -*)
            echo "Error: unknown option '$1'." >&2
            exit 1
            ;;
        *)
            if [[ -n "$AGENT" ]]; then
                echo "Error: unexpected extra argument '$1' (use -- to forward extra args)." >&2
                exit 1
            fi
            AGENT="$1"
            shift
            ;;
    esac
done

if ! command -v jq > /dev/null 2>&1; then
    echo "Error: jq command not found in PATH." >&2
    exit 1
fi

if [[ ! -f "$EXPERIMENTS_FILE" ]]; then
    echo "Error: $EXPERIMENTS_FILE not found." >&2
    exit 1
fi

mapfile -t EXPERIMENT_IDS < <(jq -r 'keys[]' "$EXPERIMENTS_FILE")

if [[ ${#EXPERIMENT_IDS[@]} -eq 0 ]]; then
    echo "Error: no experiment IDs found in $EXPERIMENTS_FILE." >&2
    exit 1
fi

COMMON_ARGS=()
[[ "$DRYRUN" == "true" ]] && COMMON_ARGS+=( -n )

# batch_run.sh expects: [batch flags] DATA_ID [run_intervention options...]
# AGENT (-a) and any user-supplied EXTRA_ARGS belong in the run_intervention
# options slot, after the data id.
FORWARD_ARGS=()
[[ -n "$AGENT" ]] && FORWARD_ARGS+=( -a "$AGENT" )
FORWARD_ARGS+=( "${EXTRA_ARGS[@]}" )

# Run the first experiment with --build so the Docker image is built exactly
# once; remaining experiments reuse the cached image.
if [[ "$BUILD" == "true" ]]; then
    FIRST_ID="${EXPERIMENT_IDS[0]}"
    EXPERIMENT_IDS=( "${EXPERIMENT_IDS[@]:1}" )
    BUILD_BATCH_FLAGS=( "${COMMON_ARGS[@]}" --build )
    [[ "$SEQUENTIAL" == "true" ]] && BUILD_BATCH_FLAGS+=( -s )
    echo "Building image and launching first experiment ($FIRST_ID)..."
    "$BATCH_SCRIPT" "${BUILD_BATCH_FLAGS[@]}" "$FIRST_ID" "${FORWARD_ARGS[@]}"
fi

if [[ "$SEQUENTIAL" == "true" ]]; then
    echo "Running ${#EXPERIMENT_IDS[@]} experiment(s) sequentially${AGENT:+ (agent=$AGENT)}..."
    status=0
    for ID in "${EXPERIMENT_IDS[@]}"; do
        echo "  -> $ID"
        # Pass -s to batch_run.sh so it runs containers without -d and
        # blocks until they exit before we move on to the next experiment.
        if ! "$BATCH_SCRIPT" "${COMMON_ARGS[@]}" -s "$ID" "${FORWARD_ARGS[@]}"; then
            status=1
        fi
    done
    exit "$status"
fi

echo "Launching ${#EXPERIMENT_IDS[@]} experiment(s) in parallel${AGENT:+ (agent=$AGENT)}..."

pids=()
for ID in "${EXPERIMENT_IDS[@]}"; do
    echo "  -> $ID"
    "$BATCH_SCRIPT" "${COMMON_ARGS[@]}" "$ID" "${FORWARD_ARGS[@]}" &
    pids+=( $! )
done

status=0
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        status=1
    fi
done

exit "$status"
