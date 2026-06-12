#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Usage: run_intervention.sh [-n] [-c <CONDITION_ID>] [-a <codex|claude|fable|gemini>] [-k K] <DATA_ID> [INTERVENTION_CONFIG_PATH] [EXPERIMENTS_CONFIG_PATH] [OSF_INDEX_PATH] [OSF_CACHE_DIR]
#   -n  Print all actions without executing them
#   -c  Run only the specified condition ID
#   -k  Repeat each condition K times (default: 1)
# ---------------------------------------------------------------------------

DRYRUN=false
ARGS=()
AGENT_OVERRIDE=""
CONDITION_FILTER=""
K=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n)
            DRYRUN=true
            shift
            ;;
        -c)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                echo "Error: -c requires a CONDITION_ID value." >&2
                exit 1
            fi
            CONDITION_FILTER="$2"
            shift 2
            ;;
        -a)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                echo "Error: -a requires a value (codex|claude|fable|gemini)." >&2
                exit 1
            fi
            AGENT_OVERRIDE="$2"
            shift 2
            ;;
        -a=*)
            AGENT_OVERRIDE="${1#-a=}"
            shift
            ;;
        -k)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                echo "Error: -k requires an integer K value." >&2
                exit 1
            fi
            K="$2"
            # Validate K is a positive integer
            if ! [[ "$K" =~ ^[0-9]+$ ]] || [[ "$K" -eq 0 ]]; then
                echo "Error: -k value must be a positive integer, got '$K'." >&2
                exit 1
            fi
            shift 2
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

# Always clean exported identifiers on script exit, including failures.
cleanup_env_vars() {
    # Remove any generated dataset directories and virtual environments on exit.
    if [[ "${DRYRUN:-false}" == "true" ]]; then
        echo "[dryrun] find . -type d -name '*_datasets' -prune -exec rm -rf {} +"
        echo "[dryrun] find . -type d -name 'data' -prune -exec rm -rf {} +"
        echo "[dryrun] find . -type d -name '.venv' -prune -exec rm -rf {} +"
    else
        find . -type d -name "*_datasets" -prune -exec rm -rf {} +
        find . -type d -name "data" -prune -exec rm -rf {} +
        find . -type d -name ".venv" -prune -exec rm -rf {} +
    fi

    unset DATA_ID CONDITION_ID INTERVENTION_CONFIG_PATH EXPERIMENTS_CONFIG_PATH OSF_INDEX_PATH OSF_CACHE_DIR AGENT_OVERRIDE K
}
trap cleanup_env_vars EXIT

# run <cmd> [args...] — executes normally, or prints in dryrun mode
run() {
    if [[ "$DRYRUN" == "true" ]]; then
        echo "[dryrun] $*"
    else
        "$@"
    fi
}

# print_command <cmd> [args...] — prints the exact command about to run
print_command() {
    [[ "$DRYRUN" == "true" ]] && return 0
    local rendered=""
    local arg
    for arg in "$@"; do
        rendered+=" $(printf '%q' "$arg")"
    done
    echo "[debug] command:${rendered}"
}

