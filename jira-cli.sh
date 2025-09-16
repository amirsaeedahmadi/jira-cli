#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

CONFIG_CANDIDATES=(
  "./.jira-cli.conf"
  "$HOME/.jira-cli.conf"
)

load_config() {
  for f in "${CONFIG_CANDIDATES[@]}"; do
    if [[ -f "$f" ]]; then
      source "$f"
    fi
  done
}

require_deps() {
  command -v curl >/dev/null 2>&1 || { echo "Please install curl"; exit 1; }
  command -v jq   >/dev/null 2>&1 || { echo "Please install jq";   exit 1; }
}

check_env() {
  : "${JIRA_URL:?Set JIRA_URL (e.g., https://your-jira-instance)}"
  JIRA_API_PREFIX="${JIRA_API_PREFIX:-/rest/api/2}"

  if [[ -n "${JIRA_TOKEN:-}" ]]; then
    AUTH_MODE="bearer"
  elif [[ -n "${JIRA_USER:-}" && -n "${JIRA_PASS:-}" ]]; then
    AUTH_MODE="basic"
  else
    echo "Set JIRA_TOKEN (Bearer) OR JIRA_USER and JIRA_PASS (Basic auth)." >&2
    exit 1
  fi
}

auth_args() {
  if [[ "$AUTH_MODE" == "bearer" ]]; then
    printf -- "-H\nAuthorization: Bearer %s\n" "$JIRA_TOKEN"
  else
    printf -- "-u\n%s:%s\n" "$JIRA_USER" "$JIRA_PASS"
  fi
}

curl_base_args() {
  if [[ -n "${JIRA_CURL_OPTS:-}" ]]; then
    echo $JIRA_CURL_OPTS
  fi
}

api() {
  local method=$1; shift
  local path=$1; shift
  local data=${1:-}
  local url="${JIRA_URL%/}${path}"

  local -a args
  local -a auth=( $(auth_args) )
  local -a extra=( $(curl_base_args) )

  args=(-sS "${extra[@]}" -X "$method" "${auth[@]}" -H "Content-Type: application/json")

  if [[ -n "${JIRA_DEBUG:-}" ]]; then
    echo "[DEBUG] $method $url" >&2
    if [[ -n "$data" ]]; then echo "[DEBUG] payload: $data" >&2; fi
  fi

  if [[ "$method" == "GET" ]]; then
    curl "${args[@]}" "$url"
  else
    if [[ -n "$data" ]]; then
      curl "${args[@]}" --data "$data" "$url"
    else
      curl "${args[@]}" "$url"
    fi
  fi
}

cmd_whoami() {
  api GET "${JIRA_API_PREFIX}/myself" | jq '{name: .name, displayName, emailAddress}'
}

cmd_list() {
  local jql=${1:-'assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC'}
  local body
  body="$(jq -cn --arg jql "$jql" '
    {
      jql: $jql,
      maxResults: 100,
      fields: ["key","summary","status","project","updated","issuetype"]
    }')"

  local resp
  resp="$(api POST "${JIRA_API_PREFIX}/search" "$body")"

  printf "%-14s %-14s %-18s %-20s %s\n" "KEY" "TYPE" "STATUS" "UPDATED" "SUMMARY"
  echo "$resp" | jq -r '
    .issues[] |
    [
      .key,
      .fields.issuetype.name,
      .fields.status.name,
      (.fields.updated | sub("\\..*$";"") | gsub("T";" ")),
      (.fields.summary | gsub("[\\r\\n]"; " "))
    ] | @tsv' |
  while IFS=$'\t' read -r k it s u m; do
    printf "%-14s %-14s %-18s %-20s %s\n" "$k" "$it" "$s" "$u" "$m"
  done
}

cmd_transitions() {
  local key=${1:?Usage: transitions ISSUE_KEY}
  local resp
  resp="$(api GET "${JIRA_API_PREFIX}/issue/${key}/transitions?expand=transitions.fields")"

  local count
  count="$(echo "$resp" | jq '.transitions | length')"
  if [[ "$count" -eq 0 ]]; then
    echo "No transitions available for $key."
    return 0
  fi

  echo "Available transitions for $key:"
  echo "$resp" | jq -r '
    .transitions
    | to_entries[]
    | "\(.key|tonumber+1)) id:\(.value.id)\t\(.value.name) → \(.value.to.name)"'
}

