#!/usr/bin/env bash
# Roll the security scan out to other repos.
#
#   scripts/rollout.sh [--ref <sha>] owner/repo [owner/repo ...]
#
# For each repo:
#   1. opens a PR adding .github/workflows/security.yml (calling scan.yml pinned to a commit SHA)
#      and a github-actions entry in .github/dependabot.yml
#   2. enables CodeQL default setup (public repos only)
#   3. adds a ruleset on the default branch requiring the "security" check
#
# Re-running is safe: unchanged repos get no PR, and an existing ruleset is updated in place.
set -euo pipefail

SOURCE_REPO=elicollinson/security-workflows
BRANCH=security-workflows
RULESET_NAME=security
GITHUB_ACTIONS_APP_ID=15368 # the check must come from GitHub Actions

ref=""
if [[ "${1:-}" == --ref ]]; then
  ref=$2
  shift 2
fi
if [[ $# -eq 0 ]]; then
  echo "usage: $0 [--ref <sha>] owner/repo [owner/repo ...]" >&2
  exit 2
fi

command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

if [[ -z "$ref" ]]; then
  ref=$(gh api "repos/$SOURCE_REPO/commits/main" --jq .sha)
fi
[[ "$ref" =~ ^[0-9a-f]{40}$ ]] || { echo "--ref must be a full 40-character commit SHA" >&2; exit 1; }
# Version comment for Dependabot: the newest tag pointing at $ref, else the SHA itself.
version=$(gh api "repos/$SOURCE_REPO/tags" --jq "[.[] | select(.commit.sha == \"$ref\") | .name][0] // \"$ref\"")
echo "Using $SOURCE_REPO@$ref ($version)"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

write_caller() {
  cat > "$1" <<EOF
name: security

on:
  pull_request:
  push:
    branches: [$2]
  schedule:
    - cron: "17 6 * * 1"
  workflow_dispatch:

permissions: {}

concurrency:
  group: \${{ github.workflow }}-\${{ github.ref }}
  cancel-in-progress: true

jobs:
  scan:
    permissions:
      contents: read
      security-events: write
    uses: $SOURCE_REPO/.github/workflows/scan.yml@$ref # $version

  # Single required check for the ruleset: passes only if every scan job passed.
  security:
    if: \${{ always() }}
    needs: scan
    runs-on: ubuntu-latest
    permissions: {}
    steps:
      - uses: step-security/harden-runner@46b06cea07f9e64621fdf066ba77ac6915163d43 # v2.22.3
        with:
          egress-policy: audit
      - env:
          RESULT: \${{ needs.scan.result }}
        run: test "\$RESULT" = success
EOF
}

DEPENDABOT_ENTRY='  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    cooldown:
      default-days: 7
    groups:
      actions:
        patterns: ["*"]'

# Returns 0 if the file was written or already fine, 1 if it needs a manual edit.
write_dependabot() {
  local f=$1
  if [[ ! -f "$f" ]]; then
    printf 'version: 2\nupdates:\n%s\n' "$DEPENDABOT_ENTRY" > "$f"
  elif grep -Eq 'package-ecosystem:[[:space:]]*"?github-actions"?' "$f"; then
    : # already present
  elif [[ "$(grep -E '^[A-Za-z]' "$f" | tail -1)" == updates:* ]]; then
    # `updates:` is the last top-level key, so appending lands inside its list.
    [[ -z "$(tail -c1 "$f")" ]] || echo >> "$f"
    printf '%s\n' "$DEPENDABOT_ENTRY" >> "$f"
  else
    return 1
  fi
}

open_pr() {
  local repo=$1 default_branch=$2 dir="$workdir/${1//\//_}" pr
  pr=$(gh pr list --repo "$repo" --head "$BRANCH" --state open --json url --jq '.[0].url // ""')
  if [[ -n "$pr" ]]; then
    echo "  = PR: already open, $pr"
    return
  fi
  gh repo clone "$repo" "$dir" -- --depth 1 --branch "$default_branch" --quiet
  git -C "$dir" switch --quiet -c "$BRANCH"
  mkdir -p "$dir/.github/workflows"
  write_caller "$dir/.github/workflows/security.yml" "$default_branch"
  local note=""
  if ! write_dependabot "$dir/.github/dependabot.yml"; then
    note=$'\n\n**Manual step:** `.github/dependabot.yml` has keys after `updates:`, so the github-actions entry was not added automatically.'
    echo "  ! $repo: add the github-actions entry to .github/dependabot.yml by hand"
  fi

  git -C "$dir" add .github
  if git -C "$dir" diff --cached --quiet; then
    echo "  = PR: nothing to change"
    return
  fi
  git -C "$dir" commit --quiet -m "Add security scanning workflow"
  # Fails if a stale $BRANCH exists without an open PR; delete it and re-run.
  git -C "$dir" push --quiet -u origin "$BRANCH"
  gh pr create --repo "$repo" --base "$default_branch" --head "$BRANCH" \
    --title "Add security scanning workflow" \
    --body "Adds the reusable scan from $SOURCE_REPO (gitleaks, opengrep, osv-scanner, zizmor), pinned to \`$ref\`, and a weekly Dependabot github-actions update.

Per-repo ignores: \`.gitleaksignore\`, \`osv-scanner.toml\`, \`.semgrepignore\`, \`.github/zizmor.yml\`. See https://github.com/$SOURCE_REPO#readme.$note"
}

enable_codeql() {
  local repo=$1 visibility=$2
  if [[ "$visibility" != public ]]; then
    echo "  - CodeQL: skipped ($visibility repo)"
    return
  fi
  if gh api --silent -X PATCH "repos/$repo/code-scanning/default-setup" -f state=configured 2>"$workdir/err"; then
    echo "  + CodeQL: default setup requested"
  else
    echo "  ! CodeQL: $(cat "$workdir/err")"
  fi
}

add_ruleset() {
  local repo=$1 id body
  body=$(jq -n --arg name "$RULESET_NAME" --argjson app "$GITHUB_ACTIONS_APP_ID" '{
    name: $name,
    target: "branch",
    enforcement: "active",
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [{
      type: "required_status_checks",
      parameters: {
        strict_required_status_checks_policy: false,
        do_not_enforce_on_create: true,
        required_status_checks: [{context: "security", integration_id: $app}]
      }
    }]
  }')
  id=$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$RULESET_NAME\") | .id" 2>/dev/null || true)
  if [[ -n "$id" ]]; then
    gh api --silent -X PUT "repos/$repo/rulesets/$id" --input - <<< "$body" 2>"$workdir/err" \
      && echo "  = ruleset: updated" || echo "  ! ruleset: $(cat "$workdir/err")"
  else
    gh api --silent -X POST "repos/$repo/rulesets" --input - <<< "$body" 2>"$workdir/err" \
      && echo "  + ruleset: created" || echo "  ! ruleset: $(cat "$workdir/err")"
  fi
}

for repo in "$@"; do
  echo "== $repo"
  read -r default_branch visibility < <(gh api "repos/$repo" --jq '"\(.default_branch) \(.visibility)"')
  open_pr "$repo" "$default_branch"
  enable_codeql "$repo" "$visibility"
  add_ruleset "$repo"
done