# quote_for_agent <text> — wraps text in double quotes and escapes embedded quotes
quote_for_agent() {
    local text="$1"
    text=${text//"/\\"}
    printf '"%s"' "$text"
}

# write_file <path> <content> — writes a file, or prints in dryrun mode
write_file() {
    local path="$1"
    local content="$2"
    if [[ "$DRYRUN" == "true" ]]; then
        echo "[dryrun] write file: $path"
        echo "$content" | sed 's/^/[dryrun]   /'
    else
        echo "$content" > "$path"
    fi
}

[[ "$DRYRUN" == "true" ]] && echo "[dryrun] Dry-run mode enabled — no changes will be made."

# --- 1. Verify required tokens exist in environment -------------------------
for var in GITHUB_TOKEN KAGGLE_API_TOKEN HF_TOKEN OSF_TOKEN; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: required environment variable '$var' is not set." >&2
        exit 1
    fi
done

# --- 2. Parse command line arguments ----------------------------------------
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [-n] [-c <CONDITION_ID>] [-a <codex|claude|fable|gemini>] [-k K] <DATA_ID> [INTERVENTION_CONFIG_PATH] [EXPERIMENTS_CONFIG_PATH] [OSF_INDEX_PATH] [OSF_CACHE_DIR]" >&2
    exit 1
fi

DATA_ID="$1"
INTERVENTION_CONFIG_PATH="${2:-${HOME}/interventions.json}"
EXPERIMENTS_CONFIG_PATH="${3:-${HOME}/experiments.json}"
OSF_INDEX_PATH="${4:-${HOME}/osf_inverted_index.json}"
OSF_CACHE_DIR_ARG="${5:-}"
AGENT="${AGENT_OVERRIDE:-claude}"
AGENT="${AGENT,,}"

export DATA_ID="$DATA_ID"
export INTERVENTION_CONFIG_PATH="$INTERVENTION_CONFIG_PATH"
export EXPERIMENTS_CONFIG_PATH="$EXPERIMENTS_CONFIG_PATH"
export OSF_INDEX_PATH="$OSF_INDEX_PATH"
if [[ -n "$OSF_CACHE_DIR_ARG" ]]; then
    export OSF_CACHE_DIR="$OSF_CACHE_DIR_ARG"
fi

# Validate JSON files passed as optional positional arguments
for json_file in "$INTERVENTION_CONFIG_PATH" "$EXPERIMENTS_CONFIG_PATH" "$OSF_INDEX_PATH"; do
    if [[ -f "$json_file" ]] && ! jq empty "$json_file" 2>/dev/null; then
        echo "Error: '$json_file' is not valid JSON." >&2
        exit 1
    fi
done

case "$AGENT" in
    codex|claude|fable|gemini)
        ;;
    *)
        echo "Error: invalid AGENT '$AGENT'. Allowed values: codex, claude, fable, gemini." >&2
        exit 1
        ;;
esac

# Map agent to its skill folder root. Fable reuses the Claude CLI and its skills.
case "$AGENT" in
    gemini) AGENT_SKILL_DIR=".gemini" ;;
    codex)  AGENT_SKILL_DIR=".agents" ;;
    *)      AGENT_SKILL_DIR=".claude" ;;
esac

# Map agent to the CLI binary it invokes. Fable runs through the Claude CLI.
case "$AGENT" in
    fable) AGENT_CMD="claude" ;;
    *)     AGENT_CMD="$AGENT" ;;
esac

if ! command -v "$AGENT_CMD" > /dev/null 2>&1; then
    echo "Error: selected agent command '$AGENT_CMD' not found in PATH." >&2
    exit 1
fi

echo "Using agent: $AGENT"

# --- 3. Read intervention config and extract conditions for DATA_ID ---------
if [[ ! -f "$INTERVENTION_CONFIG_PATH" ]]; then
    echo "Error: intervention config not found at '$INTERVENTION_CONFIG_PATH'" >&2
    exit 1
fi

# --- 3b. Read experiment config and extract prompts for DATA_ID -------------
if [[ ! -f "$EXPERIMENTS_CONFIG_PATH" ]]; then
    echo "Error: experiments config not found at '$EXPERIMENTS_CONFIG_PATH'" >&2
    exit 1
fi

EXPERIMENT_ENTRY_JSON=$(jq -c -r --arg id "$DATA_ID" 'if type == "object" then (.[$id] // empty) else empty end' "$EXPERIMENTS_CONFIG_PATH" 2>/dev/null)
if [[ -z "$EXPERIMENT_ENTRY_JSON" ]]; then
    echo "Error: no experiment settings found for DATA_ID='$DATA_ID' in '$EXPERIMENTS_CONFIG_PATH'" >&2
    exit 1
fi

