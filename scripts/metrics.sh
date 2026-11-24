#!/usr/bin/env bash

metrics_empty_json() {
  local provider="$1"
  local duration_ms="${2:-0}"

  jq -n \
    --arg provider "$provider" \
    --argjson duration_ms "$duration_ms" \
    '{
      provider: $provider,
      duration_ms: $duration_ms,
      input_tokens: 0,
      output_tokens: 0,
      cost_usd: null
    }'
}

metrics_from_claude_log() {
  local log_file="$1"
  local fallback_duration_ms="$2"

  if [[ -s "$log_file" ]] && tail -1 "$log_file" | jq -e '.' >/dev/null 2>&1; then
    tail -1 "$log_file" | jq \
      --arg provider "claude" \
      --argjson fallback_duration "$fallback_duration_ms" \
      '{
        provider: $provider,
        duration_ms: (.duration_ms // $fallback_duration),
        input_tokens: (.usage.input_tokens // 0),
        output_tokens: (.usage.output_tokens // 0),
        cost_usd: (.total_cost_usd // null)
      }'
  else
    metrics_empty_json "claude" "$fallback_duration_ms"
  fi
}

metrics_from_codex_log() {
  local log_file="$1"
  local duration_ms="$2"

  if [[ -s "$log_file" ]] && jq -s '.' "$log_file" >/dev/null 2>&1; then
    jq -s \
      --arg provider "codex" \
      --argjson duration_ms "$duration_ms" \
      'reduce .[] as $event (
        {
          provider: $provider,
          duration_ms: $duration_ms,
          input_tokens: 0,
          output_tokens: 0,
          cost_usd: null
        };
        if $event.type == "turn.completed" then
          .input_tokens += ($event.usage.input_tokens // 0)
          | .output_tokens += ($event.usage.output_tokens // 0)
        else
          .
        end
      )' "$log_file"
  else
    metrics_empty_json "codex" "$duration_ms"
  fi
}

metrics_from_pi_log() {
  local log_file="$1"
  local duration_ms="$2"
  local provider="$3"

  if [[ -s "$log_file" ]] && jq -s '.' "$log_file" >/dev/null 2>&1; then
    jq -s \
      --arg provider "$provider" \
      --argjson duration_ms "$duration_ms" \
      'reduce (.[] | select(.type == "message_end" and .message.role == "assistant")) as $event (
        {
          provider: $provider,
          duration_ms: $duration_ms,
          input_tokens: 0,
          output_tokens: 0,
          cost_usd: 0
        };
        .input_tokens += ($event.message.usage.input // 0)
        | .output_tokens += ($event.message.usage.output // 0)
        | .cost_usd += ($event.message.usage.cost.total // 0)
      )' "$log_file"
  else
    metrics_empty_json "$provider" "$duration_ms"
  fi
}

# Reads the last result event of an agy stream-json log. agy reports token
# usage but no cost, and a few non-JSON lines must not hide the result.
metrics_from_gemini_log() {
  local log_file="$1"
  local fallback_duration_ms="$2"
  local metrics

  metrics="$(jq -Rn \
    --arg provider "gemini" \
    --argjson fallback_duration "$fallback_duration_ms" \
    '[inputs | fromjson? | objects | select(.event == "result")]
     | last
     | select(. != null)
     | {
         provider: $provider,
         duration_ms: (((.result.duration_seconds // null) | if . == null then $fallback_duration else (. * 1000 | floor) end)),
         input_tokens: (.result.usage.input_tokens // 0),
         output_tokens: (.result.usage.output_tokens // 0),
         cost_usd: null
       }' "$log_file" 2>/dev/null)" || metrics=""

  if [[ -n "$metrics" ]]; then
    printf '%s\n' "$metrics"
  else
    metrics_empty_json "gemini" "$fallback_duration_ms"
  fi
}

metrics_print_summary() {
  local state_file="$1"

  printf "%-4s %-24s %-10s %-12s %-12s %-10s\n" "#" "Step ID" "Agent" "Status" "Duration" "Cost"
  jq -r '
    .steps
    | to_entries[]
    | [
        (.key + 1),
        .value.id,
        (.value.agent // "-"),
        .value.status,
        (.value.metrics.duration_ms // "-"),
        (if (.value.metrics.cost_usd == null) then "-" else .value.metrics.cost_usd end)
      ]
    | @tsv
  ' "$state_file" | while IFS=$'\t' read -r number id agent status duration cost; do
    printf "%-4s %-24s %-10s %-12s %-12s %-10s\n" "$number" "$id" "$agent" "$status" "$duration" "$cost"
  done
}
