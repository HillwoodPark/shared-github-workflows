#!/usr/bin/env bash
# Cut the next semver tag + GitHub release for a merge to main.
#
# Called by .github/workflows/release.yml on every push to main. The bump is
# the highest release:* label across EVERY merged PR since the latest tag —
# not just the PR that produced this push — so a failed or cancelled run can
# never let a release:major change ride out as somebody else's patch.
# An unlabelled Dependabot PR counts as patch; an unlabelled human PR, or a
# commit with no merged PR (direct push), fails the run loudly.
# See CLAUDE.md "Releases".
#
# Local use:
#   .github/scripts/release.sh --self-test
#   DRY_RUN=1 SHA=<commit on main> .github/scripts/release.sh
#   DRY_RUN=1 RANGE_BASE=<older commit> SHA=<commit> .github/scripts/release.sh   # exercise the range logic on history
#
# Environment: SHA (required), GH_TOKEN (for gh), GITHUB_REPOSITORY (defaults
# to HillwoodPark/shared-github-workflows), DRY_RUN, RANGE_BASE (DRY_RUN only),
# GITHUB_STEP_SUMMARY, ALLOW_LOCAL_RELEASE (create for real outside Actions).
set -euo pipefail
# A set -e exit with no message is undiagnosable from the Actions log; name the line.
trap 'echo "::error::release.sh failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

REPO="${GITHUB_REPOSITORY:-HillwoodPark/shared-github-workflows}"
DEPENDABOT_LOGIN='dependabot[bot]'
TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}

# decide_bump <author login> <newline-separated release:* label names>
# Prints major|minor|patch|skip, or "none" when no release label applies.
# Returns 2 when more than one release:* label is present.
decide_bump() {
  local author="$1" labels="$2" found=() label_list=() label
  if [[ -n "$labels" ]]; then IFS=$'\n' read -r -d '' -a label_list <<< "$labels" || true; fi
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

# highest_bump <space-separated bumps> — major > minor > patch; skip/none are ignored.
# Prints nothing when no releasable bump is present.
highest_bump() {
  local best='' b
  for b in $1; do
    case "$b" in
      major) best=major ;;
      minor) [[ "$best" != major ]] && best=minor ;;
      patch) [[ -z "$best" ]] && best='patch' ;;
    esac
  done
  echo "$best"
}

# next_version <vX.Y.Z> <major|minor|patch>. 10# forces decimal: a tag part
# with a leading zero would otherwise be read as octal (010 → 8, 08 → error).
next_version() {
  local current="${1#v}" bump="$2" major minor patch
  IFS='.' read -r major minor patch <<< "$current"
  case "$bump" in
    major) echo "v$((10#$major + 1)).0.0" ;;
    minor) echo "v${major}.$((10#$minor + 1)).0" ;;
    patch) echo "v${major}.${minor}.$((10#$patch + 1))" ;;
    *) return 2 ;;
  esac
}

# latest_tag: reads tag names on stdin, prints the highest vX.Y.Z (or nothing).
# Anything that isn't exactly three numeric parts (e.g. a floating `v1`) is
# ignored so a stray tag can never become the version baseline.
latest_tag() {
  { grep -E "$TAG_RE" || true; } | sort -V | tail -n 1
}