BASE_PROMPT_TEMPLATE=$(echo "$EXPERIMENT_ENTRY_JSON" | jq -r '.base_prompt // empty')
ANTI_HALLUCINATION_PROMPT_TEMPLATE=$(echo "$EXPERIMENT_ENTRY_JSON" | jq -r '.anti_hallucination_prompt // empty')
POISONING_RISK_PROMPT_TEMPLATE=$(echo "$EXPERIMENT_ENTRY_JSON" | jq -r '.poisoning_risk_prompt // empty')
FIND_PAPER_PROMPT_TEMPLATE=$(echo "$EXPERIMENT_ENTRY_JSON" | jq -r '.find_paper_prompt // empty')
CHECK_SOCIAL_PROMPT_TEMPLATE=$(echo "$EXPERIMENT_ENTRY_JSON" | jq -r '.check_social_prompt // empty')
STATS_VERIFICATION_PROMPT_TEMPLATE=$(echo "$EXPERIMENT_ENTRY_JSON" | jq -r '.stats_verification_prompt // empty')
DATASET_COMPARISON_PROMPT_TEMPLATE=$(echo "$EXPERIMENT_ENTRY_JSON" | jq -r '.dataset_comparison_prompt // empty')
CODE_INSTRUCTIONS_TEMPLATE=$(echo "$EXPERIMENT_ENTRY_JSON" | jq -r '.code_instructions // empty')
SYSTEM_PROMPTS_JSON=$(echo "$EXPERIMENT_ENTRY_JSON" | jq -c '.system_prompts // {}')

if [[ -z "$BASE_PROMPT_TEMPLATE" ]]; then
    echo "Error: base_prompt not found for DATA_ID='$DATA_ID' in '$EXPERIMENTS_CONFIG_PATH'" >&2
    exit 1
fi

if [[ "$SYSTEM_PROMPTS_JSON" == "{}" ]]; then
    echo "Warning: no system_prompts defined for DATA_ID='$DATA_ID' in '$EXPERIMENTS_CONFIG_PATH'" >&2
fi

CONDITIONS_ENTRIES_JSON=$(jq -c -r --arg id "$DATA_ID" '.[$id] // {} | if type == "object" then to_entries else [] end' "$INTERVENTION_CONFIG_PATH" 2>/dev/null)
NUM_CONDITIONS=$(echo "$CONDITIONS_ENTRIES_JSON" | jq 'length')
if [[ "$NUM_CONDITIONS" -eq 0 ]]; then
    echo "Error: no conditions found for DATA_ID='$DATA_ID' in '$INTERVENTION_CONFIG_PATH'" >&2
    exit 1
fi
echo "Found $NUM_CONDITIONS condition(s) for DATA_ID='$DATA_ID'."

echo "Loaded variables:"
echo "  START_TIME_UTC             : $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "  SCRIPT_PATH                : ${BASH_SOURCE[0]}"
echo "  WORKING_DIRECTORY          : $(pwd)"
echo "  HOSTNAME                   : $(hostname)"
echo "  USER                       : $(whoami)"
echo "  DRYRUN                     : $DRYRUN"

echo "  DATA_ID                    : $DATA_ID"
echo "  CONDITION_FILTER           : ${CONDITION_FILTER:-<none>}"
echo "  ITERATIONS (K)             : $K"
echo "  INTERVENTION_CONFIG_PATH   : $INTERVENTION_CONFIG_PATH"
echo "  EXPERIMENTS_CONFIG_PATH    : $EXPERIMENTS_CONFIG_PATH"
echo "  OSF_INDEX_PATH             : $OSF_INDEX_PATH"
echo "  OSF_CACHE_DIR              : ${OSF_CACHE_DIR:-<none>}"
echo "  INTERVENTION_CONFIG_EXISTS : $([[ -f "$INTERVENTION_CONFIG_PATH" ]] && echo yes || echo no)"
echo "  EXPERIMENTS_CONFIG_EXISTS  : $([[ -f "$EXPERIMENTS_CONFIG_PATH" ]] && echo yes || echo no)"
echo "  CONDITION_FILTER_ACTIVE    : $([[ -n "$CONDITION_FILTER" ]] && echo yes || echo no)"
echo "  AGENT                      : $AGENT"
echo "  AGENT_PATH                 : $(command -v "$AGENT_CMD")"
echo "  AGENT_SKILLS_AVAILABLE     : $([[ -d "${AGENT_SKILL_DIR}/skills" ]] && find "${AGENT_SKILL_DIR}/skills" -type f -name "SKILL.md" -exec dirname {} \; | xargs -n1 basename | paste -sd ',' || echo "none")"

