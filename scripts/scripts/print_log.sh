#!/usr/bin/env bash
# Pretty-print a Claude Code or Gemini execution log (.jsonl) embedded in a broader log file.
# Requires: jq
set -euo pipefail

# ── Colours & styles ──────────────────────────────────────────────────────
RST=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
ITALIC=$'\033[3m'

FG_RED=$'\033[31m'
FG_GREEN=$'\033[32m'
FG_YELLOW=$'\033[33m'
FG_BLUE=$'\033[34m'
FG_MAGENTA=$'\033[35m'
FG_CYAN=$'\033[36m'
FG_WHITE=$'\033[37m'
FG_GRAY=$'\033[90m'

BG_BLUE=$'\033[44m'
BG_GREEN=$'\033[42m'
BG_YELLOW=$'\033[43m'
BG_MAGENTA=$'\033[45m'

WIDTH=100

# ── Filter & truncation defaults ─────────────────────────────────────────
SHOW_SYSTEM=true
SHOW_USER=true
SHOW_ASSISTANT=true
MAX_LINES=0   # 0 = use per-call defaults

separator() {
  printf '%s%*s%s\n' "$FG_GRAY" "$WIDTH" '' "$RST" | tr ' ' '─'
}

# ── Text wrapping helper ─────────────────────────────────────────────────
# Prints text indented, wrapping at $WIDTH. Accepts colour prefix as $1.
wrap() {
  local color="$1"
  shift
  local text="$*"
  if ((MAX_LINES > 0)); then
    echo "$text" | fold -s -w $((WIDTH - 4)) | head -n "$MAX_LINES" | sed "s/^/    ${color}/" | sed "s/$/${RST}/"
    local total
    total=$(echo "$text" | fold -s -w $((WIDTH - 4)) | wc -l)
    if ((total > MAX_LINES)); then
      printf '    %s… (%d more lines)%s\n' "$FG_GRAY" $((total - MAX_LINES)) "$RST"
    fi
  else
    echo "$text" | fold -s -w $((WIDTH - 4)) | sed "s/^/    ${color}/" | sed "s/$/${RST}/"
  fi
}

