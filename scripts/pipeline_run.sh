#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
# pipeline_run.sh
#
# Push-a-button driver that performs README steps 3-5 in one go:
#   3. Run the experiments   (all_experiments.sh / batch_run.sh -> Docker)
#   4. Evaluate the runs      (copy_results.sh, eval_batch.sh, export_eval_csv.py)
#   5. Produce full.csv       (plotting in analysis/plots.R is left to you)
#
# The script creates a fresh working folder in the current directory, copies
# the contents of this scripts/ folder into it, selects the requested
# experimental conditions, and then runs the three stages inside that folder.
#
# Every parameter described in README steps 3-5 is exposed as a flag (see
# --help below). Nothing about your environment is assumed: a .env with API
# tokens is required, the OSF inverted index is optional (a warning is printed
# if absent), and the final figures (step 5) are NOT generated automatically.
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Defaults -------------------------------------------------------------
INTERVENTIONS="all"          # all | baseline | mitigations          (step 3.3)
DATA_ID="all"                # all | 3hu9k | 6jmfx | av | hiring | fertility
AGENT="claude"               # claude | codex | gemini | fable        (step 3.6)
ITERATIONS=""                # k iterations per condition (empty -> script default)
POLARITY="negative"          # negative | positive (adversary goal)   (step 4.1)
EVAL_MODEL="claude-sonnet-4-6"   # LLM-as-a-judge model               (step 4.2)
OUTPUT="full.csv"            # final CSV name                         (step 4.3)

SEQUENTIAL=false             # -s : run containers one at a time
BUILD=false                  # --build : (re)build the Docker image
DRYRUN=false                 # -n : print the plan, change nothing

ENV_FILE=""                  # required: path to the .env with API tokens
OSF_INDEX=""                 # optional: path to osf_inverted_index.json
RUN_DIR=""                   # optional: working folder to create

SKIP_RUN=false               # skip stage 3 (re-evaluate an existing run folder)
SKIP_EVAL=false              # skip stage 4 (only run the experiments)

# Valid choices.
VALID_DATA_IDS=(3hu9k 6jmfx av hiring fertility)
VALID_AGENTS=(claude codex gemini fable)
VALID_INTERVENTIONS=(all baseline mitigations)

usage() {
    cat >&2 <<'EOF'
Usage: pipeline_run.sh --env-file PATH [OPTIONS]

Runs README steps 3-5 automatically. Creates a new working folder in the
current directory, copies scripts/ into it, and runs everything there.

Required:
  --env-file PATH        .env file with API tokens (OSF/HF/KAGGLE/GITHUB +
                         model keys). Copied into the working folder as .env.

Experiment selection (step 3):
  -i, --interventions SET   Condition set: all | baseline | mitigations
                            (default: all). Selects interventions_<SET>.json.
  -d, --data-id ID          Dataset to run: all | 3hu9k | 6jmfx | av |
                            hiring | fertility (default: all).
  -a, --agent AGENT         Agent: claude | codex | gemini | fable
                            (default: claude).
  -k, --iterations K        Iterations per condition (default: run_intervention
                            default).

Execution (step 3):
  -s, --sequential          Run containers one at a time (default: parallel).
      --build               (Re)build the Docker image before running.
      --osf-index PATH      OSF inverted index JSON. Defaults to
                            scripts/osf_inverted_index.json if present;
                            a warning is printed if no index is found.

Evaluation (step 4):
  -p, --polarity POL        Adversary goal: negative | positive
                            (default: negative). Picks copy_results.sh
                            polarity and eval_schema_<POL>.json.
  -m, --eval-model MODEL    LLM-as-a-judge model (default: claude-sonnet-4-6).
  -o, --output FILE         Final CSV name written in the working folder
                            (default: full.csv).

General:
      --run-dir DIR         Working folder to create/use
                            (default: ./pipeline_<polarity>_<agent>_<timestamp>).
      --skip-run            Skip stage 3 (evaluate an existing --run-dir).
      --skip-eval           Skip stage 4 (only run the experiments).
  -n, --dry-run             Print the full plan without creating or running
                            anything.
  -h, --help                Show this help.

Examples:
  # All datasets, all conditions, Claude, reject (negative) goal, k=3, sequential.
  pipeline_run.sh --env-file ./.env -a claude -k 3 -s

  # Single dataset, mitigation conditions only, Codex, exaggerate goal.
  pipeline_run.sh --env-file ./.env -d 6jmfx -i mitigations -a codex -p positive

  # Re-evaluate an existing run folder without re-running the experiments.
  pipeline_run.sh --env-file ./.env --skip-run --run-dir ./pipeline_negative_claude_20260614_120000
EOF
}

