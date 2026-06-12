#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Usage: run_batch.sh [-n] [-s] [--build] <DATA_ID> [RUN_INTERVENTION_OPTIONS...]
#
# Starts one Docker container per CONDITION_ID found in interventions.json for
# the provided DATA_ID. Each container runs run_intervention.sh filtered to a
# single condition via -c.
#
# Examples:
#   ./run_batch.sh 6jmfx
#   ./run_batch.sh -n 6jmfx -a codex -k 2
#   ./run_batch.sh 6jmfx -a fable -k 2          # Claude CLI with the claude-fable-5 model
#   ./run_batch.sh -s 6jmfx -a codex -k 2       # serial: wait for each container
#   ./run_batch.sh --build 6jmfx -a codex -k 2
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="exp-sandbox"
BUILD_IMAGE=false
DRYRUN=false
SERIAL=false

run() {
    if [[ "$DRYRUN" == "true" ]]; then
        printf '[dryrun]'
        for arg in "$@"; do
            printf ' %q' "$arg"
        done
        printf '\n'
    else
        "$@"
    fi
}

validate_ssh_for_build() {
    if [[ "$DRYRUN" == "true" ]]; then
        echo "[dryrun] eval \$(ssh-agent -s)"
        echo "[dryrun] ssh-add ~/.ssh/id_ed25519 2>/dev/null || ssh-add ~/.ssh/id_rsa"
        return
    fi

    if ! command -v ssh-agent > /dev/null 2>&1; then
        echo "Error: ssh-agent command not found in PATH." >&2
        exit 1
    fi

    if ! command -v ssh-add > /dev/null 2>&1; then
        echo "Error: ssh-add command not found in PATH." >&2
        exit 1
    fi

    eval "$(ssh-agent -s)" > /dev/null
    if ! ssh-add ~/.ssh/id_ed25519 2>/dev/null && ! ssh-add ~/.ssh/id_rsa 2>/dev/null; then
        echo "Error: failed to add SSH key (~/.ssh/id_ed25519 or ~/.ssh/id_rsa) for Docker build." >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n)
            DRYRUN=true
            shift
            ;;
        -s)
            SERIAL=true
            shift
            ;;
        --build)
            BUILD_IMAGE=true
            shift
            ;;
        --)
            shift
            break
            ;;
        -* )
            echo "Error: unknown option '$1'." >&2
            echo "Usage: $0 [-n] [-s] [--build] <DATA_ID> [RUN_INTERVENTION_OPTIONS...]" >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [-n] [-s] [--build] <DATA_ID> [RUN_INTERVENTION_OPTIONS...]" >&2
    exit 1
fi

if [[ "$DRYRUN" != "true" ]] && ! command -v docker > /dev/null 2>&1; then
    echo "Error: docker command not found in PATH." >&2
    exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
    echo "Error: jq command not found in PATH." >&2
    exit 1
fi

DATA_ID="$1"
shift
RUN_INTERVENTION_OPTIONS=("$@")

INTERVENTIONS_FILE="${SCRIPT_DIR}/interventions.json"
EXPERIMENTS_FILE="${SCRIPT_DIR}/experiments.json"
OSF_INDEX_FILE="${SCRIPT_DIR}/osf_inverted_index.json"
RUN_INTERVENTION_SCRIPT="${SCRIPT_DIR}/run_intervention.sh"
ENV_FILE="${SCRIPT_DIR}/.env"

for required_file in "$INTERVENTIONS_FILE" "$EXPERIMENTS_FILE" "$OSF_INDEX_FILE" "$RUN_INTERVENTION_SCRIPT" "$ENV_FILE"; do
    if [[ ! -f "$required_file" ]]; then
        echo "Error: required file not found: $required_file" >&2
        exit 1
    fi
done

if [[ "$BUILD_IMAGE" == "true" ]] || [[ "$DRYRUN" == "true" ]] || ! docker image inspect "$IMAGE_NAME" > /dev/null 2>&1; then
    echo "Validating SSH setup for Docker build..."
    validate_ssh_for_build
    echo "Building Docker image '$IMAGE_NAME' from ${SCRIPT_DIR}/Dockerfile..."
    run env DOCKER_BUILDKIT=1 docker build --ssh default --build-arg "CACHEBUST=$(date +%s)" -t "$IMAGE_NAME" "$SCRIPT_DIR"
fi