# Truncate output: print first N lines, then "… (X more lines)"
print_truncated() {
  local max_lines="${1:-20}"
  if ((MAX_LINES > 0)); then max_lines=$MAX_LINES; fi
  local color="${2:-$DIM}"
  local lines=()
  while IFS= read -r l; do lines+=("$l"); done

  local total=${#lines[@]}
  local show=$((total < max_lines ? total : max_lines))

  for ((i = 0; i < show; i++)); do
    printf '    %s%s%s\n' "$color" "${lines[$i]}" "$RST"
  done
  if ((total > max_lines)); then
    printf '    %s… (%d more lines)%s\n' "$FG_GRAY" $((total - max_lines)) "$RST"
  fi
}

# ── Format a timestamp ────────────────────────────────────────────────────
fmt_ts() {
  local iso="$1"
  if [[ -z "$iso" ]]; then return; fi
  # Try GNU date first, fall back to showing raw
  if date --version &>/dev/null; then
    date -d "$iso" '+%H:%M:%S' 2>/dev/null || echo "$iso"
  elif command -v gdate &>/dev/null; then
    gdate -d "$iso" '+%H:%M:%S' 2>/dev/null || echo "$iso"
  else
    # macOS date: strip to time portion
    echo "${iso}" | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1 || echo "$iso"
  fi
}

# ── Printers for each content type ───────────────────────────────────────

print_system_init() {
  local json="$1"
  printf '\n%s ⚙  SYSTEM %s\n' "${BG_MAGENTA}${FG_WHITE}${BOLD}" "$RST"
  printf '  %sSession:%s  %s\n' "${FG_CYAN}" "$RST" "$(echo "$json" | jq -r '.session_id // "?"')"
  printf '  %sModel:%s    %s\n' "${FG_CYAN}" "$RST" "$(echo "$json" | jq -r '.model // "?"')"
  printf '  %sVersion:%s  %s\n' "${FG_CYAN}" "$RST" "$(echo "$json" | jq -r '.claude_code_version // "?"')"
  printf '  %sCWD:%s      %s\n' "${FG_CYAN}" "$RST" "$(echo "$json" | jq -r '.cwd // "?"')"

  local description
  description=$(echo "$json" | jq -r '.description // empty')
  if [[ -n "$description" ]]; then printf '  %sDesc:%s     %s\n' "${FG_CYAN}" "$RST" "$description"; fi

  local tools
  tools=$(echo "$json" | jq -r '(.tools // [])[:10] | join(", ")')
  local tool_count
  tool_count=$(echo "$json" | jq '(.tools // []) | length')
  local suffix=""
  if ((tool_count > 10)); then suffix="…"; fi
  if [[ -n "$tools" ]]; then printf '  %sTools:%s    %s%s\n' "${FG_CYAN}" "$RST" "$tools" "$suffix"; fi

  local agents
  agents=$(echo "$json" | jq -r '(.agents // []) | join(", ")')
  if [[ -n "$agents" ]]; then printf '  %sAgents:%s   %s\n' "${FG_CYAN}" "$RST" "$agents"; fi
  separator
}

print_thinking() {
  local text="$1"
  printf '  %s%s💭 Thinking:%s\n' "$FG_MAGENTA" "$ITALIC" "$RST"
  echo "$text" | print_truncated 12 "${FG_MAGENTA}${DIM}"
}

print_text() {
  local text="$1"
  printf '  %s%s💬 Text:%s\n' "$FG_WHITE" "$BOLD" "$RST"
  wrap "$FG_WHITE" "$text"
}

print_tool_use() {
  local block_json="$1"
  local tool name tool_id
  tool=$(echo "$block_json" | jq -r '.name // "?"')
  tool_id=$(echo "$block_json" | jq -r '.id // ""')

  printf '  %s%s🔧 Tool Call: %s%s  %s(%s)%s\n' \
    "$FG_YELLOW" "$BOLD" "$tool" "$RST" "$FG_GRAY" "$tool_id" "$RST"

  case "$tool" in
    Bash)
      local cmd desc
      cmd=$(echo "$block_json" | jq -r '.input.command // ""')
      desc=$(echo "$block_json" | jq -r '.input.description // ""')
      if [[ -n "$desc" ]]; then printf '    %s# %s%s\n' "$FG_GRAY" "$desc" "$RST"; fi
      printf '    %s$%s %s%s%s\n' "$FG_GREEN" "$RST" "$FG_CYAN" "$cmd" "$RST"
      ;;
    Read)
      printf '    %s📄 %s%s\n' "$FG_CYAN" "$(echo "$block_json" | jq -r '.input.file_path // "?"')" "$RST"
      ;;
    Write|Edit)
      printf '    %s✏️  %s%s\n' "$FG_CYAN" "$(echo "$block_json" | jq -r '.input.file_path // "?"')" "$RST"
      ;;
    WebSearch|WebFetch)
      local target
      target=$(echo "$block_json" | jq -r '.input.query // .input.url // "?"')
      printf '    %s🌐 %s%s\n' "$FG_CYAN" "$target" "$RST"
      ;;
    *)
      # Generic: show each input key
      echo "$block_json" | jq -r '.input // {} | to_entries[] | "\(.key): \(.value | tostring | if length > 120 then .[:120] + "…" else . end)"' \
        | while IFS= read -r kv; do
            printf '    %s%s%s\n' "$FG_GRAY" "$kv" "$RST"
          done || true
      ;;
  esac
}

print_usage() {
  local msg_json="$1"
  local parts=""
  local inp out cr cc
  inp=$(echo "$msg_json" | jq '.usage.input_tokens // empty')
  out=$(echo "$msg_json" | jq '.usage.output_tokens // empty')
  cr=$(echo "$msg_json" | jq '.usage.cache_read_input_tokens // empty')
  cc=$(echo "$msg_json" | jq '.usage.cache_creation_input_tokens // empty')

  if [[ -n "$inp" ]]; then parts+="in=$inp"; fi
  if [[ -n "$out" ]]; then [[ -n "$parts" ]] && parts+=" · "; parts+="out=$out"; fi
  if [[ -n "$cr" ]]; then [[ -n "$parts" ]] && parts+=" · "; parts+="cache_read=$cr"; fi
  if [[ -n "$cc" ]]; then [[ -n "$parts" ]] && parts+=" · "; parts+="cache_create=$cc"; fi

  if [[ -n "$parts" ]]; then printf '  %s📊 Tokens: %s%s\n' "$FG_GRAY" "$parts" "$RST"; fi
}

