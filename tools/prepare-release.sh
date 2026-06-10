#!/usr/bin/env bash
#
# prepare-release.sh — prepare a new SEAPATH repo-manifest release.
#
# Usage:
#   tools/prepare-release.sh <version>
#
#   <version> must match: ^v[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$
#   Examples: v2.0.0  v2.0.0-rc1
#
# For a stable version (e.g. v2.0.0) the script will:
#   1. download the manifest from releases.seapath.org
#   2. commit the new manifest file (signed-off)
#   3. commit the default.xml symlink switch (signed-off)
#   4. revert the default.xml switch (signed-off)
#   5. print the git tag command to run AFTER the PR is merged on main
#      (the script intentionally does NOT tag, because the merge changes
#      commit SHAs and a tag created on the dev branch would not point to
#      the right commit once the PR is merged)
#
# For an -rc# pre-release (e.g. v2.0.0-rc1) the script will:
#   1. download the manifest from releases.seapath.org
#   2. commit the new manifest file (signed-off)
# and stop there (no default switch, no revert) — matching the
# convention used for v2.0.0-rc1 (commit 8ce9120).
#
# The script aborts (non-zero) on any error and leaves the working tree
# untouched aside from the new commits it creates. Any partial state
# (e.g. a half-downloaded manifest) is cleaned up automatically.
#
# Set MOCK_RELEASES_URL to a directory (ending with /) to use a local file
# instead of hitting the network. Intended for testing only.
#

set -euo pipefail

VERSION="${1:-}"

usage() {
    cat <<'USAGE'
Usage: tools/prepare-release.sh <version>

  <version> must match: vX.Y.Z or vX.Y.Z-rc#
  Examples: v2.0.0  v2.0.0-rc1

For a stable version (e.g. v2.0.0) the script will:
  1. download the manifest from releases.seapath.org
  2. commit the new manifest file (signed-off)
  3. commit the default.xml symlink switch (signed-off)
  4. revert the default.xml switch (signed-off)
  5. print the git tag command to run AFTER the PR is merged on main

For an -rc# pre-release (e.g. v2.0.0-rc1) the script will:
  1. download the manifest from releases.seapath.org
  2. commit the new manifest file (signed-off)
and stop there (no default switch, no revert).

The script never creates the git tag itself: the release is shipped
through a PR, and the PR merge rewrites commit SHAs.
USAGE
}

die() {
    echo "error: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

if [[ -z "$VERSION" ]]; then
    usage
    exit 1
fi

if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]]; then
    die "version '$VERSION' does not match vX.Y.Z or vX.Y.Z-rc#"
fi

is_rc=0
if [[ "$VERSION" == *-rc* ]]; then
    is_rc=1
fi

# --- preflight ---------------------------------------------------------------

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not inside a git working tree"

if ! git diff --quiet --ignore-submodules HEAD 2>/dev/null; then
    die "working tree has uncommitted changes; please commit or stash them first"
fi
if [[ -n "$(git status --porcelain)" ]]; then
    die "working tree has untracked or modified files; please clean up first"
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "$branch" != "HEAD" ]] || die "detached HEAD; please checkout a branch first"

if [[ -f "$VERSION.xml" ]]; then
    die "file '$VERSION.xml' already exists in the working tree"
fi

if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
    die "tag '$VERSION' already exists"
fi

# --- download ----------------------------------------------------------------

if [[ -n "${MOCK_RELEASES_URL:-}" ]]; then
    src="${MOCK_RELEASES_URL}${VERSION}.xml"
    info "MOCK_RELEASES_URL set: copying $src"
    cp "$src" "$VERSION.xml"
else
    url="https://releases.seapath.org/builds/${VERSION}/${VERSION}.xml"
    info "downloading $url"
    if ! curl -fSL --retry 3 --retry-delay 2 -o "$VERSION.xml" "$url"; then
        die "failed to download $url"
    fi
fi

# From here on, any abort removes the downloaded manifest so the working
# tree is left untouched. The msgfile trap installed later in the script
# is preserved because EXIT fires after ERR and re-uses the same handler.
trap 'rm -f "$VERSION.xml"' ERR
[[ -s "$VERSION.xml" ]] || die "downloaded manifest is empty"

# --- commit 1: add the manifest file ----------------------------------------

if (( is_rc )); then
    release_kind="pre-release"
    subject="$VERSION: release repo manifest for pre-release $VERSION"
else
    release_kind="release"
    subject="$VERSION: release repo manifest for release $VERSION"
fi

body="This commit adds the manifest file for the $VERSION $release_kind of the
SEAPATH project. All the git references are fixed to a specific commit
to ensure reproducibility of the build."

git add "$VERSION.xml"

msgfile="$(mktemp)"
trap 'rm -f "$msgfile"' EXIT
{
    printf '%s\n\n%s\n' "$subject" "$body"
} > "$msgfile"

info "creating manifest commit"
git commit -s -F "$msgfile"

if (( is_rc )); then
    # For pre-releases the only commit created is the manifest commit;
    # HEAD is the commit to tag once the PR is merged on main.
    cat <<EOF

============================================================
Pre-release $VERSION manifest prepared on branch '$branch'.

  * manifest commit  : $(git rev-parse --short HEAD)  (tag this commit after the PR is merged on main)

Next steps:
  1. Push the branch and open a PR.
  2. Once the PR is merged on the main branch, create the tag there by running:

       git checkout main && git pull
       git tag -a $VERSION -m "version $VERSION" HEAD
       git push origin $VERSION

  (The script intentionally does NOT create the tag itself: the PR merge
  rewrites commit SHAs, so a tag created on the dev branch would not point
  to the right commit once merged on main.)
============================================================
EOF
    exit 0
fi

# --- commit 2: switch default.xml -------------------------------------------

info "switching default.xml -> $VERSION.xml"
ln -sfn "$VERSION.xml" default.xml.tmp
mv -f default.xml.tmp default.xml
git add default.xml
git commit -s -m "default: change to $VERSION manifest"

# --- revert the default switch ----------------------------------------------

info "reverting the default.xml switch"
git revert -s --no-edit HEAD

# --- summary ----------------------------------------------------------------

# For stable releases HEAD^ is the "default: change to X.Y.Z manifest"
# commit, i.e. the one to tag once the PR is merged on main.
cat <<EOF

============================================================
Release $VERSION prepared on branch '$branch'.

  * manifest commit  : $(git rev-parse --short 'HEAD~2')
  * default switch   : $(git rev-parse --short 'HEAD^')  (tag this commit after the PR is merged on main)
  * revert of switch : $(git rev-parse --short HEAD)

  default.xml now points to: $(git show HEAD:default.xml)

Next steps:
  1. Push the branch and open a PR.
  2. Once the PR is merged on the main branch, create the tag there by running:

       git checkout main && git pull
       git tag -a $VERSION -m "version $VERSION" HEAD^
       git push origin $VERSION

  (The script intentionally does NOT create the tag itself: the PR merge
  rewrites commit SHAs, so a tag created on the dev branch would not point
  to the right commit once merged on main.)
============================================================
EOF