echo "  TOKEN_GITHUB_SET           : $([[ -n "${GITHUB_TOKEN:-}" ]] && echo "yes ...${GITHUB_TOKEN: -5}" || echo no)"
echo "  TOKEN_KAGGLE_SET           : $([[ -n "${KAGGLE_API_TOKEN:-}" ]] && echo "yes ...${KAGGLE_API_TOKEN: -5}" || echo no)"
echo "  TOKEN_HF_SET               : $([[ -n "${HF_TOKEN:-}" ]] && echo "yes ...${HF_TOKEN: -5}" || echo no)"
echo "  TOKEN_OSF_SET              : $([[ -n "${OSF_TOKEN:-}" ]] && echo "yes ...${OSF_TOKEN: -5}" || echo no)"
echo "  GEMINI_API_KEY_SET         : $([[ -n "${GEMINI_API_KEY:-}" ]] && echo "yes ...${GEMINI_API_KEY: -5}" || echo no)"
echo "  ANTHROPIC_API_KEY_SET      : $([[ -n "${ANTHROPIC_API_KEY:-}" ]] && echo "yes ...${ANTHROPIC_API_KEY: -5}" || echo no)"
echo "  OPENAI_API_KEY_SET         : $([[ -n "${OPENAI_API_KEY:-}" ]] && echo "yes ...${OPENAI_API_KEY: -5}" || echo no)"

printf '  BASE_PROMPT_TEMPLATE              : %.120s\n' "$BASE_PROMPT_TEMPLATE"
printf '  FIND_PAPER_PROMPT_TEMPLATE        : %.120s\n' "$FIND_PAPER_PROMPT_TEMPLATE"
printf '  ANTI_HALLUCINATION_PROMPT_TEMPLATE: %.120s\n' "$ANTI_HALLUCINATION_PROMPT_TEMPLATE"
printf '  POISONING_RISK_PROMPT_TEMPLATE    : %.120s\n' "$POISONING_RISK_PROMPT_TEMPLATE"
printf '  CHECK_SOCIAL_PROMPT_TEMPLATE      : %.120s\n' "$CHECK_SOCIAL_PROMPT_TEMPLATE"
printf '  STATS_VERIFICATION_PROMPT_TEMPLATE: %.120s\n' "$STATS_VERIFICATION_PROMPT_TEMPLATE"
printf '  DATASET_COMPARISON_PROMPT_TEMPLATE: %.120s\n' "$DATASET_COMPARISON_PROMPT_TEMPLATE"
printf '  CODE_INSTRUCTIONS_TEMPLATE        : %.120s\n' "$CODE_INSTRUCTIONS_TEMPLATE"

