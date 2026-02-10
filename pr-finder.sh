#!/usr/bin/env bash
set -euo pipefail

LIMIT="${PR_FINDER_LIMIT:-100}"
OWNER=""

usage() {
  echo "Usage: $(basename "$0") [--owner <user-or-org>]"
  echo ""
  echo "Show open pull requests across your GitHub contexts."
  echo ""
  echo "Options:"
  echo "  --owner <name>   Filter to PRs in repos owned by a user or organization"
  echo "  -h, --help       Show this help message"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner=*) OWNER="${1#*=}"; shift ;;
    --owner)   OWNER="${2:?--owner requires a value}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Colors
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
MAGENTA='\033[35m'
BLUE='\033[34m'
RESET='\033[0m'

# Check dependencies
for cmd in gh jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

# Check auth
if ! gh auth status &>/dev/null; then
  echo "Error: not authenticated with gh. Run 'gh auth login' first." >&2
  exit 1
fi

ME=$(gh api user --jq '.login')

# JSON fields to fetch
FIELDS="repository,number,title,author,isDraft,updatedAt,url"

fetch_prs() {
  local qualifier="$1"
  local cmd=(gh search prs --state=open "$qualifier" --limit "$LIMIT" --json "$FIELDS")
  [[ -n "$OWNER" ]] && cmd+=(--owner "$OWNER")
  "${cmd[@]}" 2>/dev/null || echo '[]'
}

# Fetch all three categories
authored_json=$(fetch_prs "--author=@me")
review_json=$(fetch_prs "--review-requested=@me")
assigned_json=$(fetch_prs "--assignee=@me")

# Fetch open PRs in repos where the user has push access (owner or collaborator)
repo_flags=()
while IFS= read -r repo; do
  [[ -n "$repo" ]] && repo_flags+=("--repo=$repo")
done < <(gh api --paginate 'user/repos?affiliation=owner,collaborator,organization_member&per_page=100' \
  --jq '.[] | select(.open_issues_count > 0) | .full_name' 2>/dev/null \
  | { if [[ -n "$OWNER" ]]; then grep "^${OWNER}/" || true; else cat; fi; })

repo_prs='[]'
if [[ ${#repo_flags[@]} -gt 0 ]]; then
  batch_size=10
  for ((i = 0; i < ${#repo_flags[@]}; i += batch_size)); do
    batch=("${repo_flags[@]:i:batch_size}")
    batch_result=$(gh search prs --state=open "${batch[@]}" --limit "$LIMIT" --json "$FIELDS" 2>/dev/null || echo '[]')
    repo_prs=$(echo "$repo_prs" "$batch_result" | jq -s '.[0] + .[1]')
  done
fi

# Deduplicate: remove from later sections any PR already in earlier sections
review_json=$(echo "$review_json" | jq --argjson authored "$authored_json" '
  [($authored | map(.url)) as $seen | .[] | select(.url as $u | $seen | index($u) | not)]
')

assigned_json=$(echo "$assigned_json" | jq --argjson authored "$authored_json" --argjson review "$review_json" '
  [($authored + $review | map(.url)) as $seen | .[] | select(.url as $u | $seen | index($u) | not)]
')

repo_prs=$(echo "$repo_prs" | jq --argjson authored "$authored_json" --argjson review "$review_json" --argjson assigned "$assigned_json" '
  [($authored + $review + $assigned | map(.url)) as $seen | .[] | select(.url as $u | $seen | index($u) | not)]
')

format_pr() {
  local pr="$1"
  local repo number pr_title author is_draft updated

  repo=$(echo "$pr" | jq -r '.repository.nameWithOwner')
  number=$(echo "$pr" | jq -r '.number')
  pr_title=$(echo "$pr" | jq -r '.title')
  author=$(echo "$pr" | jq -r '.author.login')
  is_draft=$(echo "$pr" | jq -r '.isDraft')
  updated=$(echo "$pr" | jq -r '.updatedAt')

  # Relative time
  local updated_epoch now_epoch diff_secs ago
  updated_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$updated" +%s 2>/dev/null || date -d "$updated" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  diff_secs=$((now_epoch - updated_epoch))
  if (( diff_secs < 3600 )); then
    ago="$((diff_secs / 60)) minutes ago"
  elif (( diff_secs < 86400 )); then
    ago="$((diff_secs / 3600)) hours ago"
  else
    local days=$((diff_secs / 86400))
    if (( days == 1 )); then
      ago="1 day ago"
    else
      ago="$days days ago"
    fi
  fi

  local draft_tag=""
  if [[ "$is_draft" == "true" ]]; then
    draft_tag="  ${YELLOW}[DRAFT]${RESET}"
  fi

  echo -e "  ${BOLD}${repo} #${number}${RESET}  ${pr_title}${draft_tag}"
  echo -e "  ${DIM}by ${author} · ${ago}${RESET}"
  echo -e "  ${DIM}$(echo "$pr" | jq -r '.url')${RESET}"
  echo ""
}

print_section() {
  local title="$1" color="$2" json="$3"
  local count
  count=$(echo "$json" | jq 'length')

  echo ""
  echo -e "${color}${BOLD}${title}${RESET} ${DIM}(${count})${RESET}"

  if (( count == 0 )); then
    echo -e "  ${DIM}No PRs found.${RESET}"
  else
    echo ""
    while IFS= read -r pr; do
      [ -z "$pr" ] && continue
      format_pr "$pr"
    done < <(echo "$json" | jq -c '.[]')
  fi

  echo "$count"
}

if [[ -n "$OWNER" ]]; then
  echo -e "${BOLD}PR Finder${RESET} — open pull requests for ${CYAN}${ME}${RESET} in ${MAGENTA}${OWNER}${RESET}"
else
  echo -e "${BOLD}PR Finder${RESET} — open pull requests for ${CYAN}${ME}${RESET}"
fi

# Print sections, capturing count from last line
authored_out=$(print_section "Authored by you" "$GREEN" "$authored_json")
authored_count=$(echo "$authored_out" | tail -1)
echo "$authored_out" | sed '$d'

review_out=$(print_section "Review requested" "$MAGENTA" "$review_json")
review_count=$(echo "$review_out" | tail -1)
echo "$review_out" | sed '$d'

assigned_out=$(print_section "Assigned to you" "$CYAN" "$assigned_json")
assigned_count=$(echo "$assigned_out" | tail -1)
echo "$assigned_out" | sed '$d'

repo_out=$(print_section "In your repositories" "$BLUE" "$repo_prs")
repo_count=$(echo "$repo_out" | tail -1)
echo "$repo_out" | sed '$d'

total=$((authored_count + review_count + assigned_count + repo_count))
echo -e "${DIM}─────────────────────────────────${RESET}"
echo -e "${BOLD}Total: ${total} open PRs${RESET}"