self_test() {
  local failures=0 nl=$'\n'
  expect() { # expect <description> <expected> <actual>
    if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failures=$((failures + 1)); fi
  }
  expect 'dependabot, no label -> patch'      patch "$(decide_bump "$DEPENDABOT_LOGIN" '')"
  expect 'human, no label -> none'            none  "$(decide_bump TimJohns '')"
  expect 'human, release:major'               major "$(decide_bump TimJohns 'release:major')"
  expect 'human, release:minor'               minor "$(decide_bump TimJohns 'release:minor')"
  expect 'dependabot, release:skip'           skip  "$(decide_bump "$DEPENDABOT_LOGIN" 'release:skip')"
  expect 'unknown label ignored'              none  "$(decide_bump TimJohns 'release:bogus')"
  expect 'conflicting labels -> rc 2'         2     "$(decide_bump TimJohns "release:major${nl}release:minor" >/dev/null; echo $?)"
  expect 'highest: patch minor -> minor'      minor "$(highest_bump 'patch minor')"
  expect 'highest: patch major minor -> major' major "$(highest_bump 'patch major minor')"
  expect 'highest: skip patch -> patch'       patch "$(highest_bump 'skip patch')"
  expect 'highest: only skip -> empty'        ''    "$(highest_bump 'skip skip')"
  expect 'next patch'                         v1.0.1 "$(next_version v1.0.0 patch)"
  expect 'next minor resets patch'            v1.3.0 "$(next_version v1.2.3 minor)"
  expect 'next major resets minor+patch'      v2.0.0 "$(next_version v1.2.3 major)"
  expect 'leading zero is decimal not octal'  v1.0.11 "$(next_version v1.0.010 patch)"
  expect 'leading zero 08 does not error'     v1.0.9 "$(next_version v1.0.08 patch)"
  expect 'latest_tag is numeric, not lexical' v1.0.10 "$(printf 'v1\nv1.0.0\nv1.0.10\nv1.0.9\nfoo\n' | latest_tag)"
  expect 'latest_tag ignores bare v1'         ''     "$(printf 'v1\n' | latest_tag)"
  expect 'latest_tag on empty input'          ''     "$(printf '' | latest_tag)"
  if (( failures > 0 )); then echo "$failures failure(s)"; return 1; fi
  echo 'all self-tests passed'
}

# merged_pr_for_commit <sha> — prints "number<TAB>author<TAB>label1,label2" for the
# merged PR that introduced the commit, or nothing (direct push / not merged).
# Only release:* labels are kept, joined with "," and re-split on that later;
# label names are chosen by triage+ users here, so the delimiter is safe.
merged_pr_for_commit() {
  gh api "repos/${REPO}/commits/$1/pulls" \
    | jq -r '[.[] | select(.merged_at != null)] | first // empty
             | [(.number | tostring), .user.login, ([.labels[].name | select(startswith("release:"))] | join(","))]
             | @tsv'
}

manual_commands() { # manual_commands <sha> <latest>
  local b
  for b in patch minor major; do
    echo "  gh release create $(next_version "$2" "$b") --target $1 --generate-notes --notes-start-tag $2   # ${b}"
  done
}

