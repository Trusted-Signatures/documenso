#!/usr/bin/env bash

set -euo pipefail

PATCH_FILE="patches/add-trusted-signatures-signing-support.patch"
SUFFIX="-ts.1"
REMOTE="origin"
DRY_RUN=0
PUSH=0
FETCH=1
ALLOW_DIRTY=0

usage() {
  cat <<'EOF'
Usage: scripts/repair-ts-release-tags.sh [options]

Scans Trusted Signatures release tags (default: *-ts.1), checks whether the
matching release branch contains the patch, applies it when missing, and
updates/creates the ts tag to point at the branch HEAD.

Options:
  --patch <path>      Patch file path (default: patches/add-trusted-signatures-signing-support.patch)
  --suffix <suffix>   TS tag suffix (default: -ts.1)
  --remote <name>     Git remote for fetch/push/branch tracking (default: origin)
  --push              Push repaired branches and tags to remote
  --dry-run           Show what would change without modifying refs
  --no-fetch          Skip fetch of remote branches/tags
  --allow-dirty       Allow running with local working-tree changes
  --help              Show this help

Examples:
  scripts/repair-ts-release-tags.sh --dry-run
  scripts/repair-ts-release-tags.sh --push
  scripts/repair-ts-release-tags.sh --patch patches/add-trusted-signatures-signing-support.patch --push
EOF
}

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

run_cmd() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi

  "$@"
}

apply_patch_commit() {
  local patch="$1"

  if head -n 1 "$patch" | grep -qE '^From [0-9a-f]{40} '; then
    git am -3 --keep-cr "$patch"
    return 0
  fi

  git apply --3way --index "$patch"
  git commit -m "Add Trusted Signatures support

Applied from patch: $(basename "$patch")"
}

patch_present_on_head() {
  local patch="$1"
  git apply --reverse --check "$patch" >/dev/null 2>&1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --patch)
      [ "$#" -ge 2 ] || die "--patch requires a value"
      PATCH_FILE="$2"
      shift 2
      ;;
    --suffix)
      [ "$#" -ge 2 ] || die "--suffix requires a value"
      SUFFIX="$2"
      shift 2
      ;;
    --remote)
      [ "$#" -ge 2 ] || die "--remote requires a value"
      REMOTE="$2"
      shift 2
      ;;
    --push)
      PUSH=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-fetch)
      FETCH=0
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

git rev-parse --git-dir >/dev/null 2>&1 || die "Must run inside a git repository"
[ -f "$PATCH_FILE" ] || die "Patch file not found: $PATCH_FILE"

if [ "$ALLOW_DIRTY" -ne 1 ] && [ -n "$(git status --porcelain)" ]; then
  die "Working tree is not clean. Commit/stash changes before running."
fi

START_REF="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD)"
trap 'git switch -q "$START_REF" >/dev/null 2>&1 || true' EXIT

if [ "$FETCH" -eq 1 ]; then
  log "Fetching tags and branches from $REMOTE..."
  git fetch "$REMOTE" --tags --prune
  git fetch "$REMOTE" --prune
fi

mapfile -t TS_TAGS < <(git tag -l "*${SUFFIX}" | sort -V)
if [ "${#TS_TAGS[@]}" -eq 0 ]; then
  die "No tags found matching *${SUFFIX}"
fi

checked_count=0
patched_count=0
retagged_count=0
skipped_count=0
failed_count=0

for ts_tag in "${TS_TAGS[@]}"; do
  checked_count=$((checked_count + 1))
  base_tag="${ts_tag%"$SUFFIX"}"
  if [ -z "$base_tag" ] || [ "$base_tag" = "$ts_tag" ]; then
    log "Skipping malformed tag: $ts_tag"
    skipped_count=$((skipped_count + 1))
    continue
  fi

  branch="release/${base_tag}-ts"
  log ""
  log "==> Processing ${ts_tag} (base: ${base_tag}, branch: ${branch})"

  if git show-ref --verify --quiet "refs/heads/${branch}"; then
    run_cmd git switch -q "$branch"
  elif git show-ref --verify --quiet "refs/remotes/${REMOTE}/${branch}"; then
    run_cmd git switch -q -c "$branch" --track "${REMOTE}/${branch}"
  elif git rev-parse -q --verify "refs/tags/${base_tag}" >/dev/null; then
    run_cmd git switch -q -c "$branch" "$base_tag"
  else
    log "  ! Missing both branch and base tag, skipping."
    skipped_count=$((skipped_count + 1))
    continue
  fi

  had_patch=0
  if patch_present_on_head "$PATCH_FILE"; then
    had_patch=1
    log "  Patch already present on ${branch}."
  else
    log "  Patch missing on ${branch}; applying."
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '[dry-run] apply patch %s on %s\n' "$PATCH_FILE" "$branch"
      patched_count=$((patched_count + 1))
    else
      if apply_patch_commit "$PATCH_FILE"; then
        patched_count=$((patched_count + 1))
      else
        log "  ! Patch apply failed on ${branch}. Leaving for manual resolution."
        failed_count=$((failed_count + 1))
        continue
      fi
    fi
  fi

  head_sha="$(git rev-parse HEAD)"
  tag_sha="$(git rev-list -n 1 "$ts_tag")"
  if [ "$tag_sha" != "$head_sha" ] || [ "$had_patch" -eq 0 ]; then
    log "  Updating tag ${ts_tag} -> ${head_sha}"
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '[dry-run] git tag -f %s %s\n' "$ts_tag" "$head_sha"
    else
      git tag -f "$ts_tag" "$head_sha"
    fi
    retagged_count=$((retagged_count + 1))
  else
    log "  Tag ${ts_tag} already points at branch HEAD."
  fi

  if [ "$PUSH" -eq 1 ]; then
    log "  Pushing ${branch} and ${ts_tag} to ${REMOTE}."
    run_cmd git push "$REMOTE" "${branch}:${branch}"
    run_cmd git push "$REMOTE" "refs/tags/${ts_tag}" --force
  fi
done

log ""
log "Repair complete."
log "Checked:  ${checked_count}"
log "Patched:  ${patched_count}"
log "Retagged: ${retagged_count}"
log "Skipped:  ${skipped_count}"
log "Failed:   ${failed_count}"
