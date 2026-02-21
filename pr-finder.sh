#!/usr/bin/env bash
set -euo pipefail

LIMIT="${PR_FINDER_LIMIT:-100}"
OWNER=""
INTERACTIVE_OPT=""  # "", "force", or "off"

usage() {
  echo "Usage: $(basename "$0") [--owner <user-or-org>] [-i | --no-interactive]"
  echo ""
  echo "Show open pull requests across your GitHub contexts."
  echo ""
  echo "Options:"
  echo "  --owner <name>       Filter to PRs in repos owned by a user or organization"
  echo "  -i, --interactive    Force interactive mode (requires fzf)"
  echo "  --no-interactive     Force non-interactive text output"
  echo "  -h, --help           Show this help message"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner=*) OWNER="${1#*=}"; shift ;;
    --owner)   OWNER="${2:?--owner requires a value}"; shift 2 ;;
    -i|--interactive) INTERACTIVE_OPT="force"; shift ;;
    --no-interactive) INTERACTIVE_OPT="off"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Resolve interactive mode
HAS_FZF=false
command -v fzf &>/dev/null && HAS_FZF=true

INTERACTIVE=false
if [[ "$INTERACTIVE_OPT" == "force" ]]; then
  if ! $HAS_FZF; then
    echo "Error: --interactive requires fzf but it is not installed." >&2
    exit 1
  fi
  INTERACTIVE=true
elif [[ "$INTERACTIVE_OPT" == "off" ]]; then
  INTERACTIVE=false
elif [[ -t 1 ]] && $HAS_FZF; then
  INTERACTIVE=true
fi

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

FZF_HINT=false
if [[ -t 1 ]] && ! $HAS_FZF && [[ "$INTERACTIVE_OPT" != "off" ]]; then
  FZF_HINT=true
fi

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
  --jq '.[] | select(.archived | not) | select(.open_issues_count > 0) | .full_name' 2>/dev/null \
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

# ── Interactive mode functions ──────────────────────────────────────────

build_fzf_input() {
  local json="$1" section="$2" color="$3"
  echo "$json" | jq -c '.[]' | while IFS= read -r pr; do
    [ -z "$pr" ] && continue
    local url repo number pr_title author is_draft updated
    url=$(echo "$pr" | jq -r '.url')
    repo=$(echo "$pr" | jq -r '.repository.nameWithOwner')
    number=$(echo "$pr" | jq -r '.number')
    pr_title=$(echo "$pr" | jq -r '.title')
    author=$(echo "$pr" | jq -r '.author.login')
    is_draft=$(echo "$pr" | jq -r '.isDraft')
    updated=$(echo "$pr" | jq -r '.updatedAt')

    local updated_epoch now_epoch diff_secs ago
    updated_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$updated" +%s 2>/dev/null || date -d "$updated" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    diff_secs=$((now_epoch - updated_epoch))
    if (( diff_secs < 3600 )); then
      ago="$((diff_secs / 60))m ago"
    elif (( diff_secs < 86400 )); then
      ago="$((diff_secs / 3600))h ago"
    else
      ago="$((diff_secs / 86400))d ago"
    fi

    local draft_tag=""
    [[ "$is_draft" == "true" ]] && draft_tag="  ${YELLOW}[DRAFT]${RESET}"

    printf '%s\t%b%-14s  %b%-6s %b%-50s %b(%s)  %s%b%b\n' \
      "$url" \
      "$color" "$section" \
      "$BOLD" "${repo} #${number}" \
      "$RESET" "$pr_title" \
      "$DIM" "$author" "$ago" "$RESET" \
      "$draft_tag"
  done
}

handle_merge() {
  local url="$1"

  local pr_info
  pr_info=$(gh pr view "$url" --json mergeable,mergeStateStatus,title,number 2>/dev/null) || {
    echo -e "${YELLOW}Could not fetch PR details.${RESET}" >&2
    return 1
  }

  local mergeable title number merge_state
  mergeable=$(echo "$pr_info" | jq -r '.mergeable')
  merge_state=$(echo "$pr_info" | jq -r '.mergeStateStatus')
  title=$(echo "$pr_info" | jq -r '.title')
  number=$(echo "$pr_info" | jq -r '.number')

  echo ""
  echo -e "  ${BOLD}#${number}${RESET} ${title}"
  echo -e "  ${DIM}${url}${RESET}"
  echo ""

  if [[ "$mergeable" == "MERGEABLE" ]]; then
    echo -e "  ${GREEN}✓ This PR can be merged${RESET} (status: ${merge_state})"
    echo ""
    read -r -p "  Merge this PR? [y/N] " answer </dev/tty
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      echo ""
      gh pr merge "$url" || {
        echo -e "  ${YELLOW}Merge failed. Open in browser to resolve.${RESET}" >&2
        return 1
      }
      echo -e "  ${GREEN}✓ Merged successfully${RESET}"
    fi
  elif [[ "$mergeable" == "CONFLICTING" ]]; then
    echo -e "  ${YELLOW}✗ This PR has merge conflicts${RESET}"
    echo ""
    read -r -p "  Open in browser to resolve? [y/N] " answer </dev/tty
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      gh pr view "$url" --web
    fi
  else
    echo -e "  ${DIM}⋯ Mergeability is still being computed by GitHub${RESET}"
    echo -e "  ${DIM}  Try again in a few seconds.${RESET}"
  fi
}

run_interactive() {
  local fzf_input
  fzf_input=$(
    build_fzf_input "$authored_json"  "✎ Authored"  "$GREEN"
    build_fzf_input "$review_json"    "⊙ Review"    "$MAGENTA"
    build_fzf_input "$assigned_json"  "→ Assigned"  "$CYAN"
    build_fzf_input "$repo_prs"       "◈ Repo"      "$BLUE"
  )

  if [[ -z "$fzf_input" ]]; then
    echo -e "${DIM}No open PRs found.${RESET}"
    return
  fi

  while true; do
    local selected
    selected=$(echo "$fzf_input" | fzf \
      --delimiter=$'\t' \
      --with-nth=2 \
      --ansi \
      --no-sort \
      --header="enter: merge · ctrl-o: open in browser · esc: quit" \
      --preview='gh pr view {1}' \
      --preview-window=right:50%:wrap \
      --bind='ctrl-o:execute-silent(gh pr view --web {1})' \
    ) || break

    local url
    url=$(echo "$selected" | cut -f1)
    [[ -z "$url" ]] && continue

    handle_merge "$url"

    # Remove the merged/handled PR from the list
    fzf_input=$(echo "$fzf_input" | awk -F'\t' -v url="$url" '$1 != url')

    if [[ -z "$fzf_input" ]]; then
      echo -e "${DIM}No more open PRs.${RESET}"
      break
    fi
  done
}

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

if $INTERACTIVE; then
  run_interactive
else
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

  if $FZF_HINT; then
    echo ""
    echo -e "${DIM}Tip: Install fzf for interactive mode (https://github.com/junegunn/fzf)${RESET}"
  fi
fi
