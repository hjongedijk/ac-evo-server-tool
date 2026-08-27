#!/usr/bin/env bash
# release.sh — bump the tooling version, sanity-check, commit, tag, push.
# Usage: ./release.sh [v1.0.1|next] ["optional commit message"]
#
# Unlike some other projects' release scripts, this one does NOT call
# `gh release create` itself — .github/workflows/release.yml already does
# that automatically (plus builds and pushes the Docker image to GHCR)
# whenever a "v*" tag is pushed. This script's job is just: bump,
# lint, commit, tag, push - then GitHub Actions takes it from there.
#
# "next" (default) auto-computes the next version from the latest
# "v*" git tag, rolling PATCH over into MINOR at 99:
# v1.0.99 -> v1.1.00 -> ... indefinitely. Pass an explicit
# version to override this (e.g. for a MAJOR bump or an -rc suffix). You can
# pass it with or without the "v" prefix - it's added automatically
# if missing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

PREFIX="v"
RAW_VERSION="${1:-next}"
COMMIT_MESSAGE="${2:-}"

# ── Resolve version ───────────────────────────────────────────────────────────

next_version() {
  local latest
  latest="$(git tag --list "${PREFIX}[0-9]*.[0-9]*.[0-9]*" | sort -V | tail -1)"
  if [[ -z "$latest" ]]; then
    echo "${PREFIX}0.0.1"
    return
  fi
  local ver="${latest#"$PREFIX"}"
  local major="${ver%%.*}"
  local rest="${ver#*.}"
  local minor="${rest%%.*}"
  local patch="${rest#*.}"
  patch="${patch%%[.-]*}" # drop any -rc1/.1 style suffix on the patch segment
  # 10# forces base-10 parsing -- without it, a zero-padded segment like "09"
  # is parsed as (invalid) octal and errors out.
  major=$((10#$major))
  minor=$((10#$minor))
  patch=$((10#$patch))
  if (( patch >= 99 )); then
    minor=$((minor + 1))
    patch=0
  else
    patch=$((patch + 1))
  fi
  printf "%s%d.%d.%02d\n" "$PREFIX" "$major" "$minor" "$patch"
}

if [[ "$RAW_VERSION" == "next" ]]; then
  git fetch origin --tags >/dev/null 2>&1 || true
  VERSION="$(next_version)"
  echo "==> Auto-computed next version: $VERSION"
else
  VERSION="$RAW_VERSION"
  # Accept "1.0.1" or "v1.0.1" - normalize to the latter.
  if [[ "$VERSION" != "${PREFIX}"* ]]; then
    VERSION="${PREFIX}${VERSION#v}"
  fi
fi

# ── Validation ────────────────────────────────────────────────────────────────

if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]]; then
  echo "Version must look like v1.0.1 or v1.0.1-rc1"
  exit 1
fi

if [[ ! -d "$REPO_ROOT/.git" ]]; then
  echo "Not a git repository: $REPO_ROOT"
  exit 1
fi

IMAGE_VERSION="${VERSION#"$PREFIX"}"   # the clean tag actually published as the image, e.g. "1.0.1"
DEFAULT_COMMIT_MESSAGE="Release tooling v${IMAGE_VERSION}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-$DEFAULT_COMMIT_MESSAGE}"

# ── Update version file ────────────────────────────────────────────────────────

echo "==> Updating TOOLING_VERSION to $IMAGE_VERSION"
echo "$IMAGE_VERSION" > "$REPO_ROOT/TOOLING_VERSION"

# ── Sanity checks: same checks CI runs, so failures surface before pushing ────

echo "==> Running local sanity checks (mirrors the CI lint job)"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck ./*.sh bin/*.sh
else
  echo "  shellcheck not installed locally - skipping (CI will still catch issues)"
fi

if command -v hadolint >/dev/null 2>&1; then
  hadolint --ignore DL3008 --ignore DL3009 --ignore DL3002 --ignore DL3066 bin/Dockerfile
else
  echo "  hadolint not installed locally - skipping (CI will still catch issues)"
fi

echo "==> Validating compose files"
ACEVO_VERSION=v0.0.0-lint IMAGE_TAG=latest docker compose -f docker-compose.yml config -q
ACEVO_VERSION=v0.0.0-lint docker compose -f docker-compose.dev.yml config -q

# ── Git: commit, tag, push ─────────────────────────────────────────────────────

echo "==> Checking git state"
git fetch origin main --tags

if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "Local tag already exists: $VERSION"
  exit 1
fi

if git ls-remote --tags origin "refs/tags/$VERSION" | grep -q "$VERSION"; then
  echo "Remote tag already exists: $VERSION"
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "==> Committing version bump"
  git add -A
  git commit -m "$COMMIT_MESSAGE"
else
  echo "No uncommitted changes - skipping commit"
fi

echo "==> Rebasing and pushing to main"
git pull --rebase origin main
git push origin main

echo "==> Creating and pushing tag $VERSION"
git tag -a "$VERSION" -m "Tooling v${IMAGE_VERSION}"
git push origin "$VERSION"

echo
echo "Done. Pushed $VERSION."
echo "GitHub Actions will now lint, build+push the image to:"
echo "  ghcr.io/<owner>/<repo>:${IMAGE_VERSION}"
echo "and create a GitHub Release with the tooling zip attached."
echo "Check progress under the repo's Actions tab (or 'gh run watch' if the gh CLI is installed)."
