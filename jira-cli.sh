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

jira_text_field_json() {
  local text="$1"

  if [[ "$JIRA_API_PREFIX" == *"/3" ]]; then
    jq -cn --arg t "$text" '
      {
        type: "doc",
        version: 1,
        content: [
          {
            type: "paragraph",
            content: [
              { type: "text", text: $t }
            ]
          }
        ]
      }'
  else
    jq -cn --arg t "$text" '$t'
  fi
}

select_from_list() {
  local prompt="$1"
  shift
  local -a items=("$@")

  if (( ${#items[@]} == 0 )); then
    echo ""
    return 0
  fi

  echo "$prompt"
  for ((i=0; i<${#items[@]}; i++)); do
    printf "%2d) %s\n" "$((i+1))" "${items[$i]}"
  done

  local choice
  read -r -p "Choose [1-${#items[@]}] or empty to skip: " choice

  if [[ -z "$choice" ]]; then
    echo ""
    return 0
  fi

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#items[@]} )); then
    echo "Invalid choice." >&2
    return 1
  fi

  echo "${items[$((choice-1))]}"
}

get_issue_link_types() {
  api GET "${JIRA_API_PREFIX}/issueLinkType" |
    jq -r '.issueLinkTypes[] | "\(.name)|\(.inward)|\(.outward)"'
}

select_issue_link_type() {
  local -a rows labels values

  mapfile -t rows < <(
    api GET "${JIRA_API_PREFIX}/issueLinkType" |
    jq -r '
      .issueLinkTypes[] |
      "\(.name)|outward|\(.outward)",
      "\(.name)|inward|\(.inward)"
    '
  )

  for row in "${rows[@]}"; do
    IFS='|' read -r name direction label <<< "$row"

    labels+=("$label")
    values+=("$name|$direction")
  done

  echo "Issue link types:" >&2

  for ((i=0; i<${#labels[@]}; i++)); do
    printf "%2d) %s\n" "$((i+1))" "${labels[$i]}" >&2
  done

  local choice
  read -r -p "Choose link type [1-${#labels[@]}]: " choice

  echo "${values[$((choice-1))]}"
}

select_epic() {
  local project="$1"

  local jql
  jql="project = \"$project\" AND issuetype = Epic ORDER BY updated DESC"

  local body
  body="$(jq -cn --arg jql "$jql" '
    {
      jql: $jql,
      maxResults: 100,
      fields: ["key","summary"]
    }')"

  local resp
  resp="$(api POST "${JIRA_API_PREFIX}/search" "$body")"

  local -a rows labels keys
  mapfile -t rows < <(echo "$resp" | jq -r '.issues[] | "\(.key)|\(.fields.summary)"')

  if (( ${#rows[@]} == 0 )); then
    echo ""
    return 0
  fi

  for row in "${rows[@]}"; do
    IFS='|' read -r key summary <<< "$row"
    labels+=("$key - $summary")
    keys+=("$key")
  done

  echo "Epics:" >&2
  for ((i=0; i<${#labels[@]}; i++)); do
    printf "%2d) %s\n" "$((i+1))" "${labels[$i]}" >&2
  done

  local choice
  read -r -p "Choose epic [1-${#labels[@]}] or empty to skip: " choice

  [[ -z "$choice" ]] && echo "" && return 0

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#labels[@]} )); then
    echo "Invalid choice." >&2
    return 1
  fi

  echo "${keys[$((choice-1))]}"
}

get_epic_field_id() {
  api GET "${JIRA_API_PREFIX}/field" |
    jq -r '
      .[]
      | select(
          .name == "Epic Link"
          or .name == "Parent"
          or .schema.custom == "com.pyxis.greenhopper.jira:gh-epic-link"
        )
      | .id
    ' | head -n1
}

cmd_create() {
  local project=""
  local issue_type="Task"
  local summary=""
  local description=""
  local priority="Low"
  local labels=""
  local assignee=""
  local link_type=""
  local link_direction=""
  local linked_issue=""
  local epic_key=""

  while (( "$#" )); do
    case "$1" in
      --project|-p)      project=${2:-}; shift 2 ;;
      --type|-t)         issue_type=${2:-}; shift 2 ;;
      --summary|-s)      summary=${2:-}; shift 2 ;;
      --description|-d)  description=${2:-}; shift 2 ;;
      --priority)        priority=${2:-}; shift 2 ;;
      --labels|-l)       labels=${2:-}; shift 2 ;;
      --assignee|-a)     assignee=${2:-}; shift 2 ;;
      --link)            linked_issue=${2:-}; shift 2 ;;
      --link-type)       link_type=${2:-}; shift 2 ;;
      --epic)            epic_key=${2:-}; shift 2 ;;
      -i|--interactive)
        read -r -p "Project key [DO]: " project
        read -r -p "Issue type [Task]: " issue_type
        read -r -p "Summary: " summary
        read -r -p "Description [empty]: " description
        read -r -p "Priority [Low]: " priority
        read -r -p "Labels comma-separated [empty]: " labels
        read -r -p "Assignee [empty=automatic]: " assignee
        read -r -p "Linked issue [empty=none]: " linked_issue
        if [[ -n "$linked_issue" ]]; then
          selected="$(select_issue_link_type)"

          IFS='|' read -r link_type link_direction <<< "$selected"
        fi

        epic_key="$(select_epic "${project:-DO}")"
        shift
        ;;
      *) echo "Unknown option: $1"; exit 1 ;;
    esac
  done

  project="${project:-DO}"
  issue_type="${issue_type:-Task}"
  priority="${priority:-Low}"
  if [[ -n "$linked_issue" && -z "$link_type" ]]; then
    echo "Linked issue was provided but no link type selected."
    exit 1
  fi

  [[ -z "$summary" ]] && read -r -p "Summary: " summary
  [[ -z "$summary" ]] && { echo "Summary is required."; exit 1; }

  local desc_json
  desc_json="$(jira_text_field_json "$description")"

  local payload
  payload="$(jq -cn \
    --arg project "$project" \
    --arg issue_type "$issue_type" \
    --arg summary "$summary" \
    --arg priority "$priority" \
    --argjson description "$desc_json" \
    --arg labels "$labels" \
    --arg assignee "$assignee" \
    --arg epic_key "$epic_key" \
    --arg epic_field "${JIRA_EPIC_LINK_FIELD:-$(get_epic_field_id)}" '
    {
      fields: {
        project: { key: $project },
        issuetype: { name: $issue_type },
        summary: $summary,
        description: $description,
        priority: { name: $priority }
      }
    }
    | if ($labels | length) > 0 then
        .fields.labels = ($labels | split(",") | map(gsub("^\\s+|\\s+$"; "")))
      else . end
    | if ($assignee | length) > 0 then
        .fields.assignee = { name: $assignee }
      else . end
    | if ($epic_key | length) > 0 and ($epic_field | length) > 0 then
        .fields[$epic_field] = $epic_key
      else . end
  ')"

  local out
  out="$(api POST "${JIRA_API_PREFIX}/issue" "$payload")" || true

  if ! echo "$out" | jq -e '.key' >/dev/null 2>&1; then
    echo "Create issue response:"
    echo "$out" | jq . 2>/dev/null || echo "$out"
    return 1
  fi

  local new_key
  new_key="$(echo "$out" | jq -r '.key')"

  echo "Issue created: $new_key"

  if [[ -n "$linked_issue" ]]; then
    local link_payload
    if [[ "$link_direction" == "outward" ]]; then

      link_payload="$(jq -cn \
        --arg type "$link_type" \
        --arg new "$new_key" \
        --arg existing "$linked_issue" '
        {
          type: { name: $type },
          outwardIssue: { key: $new },
          inwardIssue: { key: $existing }
        }')"

    else

      link_payload="$(jq -cn \
        --arg type "$link_type" \
        --arg new "$new_key" \
        --arg existing "$linked_issue" '
        {
          type: { name: $type },
          outwardIssue: { key: $existing },
          inwardIssue: { key: $new }
        }')"

    fi

    local link_out
    link_out="$(api POST "${JIRA_API_PREFIX}/issueLink" "$link_payload")" || true

    if [[ -z "$link_out" ]]; then
      echo "Linked $new_key to $linked_issue."
    else
      echo "Link response:"
      echo "$link_out" | jq . 2>/dev/null || echo "$link_out"
    fi
  fi
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

  create|new -i
  create|new --project DO --type Task --summary "..." --description "..." --priority Low

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
    create|new)          cmd_create "$@" ;;
    ""|help|-h|--help)   usage ;;
    *) echo "Unknown command: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"