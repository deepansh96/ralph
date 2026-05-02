#!/usr/bin/env bash

status_print() {
  local state_file="$1"

  printf "%-4s %-24s %-18s %-10s %-12s %-10s\n" "#" "Step ID" "Type" "Agent" "Status" "Duration"
  jq -r '
    .steps
    | to_entries[]
    | [
        (.key + 1),
        .value.id,
        (.value.type // "-"),
        (.value.agent // "-"),
        .value.status,
        (.value.metrics.duration // .value.metrics.duration_ms // "-")
      ]
    | @tsv
  ' "$state_file" | while IFS=$'\t' read -r number id type agent status duration; do
    printf "%-4s %-24s %-18s %-10s %-12s %-10s\n" "$number" "$id" "$type" "$agent" "$status" "$duration"
  done
}