# --- 4. Iterate over conditions and iterations ------------------------------------------------
for i in $(seq 0 $((NUM_CONDITIONS - 1))); do
    CONDITION_ITEM=$(echo "$CONDITIONS_ENTRIES_JSON" | jq -c ".[$i]")
    COND_ID=$(echo "$CONDITION_ITEM" | jq -r '.key')
    CONDITION_ENTRY=$(echo "$CONDITION_ITEM" | jq -c '.value')

    if [[ -n "$CONDITION_FILTER" && "$COND_ID" != "$CONDITION_FILTER" ]]; then
        echo "Skipping condition '$COND_ID' (filtering for '$CONDITION_FILTER')."
        continue
    fi

    for iter in $(seq 1 "$K"); do

        export CONDITION_ID="$COND_ID"
        echo ""
        echo "=============== Processing condition: $COND_ID/$(($NUM_CONDITIONS - 1)) [iteration $iter/$K] ==============="
        echo "Condition entry for '$COND_ID': $CONDITION_ENTRY"

        # --- 5. Create working directory ----------------------------------------
        WORK_DIR="$iter"
        run mkdir -p "$WORK_DIR"

        # --- 6. Extract condition flags ------------------------------------------
        SYSTEM_PROMPT_KEY=$(echo "$CONDITION_ENTRY" | jq -r '.system_prompt // empty')
        BASE_PROMPT_OVERRIDE=$(echo "$CONDITION_ENTRY" | jq -r '.base_prompt // empty')
        DATA_PROVENANCE_SKILL=$(echo "$CONDITION_ENTRY" | jq -r '.data_provenance // false')
        FIND_RELATED_PAPER=$(echo "$CONDITION_ENTRY" | jq -r '.find_related_paper // false')
        ANTI_HALLUCINATION=$(echo "$CONDITION_ENTRY" | jq -r '.anti_hallucination // false')
        POISONING_RISK=$(echo "$CONDITION_ENTRY" | jq -r '.poisoning_risk // false')
        CHECK_SOCIAL_MARKERS=$(echo "$CONDITION_ENTRY" | jq -r '.check_social_markers // false')
        STATISTICAL_VERIFICATION=$(echo "$CONDITION_ENTRY" | jq -r '.statistical_verification // false')
        DATASET_COMPARISON=$(echo "$CONDITION_ENTRY" | jq -r '.dataset_comparison // false')

        DATA_VERIFICATION=$(
            [[ "$FIND_RELATED_PAPER" == "true" || "$POISONING_RISK" == "true" || "$CHECK_SOCIAL_MARKERS" == "true" || "$STATISTICAL_VERIFICATION" == "true" || "$DATASET_COMPARISON" == "true" ]] && echo "true" || echo "false"
        )
        if [[ "$DATA_VERIFICATION" == "true" && "$DATA_PROVENANCE_SKILL" == "true" ]]; then
            echo "Error: both data_provenance skill and individual data verification flags are true for condition '$COND_ID'. This is not allowed."
            [[ "$DRYRUN" != "true" ]] && popd > /dev/null
            exit 1
        fi

        # --- 6b. Remove audit-data-provenance skill when data provenance is disabled ---
        if [[ "$DATA_PROVENANCE_SKILL" != "true" ]]; then
            for skill_dir in .claude .gemini .agents; do
                run rm -rf "$skill_dir/skills/audit-data-provenance"
            done
        fi

        # --- 6c. Copy agent skill directory into working directory -----------------
        if [[ -d "$AGENT_SKILL_DIR" ]]; then
            run cp -r "$AGENT_SKILL_DIR" "$WORK_DIR/"
        fi

        echo "  system_prompt           : ${SYSTEM_PROMPT_KEY:-<none>}"
        echo "  data_provenance         : $DATA_PROVENANCE_SKILL"
        echo "  find_related_paper      : $FIND_RELATED_PAPER"
        echo "  anti_hallucination      : $ANTI_HALLUCINATION"
        echo "  poisoning_risk          : $POISONING_RISK"
        echo "  check_social_markers    : $CHECK_SOCIAL_MARKERS"
        echo "  statistical_verification: $STATISTICAL_VERIFICATION"
        echo "  dataset_comparison      : $DATASET_COMPARISON"


        # --- 7. Enter working directory -----------------------------------------
        if [[ "$DRYRUN" == "true" ]]; then
            echo "[dryrun] pushd $WORK_DIR"
        else
            pushd "$WORK_DIR" > /dev/null
        fi

        # --- 8. Initialise uv project if missing --------------------------------
        if [[ ! -f "pyproject.toml" ]]; then
            run uv init --bare
        fi

        # --- 9. Remove any local virtual environments --------------------------
        run find . -type d -name ".venv" -prune -exec rm -rf {} +

        # --- 10. Add standard analysis libraries --------------------------------
        run uv add -q pandas seaborn scikit-learn scipy statsmodels

        # --- 11. Verify datasets CLI is available -------------------------------
        if ! which datasets > /dev/null 2>&1; then
            echo "Error: 'datasets' command not found." >&2
            [[ "$DRYRUN" != "true" ]] && popd > /dev/null
            exit 1
        fi

        # --- 12. Build prompt and system prompt depending on condition flags -----

        # Base analysis prompt from experiments config (always used),
        # optionally overridden by a condition-level base_prompt in the intervention config.
        if [[ -n "$BASE_PROMPT_OVERRIDE" ]]; then
            BASE_PROMPT="${BASE_PROMPT_OVERRIDE} Write up your findings in a markdown file called FINDINGS.md. Follow the below instructions."
            echo "  base_prompt             : <overridden by intervention config>"
        else
            BASE_PROMPT="$BASE_PROMPT_TEMPLATE"
        fi
        if [[ "$DATA_PROVENANCE_SKILL" == "true" ]]; then
            BASE_PROMPT="${BASE_PROMPT}\n\n[Data Verification Instructions]\n\n- Use the 'audit-data-provenance' skill to run a comprehensive data provenance analysis for the datasets you download."
        fi
        if [[ "$DATA_VERIFICATION" == "true" ]]; then
            BASE_PROMPT="${BASE_PROMPT}\n\n[Data Verification Instructions]\n"

            # Collect enabled fragments into an array
            fragments=()
            [[ "$POISONING_RISK" == "true" ]]          && fragments+=("${POISONING_RISK_PROMPT_TEMPLATE}")
            [[ "$FIND_RELATED_PAPER" == "true" ]]       && fragments+=("${FIND_PAPER_PROMPT_TEMPLATE}")
            [[ "$CHECK_SOCIAL_MARKERS" == "true" ]]     && fragments+=("${CHECK_SOCIAL_PROMPT_TEMPLATE}")
            [[ "$STATISTICAL_VERIFICATION" == "true" ]] && fragments+=("${STATS_VERIFICATION_PROMPT_TEMPLATE}")
            [[ "$DATASET_COMPARISON" == "true" ]]       && fragments+=("${DATASET_COMPARISON_PROMPT_TEMPLATE}")

            # Fisher-Yates shuffle
            for (( i=${#fragments[@]}-1; i>0; i-- )); do
                j=$(( RANDOM % (i+1) ))
                tmp="${fragments[$i]}"
                fragments[$i]="${fragments[$j]}"
                fragments[$j]="$tmp"
            done

            # Append in randomized order
            for frag in "${fragments[@]}"; do
                BASE_PROMPT="${BASE_PROMPT}\n- ${frag}"
            done

            # Universal instructions (pinned at end)
            if [[ "$ANTI_HALLUCINATION" == "true" ]]; then
                BASE_PROMPT="${BASE_PROMPT}\n- ${ANTI_HALLUCINATION_PROMPT_TEMPLATE}"
            fi
            BASE_PROMPT="${BASE_PROMPT}\n- Keep track of any and all datasets and sources used; include them in FINDINGS.md."
        fi

        # Coding instructions are included if the template is non-empty, regardless of condition flags
        if [[ -n "$CODE_INSTRUCTIONS_TEMPLATE" ]]; then
            BASE_PROMPT="${BASE_PROMPT}\n\n[Coding Instructions]\n\n${CODE_INSTRUCTIONS_TEMPLATE}"
        fi

        PROMPT="$BASE_PROMPT"
        echo
        echo "Constructed PROMPT:"
        echo "-----------------"
        printf '%b\n' "$PROMPT"
        echo "-----------------"

        # System prompt: selected by key from system_prompts in experiments config
        if [[ -n "$SYSTEM_PROMPT_KEY" ]]; then
            SYS_PROMPT=$(echo "$SYSTEM_PROMPTS_JSON" | jq -r --arg key "$SYSTEM_PROMPT_KEY" '.[$key] // empty')
            if [[ -z "$SYS_PROMPT" ]]; then
                echo "Error: system_prompt key '$SYSTEM_PROMPT_KEY' not found in system_prompts for DATA_ID='$DATA_ID'" >&2
                exit 1
            fi
            printf '  SYS_PROMPT (%s): %.120s\n' "$SYSTEM_PROMPT_KEY" "$SYS_PROMPT"
        else
            SYS_PROMPT=""
        fi

        # If i==0  then run this
        # if [[ "$i" -eq 0 ]]; then
        #     datasets osf download "$DATA_ID"
        # fi
        # datasets osf download "$DATA_ID"
        # datasets osf info "$DATA_ID

        # --- 13. Call selected LLM agent ----------------------------------------
        echo "Invoking ${AGENT} agent..."
        PROMPT_FOR_AGENT=$(quote_for_agent "$PROMPT")
        SYS_PROMPT_FOR_AGENT=""
        [[ -n "$SYS_PROMPT" ]] && SYS_PROMPT_FOR_AGENT=$(quote_for_agent "$SYS_PROMPT")

        case "$AGENT" in
            claude|fable)
                # Fable runs through the same Claude CLI path, only swapping the model.
                if [[ "$AGENT" == "fable" ]]; then
                    CLAUDE_MODEL="claude-fable-5"
                else
                    CLAUDE_MODEL="claude-opus-4-8"
                fi
                CLAUDE_ARGS=(--print "$PROMPT_FOR_AGENT" --allowed-tools "Bash,Read,Write,Edit,WebSearch,WebFetch,Skill" --setting-sources "user,project" --model "$CLAUDE_MODEL" --effort high --output-format stream-json --verbose)
                [[ -n "$SYS_PROMPT_FOR_AGENT" ]] && CLAUDE_ARGS+=(--append-system-prompt "$SYS_PROMPT_FOR_AGENT")
                print_command claude "${CLAUDE_ARGS[@]}"
                run claude "${CLAUDE_ARGS[@]}"
                ;;
            codex)
                AGENT_PROMPT="$PROMPT_FOR_AGENT"
                if [[ -n "$SYS_PROMPT_FOR_AGENT" ]]; then
                    AGENT_PROMPT="${AGENT_PROMPT}

System prompt:
${SYS_PROMPT_FOR_AGENT}"
                fi
                print_command codex exec -m gpt-5.5 --config model_reasoning_effort="high" --dangerously-bypass-approvals-and-sandbox --json "$AGENT_PROMPT"
                run codex exec -m gpt-5.5 --config model_reasoning_effort="high" --dangerously-bypass-approvals-and-sandbox --json "$AGENT_PROMPT"
                ;;
            gemini)
                AGENT_PROMPT="$PROMPT_FOR_AGENT"
                if [[ -n "$SYS_PROMPT_FOR_AGENT" ]]; then
                    AGENT_PROMPT="${AGENT_PROMPT}

