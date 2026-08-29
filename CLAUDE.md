# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Reusable GitHub Actions workflows shared across HillwoodPark repositories. There is no application code — no `package.json`, no source tree, no test suite. The deliverable is `.github/workflows/dependabot-auto-approve.yml`, a `workflow_call` reusable workflow that other repos invoke.

**Every change here is org-wide.** Treat this repo as the org's supply-chain root: a stale or compromised `uses:` ref here propagates to every caller. Its own `.github/dependabot.yml` says exactly that.

## Verification

There is no build and no test suite. Verification is the two lint layers, and CI (`workflow-lint.yml`) runs both as a **required** status check. Reproduce them exactly before pushing:

```bash
# Layer 1 — the org-wide ban on pull_request_target (secret exfiltration via fork PRs)
grep -rnE '^[[:space:]]*pull_request_target[[:space:]]*:' .github/workflows/   # must find nothing

# Layer 2 — static audit, pinned to the same version CI uses
pipx run zizmor==1.26.1 --persona=regular --min-severity=high .github/workflows/
```

`actionlint` (run bare from the repo root; it auto-discovers `.github/workflows/` and rejects a directory argument) is not in CI but is worth running locally — it type-checks `${{ }}` expressions and catches unknown `steps.<id>` references, which zizmor does not. It cannot validate individual action *output names* (they're typed `{string => string}`); check those against the action's own `action.yml` `outputs:` block.

`workflow-lint.yml` triggers on `pull_request` types `[opened, synchronize, reopened, edited]`. The `edited` type is deliberate and load-bearing — see the comment in that file before touching it.

## Architecture: `dependabot-auto-approve.yml`

Three jobs, strictly sequential via `needs:` — `build` → `dependabot` → `claude-review`.

- **`build`** — dependency review, Node setup, `npm ci --ignore-scripts`, build, test. Optionally authenticates to GCP via Workload Identity Federation when the caller passes all three `gcp-*` inputs.
- **`dependabot`** — reads `dependabot/fetch-metadata`, then either enables auto-merge or posts a "⚠️ Review required" comment.
- **`claude-review`** — an *advisory* Claude compatibility assessment. Not a gate; callers' rulesets generally require only `build` and `workflow-lint`.

### The two risk conditions are exact complements

This is the single most important invariant and it isn't visible from either job alone:

| | condition |
|---|---|
| `dependabot` auto-merges | `(patch or minor)` **and** `(compat == 0 or compat >= 75)` |
| `claude-review` assesses | `major` **or** `(0 < compat < 75)` |

The second is the exact negation of the first. So **`claude-review` only ever runs on PRs that already require human review** — it can never be the thing that lets a PR through, and weakening it cannot weaken the merge gate. Preserve this when editing either condition.

### `claude-review` cannot run on a PR that changes a workflow file

`claude-code-action` mints its GitHub token by exchanging an OIDC token with Anthropic, and that exchange **rejects any run whose entry workflow file differs from the default-branch version** — a supply-chain guard against a PR rewriting the workflow that holds the secrets.

On rejection the action logs `Exiting due to workflow validation skip` and **returns early with empty outputs while exiting 0**, so the step reports green. Steps downstream must not infer "it ran" from a green step:

- Guard on `steps.analyze.outputs.structured_output != ''` — a *positive* precondition on the thing the step consumes — never on `conclusion != 'skipped'`.
- The complementary case, `conclusion == 'success' && structured_output == ''`, is the "never ran" outcome and gets a `::warning::`, not a failure.

Under `--json-schema`, a run that starts but produces no verdict calls `core.setFailed()` **and throws**, failing the step outright. So a green step with empty output has exactly one cause. Don't build on that invariant silently — the positive guard above is what keeps a future empty-output path routing to the warning instead of to a misleading `exit 1`.

**Consequence: every Dependabot PR that bumps this repo's own SHA in a caller goes un-reviewed by Claude, by design.** Review those by hand.

### Testing a `claude-review` change requires a real Dependabot PR

A hand-authored PR cannot exercise this job at all. Callers gate the whole reusable workflow on `github.event.pull_request.user.login == 'dependabot[bot]'`, and relaxing that doesn't help — `dependabot/fetch-metadata` errors outside a Dependabot PR context, failing the job `claude-review` needs.

To exercise it now rather than waiting for the daily schedule, comment `@dependabot recreate` on an existing Dependabot PR in a caller. Dependabot re-resolves to this repo's current `main` HEAD, and because the resulting PR changes a workflow file, it exercises the validation-skip path too.

## Propagation to callers

Callers pin by **commit SHA**, so a merge to `main` reaches nobody until each caller's Dependabot bumps its pin. Their `.github/dependabot.yml` files exempt `HillwoodPark/*` from the 3-day supply-chain cooldown specifically so these pin bumps propagate within a day instead of by hand.

Check where a change has landed:

```bash
for r in $(gh repo list HillwoodPark --limit 100 --json name --jq '.[].name'); do
  sha=$(gh api "repos/HillwoodPark/$r/contents/.github/workflows/dependabot-auto-approve.yml" \
          --jq '.content' 2>/dev/null | base64 -d 2>/dev/null \
        | grep -oE 'dependabot-auto-approve\.yml@[0-9a-f]{40}' | cut -d@ -f2)
  [ -n "$sha" ] && printf '%-32s %s\n' "$r" "${sha:0:12}"
done
```

Two caveats that command surfaces:

- **This repo's own `dependabot-auto-approve.yml` is the reusable workflow itself, not a caller.** Don't count it.
- **`common-infrastructure` calls it under a different filename** (`report-to-collector-dependabot-auto-merge.yml`), so a filename-based sweep misses it.
- **`authed` and `authed-target-example` have standalone inlined copies** of the old auto-merge pattern and do not consume this workflow. Changes here do not reach them.

## Conventions

- **Pin every `uses:` to a full commit SHA** with a trailing `# vX.Y.Z` comment. Non-negotiable here — this is the supply-chain root.
- **Never interpolate `${{ }}` directly into a `run:` block.** Pass it through `env:` instead. Every step in `dependabot-auto-approve.yml` follows this; it keeps zizmor's `template-injection` rule clear and avoids shell corruption when a value contains a quote.
- **`pull_request_target` is banned org-wide** and enforced by grep in `workflow-lint.yml`.
- **`.github/zizmor.yml` is shared config, rolled out identically to every repo running `workflow-lint`.** Its `excessive-permissions` ignore list names *caller-side* filenames — that's why entries like `report-to-collector-dependabot-auto-merge.yml` appear here despite not existing in this repo.
- **CODEOWNERS is intentionally advisory.** Do not enable "require review from Code Owners" in the ruleset — it would gate Dependabot's own action-bump PRs and deadlock auto-merge. The comment in `.github/CODEOWNERS` says so.
