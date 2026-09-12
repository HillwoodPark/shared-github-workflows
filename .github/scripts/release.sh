#!/usr/bin/env bash
# Cut the next semver tag + GitHub release for a merge to main.
#
# Called by .github/workflows/release.yml on every push to main. The bump type
# comes from the merged PR's labels (release:major / release:minor /
# release:patch / release:skip); an unlabelled Dependabot PR defaults to patch,
# an unlabelled human PR (or a direct push with no PR) fails loudly so the
# omission can't go unnoticed. See CLAUDE.md "Releases".
#
# Local use:
#   .github/scripts/release.sh --self-test
#   DRY_RUN=1 SHA=<merge commit> .github/scripts/release.sh   # decide, create nothing
#
# Environment: SHA (required), GH_TOKEN (for gh), GITHUB_REPOSITORY
# (defaults to HillwoodPark/shared-github-workflows), DRY_RUN, GITHUB_STEP_SUMMARY.
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-HillwoodPark/shared-github-workflows}"
DEPENDABOT_LOGIN='dependabot[bot]'
TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}

# decide_bump <author login> <comma-separated label names>
# Prints major|minor|patch|skip, or "none" when no release label applies.
# Returns 2 when more than one release:* label is present.
decide_bump() {
  local author="$1" labels="$2" found=() label_list=() label
  if [[ -n "$labels" ]]; then IFS=',' read -r -a label_list <<< "$labels"; fi
  # ${arr[@]+"${arr[@]}"} keeps an empty array safe under set -u on bash 3.2 (macOS /bin/bash)
  for label in ${label_list[@]+"${label_list[@]}"}; do
    case "$label" in
      release:major|release:minor|release:patch|release:skip) found+=("${label#release:}") ;;
    esac
  done
  case "${#found[@]}" in
    0) if [[ "$author" == "$DEPENDABOT_LOGIN" ]]; then echo patch; else echo none; fi ;;
    1) echo "${found[0]}" ;;
    *) return 2 ;;
  esac
}

# next_version <vX.Y.Z> <major|minor|patch>
next_version() {
  local current="${1#v}" bump="$2" major minor patch
  IFS='.' read -r major minor patch <<< "$current"
  case "$bump" in
    major) echo "v$((major + 1)).0.0" ;;
    minor) echo "v${major}.$((minor + 1)).0" ;;
    patch) echo "v${major}.${minor}.$((patch + 1))" ;;
    *) return 2 ;;
  esac
}

# latest_tag: reads tag names on stdin, prints the highest vX.Y.Z (or nothing).
# Anything that isn't exactly three numeric parts (e.g. the historical `v1`)
# is ignored so a stray tag can never become the version baseline.
latest_tag() {
  { grep -E "$TAG_RE" || true; } | sort -V | tail -n 1
}

self_test() {
  local failures=0
  expect() { # expect <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failures=$((failures + 1)); fi
  }
  expect 'dependabot, no label -> patch'      patch "$(decide_bump "$DEPENDABOT_LOGIN" 'dependencies,github_actions')"
  expect 'human, no label -> none'            none  "$(decide_bump TimJohns '')"
  expect 'human, release:major'               major "$(decide_bump TimJohns 'enhancement,release:major')"
  expect 'human, release:minor'               minor "$(decide_bump TimJohns 'release:minor')"
  expect 'dependabot, release:skip'           skip  "$(decide_bump "$DEPENDABOT_LOGIN" 'release:skip,dependencies')"
  expect 'conflicting labels -> rc 2'         2     "$(decide_bump TimJohns 'release:major,release:minor' >/dev/null; echo $?)"
  expect 'next patch'                         v1.0.1 "$(next_version v1.0.0 patch)"
  expect 'next minor resets patch'            v1.3.0 "$(next_version v1.2.3 minor)"
  expect 'next major resets minor+patch'      v2.0.0 "$(next_version v1.2.3 major)"
  expect 'latest_tag is numeric, not lexical' v1.0.10 "$(printf 'v1\nv1.0.0\nv1.0.10\nv1.0.9\nfoo\n' | latest_tag)"
  expect 'latest_tag ignores bare v1'         ''     "$(printf 'v1\n' | latest_tag)"
  expect 'latest_tag on empty input'          ''     "$(printf '' | latest_tag)"
  if (( failures > 0 )); then echo "$failures failure(s)"; return 1; fi
  echo 'all self-tests passed'
}

