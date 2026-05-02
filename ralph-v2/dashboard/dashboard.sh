#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_WORKSPACES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/workspaces"

usage() {
  cat >&2 <<'USAGE'
Usage:
  dashboard.sh aggregate [--workspaces-dir <path>]
  dashboard.sh serve [--port <N>] [--workspaces-dir <path>]
USAGE
}

resolve_workspaces_dir() {
  local workspaces_dir="${RALPH_WORKSPACES_DIR:-$DEFAULT_WORKSPACES_DIR}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workspaces-dir)
        [[ $# -ge 2 ]] || {
          echo "Error: --workspaces-dir requires a path" >&2
          return 1
        }
        workspaces_dir="$2"
        shift 2
        ;;
      *)
        echo "Error: unknown aggregate option: $1" >&2
        usage
        return 1
        ;;
    esac
  done

  printf '%s\n' "$workspaces_dir"
}

aggregate() {
  local workspaces_dir workspaces_file warnings_file state_file

  workspaces_dir="$(resolve_workspaces_dir "$@")"
  if [[ ! -d "$workspaces_dir" ]]; then
    echo "Error: workspaces directory does not exist or is not a directory: $workspaces_dir" >&2
    return 1
  fi

  workspaces_file="$(mktemp)"
  warnings_file="$(mktemp)"

  shopt -s nullglob
  for state_file in "$workspaces_dir"/*/state.json; do
    if ! jq empty "$state_file" >/dev/null 2>&1; then
      jq -Rn --arg warning "$state_file: invalid JSON" '$warning' >> "$warnings_file"
      continue
    fi

    if ! jq -e '(.issue | type) == "number"' "$state_file" >/dev/null; then
      jq -Rn --arg warning "$state_file: .issue must be numeric" '$warning' >> "$warnings_file"
      continue
    fi

    if ! jq -e '(.steps | type) == "array"' "$state_file" >/dev/null; then
      jq -Rn --arg warning "$state_file: .steps must be an array" '$warning' >> "$warnings_file"
      continue
    fi

    if ! jq -e '
      all(.steps[]; (.status // null) as $status
        | ["pending", "in_progress", "completed", "blocked", "failed"] | index($status))
    ' "$state_file" >/dev/null; then
      jq -Rn --arg warning "$state_file: step status must be one of pending, in_progress, completed, blocked, failed" '$warning' >> "$warnings_file"
      continue
    fi

    jq -c '
      def step_count($status):
        [.steps[] | select(.status == $status)] | length;

      def first_step_id($status):
        first(.steps[]? | select(.status == $status) | .id) // null;

      def current_step:
        first_step_id("failed")
        // first_step_id("blocked")
        // first_step_id("in_progress")
        // first_step_id("pending")
        // (last(.steps[]? | .id) // null);

      def derived_status:
        if any(.steps[]; .status == "failed") then "failed"
        elif any(.steps[]; .status == "blocked") then "blocked"
        elif any(.steps[]; .status == "in_progress") then "in_progress"
        elif ((.steps | length) > 0) and all(.steps[]; .status == "completed") then "completed"
        else "pending"
        end;

      def total_cost:
        [.steps[] | .metrics.cost_usd? | select(. != null)] as $costs
        | if ($costs | length) == 0 then null else ($costs | add) end;

      {
        issue,
        repo: (.repo // ""),
        branch: (.branch // ""),
        createdAt: (.createdAt // ""),
        derivedStatus: derived_status,
        currentStep: current_step,
        steps: [
          .steps[] | {
            id,
            type,
            agent,
            status,
            duration_ms: (.metrics.duration_ms // 0),
            cost_usd: (.metrics.cost_usd // null)
          }
        ],
        totalDuration_ms: ([.steps[] | .metrics.duration_ms? // 0] | add // 0),
        totalCost_usd: total_cost,
        stepCounts: {
          completed: step_count("completed"),
          pending: step_count("pending"),
          in_progress: step_count("in_progress"),
          blocked: step_count("blocked"),
          failed: step_count("failed")
        }
      }
    ' "$state_file" >> "$workspaces_file"
  done
  shopt -u nullglob

  jq -n \
    --slurpfile workspaces "$workspaces_file" \
    --slurpfile warnings "$warnings_file" \
    '{workspaces: ($workspaces | sort_by(.issue)), warnings: $warnings}'
  rm -f "$workspaces_file" "$warnings_file"
}

serve() {
  local port="8080"
  local workspaces_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        [[ $# -ge 2 ]] || {
          echo "Error: --port requires a value" >&2
          return 1
        }
        port="$2"
        shift 2
        ;;
      --workspaces-dir)
        [[ $# -ge 2 ]] || {
          echo "Error: --workspaces-dir requires a path" >&2
          return 1
        }
        workspaces_dir="$2"
        shift 2
        ;;
      *)
        echo "Error: unknown serve option: $1" >&2
        usage
        return 1
        ;;
    esac
  done

  if [[ -z "$workspaces_dir" ]]; then
    workspaces_dir="${RALPH_WORKSPACES_DIR:-$DEFAULT_WORKSPACES_DIR}"
  fi

  if [[ ! -d "$workspaces_dir" ]]; then
    echo "Error: workspaces directory does not exist or is not a directory: $workspaces_dir" >&2
    return 1
  fi

  command -v python3 >/dev/null 2>&1 || {
    echo "Error: python3 is required for dashboard.sh serve" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "Error: jq is required for dashboard.sh serve" >&2
    return 1
  }

  echo "Dashboard: http://127.0.0.1:$port"
  DASHBOARD_SCRIPT="$SCRIPT_DIR/dashboard.sh" DASHBOARD_DIR="$SCRIPT_DIR" RALPH_DASHBOARD_WORKSPACES_DIR="$workspaces_dir" RALPH_DASHBOARD_PORT="$port" python3 <<'PYTHON'
import json
import mimetypes
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse


dashboard_script = os.environ["DASHBOARD_SCRIPT"]
dashboard_dir = Path(os.environ["DASHBOARD_DIR"]).resolve()
workspaces_dir = os.environ["RALPH_DASHBOARD_WORKSPACES_DIR"]
port = int(os.environ["RALPH_DASHBOARD_PORT"])


def fully_unquote(path):
    decoded = path
    for _ in range(5):
        next_decoded = unquote(decoded)
        if next_decoded == decoded:
            return decoded
        decoded = next_decoded
    return decoded


class DashboardHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/workspaces":
            self.serve_workspaces()
            return
        self.serve_static(parsed.path)

    def serve_workspaces(self):
        result = subprocess.run(
            [dashboard_script, "aggregate", "--workspaces-dir", workspaces_dir],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            message = result.stderr.strip() or result.stdout.strip() or "aggregate command failed"
            self.send_json(500, {"error": "aggregate failed", "details": message})
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(result.stdout.encode("utf-8"))

    def serve_static(self, raw_path):
        decoded_path = fully_unquote(raw_path)
        if "../" in decoded_path or decoded_path.startswith(".."):
            self.send_error(403)
            return

        relative_path = "index.html" if decoded_path in ("", "/") else decoded_path.lstrip("/")
        target = (dashboard_dir / relative_path).resolve()
        if dashboard_dir not in target.parents and target != dashboard_dir:
            self.send_error(403)
            return
        if not target.is_file():
            self.send_error(404)
            return

        content_type = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.end_headers()
        self.wfile.write(target.read_bytes())

    def send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


try:
    HTTPServer(("127.0.0.1", port), DashboardHandler).serve_forever()
except KeyboardInterrupt:
    sys.exit(0)
PYTHON
}

main() {
  local command="${1:-}"

  case "$command" in
    aggregate)
      shift
      aggregate "$@"
      ;;
    serve)
      shift
      serve "$@"
      ;;
    *)
      usage
      return 1
      ;;
  esac
}

main "$@"