mapfile -t CONDITION_IDS < <(
    jq -r --arg id "$DATA_ID" '
        (.[$id] // empty)
        | if type == "object" then keys[] else empty end
    ' "$INTERVENTIONS_FILE"
)

if [[ ${#CONDITION_IDS[@]} -eq 0 ]]; then
    echo "Error: no CONDITION_ID entries found for DATA_ID='$DATA_ID' in '$INTERVENTIONS_FILE'." >&2
    exit 1
fi

AGENT_NAME=""
for ((i=0; i<${#RUN_INTERVENTION_OPTIONS[@]}; i++)); do
    if [[ "${RUN_INTERVENTION_OPTIONS[$i]}" == "-a" ]]; then
        AGENT_NAME="${RUN_INTERVENTION_OPTIONS[$((i+1))]:-}"
        break
    fi
done
AGENT_NAME="${AGENT_NAME:-claude}"
# Read skill name from SKILL.md frontmatter (name: field) if present.
SKILL_NAME=""
if [[ -f "${SCRIPT_DIR}/SKILL.md" ]]; then
    SKILL_NAME=$(grep -m1 '^name:' "${SCRIPT_DIR}/SKILL.md" | sed 's/^name:[[:space:]]*//' | tr -d '"')
fi

# Map agent name to its skill folder root. Fable reuses the Claude CLI and skills.
case "$AGENT_NAME" in
    gemini)       AGENT_SKILL_DIR=".gemini" ;;
    codex)        AGENT_SKILL_DIR=".agents" ;;
    claude|fable) AGENT_SKILL_DIR=".claude" ;;
    *)            AGENT_SKILL_DIR=".claude" ;;
esac

BATCH_ID="${DATA_ID}_${AGENT_NAME}_$(date +%Y%m%d_%H%M%S)"
BATCH_ROOT="${SCRIPT_DIR}/workspace/${BATCH_ID}"
WORKSPACE_ROOT="${SCRIPT_DIR}/workspace"
LOGS_DIR_HOST="${SCRIPT_DIR}/logs/${BATCH_ID}"
LOGS_DIR_CONTAINER="/root/workspace/.scripts/logs/${BATCH_ID}"
CONTAINERS_FILE="${BATCH_ROOT}/containers.txt"
run mkdir -p "$BATCH_ROOT"
run mkdir -p "$WORKSPACE_ROOT"
run mkdir -p "$LOGS_DIR_HOST"
if [[ "$DRYRUN" == "true" ]]; then
    echo "[dryrun] : > $CONTAINERS_FILE"
    echo "[dryrun] printf '%s\\n' '$BATCH_ID' > ${WORKSPACE_ROOT}/.latest_batch"
else
    : > "$CONTAINERS_FILE"
    printf '%s\n' "$BATCH_ID" > "${WORKSPACE_ROOT}/.latest_batch"
fi

LOCAL_CACHE_DIR="${SCRIPT_DIR}/cache/datasets/osf"
if [[ ! -d "$LOCAL_CACHE_DIR" ]]; then
    run mkdir -p "$LOCAL_CACHE_DIR"
fi

echo "Found ${#CONDITION_IDS[@]} condition(s) for DATA_ID='$DATA_ID'."
echo "Batch workspace: $BATCH_ROOT"
echo "Batch id: $BATCH_ID"
[[ "$DRYRUN" == "true" ]] && echo "Dry-run mode enabled: commands will be printed but not executed."
[[ "$SERIAL" == "true" ]] && echo "Serial mode enabled: containers will run one at a time."

for CONDITION_ID in "${CONDITION_IDS[@]}"; do
    SAFE_DATA_ID=$(echo "$DATA_ID" | tr -c '[:alnum:]_-' '_')
    SAFE_CONDITION_ID=$(echo "$CONDITION_ID" | tr -c '[:alnum:]_-' '_')
    SAFE_BATCH_ID=$(echo "$BATCH_ID" | tr -c '[:alnum:]_-' '_')
    CONTAINER_NAME="exp_${SAFE_DATA_ID}_${SAFE_CONDITION_ID}_${SAFE_BATCH_ID}"
    LOG_FILE_CONTAINER="${LOGS_DIR_CONTAINER}/${CONTAINER_NAME}.log"

    # Make per-condition working directory so each run is isolated.
    CONDITION_WORKDIR="${BATCH_ROOT}/${CONDITION_ID}"
    run mkdir -p "$CONDITION_WORKDIR"

    # Copy SKILL.md into the condition workspace under the agent-specific skill folder.
    # Folder root: .claude (claude/fable), .gemini (gemini), .agents (codex).
    # Skill name is read from the SKILL.md frontmatter.
    if [[ -n "$SKILL_NAME" && -f "${SCRIPT_DIR}/SKILL.md" ]]; then
        run mkdir -p "${CONDITION_WORKDIR}/${AGENT_SKILL_DIR}/skills/${SKILL_NAME}"
        run cp "${SCRIPT_DIR}/SKILL.md" "${CONDITION_WORKDIR}/${AGENT_SKILL_DIR}/skills/${SKILL_NAME}/SKILL.md"
    fi

    # Remove an existing container with the same name if present.
    if [[ "$DRYRUN" == "true" ]]; then
        echo "[dryrun] docker ps -aq --filter name=^/${CONTAINER_NAME}$"
        echo "[dryrun] docker rm -f $CONTAINER_NAME"
    elif docker ps -aq --filter "name=^/${CONTAINER_NAME}$" | grep -q .; then
        docker rm -f "$CONTAINER_NAME" > /dev/null
    fi

    if [[ "$SERIAL" == "true" ]]; then
        echo "Running container '$CONTAINER_NAME' for CONDITION_ID='$CONDITION_ID' (serial)..."
    else
        echo "Starting container '$CONTAINER_NAME' for CONDITION_ID='$CONDITION_ID'..."
    fi

    DOCKER_RUN_FLAGS=( -d --rm )
    if [[ "$SERIAL" == "true" ]]; then
        DOCKER_RUN_FLAGS=( --rm )
    fi

    AGENT_AUTH_MOUNT=()
    if [[ "$AGENT_NAME" == "codex" ]]; then
        if [[ -f "${HOME}/.codex/auth.json" ]]; then
            AGENT_AUTH_MOUNT=( -v "${HOME}/.codex/auth.json:/root/.codex/auth.json" )
        else
            echo "Warning: agent is 'codex' but ${HOME}/.codex/auth.json does not exist; skipping auth mount." >&2
        fi
    fi

    run docker run "${DOCKER_RUN_FLAGS[@]}" \
        --name "$CONTAINER_NAME" \
        --label "datasets.batch_id=${BATCH_ID}" \
        --label "datasets.data_id=${DATA_ID}" \
        --label "datasets.condition_id=${CONDITION_ID}" \
        -v "${SCRIPT_DIR}:/root/workspace/.scripts" \
        -v "${CONDITION_WORKDIR}:/root/workspace/results" \
        -v "${LOCAL_CACHE_DIR}:/root/workspace/.cache/datasets/osf" \
        "${AGENT_AUTH_MOUNT[@]}" \
        --env-file "$ENV_FILE" \
        -w /root/workspace/results \
        "$IMAGE_NAME" \
        bash -lc 'log_file="$1"; shift; mkdir -p "$(dirname "$log_file")"; exec >"$log_file" 2>&1; exec bash /root/workspace/.scripts/run_intervention.sh "$@"' _ \
        "$LOG_FILE_CONTAINER" \
        -c "$CONDITION_ID" \
        "${RUN_INTERVENTION_OPTIONS[@]}" \
        "$DATA_ID" \
        /root/workspace/.scripts/interventions.json \
        /root/workspace/.scripts/experiments.json \
        /root/workspace/.scripts/osf_inverted_index.json \
        /root/workspace/.cache/datasets/osf

    if [[ "$DRYRUN" == "true" ]]; then
        echo "[dryrun] echo '$CONTAINER_NAME' >> $CONTAINERS_FILE"
    else
        echo "$CONTAINER_NAME" >> "$CONTAINERS_FILE"
    fi

done

echo ""
if [[ "$SERIAL" == "true" ]]; then
    echo "Finished ${#CONDITION_IDS[@]} container(s) (serial)."
else
    echo "Started ${#CONDITION_IDS[@]} container(s)."
    echo "Inspect running containers with: docker ps --filter 'label=datasets.batch_id=${BATCH_ID}'"
    echo "Follow logs with: docker logs -f <container_name>"
fi
echo "Container list saved at: $CONTAINERS_FILE"
echo "Container outputs are written to: ${LOGS_DIR_HOST}/<container_name>.log"
echo "Cleanup this batch with: ./scripts/run_batch_cleanup.sh ${BATCH_ID}"

# Copy configuration files to workspace folder for reproducibility
run cp "$EXPERIMENTS_FILE" "$BATCH_ROOT/"
run cp "$INTERVENTIONS_FILE" "$BATCH_ROOT/"
