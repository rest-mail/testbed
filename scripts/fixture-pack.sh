#!/usr/bin/env bash
# Pack the restmail.test fixture template as a versioned release asset.
#
#   scripts/fixture-pack.sh <version> [<ref>] [<out-dir>]
#
# Writes <out-dir>/restmail-fixture-<version>.tar.gz and a sha256sum-format
# checksum next to it. Contents come from <ref>'s committed tree (default
# HEAD), never the working tree, so a dirty, untracked or gitignored file
# (secrets.env, dns.env, dkim.conf, ca.crt) cannot reach the archive. Only
# the allowlisted files below are packed; everything else under configs/ is
# left out by construction.
#
# The same ref always produces the same bytes: entries are sorted, owned by
# 0:0, mode 0644 (files) / 0755 (dir), and stamped with the commit's time;
# gzip drops its own name and timestamp. Needs GNU tar.
set -euo pipefail

# The fixture template: the only files a release ships. Paths in the repo;
# the archive holds them flat under restmail-fixture-<version>/.
ALLOWLIST=(
  configs/restmail/config.env
  configs/restmail/manifest.yml
)

die() { echo "fixture-pack: $*" >&2; exit 1; }

if [ $# -lt 1 ] || [ $# -gt 3 ]; then
  die "usage: $0 <version> [<ref>] [<out-dir>]"
fi
version=$1
ref=${2-HEAD}
out=${3:-dist}

# Bare SemVer (no leading v): it lands in a file name and a release asset.
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$'
[[ $version =~ $semver ]] || die "version '$version' is not SemVer X.Y.Z[-pre] (no leading v)"
[[ -n $ref && $ref != -* ]] || die "ref '$ref' is not a git ref"

repo=$(git rev-parse --show-toplevel)
commit=$(git -C "$repo" rev-parse --verify --quiet --end-of-options "$ref^{commit}") \
  || die "ref '$ref' does not name a commit"
mtime=$(git -C "$repo" show -s --format=%ct "$commit")

name=restmail-fixture-$version
stage=$(mktemp -d)
tmp=
trap 'rm -rf "$stage" ${tmp:+"$tmp"}' EXIT
mkdir "$stage/$name"

for path in "${ALLOWLIST[@]}"; do
  # Only plain committed blobs: a symlink (120000), an executable, a
  # directory or a missing path fails.
  mode=$(git -C "$repo" ls-tree --format='%(objectmode)' "$commit" -- "$path")
  [ "$mode" = 100644 ] \
    || die "$path at $commit is not a regular tracked file (mode '${mode:-missing}')"
  git -C "$repo" cat-file blob "$commit:$path" > "$stage/$name/$(basename "$path")"
done

mkdir -p -- "$out"
archive=$out/$name.tar.gz
tmp=$(mktemp "$out/.$name.XXXXXX")
LC_ALL=C tar --create --format=ustar --sort=name \
  --mtime="@$mtime" --owner=0 --group=0 --numeric-owner \
  --mode='u=rwX,go=rX,a-s' -C "$stage" "$name" \
  | gzip -9 -n > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$archive"
(cd "$out" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")

echo "$archive ($commit)"