print_tool_result_content() {
  local entry_json="$1"
  local stdout stderr interrupted

  # tool_use_result can be a string or an object; guard accordingly
  local result_type
  result_type=$(echo "$entry_json" | jq -r '.tool_use_result | type')

  if [[ "$result_type" == "string" ]]; then
    local result_str
    result_str=$(echo "$entry_json" | jq -r '.tool_use_result')
    if [[ -n "$result_str" ]]; then
      echo "$result_str" | print_truncated 20 "$DIM"
    fi
    return
  fi

  stdout=$(echo "$entry_json" | jq -r '.tool_use_result.stdout // empty')
  stderr=$(echo "$entry_json" | jq -r '.tool_use_result.stderr // empty')
  interrupted=$(echo "$entry_json" | jq -r '.tool_use_result.interrupted // false')

  if [[ "$interrupted" == "true" ]]; then printf '    %s%s⚠ INTERRUPTED%s\n' "$FG_RED" "$BOLD" "$RST"; fi

  if [[ -n "$stdout" ]]; then
    local trimmed
    trimmed=$(echo "$stdout" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [[ -n "$trimmed" ]]; then
      printf '  %s📤 stdout:%s\n' "$FG_GREEN" "$RST"
      echo "$trimmed" | print_truncated 20 "$DIM"
    fi
    if [[ -n "$stderr" ]]; then
      local strimmed
      strimmed=$(echo "$stderr" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      if [[ -n "$strimmed" ]]; then
        printf '  %s📤 stderr:%s\n' "$FG_RED" "$RST"
        echo "$strimmed" | print_truncated 10 "${FG_RED}${DIM}"
      fi
    fi
    return
  fi

  # Fallback: try inline content string from the tool_result block
  local inline
  inline=$(echo "$entry_json" | jq -r '.message.content[0].content // empty' 2>/dev/null)
  if [[ -n "$inline" ]]; then
    echo "$inline" | print_truncated 20 "$DIM"
    return
  fi

  # File read result
  local file_path file_content
  file_path=$(echo "$entry_json" | jq -r '.tool_use_result.file.filePath // empty' 2>/dev/null)
  if [[ -n "$file_path" ]]; then
    local total_lines
    total_lines=$(echo "$entry_json" | jq -r '.tool_use_result.file.totalLines // "?"' 2>/dev/null)
    printf '    %s📄 %s%s  %s(%s lines)%s\n' "$FG_CYAN" "$file_path" "$RST" "$FG_GRAY" "$total_lines" "$RST"
    file_content=$(echo "$entry_json" | jq -r '.tool_use_result.file.content // empty' 2>/dev/null)
    if [[ -n "$file_content" ]]; then
      echo "$file_content" | print_truncated 15 "$DIM"
    fi
  fi
}

# ── Gemini-specific printers ─────────────────────────────────────────────

# Map Gemini tool name to a Claude-style alias for shared rendering paths.
gemini_tool_alias() {
  case "$1" in
    run_shell_command)              echo "Bash" ;;
    write_file)                     echo "Write" ;;
    read_file)                      echo "Read" ;;
    replace|edit_file)              echo "Edit" ;;
    google_web_search|web_search)   echo "WebSearch" ;;
    web_fetch)                      echo "WebFetch" ;;
    *)                              echo "$1" ;;
  esac
}

print_gemini_init() {
  local json="$1"
  printf '\n%s ⚙  SYSTEM (Gemini) %s\n' "${BG_MAGENTA}${FG_WHITE}${BOLD}" "$RST"
  printf '  %sSession:%s  %s\n' "${FG_CYAN}" "$RST" "$(echo "$json" | jq -r '.session_id // "?"')"
  printf '  %sModel:%s    %s\n' "${FG_CYAN}" "$RST" "$(echo "$json" | jq -r '.model // "?"')"
  separator
}

