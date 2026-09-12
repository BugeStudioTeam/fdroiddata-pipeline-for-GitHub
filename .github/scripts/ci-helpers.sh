#!/usr/bin/env bash
#
# Shared helpers for the GitHub Actions workflows, ported from the GitLab CI
# anchors in the original .gitlab-ci.yml:
#
#   * get_target_source_refs
#   * get_changed_apps
#   * get_changed_builds
#
# The GitLab pipeline relied on CI_* variables such as CI_COMMIT_BEFORE_SHA,
# CI_MERGE_REQUEST_TARGET_BRANCH_NAME and CI_PROJECT_PATH.  On GitHub the
# equivalent data comes from the event payload and the GITHUB_* variables.
#
# This file is meant to be *sourced* by the workflow steps.

set -euo pipefail

# ---------------------------------------------------------------------------
# resolve_refs
#
# Determines TARGET_REF (the base the change is compared against) and
# SOURCE_REF (the change itself), and exports them plus GITHUB_ENV if present.
#
# On GitHub this is simple: for pull_request events we have
# github.event.pull_request.base.sha / github.event.pull_request.head.sha;
# for pushes we have github.event.before / github.sha.
# ---------------------------------------------------------------------------
resolve_refs() {
  local target="${TARGET_REF:-}"
  local source="${SOURCE_REF:-}"

  if [ -z "$target" ] && [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "${GITHUB_EVENT_PATH}" ]; then
    target=$(python3 - <<'PY'
import json, os, sys
try:
    with open(os.environ['GITHUB_EVENT_PATH']) as fp:
        data = json.load(fp)
except Exception:
    sys.exit(0)
pr = data.get('pull_request')
if pr:
    # base.sha is the tip of the target branch at the time the PR was created;
    # the merge-base below makes the diff robust to that.
    print(pr.get('base', {}).get('sha', '') or '')
else:
    print(data.get('before', '') or '')
PY
)
    source=$(python3 - <<'PY'
import json, os
with open(os.environ['GITHUB_EVENT_PATH']) as fp:
    data = json.load(fp)
pr = data.get('pull_request')
if pr:
    print(pr.get('head', {}).get('sha', '') or '')
else:
    print(data.get('after', '') or os.environ.get('GITHUB_SHA', ''))
PY
)
  fi

  # An all-zero "before" sha means a newly created branch; fall back to the
  # first parent if possible, otherwise HEAD~1.
  if [ -z "$target" ] || [ "$target" = "0000000000000000000000000000000000000000" ]; then
    target=$(git rev-parse HEAD~1 2>/dev/null || git rev-list --max-parents=0 HEAD)
  fi
  if [ -z "$source" ]; then
    source=$(git rev-parse HEAD)
  fi

  # Use the merge-base so we compare the PR to where it forked off, exactly
  # like the original `git merge-base HEAD upstream/<branch>` logic.
  if git merge-base "$target" "$source" >/dev/null 2>&1; then
    target=$(git merge-base "$target" "$source")
  fi

  TARGET_REF="$target"
  SOURCE_REF="$source"
  export TARGET_REF SOURCE_REF

  echo "TARGET_REF=$TARGET_REF"
  echo "SOURCE_REF=$SOURCE_REF"

  if [ -n "${GITHUB_ENV:-}" ]; then
    {
      echo "TARGET_REF=$TARGET_REF"
      echo "SOURCE_REF=$SOURCE_REF"
    } >> "$GITHUB_ENV"
  fi
}

# ---------------------------------------------------------------------------
# get_changed_apps
#
# Port of the `.get_changed_apps` anchor: list appids whose metadata or
# signature files changed between TARGET_REF and SOURCE_REF.
# ---------------------------------------------------------------------------
get_changed_apps() {
  resolve_refs
  echo "$TARGET_REF"

  local f appid
  for f in $(git diff --name-only --diff-filter=d "${TARGET_REF}...${SOURCE_REF}" -- 'metadata/*.yml') \
           $(git diff --name-only --diff-filter=d "${TARGET_REF}...${SOURCE_REF}" -- 'metadata/*/signatures'); do
    appid=$(echo "$f" | sed -E -n 's,^metadata/([^/][^/]*)(\.yml|/signatures/.*),\1,p')
    CHANGED="${CHANGED:-} $appid"
  done

  CHANGED="${CHANGED:-}"
  export CHANGED
  echo "CHANGED=$CHANGED"

  if [ -n "${GITHUB_ENV:-}" ]; then
    # multiline-safe
    {
      echo "CHANGED<<__EOF__"
      echo "$CHANGED"
      echo "__EOF__"
    } >> "$GITHUB_ENV"
  fi
}

# ---------------------------------------------------------------------------
# get_changed_builds
#
# Port of the `.get_changed_builds` anchor: like get_changed_apps, but it
# also inspects the diff to decide whether a package needs a build at all
# (skipping diff hunks that only add `disable:` and files that add
# NoSourceSince/Disabled).
# ---------------------------------------------------------------------------
get_changed_builds() {
  resolve_refs
  echo "$TARGET_REF"

  local f diff appid
  for f in $(git diff --name-only --diff-filter=d "${TARGET_REF}...${SOURCE_REF}" -- 'metadata/*.yml') \
           $(git diff --name-only --diff-filter=d "${TARGET_REF}...${SOURCE_REF}" -- 'metadata/*/signatures'); do
    diff=$(git diff "${TARGET_REF}...${SOURCE_REF}" -- "$f")
    echo "$diff"
    # `|| continue` keeps `set -e` from killing the loop when the test is false
    test "$(echo "$diff" | perl -wnle '/^[+-](( +-)|( *\w))/ and print' | grep -v -c '^+ *disable:')" = 0 && continue
    echo "$diff" | grep -E '^\+ *(NoSourceSince|Disabled):' && continue
    appid=$(echo "$f" | sed -E -n 's,^metadata/([^/][^/]*)(\.yml|/signatures/.*),\1,p')
    CHANGED="${CHANGED:-} $appid"
  done

  CHANGED="${CHANGED:-}"
  export CHANGED
  echo "CHANGED=$CHANGED"

  if [ -n "${GITHUB_ENV:-}" ]; then
    {
      echo "CHANGED<<__EOF__"
      echo "$CHANGED"
      echo "__EOF__"
    } >> "$GITHUB_ENV"
  fi
}
