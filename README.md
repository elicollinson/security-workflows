# security-workflows

A reusable GitHub Actions workflow that runs four security scanners in parallel. Other repos call it by commit SHA.

## Jobs

Each job starts with `step-security/harden-runner` (egress audit), checks out with `persist-credentials: false`, and has `contents: read` plus `security-events: write` for the SARIF upload. Every action is pinned to a commit SHA.

| Job | What it does |
| --- | --- |
| `gitleaks` | Runs `gitleaks/gitleaks-action` on a full-history clone (`fetch-depth: 0`). The action decides the commit range from the event: pull requests scan the PR's commits, pushes scan the pushed commits, and schedule or manual runs scan the whole history. The weekly run is the full-history sweep. |
| `opengrep` | Downloads the opengrep release binary, checks its SHA-256, and scans the repo with the security rules from [opengrep-rules](https://github.com/opengrep/opengrep-rules) (every `*/security/` directory, pinned to a commit). It skips style, correctness, i18n and AI-SDK-usage rules, the GitHub Actions rules (zizmor covers those) and `package-dependencies-check` (it flags every `^`/`~` range even when a lockfile pins the version). Writes SARIF. |
| `osv-scanner` | Downloads the osv-scanner release binary, checks its SHA-256, and runs `scan source --recursive` against every lockfile and manifest it finds. Writes SARIF. A repo with no lockfiles passes. |
| `zizmor` | Runs `zizmorcore/zizmor-action` on `.github/workflows` with online audits enabled. |

All SARIF goes to code scanning through `github/codeql-action/upload-sarif`, each tool under its own category. Uploads are skipped for private repos (personal accounts don't get code scanning on them) and for fork PRs. In those cases the findings still show up in the job log and still fail the job.

Each job ends with a `Check results` step. It prints every finding from the SARIF and fails the job if there are any and `fail-on-findings` is true. It also fails if a scanner errored out without producing results.

The binary versions, their checksums, and the rules commit are in the `env:` block at the top of [`scan.yml`](.github/workflows/scan.yml). Dependabot keeps the actions current. Update the binaries yourself, using the `sha256:` digest that GitHub shows for each release asset:

```sh
gh api repos/opengrep/opengrep/releases/tags/v1.33.1 --jq '.assets[] | select(.name=="opengrep_manylinux_x86") | .digest'
gh api repos/google/osv-scanner/releases/tags/v2.7.0 --jq '.assets[] | select(.name=="osv-scanner_linux_amd64") | .digest'
```

## Inputs

| Input | Type | Default | |
| --- | --- | --- | --- |
| `fail-on-findings` | boolean | `true` | When false, findings are still reported and uploaded, but the jobs pass. |
| `exclude-paths` | string | `""` | Paths to skip, separated by spaces or commas (e.g. `vendor, testdata`). Passed to opengrep `--exclude` and osv-scanner `--x-exclude`. gitleaks and zizmor ignore this input and use their own ignore files (see below). |

## Using it

Copy this into `.github/workflows/security.yml` in the calling repo. Replace `<sha>` with a full commit SHA from this repo, e.g. `gh api repos/elicollinson/security-workflows/commits/main --jq .sha`.

```yaml
name: security

on:
  pull_request:
  push:
    branches: [main]
  schedule:
    - cron: "17 6 * * 1"
  workflow_dispatch:

permissions: {}

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  scan:
    permissions:
      contents: read
      security-events: write
    uses: elicollinson/security-workflows/.github/workflows/scan.yml@<sha> # v1.0.0
    # with:
    #   fail-on-findings: false
    #   exclude-paths: vendor testdata

  # Single required check for the ruleset: passes only if every scan job passed.
  security:
    if: ${{ always() }}
    needs: scan
    runs-on: ubuntu-latest
    permissions: {}
    steps:
      - uses: step-security/harden-runner@46b06cea07f9e64621fdf066ba77ac6915163d43 # v2.22.3
        with:
          egress-policy: audit
      - env:
          RESULT: ${{ needs.scan.result }}
        run: test "$RESULT" = success
```

Jobs from a reusable workflow show up as `scan / gitleaks`, `scan / opengrep`, and so on. The small `security` job rolls them up into one check named `security`, which is the one a ruleset requires.

Add this to the calling repo's `.github/dependabot.yml` so Dependabot bumps the SHA above:

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    cooldown:
      default-days: 7
    groups:
      actions:
        patterns: ["*"]
```

Dependabot uses the trailing `# vX.Y.Z` comment to work out the version, so tag releases here (`git tag v1.0.0 && git push origin v1.0.0`) and use that tag in the comment.

## Per-repo ignores

These files go in the calling repo:

| Tool | File | Notes |
| --- | --- | --- |
| gitleaks | `.gitleaksignore` (repo root) | One finding fingerprint per line, copied from the job log or SARIF (`commit:file:rule:line`). For path-based or regex allowlists, add a `.gitleaks.toml` that has `[extend] useDefault = true`. |
| osv-scanner | `osv-scanner.toml` (next to the lockfile) | `[[IgnoredVulns]]` entries with `id`, `reason`, and optionally `ignoreUntil`. |
| opengrep | `.semgrepignore` (repo root) | gitignore-style paths. For a single line, add a `# nosemgrep: <rule-id>` comment. |
| zizmor | `.github/zizmor.yml` | Per-audit `ignore:` rules. For a single line, add a `# zizmor: ignore[<audit>]` comment. |

## Rolling out

`scripts/rollout.sh owner/repo [...]` handles each repo in turn. It:

- opens a PR that adds the caller above (pinned to the latest `main` commit, or to `--ref <sha>`) and the Dependabot entry
- enables CodeQL default setup (public repos only)
- creates or updates a ruleset named `security` on the default branch that requires the `security` check from GitHub Actions

The rollout PR runs the new workflow on itself, so it can satisfy the required check. If the repo already has findings, the PR stays blocked until you fix them, add ignores, or set `fail-on-findings: false`. With the ruleset in place, a commit can only land on the default branch if it has a passing `security` check, which in practice means every change goes through a PR.

## This repo

[`security.yml`](.github/workflows/security.yml) calls the local `scan.yml` on PRs, on pushes to `main`, and weekly, so every change here gets scanned by the version it's changing.
