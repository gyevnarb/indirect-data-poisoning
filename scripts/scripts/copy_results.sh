#!/usr/bin/env bash
# Copy workspace/<dataid>_<model>_<timestamp>/ trees into results/<dataid>/<polarity>/.
#
#   experiments.json, interventions.json  -> results/<dataid>/<polarity>/
#   <index>/<dataid>_<index>_<model>_iter_N -> results/<dataid>/<polarity>/<model>/<index>/
#     If iter_* already exist at the destination (e.g. from an earlier timestamp run),
#     incoming iters are renumbered to start after the current max.
#
# Usage: copy_to_results.sh [negative|positive] [-n]
#   polarity defaults to "negative"
#   -n / --dry-run prints actions without copying

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$ROOT/workspace"
RESULTS="$ROOT/results"
LOGS="$ROOT/logs"

polarity="negative"
dry_run=0
for arg in "$@"; do
    case "$arg" in
        negative|positive) polarity="$arg" ;;
        -n|--dry-run)      dry_run=1 ;;
        -h|--help)         sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

[[ -d "$WORKSPACE" ]] || { echo "missing workspace: $WORKSPACE" >&2; exit 1; }

run() {
    if (( dry_run )); then
        printf '    [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# Collate per-condition logs across timestamps into a single run.log.
#   Args: dataid model polarity condition
#   Source logs: logs/<dataid>_<model>_<ts>/exp_<dataid>__<C>__<ts>_.log (sorted by ts asc)
#   Dest:        results/<dataid>/<polarity>/<model>/<C>/run.log  (skipped if exists)
# Transforms:
#   - preamble taken from earliest log; "ITERATIONS (K) ... : N" rewritten to grand total
#   - "Skipping condition '...'" lines dropped
#   - each "=== Processing condition: C/T [iteration K/M] ===" block has K renumbered
#     1..grand consecutively across timestamps and M rewritten to grand total
collate_logs() {
    local dataid="$1" model="$2" polarity="$3" cond="$4"
    local dst="$RESULTS/$dataid/$polarity/$model/$cond/run.log"

    if [[ -e "$dst" ]]; then
        echo "  log: skip (exists): results/$dataid/$polarity/$model/$cond/run.log"
        return
    fi

    # Collect source logs for this (dataid, model, cond), sorted by timestamp ascending.
    local srcs=()
    while IFS= read -r line; do
        srcs+=("$line")
    done < <(
        for ts_dir in "$LOGS/${dataid}_${model}_"*/; do
            ts_dir="${ts_dir%/}"
            [[ -d "$ts_dir" ]] || continue
            local ts_name; ts_name="$(basename "$ts_dir")"
            local log="$ts_dir/exp_${dataid}__${cond}__${ts_name}_.log"
            [[ -f "$log" ]] && echo "$log"
        done | sort
    )

    if [[ ${#srcs[@]} -eq 0 ]]; then
        return
    fi

    # Grand total = sum of "Processing condition" headers across all source logs.
    local grand_total=0 n
    for log in "${srcs[@]}"; do
        n=$(grep -c '^=============== Processing condition:' "$log" || true)
        grand_total=$(( grand_total + n ))
    done

    echo "  log: results/$dataid/$polarity/$model/$cond/run.log  (sources=${#srcs[@]}, iters=$grand_total)"
    if (( dry_run )); then
        return
    fi

    mkdir -p "$(dirname "$dst")"
    awk -v grand="$grand_total" \
        -v num_files="${#srcs[@]}" \
        -v prefix="${dataid}_${cond}_${model}" \
        -v Q="'" '
        BEGIN { state = "preamble"; counter = 0; renamed = 0 }
        FNR == 1 {
            file_idx++
            if (file_idx > 1) state = "preamble"
        }
        state == "preamble" {
            if (/^=+ Processing condition:/) {
                state = "iter"
                # fall through to iter handler
            } else {
                if (/^Skipping condition /) next
                if (file_idx == 1) {
                    if ($0 ~ /^  ITERATIONS \(K\)/) sub(/: *[0-9]+/, ": " grand)
                    print
                }
                next
            }
        }
        state == "iter" {
            if (/^Renaming iteration directories for condition /) {
                state = "postamble"
                if (file_idx == num_files) {
                    print
                    for (i = 1; i <= grand; i++) {
                        printf("  Renamed %s%d%s -> %s%s_iter_%d%s\n", Q, i, Q, Q, prefix, i, Q)
                    }
                }
                next
            }
            if (/^=+ Processing condition:/) {
                counter++
                sub(/\[iteration [0-9]+\/[0-9]+\]/, "[iteration " counter "/" grand "]")
            } else if (/^=+ Done condition:/) {
                sub(/\[iteration [0-9]+\/[0-9]+\]/, "[iteration " counter "/" grand "]")
            }
            print
            next
        }
        state == "postamble" {
            if (/^  Renamed /) next
            if (file_idx == num_files) print
            next
        }
    ' "${srcs[@]}" > "$dst"
}

# Highest existing iter_N in a destination index dir (0 if none).
max_iter() {
    local dir="$1" best=0 n
    [[ -d "$dir" ]] || { echo 0; return; }
    for entry in "$dir"/*_iter_*; do
        [[ -d "$entry" ]] || continue
        n="${entry##*_iter_}"
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        (( n > best )) && best=$n
    done
    echo "$best"
}

shopt -s nullglob

for ws in "$WORKSPACE"/*/; do
    ws="${ws%/}"
    name="$(basename "$ws")"

    # Parse <dataid>_<model>_<YYYYMMDD>_<HHMMSS>
    if [[ ! "$name" =~ ^([^_]+)_([^_]+)_([0-9]{8})_([0-9]{6})$ ]]; then
        echo "skip (bad name): $name" >&2
        continue
    fi
    dataid="${BASH_REMATCH[1]}"
    model="${BASH_REMATCH[2]}"

    polarity_dir="$RESULTS/$dataid/$polarity"
    model_dir="$polarity_dir/$model"
    echo "== $name -> $polarity =="

    # Top-level metadata files.
    for fname in experiments.json interventions.json; do
        src="$ws/$fname"
        [[ -f "$src" ]] || continue
        dst="$polarity_dir/$fname"
        echo "  file: workspace/$name/$fname -> results/$dataid/$polarity/$fname"
        run mkdir -p "$polarity_dir"
        run cp -p "$src" "$dst"
    done

    # Iter folders, grouped under each numeric index dir.
    for index_dir in "$ws"/*/; do
        index_dir="${index_dir%/}"
        index="$(basename "$index_dir")"
        [[ "$index" =~ ^[0-9]+$ ]] || continue

        dst_index="$model_dir/$index"
        offset="$(max_iter "$dst_index")"

        # Collect (n, src) pairs sorted by n.
        mapfile -t iter_paths < <(
            for it in "$index_dir"/*_iter_*; do
                [[ -d "$it" ]] || continue
                n="${it##*_iter_}"
                [[ "$n" =~ ^[0-9]+$ ]] || continue
                printf '%d\t%s\n' "$n" "$it"
            done | sort -n
        )

        for line in "${iter_paths[@]}"; do
            src_n="${line%%$'\t'*}"
            src="${line#*$'\t'}"
            base="$(basename "$src")"
            prefix="${base%_iter_*}"
            new_n=$(( src_n + offset ))
            dst="$dst_index/${prefix}_iter_${new_n}"

            echo "  iter: workspace/$name/$index/$base -> results/$dataid/$polarity/$model/$index/${prefix}_iter_${new_n}"
            if [[ -e "$dst" ]]; then
                echo "    !! destination exists, skipping: $dst" >&2
                continue
            fi
            run mkdir -p "$dst_index"
            run cp -a "$src" "$dst" || echo "    !! cp failed (continuing): $src" >&2
        done
    done
done

# ---------------------------------------------------------------------------
# Collate per-condition logs across timestamps into results/.../<C>/run.log.
# ---------------------------------------------------------------------------
if [[ -d "$LOGS" ]]; then
    declare -A pairs=()
    for ts_dir in "$LOGS"/*/; do
        ts_dir="${ts_dir%/}"
        ts_name="$(basename "$ts_dir")"
        if [[ "$ts_name" =~ ^([^_]+)_([^_]+)_[0-9]{8}_[0-9]{6}$ ]]; then
            pairs["${BASH_REMATCH[1]}|${BASH_REMATCH[2]}"]=1
        fi
    done

    for key in "${!pairs[@]}"; do
        dataid="${key%|*}"
        model="${key#*|}"
        echo "== logs: ${dataid}_${model} -> $polarity =="

        declare -A conds=()
        for log in "$LOGS/${dataid}_${model}_"*/exp_"${dataid}"__*__*_.log; do
            [[ -f "$log" ]] || continue
            base="$(basename "$log")"
            if [[ "$base" =~ ^exp_${dataid}__([0-9]+)__ ]]; then
                conds["${BASH_REMATCH[1]}"]=1
            fi
        done

        for C in $(printf '%s\n' "${!conds[@]}" | sort -n); do
            collate_logs "$dataid" "$model" "$polarity" "$C"
        done
        unset conds
    done
fi