main() {
  local sha="${SHA:?SHA is required (the merge commit on main)}"
  local pr_json pr_number='' author='' labels='' title=''

  # The merged PR that produced this commit. Squash merges give an exact
  # merge_commit_sha match; rebase/merge-commit merges are not supported here.
  pr_json=$(gh api "repos/${REPO}/commits/${sha}/pulls" \
    | jq -c --arg sha "$sha" '[.[] | select(.merge_commit_sha == $sha)] | first // empty')
  if [[ -n "$pr_json" ]]; then
    pr_number=$(jq -r '.number' <<< "$pr_json")
    author=$(jq -r '.user.login' <<< "$pr_json")
    labels=$(jq -r '[.labels[].name] | join(",")' <<< "$pr_json")
    title=$(jq -r '.title' <<< "$pr_json")
    echo "Merged PR #${pr_number} by ${author} (labels: ${labels:-none}): ${title}"
  else
    echo "No merged PR found for ${sha} (direct push?)"
  fi

  local bump
  if ! bump=$(decide_bump "$author" "$labels"); then
    echo "::error::PR #${pr_number} carries more than one release:* label (${labels}); keep exactly one."
    exit 1
  fi

  local latest
  latest=$(gh api "repos/${REPO}/git/matching-refs/tags/v" --paginate --jq '.[].ref | sub("^refs/tags/"; "")' | latest_tag)
  if [[ -z "$latest" ]]; then
    echo "::error::No vX.Y.Z tag exists. Bootstrap the first release by hand: gh release create v1.0.0 --target ${sha} --generate-notes"
    exit 1
  fi
  echo "Latest release tag: ${latest}"

  case "$bump" in
    skip)
      echo "::notice::release:skip — not tagging ${sha}; it ships with the next release."
      summary "⏭️ Skipped release for PR #${pr_number} (release:skip). Latest tag stays ${latest}."
      exit 0 ;;
    none)
      echo "::error::No release:* label on ${pr_number:+PR #${pr_number} }${sha} and it is not a Dependabot PR, so no tag was cut. Either label the next PR, or release this commit by hand:"
      echo "  gh release create $(next_version "$latest" patch) --target ${sha} --generate-notes --notes-start-tag ${latest}   # patch"
      echo "  gh release create $(next_version "$latest" minor) --target ${sha} --generate-notes --notes-start-tag ${latest}   # minor"
      echo "  gh release create $(next_version "$latest" major) --target ${sha} --generate-notes --notes-start-tag ${latest}   # major"
      summary "❌ No release cut for PR #${pr_number}: missing release:* label. See the job log for the manual commands."
      exit 1 ;;
  esac

  local next
  next=$(next_version "$latest" "$bump")
  local reason="${bump} bump"
  [[ "$labels" != *"release:${bump}"* ]] && reason="Dependabot default → patch"

  if [[ -n "${DRY_RUN:-}" ]]; then
    echo "DRY RUN: would create release ${next} at ${sha} (${reason}; previous ${latest})"
    exit 0
  fi

  gh release create "$next" --repo "$REPO" --target "$sha" --title "$next" --generate-notes --notes-start-tag "$latest"
  echo "Created release ${next} (${reason})"
  summary "🏷️ Released **${next}** from PR #${pr_number} (${reason}; previous ${latest}). Callers pick it up on their next Dependabot run."
}

if [[ "${1:-}" == '--self-test' ]]; then
  self_test
else
  main
fi
