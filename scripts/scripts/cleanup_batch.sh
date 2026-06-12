#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Usage: run_batch_cleanup.sh [BATCH_ID]
#
# Stops and removes all containers started by run_batch.sh for the given batch.
# If BATCH_ID is omitted, the latest batch from scripts/workspace/.latest_batch
# is used.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${SCRIPT_DIR}/workspace"
LATEST_BATCH_FILE="${WORKSPACE_ROOT}/.latest_batch"

if ! command -v docker > /dev/null 2>&1; then
    echo "Error: docker command not found in PATH." >&2
    exit 1
fi

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [BATCH_ID]" >&2
    exit 1
fi

if [[ $# -eq 1 ]]; then
    BATCH_ID="$1"
else
    if [[ ! -f "$LATEST_BATCH_FILE" ]]; then
        echo "Error: no latest batch marker found at '$LATEST_BATCH_FILE'." >&2
        echo "Provide a BATCH_ID explicitly: $0 <BATCH_ID>" >&2
        exit 1
    fi

    BATCH_ID="$(<"$LATEST_BATCH_FILE")"
    if [[ -z "$BATCH_ID" ]]; then
        echo "Error: latest batch marker is empty: '$LATEST_BATCH_FILE'." >&2
        exit 1
    fi
fi

CONTAINERS_FILE="${WORKSPACE_ROOT}/${BATCH_ID}/containers.txt"

declare -a CONTAINERS

if [[ -f "$CONTAINERS_FILE" ]]; then
    mapfile -t CONTAINERS < "$CONTAINERS_FILE"
else
    mapfile -t CONTAINERS < <(
        docker ps -aq --filter "label=datasets.batch_id=${BATCH_ID}"
    )
fi

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    echo "No containers found for batch '$BATCH_ID'."
    exit 0
fi

echo "Cleaning up ${#CONTAINERS[@]} container(s) for batch '$BATCH_ID'..."
for container in "${CONTAINERS[@]}"; do
    [[ -z "$container" ]] && continue

    if docker ps -aq --filter "name=^/${container}$" | grep -q .; then
        docker rm -f "$container" > /dev/null
        echo "  Removed: $container"
    elif docker ps -aq --filter "id=${container}" | grep -q .; then
        docker rm -f "$container" > /dev/null
        echo "  Removed: $container"
    else
        echo "  Skipped (not found): $container"
    fi
done

echo "Done."