main() {
  local sha="${SHA:?SHA is required (the merge commit on main)}"

  local latest
  latest=$(gh api "repos/${REPO}/git/matching-refs/tags/v" --paginate --jq '.[].ref | sub("^refs/tags/"; "")' | latest_tag)
  if [[ -z "$latest" ]]; then
    echo "::error::No vX.Y.Z tag exists. Bootstrap the first release by hand: gh release create v1.0.0 --target ${sha} --generate-notes"
    exit 1
  fi
  echo "Latest release tag: ${latest}"

  # Everything on main since the latest tag. RANGE_BASE is a DRY_RUN-only test
  # aid for replaying the logic over older history.
  local base="$latest"
  if [[ -n "${DRY_RUN:-}" && -n "${RANGE_BASE:-}" ]]; then base="$RANGE_BASE"; echo "DRY RUN: comparing from ${base} instead of ${latest}"; fi
  local compare status
  compare=$(gh api "repos/${REPO}/compare/${base}...${sha}" | jq -c '{status, total_commits, shas: [.commits[].sha]}')
  status=$(jq -r '.status' <<< "$compare")
  case "$status" in
    identical)
      echo "::notice::${sha} is already ${latest}; nothing to release."
      exit 0 ;;
    ahead) ;;
    *)
      echo "::error::main history is '${status}' relative to ${latest} — expected 'ahead'. Refusing to guess a version; inspect the tag and release by hand."
      exit 1 ;;
  esac
  if [[ "$(jq -r '.total_commits' <<< "$compare")" -ne "$(jq -r '.shas | length' <<< "$compare")" ]]; then
    echo "::error::More commits since ${latest} than the compare API returns; release by hand."
    exit 1
  fi

  # One line per merged PR (deduplicated, oldest first): number, author, bump.
  local shas commit line number author labels bump head_bump='' bumps='' seen='' report='' missing='' conflicts=''
  shas=$(jq -r '.shas[]' <<< "$compare")
  for commit in $shas; do
    line=$(merged_pr_for_commit "$commit")
    if [[ -z "$line" ]]; then
      missing="${missing} ${commit:0:12} (no merged PR — direct push?)"$'\n'
      [[ "$commit" == "$sha" ]] && head_bump=none
      continue
    fi
    IFS=$'\t' read -r number author labels <<< "$line"
    [[ " ${seen} " == *" ${number} "* ]] && { [[ "$commit" == "$sha" ]] && head_bump=$(decide_bump "$author" "${labels//,/$'\n'}" || true); continue; }
    seen="${seen} ${number}"
    if ! bump=$(decide_bump "$author" "${labels//,/$'\n'}"); then
      conflicts="${conflicts} #${number} (${labels})"
      continue
    fi
    [[ "$commit" == "$sha" ]] && head_bump="$bump"
    if [[ "$bump" == none ]]; then
      missing="${missing} #${number} by ${author} (no release:* label)"$'\n'
    else
      bumps="${bumps} ${bump}"
      # No `$([[ … ]] && …)` here: a false test inside a command substitution
      # makes the assignment itself return 1, and set -e exits silently.
      if [[ -z "$labels" ]]; then
        report="${report} #${number}=${bump} (Dependabot default)"
      else
        report="${report} #${number}=${bump}"
      fi
    fi
  done
  echo "PRs since ${latest}:${report:- none}"

  if [[ -n "$conflicts" ]]; then
    echo "::error::More than one release:* label on${conflicts}; keep exactly one."
    exit 1
  fi
  if [[ "$head_bump" == skip ]]; then
    echo "::notice::release:skip on the merged PR — not tagging ${sha}. Everything since ${latest} ships with the next release; label that PR for the highest change in the accumulated range."
    summary "⏭️ Skipped release (release:skip). Latest tag stays ${latest}."
    exit 0
  fi
  if [[ -n "$missing" ]]; then
    echo "::error::Cannot release ${sha}: unlabelled changes since ${latest}:"
    printf '%s' "$missing"
    echo "Either label the next PR (the bump covers the whole range), or release this commit by hand:"
    manual_commands "$sha" "$latest"
    summary "❌ No release cut: unlabelled changes since ${latest}. See the job log for the manual commands."
    exit 1
  fi

  bump=$(highest_bump "$bumps")
  if [[ -z "$bump" ]]; then
    echo "::error::Nothing releasable since ${latest} (only release:skip PRs) yet the merged PR is not release:skip — inspect by hand."
    manual_commands "$sha" "$latest"
    exit 1
  fi
  local next
  next=$(next_version "$latest" "$bump")

  if [[ -n "${DRY_RUN:-}" ]]; then
    echo "DRY RUN: would create release ${next} at ${sha} (${bump}; previous ${latest})"
    exit 0
  fi
  if [[ "${GITHUB_ACTIONS:-}" != true && "${ALLOW_LOCAL_RELEASE:-}" != 1 ]]; then
    echo "::error::Refusing to create a release outside GitHub Actions. Set DRY_RUN=1 to preview, or ALLOW_LOCAL_RELEASE=1 to override."
    exit 1
  fi

  gh release create "$next" --repo "$REPO" --target "$sha" --title "$next" --generate-notes --notes-start-tag "$latest"
  echo "Created release ${next} (${bump})"
  summary "🏷️ Released **${next}** (${bump}; previous ${latest}) covering${report}. Callers pick it up on their next Dependabot run."
}

if [[ "${1:-}" == '--self-test' ]]; then
  self_test
else
  main
fi