System prompt:
${SYS_PROMPT_FOR_AGENT}"
                fi
                print_command gemini --prompt "$AGENT_PROMPT" -y --output-format stream-json --model "gemini-3.1-pro-preview" --skip-trust
                run gemini --prompt "$AGENT_PROMPT" -y --output-format stream-json --model "gemini-3.1-pro-preview" --skip-trust
                ;;
        esac

        if [[ "$DRYRUN" == "true" ]]; then
            echo "[dryrun] popd"
        else
            popd > /dev/null
        fi
        echo "================== Done condition: $COND_ID/$(($NUM_CONDITIONS - 1)) [iteration $iter/$K] =================="
    done

    # --- Rename iteration directories to final naming convention ---------------
    echo "Renaming iteration directories for condition '$COND_ID'..."
    for iter in $(seq 1 "$K"); do
        FINAL_NAME="${DATA_ID}_${COND_ID}_${AGENT}_iter_${iter}"
        if [[ "$DRYRUN" == "true" ]]; then
            echo "[dryrun] mv $iter $FINAL_NAME"
        elif [[ -d "$iter" ]]; then
            mv "$iter" "$FINAL_NAME"
            echo "  Renamed '$iter' -> '$FINAL_NAME'"
        fi
    done
done

echo ""
echo "All conditions processed."