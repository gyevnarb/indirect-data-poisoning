#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Usage: fix_ownership.sh
#   Recursively transfers ownership of everything in the workspace folder
#   to the current user.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${SCRIPT_DIR}/workspace"
LOGS_ROOT="${SCRIPT_DIR}/logs"
CACHE_ROOT="${SCRIPT_DIR}/cache"

if [[ ! -d "$WORKSPACE_ROOT" ]]; then
    echo "Error: workspace directory not found at '$WORKSPACE_ROOT'" >&2
    exit 1
fi

if [[ ! -d "$LOGS_ROOT" ]]; then
    echo "Error: logs directory not found at '$LOGS_ROOT'" >&2
    exit 1
fi

if [[ ! -d "$CACHE_ROOT" ]]; then
    echo "Error: cache directory not found at '$CACHE_ROOT'" >&2
    exit 1
fi

CURRENT_USER="$(id -u):$(id -g)"

echo "Changing ownership of '$WORKSPACE_ROOT' to ${CURRENT_USER} ($(whoami))..."
sudo chown -R "$CURRENT_USER" "$WORKSPACE_ROOT"
echo "Changing ownership of '$LOGS_ROOT' to ${CURRENT_USER} ($(whoami))..."
sudo chown -R "$CURRENT_USER" "$LOGS_ROOT"
echo "Changing ownership of '$CACHE_ROOT' to ${CURRENT_USER} ($(whoami))..."
sudo chown -R "$CURRENT_USER" "$CACHE_ROOT"
echo "Done."