print_gemini_tool_use() {
  local block_json="$1"
  local raw_name tool tool_id
  raw_name=$(echo "$block_json" | jq -r '.tool_name // "?"')
  tool_id=$(echo "$block_json" | jq -r '.tool_id // ""')
  tool=$(gemini_tool_alias "$raw_name")

  printf '  %s%s🔧 Tool Call: %s%s  %s(%s)%s\n' \
    "$FG_YELLOW" "$BOLD" "$tool" "$RST" "$FG_GRAY" "$tool_id" "$RST"

  case "$tool" in
    Bash)
      local cmd desc
      cmd=$(echo "$block_json" | jq -r '.parameters.command // ""')
      desc=$(echo "$block_json" | jq -r '.parameters.description // ""')
      if [[ -n "$desc" ]]; then printf '    %s# %s%s\n' "$FG_GRAY" "$desc" "$RST"; fi
      printf '    %s$%s %s%s%s\n' "$FG_GREEN" "$RST" "$FG_CYAN" "$cmd" "$RST"
      ;;
    Read)
      printf '    %s📄 %s%s\n' "$FG_CYAN" \
        "$(echo "$block_json" | jq -r '.parameters.file_path // .parameters.absolute_path // "?"')" "$RST"
      ;;
    Write|Edit)
      printf '    %s✏️  %s%s\n' "$FG_CYAN" \
        "$(echo "$block_json" | jq -r '.parameters.file_path // .parameters.absolute_path // "?"')" "$RST"
      ;;
    WebSearch|WebFetch)
      local target
      target=$(echo "$block_json" | jq -r '.parameters.query // .parameters.url // "?"')
      printf '    %s🌐 %s%s\n' "$FG_CYAN" "$target" "$RST"
      ;;
    *)
      echo "$block_json" | jq -r '.parameters // {} | to_entries[] | "\(.key): \(.value | tostring | if length > 120 then .[:120] + "…" else . end)"' \
        | while IFS= read -r kv; do
            printf '    %s%s%s\n' "$FG_GRAY" "$kv" "$RST"
          done || true
      ;;
  esac
}

print_gemini_tool_result() {
  local json="$1"
  local tool_id status timestamp time_str content
  tool_id=$(echo "$json" | jq -r '.tool_id // ""')
  status=$(echo "$json" | jq -r '.status // "?"')
  timestamp=$(echo "$json" | jq -r '.timestamp // ""')
  time_str=$(fmt_ts "$timestamp")

  local err_tag=""
  if [[ "$status" != "success" ]]; then err_tag="  ${FG_RED}${BOLD}${status}${RST}"; fi

  printf '\n%s 👤 USER (tool result) %s  %s%s  ← %s%s%s\n' \
    "${BG_GREEN}${FG_WHITE}${BOLD}" "$RST" "$FG_GRAY" "$time_str" "$tool_id" "$RST" "$err_tag"

  content=$(echo "$json" | jq -r '.content // .output // .stdout // empty')
  if [[ -n "$content" ]]; then
    echo "$content" | print_truncated 20 "$DIM"
  else
    printf '    %s✓ %s%s\n' "$FG_GREEN" "$status" "$RST"
  fi
}

print_gemini_message() {
  local json="$1"
  local role timestamp time_str content model
  role=$(echo "$json" | jq -r '.role // ""')
  timestamp=$(echo "$json" | jq -r '.timestamp // ""')
  time_str=$(fmt_ts "$timestamp")
  content=$(echo "$json" | jq -r '.content // ""')

  case "$role" in
    user)
      if [[ "$SHOW_USER" != "true" ]]; then return; fi
      printf '\n%s 👤 USER %s  %s%s%s\n' \
        "${BG_GREEN}${FG_WHITE}${BOLD}" "$RST" "$FG_GRAY" "$time_str" "$RST"
      if [[ -n "$content" ]]; then wrap "$FG_WHITE" "$content"; fi
      ;;
    assistant)
      if [[ "$SHOW_ASSISTANT" != "true" ]]; then return; fi
      model=$(echo "$json" | jq -r '.model // ""')
      printf '\n%s 🤖 ASSISTANT %s  %s%s%s\n' \
        "${BG_BLUE}${FG_WHITE}${BOLD}" "$RST" "$FG_GRAY" "$model" "$RST"
      if [[ -n "$content" ]]; then print_text "$content"; fi
      ;;
  esac
}

print_gemini_result() {
  local json="$1"
  printf '\n%s ✅ RESULT %s\n' "${BG_MAGENTA}${FG_WHITE}${BOLD}" "$RST"
  local status total inp out cached duration tool_calls
  status=$(echo "$json" | jq -r '.status // "?"')
  total=$(echo "$json" | jq -r '.stats.total_tokens // empty')
  inp=$(echo "$json" | jq -r '.stats.input_tokens // empty')
  out=$(echo "$json" | jq -r '.stats.output_tokens // empty')
  cached=$(echo "$json" | jq -r '.stats.cached // empty')
  duration=$(echo "$json" | jq -r '.stats.duration_ms // empty')
  tool_calls=$(echo "$json" | jq -r '.stats.tool_calls // empty')

  printf '  %sStatus:%s     %s\n' "${FG_CYAN}" "$RST" "$status"
  if [[ -n "$total" ]]; then
    printf '  %sTokens:%s     total=%s · in=%s · out=%s · cached=%s\n' \
      "${FG_CYAN}" "$RST" "$total" "$inp" "$out" "$cached"
  fi
  if [[ -n "$duration" ]]; then printf '  %sDuration:%s   %sms\n' "${FG_CYAN}" "$RST" "$duration"; fi
  if [[ -n "$tool_calls" ]]; then printf '  %sTool calls:%s %s\n' "${FG_CYAN}" "$RST" "$tool_calls"; fi
}

