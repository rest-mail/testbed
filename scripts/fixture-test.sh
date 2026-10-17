#!/usr/bin/env bash
# Tests for scripts/fixture-pack.sh and the consumer steps in the README.
#
#   scripts/fixture-test.sh
#
# Runs in a scratch directory and a scratch clone; the repo's own working
# tree is only read. No Docker, no network. Needs a full clone (CI checks
# out with fetch-depth: 0).
#
# pass/fail always succeed, so `cond && pass .. || fail ..` is an if/else.
# shellcheck disable=SC2015
set -euo pipefail

repo=$(git rev-parse --show-toplevel)
pack=$repo/scripts/fixture-pack.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; fails=$((fails + 1)); }

V=0.0.0-test
name=restmail-fixture-$V
commit=$(git -C "$repo" rev-parse HEAD)

# The README's consumer steps, made checkable: verify the checksum, refuse
# anything but the one directory and two regular files, then extract into a
# directory the consumer owns. Non-zero when the archive is not acceptable.
consumer_install() { # <dir with archive + .sha256> <dest>
  local dir=$1 dest=$2 types
  (cd "$dir" && sha256sum --quiet -c "$name.tar.gz.sha256" >/dev/null 2>&1) || return 1
  [ "$(tar -tzf "$dir/$name.tar.gz")" = "$name/
$name/config.env
$name/manifest.yml" ] || return 1
  types=$(tar -tvzf "$dir/$name.tar.gz" | cut -c1 | LC_ALL=C sort -u | tr -d '\n')
  [ "$types" = "-d" ] || return 1
  mkdir -p "$dest"
  tar -xzf "$dir/$name.tar.gz" -C "$dest" --strip-components=1 \
    --no-same-owner --no-same-permissions
}

# ── reproducible bytes from the same ref ────────────────────────────────
(umask 022; TZ=UTC "$pack" "$V" HEAD "$work/a" >/dev/null)
(umask 077; TZ=Pacific/Kiritimati LC_ALL=C "$pack" "$V" "$commit" "$work/b" >/dev/null)
if cmp -s "$work/a/$name.tar.gz" "$work/b/$name.tar.gz" \
  && cmp -s "$work/a/$name.tar.gz.sha256" "$work/b/$name.tar.gz.sha256"; then
  pass "same ref, different umask/TZ: identical archive and checksum"
else
  fail "same ref produced different bytes"
fi
(cd "$work/a" && sha256sum --quiet -c "$name.tar.gz.sha256") \
  && pass "checksum file verifies with sha256sum -c" \
  || fail "checksum file does not verify"

# ── only the allowlisted template inputs ────────────────────────────────
listing=$(tar --numeric-owner -tvzf "$work/a/$name.tar.gz" | awk '{print $1, $2, $6}')
expected="drwxr-xr-x 0/0 $name/
-rw-r--r-- 0/0 $name/config.env
-rw-r--r-- 0/0 $name/manifest.yml"
[ "$listing" = "$expected" ] \
  && pass "archive holds exactly manifest.yml + config.env, 0/0, 0644/0755" \
  || fail "unexpected archive entries:"$'\n'"$listing"
for f in config.env manifest.yml; do
  if tar -xOzf "$work/a/$name.tar.gz" "$name/$f" \
    | cmp -s - <(git -C "$repo" cat-file blob "$commit:configs/restmail/$f"); then
    pass "$f is the committed content"
  else
    fail "$f differs from the committed content"
  fi
done

# ── planted secrets and working-tree state never enter the archive ──────
src=$work/src
git clone -q --no-hardlinks "$repo" "$src"
git -C "$src" checkout -q --detach "$commit"
secret=planted-secret-$RANDOM$RANDOM
for f in secrets.env dns.env dkim.conf ca.key; do
  echo "LEAK=$secret" > "$src/configs/restmail/$f"
done
echo "# $secret" >> "$src/configs/restmail/manifest.yml"   # dirty tracked file
echo "leak: $secret" > "$src/configs/restmail/extra.yml"    # untracked file
git -C "$src" add -f configs/restmail/secrets.env           # staged, not committed
(cd "$src" && "$pack" "$V" HEAD "$work/c" >/dev/null)
if cmp -s "$work/a/$name.tar.gz" "$work/c/$name.tar.gz" \
  && ! gzip -dc "$work/c/$name.tar.gz" | grep -q "$secret"; then
  pass "dirty/untracked/staged secrets: archive unchanged, secret absent"
else
  fail "working-tree state leaked into the archive"
fi
git -C "$src" -c user.name=t -c user.email=t@t commit -q -m planted
(cd "$src" && "$pack" "$V" HEAD "$work/d" >/dev/null)
if ! gzip -dc "$work/d/$name.tar.gz" | grep -q "$secret" \
  && [ "$(tar -tzf "$work/d/$name.tar.gz" | wc -l)" -eq 3 ]; then
  pass "a committed secrets.env is still left out (allowlist, not a glob)"
else
  fail "committed secrets.env reached the archive"
fi
ln -sf manifest.yml "$src/configs/restmail/config.env"
git -C "$src" -c user.name=t -c user.email=t@t commit -q -am symlink
(cd "$src" && "$pack" "$V" HEAD "$work/e" >/dev/null 2>&1) \
  && fail "a symlinked template file was packed" \
  || pass "a symlinked template file in the ref is refused"
git -C "$src" reset -q --hard "$commit"
git -C "$src" clean -qfdx

# ── the consumer owns its copy ──────────────────────────────────────────
dest=$work/consumer/instances/restmail.test
if consumer_install "$work/a" "$dest"; then
  pass "consumer steps verify and extract the archive"
else
  fail "consumer steps rejected a good archive"
fi
owned=1
for f in config.env manifest.yml; do
  [ -f "$dest/$f" ] && [ ! -L "$dest/$f" ] || owned=0
  [ "$(stat -c '%h %u' "$dest/$f")" = "1 $(id -u)" ] || owned=0
  [ "$(stat -c %i "$dest/$f")" != "$(stat -c %i "$src/configs/restmail/$f")" ] || owned=0
done
[ -z "$(find "$work/consumer" -type l)" ] || owned=0
[ "$owned" = 1 ] \
  && pass "extracted files are regular, unlinked, owned by the consumer" \
  || fail "extracted files are links or not owned by the consumer"
before=$(git -C "$src" hash-object configs/restmail/manifest.yml)
echo "image_tag: 9.9.9   # consumer edit" >> "$dest/manifest.yml"
if [ "$(git -C "$src" hash-object configs/restmail/manifest.yml)" = "$before" ] \
  && [ -z "$(git -C "$src" status --porcelain)" ]; then
  pass "editing the consumer copy leaves the source untouched"
else
  fail "editing the consumer copy changed the source"
fi
rm -rf "$src"
if grep -q '^domain: *restmail.test' "$dest/manifest.yml" \
  && grep -q '9.9.9' "$dest/manifest.yml" \
  && cmp -s "$dest/config.env" <(git -C "$repo" cat-file blob "$commit:configs/restmail/config.env"); then
  pass "consumer copy still complete with the source clone deleted"
else
  fail "consumer copy depends on the source clone"
fi

# ── the consumer steps refuse a tampered or hostile archive ─────────────
evil=$work/evil
mkdir -p "$evil/build/$name"
cp "$work/a/$name.tar.gz" "$evil/"
printf 'x' >> "$evil/$name.tar.gz"
cp "$work/a/$name.tar.gz.sha256" "$evil/"
consumer_install "$evil" "$work/evil-dest" 2>/dev/null \
  && fail "tampered archive accepted" \
  || pass "tampered archive fails the checksum"
cp "$repo/configs/restmail/config.env" "$evil/build/$name/config.env"
ln -s /etc/passwd "$evil/build/$name/manifest.yml"
tar --sort=name -czf "$evil/$name.tar.gz" -C "$evil/build" "$name"
(cd "$evil" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
consumer_install "$evil" "$work/evil-dest" 2>/dev/null \
  && fail "archive with a symlink accepted" \
  || pass "archive with a symlink is refused before extraction"
[ ! -e "$work/evil-dest" ] \
  && pass "nothing extracted from a refused archive" \
  || fail "refused archive was partly extracted"

# ── invalid version or ref fails, and writes nothing ────────────────────
for v in "" 1.2 v1.2.3 01.2.3 1.2.3.4 latest ../1.2.3 1.2.3/x '1.2.3;id' -1.2.3 "1.2.3 "; do
  if "$pack" "$v" HEAD "$work/bad" >/dev/null 2>&1; then
    fail "version '$v' accepted"
  else
    pass "version '$v' rejected"
  fi
done
for r in "" no-such-ref --output=/tmp/x "HEAD:configs" "$(printf '%040d' 0)"; do
  if "$pack" 1.2.3 "$r" "$work/bad" >/dev/null 2>&1; then
    fail "ref '$r' accepted"
  else
    pass "ref '$r' rejected"
  fi
done
[ -z "$(ls -A "$work/bad" 2>/dev/null)" ] \
  && pass "rejected runs wrote no files" \
  || fail "rejected runs left files: $(ls -A "$work/bad")"

if [ "$fails" -ne 0 ]; then
  echo "$fails fixture test(s) failed" >&2
  exit 1
fi
echo "all fixture tests passed"