contains() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

# ---- Parse arguments ------------------------------------------------------
if [[ $# -eq 0 ]]; then usage; exit 1; fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--interventions) INTERVENTIONS="${2:?--interventions needs a value}"; shift 2 ;;
        -d|--data-id)       DATA_ID="${2:?--data-id needs a value}"; shift 2 ;;
        -a|--agent)         AGENT="${2:?--agent needs a value}"; shift 2 ;;
        -k|--iterations)    ITERATIONS="${2:?--iterations needs a value}"; shift 2 ;;
        -p|--polarity)      POLARITY="${2:?--polarity needs a value}"; shift 2 ;;
        -m|--eval-model)    EVAL_MODEL="${2:?--eval-model needs a value}"; shift 2 ;;
        -o|--output)        OUTPUT="${2:?--output needs a value}"; shift 2 ;;
        --env-file)         ENV_FILE="${2:?--env-file needs a value}"; shift 2 ;;
        --osf-index)        OSF_INDEX="${2:?--osf-index needs a value}"; shift 2 ;;
        --run-dir)          RUN_DIR="${2:?--run-dir needs a value}"; shift 2 ;;
        -s|--sequential)    SEQUENTIAL=true; shift ;;
        --build)            BUILD=true; shift ;;
        --skip-run)         SKIP_RUN=true; shift ;;
        --skip-eval)        SKIP_EVAL=true; shift ;;
        -n|--dry-run)       DRYRUN=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "Error: unknown argument '$1'." >&2; usage; exit 1 ;;
    esac
done

# ---- Validate choices -----------------------------------------------------
if ! contains "$INTERVENTIONS" "${VALID_INTERVENTIONS[@]}"; then
    echo "Error: --interventions must be one of: ${VALID_INTERVENTIONS[*]} (got '$INTERVENTIONS')." >&2; exit 1
fi
if [[ "$DATA_ID" != "all" ]] && ! contains "$DATA_ID" "${VALID_DATA_IDS[@]}"; then
    echo "Error: --data-id must be 'all' or one of: ${VALID_DATA_IDS[*]} (got '$DATA_ID')." >&2; exit 1
fi
if ! contains "$AGENT" "${VALID_AGENTS[@]}"; then
    echo "Error: --agent must be one of: ${VALID_AGENTS[*]} (got '$AGENT')." >&2; exit 1
fi
if [[ "$POLARITY" != "negative" && "$POLARITY" != "positive" ]]; then
    echo "Error: --polarity must be 'negative' or 'positive' (got '$POLARITY')." >&2; exit 1
fi
if [[ -n "$ITERATIONS" && ! "$ITERATIONS" =~ ^[0-9]+$ ]]; then
    echo "Error: --iterations must be a positive integer (got '$ITERATIONS')." >&2; exit 1
fi
if ! command -v jq > /dev/null 2>&1; then
    echo "Error: jq command not found in PATH." >&2; exit 1
fi

# .env is required.
if [[ -z "$ENV_FILE" ]]; then
    echo "Error: --env-file is required (see --help)." >&2; exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: --env-file not found: $ENV_FILE" >&2; exit 1
fi

# OSF index: explicit path must exist; otherwise fall back to scripts/ copy.
if [[ -n "$OSF_INDEX" ]]; then
    if [[ ! -f "$OSF_INDEX" ]]; then
        echo "Error: --osf-index not found: $OSF_INDEX" >&2; exit 1
    fi
elif [[ -f "${SCRIPT_DIR}/osf_inverted_index.json" ]]; then
    OSF_INDEX="${SCRIPT_DIR}/osf_inverted_index.json"
fi

# ---- Resolve the working folder -------------------------------------------
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
if [[ -z "$RUN_DIR" ]]; then
    RUN_DIR="${PWD}/pipeline_${POLARITY}_${AGENT}_${TIMESTAMP}"