# ── Process a single JSONL entry ──────────────────────────────────────────
process_entry() {
  local json="$1"
  local etype
  etype=$(echo "$json" | jq -r '.type')

  case "$etype" in
    system)
      if [[ "$SHOW_SYSTEM" != "true" ]]; then return; fi
      print_system_init "$json"
      ;;

    assistant)
      if [[ "$SHOW_ASSISTANT" != "true" ]]; then return; fi
      local last_block_type last_block model msg_id
      last_block_type=$(echo "$json" | jq -r '.message.content[-1].type // empty')
      model=$(echo "$json" | jq -r '.message.model // ""')
      msg_id=$(echo "$json" | jq -r '.message.id // ""')

      case "$last_block_type" in
        thinking)
          printf '\n%s 🤖 ASSISTANT %s  %s%s  %s%s\n' \
            "${BG_BLUE}${FG_WHITE}${BOLD}" "$RST" "$FG_GRAY" "$model" "$msg_id" "$RST"
          local thinking_text
          thinking_text=$(echo "$json" | jq -r '.message.content[-1].thinking // ""')
          print_thinking "$thinking_text"
          print_usage "$(echo "$json" | jq '.message')"
          separator
          ;;
        text)
          local text
          text=$(echo "$json" | jq -r '.message.content[-1].text // ""')
          if [[ -n "$text" ]]; then
            printf '\n%s 🤖 ASSISTANT %s  %s%s%s\n' \
              "${BG_BLUE}${FG_WHITE}${BOLD}" "$RST" "$FG_GRAY" "$model" "$RST"
            print_text "$text"
            separator
          fi
          ;;
        tool_use)
          printf '\n%s 🤖 ASSISTANT %s  %s%s%s\n' \
            "${BG_BLUE}${FG_WHITE}${BOLD}" "$RST" "$FG_GRAY" "$model" "$RST"
          local block
          block=$(echo "$json" | jq -c '.message.content[-1]')
          print_tool_use "$block"
          print_usage "$(echo "$json" | jq '.message')"
          separator
          ;;
      esac
      ;;

    user)
      if [[ "$SHOW_USER" != "true" ]]; then return; fi
      local timestamp tool_use_id is_error time_str content_type
      timestamp=$(echo "$json" | jq -r '.timestamp // ""')
      content_type=$(echo "$json" | jq -r '.message.content[0].type // ""')
      time_str=$(fmt_ts "$timestamp")

      if [[ "$content_type" == "tool_result" ]]; then
        tool_use_id=$(echo "$json" | jq -r '.message.content[0].tool_use_id // ""')
        is_error=$(echo "$json" | jq -r '.message.content[0].is_error // false')

        local err_tag=""
        if [[ "$is_error" == "true" ]]; then err_tag="  ${FG_RED}${BOLD}ERROR${RST}"; fi

        printf '\n%s 👤 USER (tool result) %s  %s%s  ← %s%s%s\n' \
          "${BG_GREEN}${FG_WHITE}${BOLD}" "$RST" "$FG_GRAY" "$time_str" "$tool_use_id" "$RST" "$err_tag"

        print_tool_result_content "$json"
      else
        printf '\n%s 👤 USER %s  %s%s%s\n' \
          "${BG_GREEN}${FG_WHITE}${BOLD}" "$RST" "$FG_GRAY" "$time_str" "$RST"

        local user_text
        user_text=$(echo "$json" | jq -r '.message.content[0].text // ""')
        if [[ -n "$user_text" ]]; then
          wrap "$FG_WHITE" "$user_text"
        fi
      fi
      separator
      ;;

    # ── Gemini stream-json types ────────────────────────────────────────
    init)
      if [[ "$SHOW_SYSTEM" != "true" ]]; then return; fi
      print_gemini_init "$json"
      ;;

    message)
      print_gemini_message "$json"
      separator
      ;;

    tool_use)
      if [[ "$SHOW_ASSISTANT" != "true" ]]; then return; fi
      local g_ts g_time
      g_ts=$(echo "$json" | jq -r '.timestamp // ""')
      g_time=$(fmt_ts "$g_ts")
      printf '\n%s 🤖 ASSISTANT %s  %s%s%s\n' \
        "${BG_BLUE}${FG_WHITE}${BOLD}" "$RST" "$FG_GRAY" "$g_time" "$RST"
      print_gemini_tool_use "$json"
      separator
      ;;

    tool_result)
      if [[ "$SHOW_USER" != "true" ]]; then return; fi
      print_gemini_tool_result "$json"
      separator
      ;;

    result)
      print_gemini_result "$json"
      separator
      ;;
  esac
}