cmd_transition() {
  local key=${1:?Usage: transition ISSUE_KEY [CHOICE_NUMBER]}
  local choice="${2:-}"

  local resp
  resp="$(api GET "${JIRA_API_PREFIX}/issue/${key}/transitions?expand=transitions.fields")"

  local total
  total="$(echo "$resp" | jq '.transitions | length')"
  if [[ "$total" -eq 0 ]]; then
    echo "No transitions available for $key."
    return 1
  fi

  mapfile -t IDS   < <(echo "$resp" | jq -r '.transitions[].id')
  mapfile -t LABEL < <(echo "$resp" | jq -r '.transitions[] | "\(.name) → \(.to.name)"')

  if [[ -z "$choice" ]]; then
    echo "Transitions for $key:"
    for ((i=0; i<${#IDS[@]}; i++)); do
      printf "%2d) id:%s  %s\n" "$((i+1))" "${IDS[$i]}" "${LABEL[$i]}"
    done
    read -r -p "Choose a transition [1-$total]: " choice
  fi

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > total )); then
    echo "Invalid choice."
    return 1
  fi

  local id="${IDS[$((choice-1))]}"
  local payload
  payload="$(jq -cn --arg id "$id" '{transition:{id:$id}}')"

  echo "Applying transition ($choice = id:$id) on $key…"
  local out
  out="$(api POST "${JIRA_API_PREFIX}/issue/${key}/transitions" "$payload")" || true

  if [[ -z "$out" ]]; then
    echo "Transition applied."
  else
    echo "$out" | jq . 2>/dev/null || echo "$out"
  fi
}

cmd_worklog() {
  local key=${1:?Usage: worklog ISSUE_KEY --time \"1h\" --comment \"...\"}
  shift

  local time_spent=""
  local comment=""
  local started=""

  while (( "$#" )); do
    case "$1" in
      --time|-t)    time_spent=${2:-}; shift 2 ;;
      --comment|-c) comment=${2:-};   shift 2 ;;
      --started|-s) started=${2:-};   shift 2 ;;
      *) echo "Unknown option: $1"; exit 1 ;;
    esac
  done

  if [[ -z "$time_spent" ]]; then
    read -r -p "Time spent (e.g., 1h 30m): " time_spent
  fi
  if [[ -z "$comment" ]]; then
    read -r -p "Comment: " comment
  fi
  if [[ -z "$started" ]]; then
    started="$(date -u +"%Y-%m-%dT%H:%M:%S.000+0000")"
  fi

  local payload
  payload="$(jq -cn --arg c "$comment" --arg t "$time_spent" --arg s "$started" '
    { comment: $c, timeSpent: $t, started: $s }')"

  local out
  out="$(api POST "${JIRA_API_PREFIX}/issue/${key}/worklog" "$payload")" || true

  if echo "$out" | jq -e '.id' >/dev/null 2>&1; then
    local wid
    wid="$(echo "$out" | jq -r '.id')"
    echo "Worklog added (id: $wid) to $key."
  else
    echo "Worklog response:"
    echo "$out" | jq . 2>/dev/null || echo "$out"
  fi
}

usage() {
  cat <<'EOF'
jira-cli.sh — Tiny Jira CLI

Required env/config:
  JIRA_URL
  JIRA_API_PREFIX   (default: /rest/api/2, set /rest/api/3 for Jira Cloud)
  JIRA_TOKEN        OR JIRA_USER + JIRA_PASS
Optional:
  JIRA_CURL_OPTS
  JIRA_DEBUG=1

Commands:
  whoami
  list [JQL]
  transitions ISSUE_KEY
  transition|t ISSUE_KEY [N]
  worklog|w ISSUE_KEY --time|-t "1h" --comment|-c "..." [--started|-s "YYYY-MM-DDThh:mm:ss.000+0000"]
EOF
}

main() {
  load_config
  require_deps
  check_env

  local cmd="${1:-}"; shift || true
  case "${cmd:-}" in
    whoami)        cmd_whoami "$@";;
    list|l)        cmd_list "$@";;
    transitions)   cmd_transitions "$@";;
    transition|t)  cmd_transition "$@";;
    worklog|w)     cmd_worklog "$@";;
    ""|help|-h|--help) usage;;
    *) echo "Unknown command: $cmd"; usage; exit 1;;
  esac
}

main "$@"