fi
# Absolutise so cd-ing around stays correct.
case "$RUN_DIR" in
    /*) : ;;
    *)  RUN_DIR="${PWD}/${RUN_DIR}" ;;
esac

# run() executes a command, or prints it (quoted) in dry-run mode.
run() {
    if [[ "$DRYRUN" == "true" ]]; then
        printf '[dry-run]'
        local a
        for a in "$@"; do printf ' %q' "$a"; done
        printf '\n'
    else
        "$@"
    fi
}

# run_in_dir() runs a command from inside the working folder, or prints it
# (prefixed with the cd) in dry-run mode.
run_in_dir() {
    if [[ "$DRYRUN" == "true" ]]; then
        printf '[dry-run] (cd %q &&' "$RUN_DIR"
        local a
        for a in "$@"; do printf ' %q' "$a"; done
        printf ')\n'
    else
        ( cd "$RUN_DIR" && "$@" )
    fi
}

# Data IDs to evaluate. Read from the source experiments.json so this works
# even in dry-run (before the working folder is populated).
DATA_IDS=()
if [[ "$DATA_ID" == "all" ]]; then
    mapfile -t DATA_IDS < <(jq -r 'keys[]' "${SCRIPT_DIR}/experiments.json")
else
    DATA_IDS=("$DATA_ID")
fi

echo "============================================================"
echo " Pipeline configuration"
echo "------------------------------------------------------------"
echo "  Working folder : $RUN_DIR"
echo "  Interventions  : $INTERVENTIONS"
echo "  Dataset(s)     : ${DATA_IDS[*]}"
echo "  Agent          : $AGENT"
echo "  Iterations (k) : ${ITERATIONS:-<run_intervention default>}"
echo "  Adversary goal : $POLARITY"
echo "  Eval model     : $EVAL_MODEL"
echo "  Output CSV     : $OUTPUT"
echo "  Mode           : $([[ "$SEQUENTIAL" == true ]] && echo sequential || echo parallel)$([[ "$BUILD" == true ]] && echo ', build image')"
echo "  .env file      : $ENV_FILE"
echo "  OSF index      : ${OSF_INDEX:-<none; live OSF API will be used>}"
echo "  Stages         : $([[ "$SKIP_RUN" == true ]] && echo '(skip run) ' || echo 'run ')$([[ "$SKIP_EVAL" == true ]] && echo '(skip eval)' || echo 'eval')"
[[ "$DRYRUN" == true ]] && echo "  DRY RUN        : nothing will be created or executed"
echo "============================================================"

if [[ -z "$OSF_INDEX" ]]; then
    echo "Warning: no OSF inverted index found or supplied; OSF searches will use the (slow) live API." >&2
fi

# ---------------------------------------------------------------------------
# Stage 0: set up the working folder (README step 3.1-3.4)
# ---------------------------------------------------------------------------
if [[ "$SKIP_RUN" == "true" ]]; then
    # Re-using an existing run folder: it must already exist and be populated.
    if [[ "$DRYRUN" != "true" && ! -d "$RUN_DIR" ]]; then
        echo "Error: --skip-run set but working folder does not exist: $RUN_DIR" >&2
        exit 1
    fi
    echo "==> Stage 0: reusing existing working folder (--skip-run)."
else
    echo "==> Stage 0: preparing working folder."
    run mkdir -p "$RUN_DIR"

    # Copy the contents of scripts/ into the working folder (README step 3.2),
    # excluding previously generated outputs and any nested pipeline folders.
    if command -v rsync > /dev/null 2>&1; then
        run rsync -a \
            --exclude 'workspace' --exclude 'logs' --exclude 'results' \
            --exclude 'eval' --exclude 'cache' --exclude 'pipeline_*' \
            "${SCRIPT_DIR}/" "${RUN_DIR}/"
    else
        run cp -R "${SCRIPT_DIR}/." "${RUN_DIR}/"
        for stale in workspace logs results eval cache; do
            run rm -rf "${RUN_DIR}/${stale}"
        done
    fi

    # Select the experimental conditions (README step 3.3).
    SRC_INTERVENTIONS="${SCRIPT_DIR}/interventions_${INTERVENTIONS}.json"
    if [[ ! -f "$SRC_INTERVENTIONS" ]]; then
        echo "Error: interventions file not found: $SRC_INTERVENTIONS" >&2
        exit 1
    fi
    run cp "$SRC_INTERVENTIONS" "${RUN_DIR}/interventions.json"

    # Place the required .env (README step 3.4).
    run cp "$ENV_FILE" "${RUN_DIR}/.env"

    # Place the optional OSF inverted index.
    if [[ -n "$OSF_INDEX" ]]; then
        run cp "$OSF_INDEX" "${RUN_DIR}/osf_inverted_index.json"
    fi
fi

# Sanity-check the eval schema exists for the chosen polarity (README step 4.2).
EVAL_SCHEMA_SRC="${SCRIPT_DIR}/eval_schema_${POLARITY}.json"
if [[ ! -f "$EVAL_SCHEMA_SRC" ]]; then
    echo "Error: evaluation schema not found: $EVAL_SCHEMA_SRC" >&2
    exit 1
fi
EVAL_SCHEMA="eval_schema_${POLARITY}.json"   # relative to the working folder

# ---------------------------------------------------------------------------
# Stage 3: run the experiments (README step 3.6)
# ---------------------------------------------------------------------------
if [[ "$SKIP_RUN" == "true" ]]; then
    echo "==> Stage 3: skipped (--skip-run)."
else
    echo "==> Stage 3: running experiments."
    if [[ "$DATA_ID" == "all" ]]; then
        # all_experiments.sh iterates every dataset in experiments.json.
        RUN_CMD=(bash ./all_experiments.sh)
        [[ "$DRYRUN" == true ]]     && RUN_CMD+=(-n)
        [[ "$SEQUENTIAL" == true ]] && RUN_CMD+=(-s)
        [[ "$BUILD" == true ]]      && RUN_CMD+=(--build)
        RUN_CMD+=("$AGENT")
        if [[ -n "$ITERATIONS" ]]; then
            RUN_CMD+=(-- -k "$ITERATIONS")
        fi
    else
        # batch_run.sh runs every condition for a single dataset.
        RUN_CMD=(bash ./batch_run.sh)
        [[ "$DRYRUN" == true ]]     && RUN_CMD+=(-n)
        [[ "$SEQUENTIAL" == true ]] && RUN_CMD+=(-s)
        [[ "$BUILD" == true ]]      && RUN_CMD+=(--build)
        RUN_CMD+=("$DATA_ID" -a "$AGENT")
        [[ -n "$ITERATIONS" ]]      && RUN_CMD+=(-k "$ITERATIONS")
    fi
    run_in_dir "${RUN_CMD[@]}"
fi

# ---------------------------------------------------------------------------
# Stage 4: evaluate the experiments (README step 4)
# ---------------------------------------------------------------------------
if [[ "$SKIP_EVAL" == "true" ]]; then
    echo "==> Stage 4: skipped (--skip-eval)."
    echo
    echo "Experiments finished. Results are under: ${RUN_DIR}/workspace and ${RUN_DIR}/logs"
    exit 0
fi

echo "==> Stage 4: collecting results into the results/ tree (copy_results.sh)."
COPY_CMD=(bash ./copy_results.sh "$POLARITY")
[[ "$DRYRUN" == true ]] && COPY_CMD+=(-n)
run_in_dir "${COPY_CMD[@]}"

echo "==> Stage 4: running the LLM-as-a-judge evaluation (eval_batch.sh)."
for did in "${DATA_IDS[@]}"; do
    echo "    - evaluating DATA_ID='$did'"
    EVAL_CMD=(bash ./eval_batch.sh)
    [[ "$DRYRUN" == true ]] && EVAL_CMD+=(-n)
    EVAL_CMD+=(-m "$EVAL_MODEL" "$did" "$EVAL_SCHEMA" "$POLARITY" "$AGENT")
    run_in_dir "${EVAL_CMD[@]}"
done

echo "==> Stage 4: exporting the combined CSV (export_eval_csv.py)."
run_in_dir python3 ./export_eval_csv.py -o "$OUTPUT"

# ---------------------------------------------------------------------------
# Stage 5: plotting (left to the user, per README step 5)
# ---------------------------------------------------------------------------
echo
echo "============================================================"
echo " Done. Combined results: ${RUN_DIR}/${OUTPUT}"
echo "------------------------------------------------------------"
echo " Step 5 (figures) is not run automatically. To reproduce the"
echo " paper figures with analysis/plots.R, point its input at your"
echo " CSV by editing line 39 of analysis/plots.R:"
echo
echo "   in_path <- \"${RUN_DIR}/${OUTPUT}\""
echo
echo " then run:  Rscript analysis/plots.R"
echo " (figures are written to analysis/figures/)"
echo "============================================================"
