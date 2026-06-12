#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Usage: evaluate_batch.sh [-n] [-p] [-N] [-f] [-m EVAL_MODEL] <DATA_ID> <EVAL_CONFIG_PATH> [POLARITY] [AGENT_MODEL]
#   -n              Dry-run mode (print commands without executing)
#   -p              Print a head/tail preview of the assembled prompt for each iteration
#   -N              Print the full assembled prompt (instead of the head/tail preview)
#   -f              Force re-evaluation (ignore cached eval_raw/*.txt and re-call the model)
#   -m EVAL_MODEL   Claude model used for evaluation (default: claude-sonnet-4-6)
#
#   POLARITY        "negative" or "positive". If omitted, evaluate every polarity dir found.
#   AGENT_MODEL     Agent model name (gemini, claude, codex, ...). If omitted, evaluate every
#                   agent model found under results/<DATA_ID>/<POLARITY>/.
#
# Reads results/<DATA_ID>/<POLARITY>/<AGENT_MODEL>/<COND>/<DATA_ID>_<COND>_<AGENT_MODEL>_iter_K/
# Per-iter agent activity is sliced from the collated results/.../run.log between matching
# "Processing condition" / "Done condition" markers.
#
# Output: eval/<DATA_ID>/<POLARITY>/evaluation_report.json (one report per polarity,
#         combining all agent models). Raw Claude responses go to eval/.../eval_raw/.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_ROOT="$SCRIPT_DIR/results"
EVAL_ROOT="$SCRIPT_DIR/eval"
DRYRUN=false
PRINT_PROMPT=false
PRINT_FULL_PROMPT=false
FORCE=false
EVAL_MODEL="claude-sonnet-4-6"
ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) DRYRUN=true; shift ;;
        -p|--print-prompt) PRINT_PROMPT=true; shift ;;
        -N|--print-full-prompt) PRINT_FULL_PROMPT=true; shift ;;
        -f|--force) FORCE=true; shift ;;
        -m)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                echo "Error: -m requires a model name." >&2
                exit 1
            fi
            EVAL_MODEL="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '4,19p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            exit 0
            ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 [-n] [-m EVAL_MODEL] <DATA_ID> <EVAL_CONFIG_PATH> [POLARITY] [AGENT_MODEL]" >&2
    exit 1
fi

DATA_ID="$1"
EVAL_CONFIG_PATH="$2"
POLARITY_ARG="${3:-}"
AGENT_MODEL_ARG="${4:-}"

# --- Validate prerequisites ------------------------------------------------

for cmd in jq claude awk; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
        echo "Error: required command '$cmd' not found in PATH." >&2
        exit 1
    fi
done

if [[ ! -f "$EVAL_CONFIG_PATH" ]]; then
    echo "Error: evaluation config not found at '$EVAL_CONFIG_PATH'" >&2
    exit 1
fi

if ! jq empty "$EVAL_CONFIG_PATH" 2>/dev/null; then
    echo "Error: '$EVAL_CONFIG_PATH' is not valid JSON." >&2
    exit 1
fi

EVAL_ENTRY=$(jq -c --arg id "$DATA_ID" '.[$id] // empty' "$EVAL_CONFIG_PATH")
if [[ -z "$EVAL_ENTRY" ]]; then
    echo "Error: no evaluation config found for DATA_ID='$DATA_ID' in '$EVAL_CONFIG_PATH'" >&2
    exit 1
fi

DATA_ID_ROOT="$RESULTS_ROOT/$DATA_ID"
if [[ ! -d "$DATA_ID_ROOT" ]]; then
    echo "Error: results dir not found: $DATA_ID_ROOT" >&2
    exit 1
fi

if [[ -n "$POLARITY_ARG" && "$POLARITY_ARG" != "negative" && "$POLARITY_ARG" != "positive" ]]; then
    echo "Error: POLARITY must be 'negative' or 'positive' (got '$POLARITY_ARG')" >&2
    exit 1
fi

# --- Resolve polarities ----------------------------------------------------

shopt -s nullglob

POLARITIES=()
if [[ -n "$POLARITY_ARG" ]]; then
    POLARITIES=("$POLARITY_ARG")
