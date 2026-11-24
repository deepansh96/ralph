#!/usr/bin/env bash

parse_log() {
  local log_file="$1"
  local agent="$2"
  local lines="${3:-10}"

  if [[ ! -s "$log_file" ]]; then
    printf 'Starting...\n'
    return
  fi

  local jq_filter

  case "$agent" in
    claude)
      jq_filter='
        select(.type == "assistant")
        | .message.content[]?
        | if .type == "text" then
            "[text] " + (.text[:120] | gsub("\n"; " "))
          elif .type == "tool_use" then
            "[tool] " + .name + ": " + (
              (.input | to_entries | first | (.key + "=" + (.value | tostring)[:80])) // ""
            )
          else
            empty
          end
      '
      ;;
    codex)
      jq_filter='
        select(.type == "item.completed")
        | .item
        | if .type == "agent_message" then
            "[text] " + (.text[:120] | gsub("\n"; " "))
          elif .type == "command_execution" then
            "[cmd] " + (.command[:120] | gsub("\n"; " "))
          else
            empty
          end
      '
      ;;
    deepseek)
      jq_filter='
        if .type == "message_end" and .message.role == "assistant" then
          .message.content[]?
          | select(.type == "text")
          | "[text] " + (.text[:120] | gsub("\n"; " "))
        elif .type == "tool_execution_start" then
          "[tool] " + .toolName + ": " + (
            (.args | to_entries | first | (.key + "=" + (.value | tostring)[:80])) // ""
          )
        else
          empty
        end
      '
      ;;
    gemini)
      jq_filter='
        select(.event == "step_update")
        | .step_update
        | if .step_type == "tool" and .state == "ACTIVE" then
            "[tool] " + (.tool_name // "tool") + ": " + (
              (
                (.tool_info.parameters // {})
                | to_entries
                | (map(select(.key == "CommandLine" or .key == "Path")) | first) // first
                | (.key + "=" + (.value | tostring)[:80])
              ) // ""
            )
          elif .step_type == "agent_response" and ((.text_delta // "") | test("\\S")) then
            "[text] " + (.text_delta[:120] | gsub("\n"; " "))
          else
            empty
          end
      '
      ;;
    *)
      printf 'Unknown agent: %s\n' "$agent"
      return
      ;;
  esac

  tail -20 "$log_file" \
    | jq -R 'try fromjson' \
    | jq -r "$jq_filter" \
    | tail -"$lines"
}
