#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

CONFIG_CANDIDATES=(
  "./.jira-cli.conf"
  "$HOME/.jira-cli.conf"
)

load_config() {
  for f in "${CONFIG_CANDIDATES[@]}"; do
    [[ -f "$f" ]] && source "$f"
  done
}

require_deps() {
  command -v curl >/dev/null 2>&1 || { echo "Please install curl"; exit 1; }
  command -v jq   >/dev/null 2>&1 || { echo "Please install jq";   exit 1; }
}

check_env() {
  : "${JIRA_URL:?Set JIRA_URL}"
  JIRA_API_PREFIX="${JIRA_API_PREFIX:-/rest/api/2}"

  if [[ -n "${JIRA_TOKEN:-}" ]]; then
    AUTH_MODE="bearer"
  elif [[ -n "${JIRA_USER:-}" && -n "${JIRA_PASS:-}" ]]; then
    AUTH_MODE="basic"
  else
    echo "Set JIRA_TOKEN OR JIRA_USER and JIRA_PASS." >&2
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
  [[ -n "${JIRA_CURL_OPTS:-}" ]] && echo $JIRA_CURL_OPTS
}

jira_comment_json() {
  local comment="$1"

  if [[ "$JIRA_API_PREFIX" == *"/3" ]]; then
    jq -cn --arg c "$comment" '
      {
        body: {
          type: "doc",
          version: 1,
          content: [
            {
              type: "paragraph",
              content: [
                {
                  type: "text",
                  text: $c
                }
              ]
            }
          ]
        }
      }'
  else
    jq -cn --arg c "$comment" '{body: $c}'
  fi
}

api() {
  local method=$1; shift
  local path=$1; shift
  local data=${1:-}
  local url="${JIRA_URL%/}${path}"

  local -a auth=( $(auth_args) )
  local -a extra=( $(curl_base_args) )
  local -a args=(-sS "${extra[@]}" -X "$method" "${auth[@]}" -H "Content-Type: application/json")

  [[ -n "${JIRA_DEBUG:-}" ]] && echo "[DEBUG] $method $url" >&2

  if [[ "$method" == "GET" || "$method" == "DELETE" ]]; then
    curl "${args[@]}" "$url"
  else
    curl "${args[@]}" --data "$data" "$url"
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
      .fields.updated,
      (.fields.summary | gsub("[\\r\\n]"; " "))
    ] | @tsv' |
  while IFS=$'\t' read -r k it s u m; do
    u="$(fmt_local_time "$u")"
    printf "%-14s %-14s %-18s %-24s %s\n" "$k" "$it" "$s" "$u" "$m"
  done
}

fmt_local_time() {
  local ts="$1"
  date -d "$ts" +"%Y-%m-%d %H:%M:%S %Z"
}

cmd_transitions() {
  local key=${1:?Usage: transitions ISSUE_KEY}
  local resp
  resp="$(api GET "${JIRA_API_PREFIX}/issue/${key}/transitions?expand=transitions.fields")"

  local count
  count="$(echo "$resp" | jq '.transitions | length')"
  [[ "$count" -eq 0 ]] && { echo "No transitions available for $key."; return 0; }

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
  [[ "$total" -eq 0 ]] && { echo "No transitions available for $key."; return 1; }

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

  [[ -z "$out" ]] && echo "Transition applied." || echo "$out" | jq . 2>/dev/null || echo "$out"
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

  [[ -z "$time_spent" ]] && read -r -p "Time spent: " time_spent
  [[ -z "$comment" ]] && read -r -p "Comment: " comment
  [[ -z "$started" ]] && started="$(date +"%Y-%m-%dT%H:%M:%S.000%z")"

  local payload
  payload="$(jq -cn --arg c "$comment" --arg t "$time_spent" --arg s "$started" '
    { comment: $c, timeSpent: $t, started: $s }')"

  local out
  out="$(api POST "${JIRA_API_PREFIX}/issue/${key}/worklog" "$payload")" || true

  if echo "$out" | jq -e '.id' >/dev/null 2>&1; then
    echo "Worklog added (id: $(echo "$out" | jq -r '.id')) to $key."
  else
    echo "$out" | jq . 2>/dev/null || echo "$out"
  fi
}

cmd_comment() {
  local key=${1:?Usage: comment ISSUE_KEY --message|-m \"...\"}
  shift

  local message=""

  while (( "$#" )); do
    case "$1" in
      --message|-m|--body|-b) message=${2:-}; shift 2 ;;
      *) echo "Unknown option: $1"; exit 1 ;;
    esac
  done

  [[ -z "$message" ]] && read -r -p "Comment: " message

  local payload
  payload="$(jira_comment_json "$message")"

  local out
  out="$(api POST "${JIRA_API_PREFIX}/issue/${key}/comment" "$payload")" || true

  if echo "$out" | jq -e '.id' >/dev/null 2>&1; then
    echo "Comment added (id: $(echo "$out" | jq -r '.id')) to $key."
  else
    echo "$out" | jq . 2>/dev/null || echo "$out"
  fi
}

cmd_comments() {
  local key=${1:?Usage: comments ISSUE_KEY}

  api GET "${JIRA_API_PREFIX}/issue/${key}/comment" | jq -r '
    .comments[] |
    [
      .id,
      (.author.displayName // .author.name // "-"),
      .created,
      (
        if (.body | type) == "string" then
          .body
        else
          [.body.content[]?.content[]?.text?] | join("\n")
        end
      )
    ] | @tsv' |
  while IFS=$'\t' read -r id author created body; do
    echo "id: $id"
    echo "author: $author"
    echo "created: $(fmt_local_time "$created")"
    echo "comment:"
    echo "$body"
    echo "---"
  done
}

cmd_delete_comment() {
  local key=${1:?Usage: delete-comment ISSUE_KEY COMMENT_ID}
  local comment_id=${2:?Usage: delete-comment ISSUE_KEY COMMENT_ID}

  local out
  out="$(api DELETE "${JIRA_API_PREFIX}/issue/${key}/comment/${comment_id}")" || true

  [[ -z "$out" ]] && echo "Comment $comment_id deleted from $key." || echo "$out" | jq . 2>/dev/null || echo "$out"
}

usage() {
  cat <<'EOF'
jira-cli.sh — Tiny Jira CLI

Commands:
  whoami
  list|l [JQL]
  transitions ISSUE_KEY
  transition|t ISSUE_KEY [N]

  worklog|w ISSUE_KEY --time|-t "1h" --comment|-c "..." [--started|-s "..."]

  comment|c ISSUE_KEY --message|-m "..."
  comments|cs ISSUE_KEY
  delete-comment|dc ISSUE_KEY COMMENT_ID

Examples:
  j c K45-123 -m "Fixed this issue."
  j comments K45-123
  j dc K45-123 10042
EOF
}

main() {
  load_config
  require_deps
  check_env

  local cmd="${1:-}"
  shift || true

  case "${cmd:-}" in
    whoami)              cmd_whoami "$@" ;;
    list|l)              cmd_list "$@" ;;
    transitions)         cmd_transitions "$@" ;;
    transition|t)        cmd_transition "$@" ;;
    worklog|w)           cmd_worklog "$@" ;;
    comment|c)           cmd_comment "$@" ;;
    comments|cs)         cmd_comments "$@" ;;
    delete-comment|dc)   cmd_delete_comment "$@" ;;
    ""|help|-h|--help)   usage ;;
    *) echo "Unknown command: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"