else
    for p in "$DATA_ID_ROOT"/*/; do
        n="$(basename "${p%/}")"
        case "$n" in negative|positive) POLARITIES+=("$n") ;; esac
    done
fi

if [[ ${#POLARITIES[@]} -eq 0 ]]; then
    echo "Error: no polarity directories found in $DATA_ID_ROOT" >&2
    exit 1
fi

# --- Eval-config-derived prompt content ------------------------------------

DATASET_DESCRIPTION=$(echo "$EVAL_ENTRY" | jq -r '.description // ""')
SHARED_CRITERIA=$(echo "$EVAL_ENTRY" | jq -c '.shared')
CONDITION_OVERRIDES=$(echo "$EVAL_ENTRY" | jq -c '.condition_overrides // {}')

# --- Helpers ---------------------------------------------------------------

truncate_text() {
    local text="$1"
    local max_chars="${2:-80000}"
    local len=${#text}
    if (( len > max_chars )); then
        echo "${text:0:$max_chars}

[... TRUNCATED: ${len} chars total, showing first ${max_chars} ...]"
    else
        echo "$text"
    fi
}

# Compute the [start,end] line range of an iteration's section within run.log.
# Section begins at "=== Processing condition: ... [iteration K/N] ===" and ends at
# the matching "=== Done condition: ... [iteration K/N] ===" (inclusive).
# Prints "<start> <end>" (1-indexed); empty if not found.
iter_line_range() {
    local log="$1" iter="$2"
    [[ -f "$log" ]] || return
    awk -v want="$iter" '
        function get_iter(line,    s) {
            s = line
            sub(/.*\[iteration /, "", s); sub(/\/.*/, "", s)
            return s + 0
        }
        /^=+ Processing condition:.*\[iteration / {
            if (get_iter($0) == want && !start) start = NR
        }
        /^=+ Done condition:.*\[iteration / {
            if (start && get_iter($0) == want) { end = NR; exit }
        }
        END {
            if (start && end) print start, end
            else if (start) print start, NR
        }
    ' "$log"
}

# --- Main loop -------------------------------------------------------------

EVAL_COUNT=0
EVAL_ERRORS=0
TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

for POLARITY in "${POLARITIES[@]}"; do
    POLARITY_ROOT="$DATA_ID_ROOT/$POLARITY"
    if [[ ! -d "$POLARITY_ROOT" ]]; then
        echo "Skipping missing polarity dir: $POLARITY_ROOT"
        continue
    fi

    AGENT_MODELS=()
    if [[ -n "$AGENT_MODEL_ARG" ]]; then
        AGENT_MODELS=("$AGENT_MODEL_ARG")
    else
        for m in "$POLARITY_ROOT"/*/; do
            n="$(basename "${m%/}")"
            # Treat a dir as an agent model only if it has at least one numeric condition subdir.
            local_has_cond=0
            for sub in "$m"*/; do
                sn="$(basename "${sub%/}")"
                if [[ "$sn" =~ ^[0-9]+$ ]]; then
                    local_has_cond=1
                    break
                fi
            done
            if (( local_has_cond )); then
                AGENT_MODELS+=("$n")
            fi
        done
    fi

    if [[ ${#AGENT_MODELS[@]} -eq 0 ]]; then
        echo "No agent models found under $POLARITY_ROOT; skipping."
        continue
    fi

    EVAL_OUT_DIR="$EVAL_ROOT/$DATA_ID/$POLARITY"
    REPORT_FILE="$EVAL_OUT_DIR/evaluation_report.json"
    EVAL_RAW_DIR="$EVAL_OUT_DIR/eval_raw"
    if [[ "$DRYRUN" != "true" ]]; then
        mkdir -p "$EVAL_RAW_DIR"
    fi

    AGENT_MODELS_JSON="$(printf '%s\n' "${AGENT_MODELS[@]}" | jq -R . | jq -s .)"

    # Load existing report on resume; otherwise initialize a fresh one.
    if [[ -f "$REPORT_FILE" ]] && jq empty "$REPORT_FILE" 2>/dev/null; then
        echo "Resuming from existing report: $REPORT_FILE"
        REPORT=$(jq \
            --arg ts "$TIMESTAMP" \
            --arg eval_model "$EVAL_MODEL" \
            --argjson new_agents "$AGENT_MODELS_JSON" \
            '
            .metadata.last_resumed = $ts
            | .metadata.eval_model = $eval_model
            | .metadata.agent_models = ((.metadata.agent_models // []) + $new_agents | unique)
            | .models = (.models // {})
            ' "$REPORT_FILE")
    else
        REPORT=$(jq -n \
            --arg data_id "$DATA_ID" \
            --arg polarity "$POLARITY" \
            --arg eval_model "$EVAL_MODEL" \
            --arg timestamp "$TIMESTAMP" \
            --arg eval_config "$EVAL_CONFIG_PATH" \
            --argjson agent_models "$AGENT_MODELS_JSON" \
            '{
                metadata: {
                    data_id: $data_id,
                    polarity: $polarity,
                    eval_model: $eval_model,
                    eval_timestamp: $timestamp,
                    eval_config: $eval_config,
                    agent_models: $agent_models
                },
                models: {},
                summary: {}
            }'
        )
    fi

    # Atomic write: tmp file + rename so a kill mid-write can't corrupt the report.
    save_report() {
        local tmp="${REPORT_FILE}.tmp"
        printf '%s\n' "$REPORT" | jq . > "$tmp" && mv "$tmp" "$REPORT_FILE"
    }

    echo "============================================================"
    echo "Evaluating $DATA_ID / $POLARITY"
    echo "  agent models : ${AGENT_MODELS[*]}"
    echo "  eval model   : $EVAL_MODEL"
    echo "  output       : $REPORT_FILE"
    echo "  dryrun       : $DRYRUN"
    echo "============================================================"

    for AGENT in "${AGENT_MODELS[@]}"; do
        AGENT_ROOT="$POLARITY_ROOT/$AGENT"
        if [[ ! -d "$AGENT_ROOT" ]]; then
            echo "  Skipping missing agent dir: $AGENT_ROOT"
            continue
        fi

        echo ""
        echo "## Agent: $AGENT"

        # Initialize agent entry only if absent — preserve previously-saved iters on resume.
        REPORT=$(echo "$REPORT" | jq --arg a "$AGENT" '
            .models[$a] = (.models[$a] // {conditions: {}})
            | .models[$a].conditions = (.models[$a].conditions // {})
        ')

        for COND_DIR in "$AGENT_ROOT"/*/; do
            COND_DIR="${COND_DIR%/}"
            COND_ID="$(basename "$COND_DIR")"
            [[ "$COND_ID" =~ ^[0-9]+$ ]] || continue

            echo "  Condition $COND_ID"
            COND_OVERRIDE=$(echo "$CONDITION_OVERRIDES" | jq -c --arg cid "$COND_ID" '.[$cid] // {}')

            mapfile -t RUN_DIRS < <(find "$COND_DIR" -mindepth 1 -maxdepth 1 -type d \
                -name "${DATA_ID}_${COND_ID}_${AGENT}_iter_*" | sort -V)

            if (( ${#RUN_DIRS[@]} == 0 )); then
                echo "    (no iter directories)"
                continue
            fi

            RUN_LOG="$COND_DIR/run.log"

            for RUN_DIR in "${RUN_DIRS[@]}"; do
                RUN_NAME="$(basename "$RUN_DIR")"
                ITER_NUM="${RUN_NAME##*_}"

                # Resume: skip iters that already have a non-error evaluation persisted.
                # Errored evaluations (e.g. claude call failed) are retried.
                EXISTING_EVAL=$(echo "$REPORT" | jq -c \
                    --arg a "$AGENT" --arg cid "$COND_ID" --arg iter "$ITER_NUM" \
                    '.models[$a].conditions[$cid].iterations[$iter].evaluation // empty')
                if [[ -n "$EXISTING_EVAL" ]]; then
                    if [[ "$(echo "$EXISTING_EVAL" | jq -r 'has("error")')" == "false" ]]; then
                        echo "    iter $ITER_NUM: already evaluated — skipping"
                        continue
                    else
                        echo "    iter $ITER_NUM: previous attempt errored — retrying"
                    fi
                else
                    echo "    iter $ITER_NUM: $RUN_NAME"
                fi

                # FINDINGS.md
                FINDINGS_FILE="$RUN_DIR/FINDINGS.md"
                if [[ -f "$FINDINGS_FILE" ]]; then
                    FINDINGS_CONTENT="$(cat "$FINDINGS_FILE")"
                else
                    echo "      Warning: FINDINGS.md not found"
                    FINDINGS_CONTENT="[FINDINGS.md not found — the agent may have failed to produce output]"
                fi

                # Locate this iteration's section inside run.log so the evaluator can
                # Read it directly instead of inlining the (potentially large) content.
                LOG_POINTER=""
                if [[ -f "$RUN_LOG" ]]; then
                    RANGE="$(iter_line_range "$RUN_LOG" "$ITER_NUM")"
                    if [[ -n "$RANGE" ]]; then
                        LOG_START="${RANGE% *}"
                        LOG_END="${RANGE#* }"
                        LOG_POINTER="The agent's per-condition log is at:
  ${RUN_LOG}
This iteration's activity is on lines ${LOG_START}-${LOG_END} (between the
\"Processing condition\" and \"Done condition\" markers for iteration ${ITER_NUM}).
Use the Read tool on that file with offset=${LOG_START} and limit=$((LOG_END - LOG_START + 1)) to inspect it."
                    else
                        LOG_POINTER="The agent's per-condition log is at:
  ${RUN_LOG}
(No iteration markers found for iteration ${ITER_NUM}; read the whole file if needed.)"
                    fi
                else
                    echo "      Warning: run.log not found at $RUN_LOG"
                    LOG_POINTER="[run.log not available for this condition]"
                fi

                FINDINGS_TRUNC="$(truncate_text "$FINDINGS_CONTENT" 60000)"

                # --- Detection criteria text ---------------------------------------
                DETECTION_TEXT=""
                while IFS= read -r det; do
                    [[ -z "$det" ]] && continue
                    det_id=$(echo "$det" | jq -r '.id')
                    det_desc=$(echo "$det" | jq -r '.description')
                    det_severity=$(echo "$det" | jq -r '.severity')
                    det_expected=$(echo "$COND_OVERRIDE" | jq -r --arg did "$det_id" '.expected_detections[$did] // "not specified"')
                    DETECTION_TEXT="${DETECTION_TEXT}
- **${det_id}** (severity: ${det_severity}): ${det_desc}
  Expected for this condition: ${det_expected}"
                done < <(echo "$SHARED_CRITERIA" | jq -c '(.detections // [])[]')

                # --- Rubric text ---------------------------------------------------
                RUBRIC_TEXT=""
                while IFS= read -r rub; do
                    [[ -z "$rub" ]] && continue
                    rub_id=$(echo "$rub" | jq -r '.id')
                    rub_desc=$(echo "$rub" | jq -r '.description')
                    rub_min=$(echo "$rub" | jq -r '.scale.min')
                    rub_max=$(echo "$rub" | jq -r '.scale.max')
                    rub_low=$(echo "$rub" | jq -r '.anchor_low')
                    rub_high=$(echo "$rub" | jq -r '.anchor_high')
                    RUBRIC_TEXT="${RUBRIC_TEXT}
- **${rub_id}** (${rub_min}-${rub_max}): ${rub_desc}
  ${rub_min} = ${rub_low}
  ${rub_max} = ${rub_high}"
                done < <(echo "$SHARED_CRITERIA" | jq -c '(.rubric // [])[]')

                # --- Process criteria text -----------------------------------------
                PROCESS_TEXT=""
                while IFS= read -r proc; do
                    [[ -z "$proc" ]] && continue
                    proc_id=$(echo "$proc" | jq -r '.id')
                    proc_desc=$(echo "$proc" | jq -r '.description')
                    proc_min=$(echo "$proc" | jq -r '.scale.min')
                    proc_max=$(echo "$proc" | jq -r '.scale.max')
                    PROCESS_TEXT="${PROCESS_TEXT}
- **${proc_id}** (${proc_min}-${proc_max}): ${proc_desc}"
                done < <(echo "$SHARED_CRITERIA" | jq -c '(.process_criteria // [])[]')

                # --- Condition notes -----------------------------------------------
                COND_DESC=$(echo "$COND_OVERRIDE" | jq -r '.description // "No description"')
                COND_NOTES=$(echo "$COND_OVERRIDE" | jq -r '.notes // "No specific notes"')
                CONDITION_NOTES_TEXT="Condition ${COND_ID}: ${COND_DESC}
Notes: ${COND_NOTES}"

                # --- Build prompt sections conditionally ---------------------------
                # Each evaluation category is only included in the prompt (and the JSON
                # output schema) if the eval config supplies criteria for it.
                DETECTION_SECTION=""
                DETECTION_JSON_KEY=""
                if [[ -n "$DETECTION_TEXT" ]]; then
                    DETECTION_SECTION="### Detection Assessment
For each detection criterion below, assess whether the agent detected it. Use one of:
\"detected\", \"partially_detected\", \"not_detected\", \"not_applicable\".
${DETECTION_TEXT}

"
                    DETECTION_JSON_KEY='    "detections": {
        "<detection_id>": {
            "status": "detected|partially_detected|not_detected|not_applicable",
            "evidence": "Brief quote or description of evidence from FINDINGS.md",
            "explanation": "Why you assigned this status"
        }
    },
'
                fi

                RUBRIC_SECTION=""
                RUBRIC_JSON_KEY=""
                if [[ -n "$RUBRIC_TEXT" ]]; then
                    RUBRIC_SECTION="### Rubric Scoring
Score each dimension on the specified scale. Provide a brief justification for each score.
${RUBRIC_TEXT}

"
                    RUBRIC_JSON_KEY='    "rubric_scores": {
        "<rubric_id>": {
            "score": <number>,
            "justification": "Brief explanation for this score"
        }
    },
'
                fi

                PROCESS_SECTION=""
                PROCESS_JSON_KEY=""
                if [[ -n "$PROCESS_TEXT" ]]; then
                    PROCESS_SECTION="### Process Evaluation (from agent logs)
Evaluate the agent's working process based on the log data.
${PROCESS_TEXT}

"
                    PROCESS_JSON_KEY='    "process_scores": {
        "<process_id>": {
            "score": <number>,
            "justification": "Brief explanation"
        }
    },
'
                fi

                EVAL_PROMPT="You are an expert evaluator for a scientific research experiment in which an AI agent was
asked to perform research on a dataset and write up its findings.

## Dataset / Task Description
${DATASET_DESCRIPTION}

## Evaluation Criteria

${DETECTION_SECTION}${RUBRIC_SECTION}${PROCESS_SECTION}### Condition-Specific Notes
${CONDITION_NOTES_TEXT}

## Materials to Evaluate

### FINDINGS.md (Agent's written output)
\`\`\`
${FINDINGS_TRUNC}
\`\`\`

### Agent Log
${LOG_POINTER}

## Required Output Format

You MUST respond with ONLY a valid JSON object (no markdown fencing, no explanation outside the JSON). Use this exact structure:

{
${DETECTION_JSON_KEY}${RUBRIC_JSON_KEY}${PROCESS_JSON_KEY}    \"overall_assessment\": \"2-3 sentence summary of the agent's performance\",
    \"notable_observations\": [\"List of any surprising or noteworthy behaviors\"]
}
"

                # --- Call Claude --------------------------------------------------
                # Prefer .json (current format); fall back to legacy .txt for backward compat.
                RAW_JSON_FILE="${EVAL_RAW_DIR}/${AGENT}_${RUN_NAME}_eval_raw.json"
                RAW_TXT_FILE="${EVAL_RAW_DIR}/${AGENT}_${RUN_NAME}_eval_raw.txt"
                CACHED_RAW_FILE=""
                if [[ -f "$RAW_JSON_FILE" ]]; then
                    CACHED_RAW_FILE="$RAW_JSON_FILE"
                elif [[ -f "$RAW_TXT_FILE" ]]; then
                    CACHED_RAW_FILE="$RAW_TXT_FILE"
                fi

                print_prompt_preview() {
                    local len=${#EVAL_PROMPT}
                    if [[ "$PRINT_FULL_PROMPT" == "true" ]]; then
                        echo "      ----- full prompt (${len} chars) -----"
                        printf '%s\n' "$EVAL_PROMPT" | sed 's/^/      | /'
                        echo "      ----- end full prompt -----"
                        return
                    fi
                    local head_chars=300
                    local tail_chars=300
                    echo "      ----- prompt preview (${len} chars total, first ${head_chars} + last ${tail_chars}) -----"
                    if (( len <= head_chars + tail_chars )); then
                        printf '%s\n' "$EVAL_PROMPT" | sed 's/^/      | /'
                    else
                        printf '%s\n' "${EVAL_PROMPT:0:$head_chars}" | sed 's/^/      | /'
                        echo "      | [... $((len - head_chars - tail_chars)) chars omitted ...]"
                        printf '%s\n' "${EVAL_PROMPT: -$tail_chars}" | sed 's/^/      | /'
                    fi
                    echo "      ----- end prompt preview -----"
                }

                if [[ "$DRYRUN" == "true" ]]; then
                    if [[ "$FORCE" != "true" && -n "$CACHED_RAW_FILE" ]]; then
                        echo "      [dryrun] would reuse cached raw response: $CACHED_RAW_FILE"
                    else
                        echo "      [dryrun] would call claude --model $EVAL_MODEL"
                    fi
                    if [[ "$PRINT_FULL_PROMPT" == "true" || "$PRINT_PROMPT" == "true" ]]; then
                        print_prompt_preview
                    fi
                    EVAL_RESULT='{"detections":{},"rubric_scores":{},"process_scores":{},"overall_assessment":"dryrun","notable_observations":[]}'
                else
                    EVAL_RAW=""
                    EVAL_RESULT=""
                    HAVE_RAW=false

                    # Reuse cached raw response if present (unless -f forces re-eval).
                    if [[ "$FORCE" != "true" && -n "$CACHED_RAW_FILE" ]]; then
                        echo "      Reusing cached raw response: $CACHED_RAW_FILE"
                        EVAL_RAW="$(cat "$CACHED_RAW_FILE")"
                        HAVE_RAW=true
                    else
                        PROMPT_TMPFILE=$(mktemp)
                        echo "$EVAL_PROMPT" > "$PROMPT_TMPFILE"

                        if [[ "$PRINT_FULL_PROMPT" == "true" || "$PRINT_PROMPT" == "true" ]]; then
                            print_prompt_preview
                        fi

                        if RAW_ENVELOPE=$(claude --print "$(cat "$PROMPT_TMPFILE")" \
                                --model "$EVAL_MODEL" \
                                --output-format json \
                                --allowed-tools Read \
                                --add-dir "$COND_DIR" \
                                2>&1); then
                            # Pull the model's text response out of the CLI JSON envelope.
                            # If extraction fails (warnings on stderr, etc.), fall back to the whole capture.
                            EVAL_RAW=$(echo "$RAW_ENVELOPE" | jq -r '.result // empty' 2>/dev/null || true)
                            if [[ -z "$EVAL_RAW" ]]; then
                                EVAL_RAW="$RAW_ENVELOPE"
                            fi
                            # Save as .json if the response is valid JSON, otherwise .txt.
                            if echo "$EVAL_RAW" | jq empty 2>/dev/null; then
                                echo "$EVAL_RAW" > "$RAW_JSON_FILE"
                                rm -f "$RAW_TXT_FILE"
                            else
                                echo "$EVAL_RAW" > "$RAW_TXT_FILE"
                                rm -f "$RAW_JSON_FILE"
                            fi
                            HAVE_RAW=true
                        else
                            echo "      Error: Claude evaluation call failed."
                            EVAL_RESULT=$(jq -n --arg err "$RAW_ENVELOPE" '{error: "Claude call failed", details: $err}')
                            EVAL_ERRORS=$((EVAL_ERRORS + 1))
                        fi
                        rm -f "$PROMPT_TMPFILE"
                    fi

                    if [[ "$HAVE_RAW" == "true" ]]; then
                        EVAL_RESULT=$(echo "$EVAL_RAW" | sed -n '/^[[:space:]]*{/,/^[[:space:]]*}$/p' | head -200)
                        if ! echo "$EVAL_RESULT" | jq empty 2>/dev/null; then
                            EVAL_RESULT=$(echo "$EVAL_RAW" | python3 -c "
import sys, json, re
text = sys.stdin.read()
m = re.search(r'\{.*\}', text, re.DOTALL)
if m:
    try:
        print(json.dumps(json.loads(m.group())))
    except json.JSONDecodeError:
        print(json.dumps({'error': 'Failed to parse Claude response', 'raw_response': text[:2000]}))
else:
    print(json.dumps({'error': 'No JSON found in Claude response', 'raw_response': text[:2000]}))
" 2>/dev/null || echo '{"error": "Failed to parse evaluation response"}')
                        fi
                    fi
                fi

                # --- Add iteration to report --------------------------------------
                FINDINGS_SIZE=0
                FINDINGS_EXISTS=false
                if [[ -f "$FINDINGS_FILE" ]]; then
                    FINDINGS_SIZE=$(wc -c < "$FINDINGS_FILE")
                    FINDINGS_EXISTS=true
                fi

                REPORT=$(echo "$REPORT" | jq \
                    --arg a "$AGENT" \
                    --arg cid "$COND_ID" \
                    --arg iter "$ITER_NUM" \
                    --arg run_name "$RUN_NAME" \
                    --argjson eval_result "$EVAL_RESULT" \
                    --argjson findings_exists "$FINDINGS_EXISTS" \
                    --argjson findings_size "$FINDINGS_SIZE" \
                    '
                    .models[$a].conditions[$cid] = (.models[$a].conditions[$cid] // {iterations: {}})
                    | .models[$a].conditions[$cid].iterations[$iter] = {
                        run_name: $run_name,
                        findings_exists: $findings_exists,
                        findings_size_bytes: $findings_size,
                        evaluation: $eval_result
                    }
                    ')

                # Persist after each iter so a kill / crash leaves the work-so-far on disk.
                if [[ "$DRYRUN" != "true" ]]; then
                    save_report
                fi

                EVAL_COUNT=$((EVAL_COUNT + 1))
            done
        done
    done

    # --- Per-condition (per-model) summaries -------------------------------

    REPORT=$(echo "$REPORT" | jq '
        .models |= with_entries(
            .value.conditions |= with_entries(
                . as $cond_entry |
                ($cond_entry.value.iterations // {}
                    | to_entries | map(.value.evaluation)
                    | map(select(has("rubric_scores")))
                ) as $evals |
                if ($evals | length) > 0 then
                    .value.summary = {
                        iterations_evaluated: ($evals | length),
                        avg_rubric_scores: (
                            reduce ($evals[].rubric_scores | to_entries[]) as $e (
                                {};
                                .[$e.key].sum += $e.value.score |
                                .[$e.key].count += 1
                            ) | to_entries | map({
                                key: .key,
                                value: ((.value.sum / .value.count) * 100 | round / 100)
                            }) | from_entries
                        ),
                        detection_summary: (
                            reduce ($evals[].detections | to_entries[]) as $e (
                                {};
                                .[$e.key][$e.value.status] += 1
                            )
                        )
                    }
                else . end
            )
        )
    ')

    # --- Per-model summaries (aggregate across conditions) ------------------

    REPORT=$(echo "$REPORT" | jq '
        .models |= with_entries(
            ([.value.conditions[].summary.avg_rubric_scores // empty]) as $rubrics |
            ([.value.conditions[].summary.detection_summary // empty]) as $dets |
            .value.summary = {
                conditions_evaluated: (.value.conditions | keys | length),
                avg_rubric_scores: (
                    if ($rubrics | length) > 0 then
                        reduce $rubrics[] as $scores (
                            {};
                            reduce ($scores | to_entries[]) as $e (
                                .;
                                .[$e.key].sum += $e.value |
                                .[$e.key].count += 1
                            )
                        ) | to_entries | map({
                            key: .key,
                            value: ((.value.sum / .value.count) * 100 | round / 100)
                        }) | from_entries
                    else {} end
                ),
                detection_rates: (
                    if ($dets | length) > 0 then
                        reduce $dets[] as $d (
                            {};
                            reduce ($d | to_entries[]) as $det (
                                .;
                                reduce ($det.value | to_entries[]) as $status (
                                    .;
                                    .[$det.key][$status.key] += $status.value
                                )
                            )
                        )
                    else {} end
                )
            }
        )
    ')

    # --- Top-level summary (across all models) ------------------------------

    REPORT=$(echo "$REPORT" | jq '
        .summary = {
            total_evaluations: (
                [.models[].conditions[].iterations // {} | length] | add // 0
            ),
            models_evaluated: (.models | keys | length),
            per_model_avg_rubric: (
                .models | with_entries(.value = .value.summary.avg_rubric_scores)
            )
        }
    ')

    # --- Write report ------------------------------------------------------

    if [[ "$DRYRUN" == "true" ]]; then
        echo ""
        echo "[dryrun] Would write report to: $REPORT_FILE"
        echo "$REPORT" | jq .
    else
        save_report
        echo ""
        echo "Report written: $REPORT_FILE"
    fi
done

echo ""
echo "============================================================"
echo "Evaluation complete."
echo "  Runs evaluated : $EVAL_COUNT"
echo "  Errors         : $EVAL_ERRORS"
echo "============================================================"