# ── Extract the JSONL block from a broader log file ───────────────────────
# Splits the file into preamble / jsonl / postamble.
# A line is considered part of the JSONL block if it parses as JSON with a
# top-level "type" key.

extract_and_run() {
  local path="$1"

  local preamble=()
  local jsonl=()
  local postamble=()
  local state="preamble"

  while IFS= read -r line || [[ -n "$line" ]]; do
    local stripped
    stripped=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    case "$state" in
      preamble)
        if [[ -z "$stripped" ]]; then
          preamble+=("$line")
          continue
        fi
        # Check if it's a CC log JSON entry
        if echo "$stripped" | jq -e 'select(type == "object" and has("type"))' &>/dev/null; then
          state="jsonl"
          jsonl+=("$stripped")
        else
          preamble+=("$line")
        fi
        ;;
      jsonl)
        if [[ -z "$stripped" ]]; then
          # tolerate blank lines inside the block
          continue
        fi
        if echo "$stripped" | jq -e 'select(type == "object" and has("type"))' &>/dev/null; then
          jsonl+=("$stripped")
        else
          state="postamble"
          postamble+=("$line")
        fi
        ;;
      postamble)
        postamble+=("$line")
        ;;
    esac
  done < "$path"

  # ── Detect agent flavour from the first JSONL entry ─────────────────
  local agent_label="Claude Code"
  if ((${#jsonl[@]} > 0)); then
    local first_type first_model
    first_type=$(echo "${jsonl[0]}" | jq -r '.type // ""')
    first_model=$(echo "${jsonl[0]}" | jq -r '.model // ""')
    if [[ "$first_type" == "init" ]]; then
      if [[ "$first_model" == gemini* ]]; then
        agent_label="Gemini"
      else
        agent_label="Agent"
      fi
    fi
  fi

  # ── Coalesce consecutive Gemini assistant streaming deltas ──────────
  if [[ "$agent_label" == "Gemini" ]] && ((${#jsonl[@]} > 0)); then
    local merged=()
    local buf=""
    for ln in "${jsonl[@]}"; do
      local lt lr ld
      lt=$(echo "$ln" | jq -r '.type // ""')
      lr=$(echo "$ln" | jq -r '.role // ""')
      ld=$(echo "$ln" | jq -r '.delta // false')
      if [[ "$lt" == "message" && "$lr" == "assistant" && "$ld" == "true" ]]; then
        if [[ -n "$buf" ]]; then
          local addl
          addl=$(echo "$ln" | jq -r '.content // ""')
          buf=$(echo "$buf" | jq --arg c "$addl" '.content = ((.content // "") + $c)')
        else
          buf="$ln"
        fi
        continue
      fi
      if [[ -n "$buf" ]]; then
        merged+=("$buf")
        buf=""
      fi
      merged+=("$ln")
    done
    if [[ -n "$buf" ]]; then merged+=("$buf"); fi
    jsonl=("${merged[@]}")
  fi

  # ── Header ──────────────────────────────────────────────────────────
  local header_label="${agent_label} Log: ${path}"
  local header_pad=$((WIDTH - 6 - ${#header_label}))
  if ((header_pad < 0)); then header_pad=0; fi
  printf '\n%s╔%*s╗%s\n' "${BOLD}${FG_CYAN}" $((WIDTH - 2)) '' "$RST" | tr ' ' '═'
  printf '%s║  %s%*s  ║%s\n' "${BOLD}${FG_CYAN}" "$header_label" "$header_pad" '' "$RST"
  printf '%s╚%*s╝%s\n' "${BOLD}${FG_CYAN}" $((WIDTH - 2)) '' "$RST" | tr ' ' '═'

  # ── Preamble ────────────────────────────────────────────────────────
  if ((${#preamble[@]} > 0)); then
    # Check if there's any non-blank content
    local has_content=false
    for pl in "${preamble[@]}"; do
      [[ -n "$(echo "$pl" | tr -d '[:space:]')" ]] && { has_content=true; break; }
    done
    if $has_content; then
      printf '\n%s 📋 PREAMBLE (%d lines) %s\n' "${BG_YELLOW}${FG_WHITE}${BOLD}" "${#preamble[@]}" "$RST"
      local count=0
      for pl in "${preamble[@]}"; do
        if ((count >= 30)); then printf '  %s… (%d more lines)%s\n' "$FG_GRAY" $(( ${#preamble[@]} - 30 )) "$RST"; break; fi
        printf '  %s%s%s\n' "$FG_GRAY" "$pl" "$RST"
        count=$((count + 1))
      done
      separator
    fi
  fi

  # ── JSONL block ─────────────────────────────────────────────────────
  if ((${#jsonl[@]} == 0)); then
    printf '\n%s%s  ⚠ No JSONL block found in file.%s\n\n' "$FG_RED" "$BOLD" "$RST"
    exit 1
  fi

  printf '\n%s  ℹ Found %d JSONL entries%s\n' "$FG_CYAN" "${#jsonl[@]}" "$RST"
  separator

  for line in "${jsonl[@]}"; do
    [[ -z "$line" ]] && continue
    process_entry "$line"
  done

  # ── Postamble ───────────────────────────────────────────────────────
  if ((${#postamble[@]} > 0)); then
    local has_content=false
    for pl in "${postamble[@]}"; do
      [[ -n "$(echo "$pl" | tr -d '[:space:]')" ]] && { has_content=true; break; }
    done
    if $has_content; then
      printf '\n%s 📋 POST-RUN (%d lines) %s\n' "${BG_YELLOW}${FG_WHITE}${BOLD}" "${#postamble[@]}" "$RST"
      local count=0
      for pl in "${postamble[@]}"; do
        if ((count >= 30)); then printf '  %s… (%d more lines)%s\n' "$FG_GRAY" $(( ${#postamble[@]} - 30 )) "$RST"; break; fi
        printf '  %s%s%s\n' "$FG_GRAY" "$pl" "$RST"
        count=$((count + 1))
      done
      separator
    fi
  fi

  # ── Footer ──────────────────────────────────────────────────────────
  printf '\n%s%s%*s%s\n' "$BOLD" "$FG_CYAN" "$WIDTH" '' "$RST" | tr ' ' '═'
  printf '%s%s  ✅ End of log%s\n' "$BOLD" "$FG_CYAN" "$RST"
  printf '%s%s%*s%s\n\n' "$BOLD" "$FG_CYAN" "$WIDTH" '' "$RST" | tr ' ' '═'
}

# ── Main ──────────────────────────────────────────────────────────────────
usage() {
  printf '%sUsage: %s [OPTIONS] <logfile>%s\n\n' "$FG_CYAN" "$0" "$RST"
  printf '  --no-system      Hide system entries\n'
  printf '  --no-user        Hide user entries\n'
  printf '  --no-assistant   Hide assistant entries\n'
  printf '  --max-lines N    Truncate content blocks to N lines\n'
  printf '  -h, --help       Show this help\n'
}

LOGFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-system)    SHOW_SYSTEM=false;   shift ;;
    --no-user)      SHOW_USER=false;     shift ;;
    --no-assistant) SHOW_ASSISTANT=false; shift ;;
    --max-lines)
      if [[ -z "${2:-}" ]]; then printf '%s--max-lines requires a number%s\n' "$FG_RED" "$RST"; exit 1; fi
      MAX_LINES="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    -*)             printf '%sUnknown option: %s%s\n' "$FG_RED" "$1" "$RST"; usage; exit 1 ;;
    *)              LOGFILE="$1"; shift ;;
  esac
done

if [[ -z "$LOGFILE" ]]; then
  usage
  exit 1
fi

if ! command -v jq &>/dev/null; then
  printf '%s%s  ⚠ jq is required but not found. Install it first.%s\n' "$FG_RED" "$BOLD" "$RST"
  exit 1
fi

extract_and_run "$LOGFILE"