#!/usr/bin/env bash
set -euo pipefail

fork_url="https://github.com/soyeht/iSoyehtTerm.git"
fork_base="31553fe7fc192835ebb13c12d31f6b4c4d565dd6"
fork_tag="vendor-anchor-2026-07-23"
fork_tag_object="89cf98f003561e808c660f241d0f09a3a2257c51"
fork_head="a6351d8aee88a87f7e87ed276a6369c0d2211064"
fork_vendor_tree="c351e4e1a84eedfe21967841da0241b60ae4d630"
mirror_commit="4c3a1028921576fad7893a67778a02a0368fedf9"
vendor_commit="b37b9f41137a0e739b9a3aa22dd51d0378910b2e"
vendor_tree="73b054b10ff993def820a885da791d12a8892265"
vendor_delta_patch_id="73f4730033a1bc19b41ed92040aa10302cbafcbb"

repo_root="$(git rev-parse --show-toplevel)"
fork_table="$repo_root/docs/vendor/swiftterm-fork-series.tsv"
delta_table="$repo_root/docs/vendor/swiftterm-vendored-delta.tsv"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/swiftterm-provenance.XXXXXX")"
trap 'rm -rf -- "$tmpdir"' EXIT

fail() {
  echo "swiftterm vendor provenance: $*" >&2
  exit 1
}

patch_id_full() {
  local repository="$1"
  local commit="$2"
  git -C "$repository" show --full-index --no-ext-diff --pretty=format: "$commit" |
    git patch-id --stable |
    awk 'NR == 1 { print $1 }'
}

patch_id_path() {
  local repository="$1"
  local commit="$2"
  git -C "$repository" show --full-index --no-ext-diff --pretty=format: \
    "$commit" -- Sources/SwiftTerm |
    git patch-id --stable |
    awk 'NR == 1 { print $1 }'
}

for command in git awk cmp cut grep tail tr wc; do
  command -v "$command" >/dev/null || fail "missing required command: $command"
done

test -f "$fork_table" || fail "missing $fork_table"
test -f "$delta_table" || fail "missing $delta_table"

git cat-file -e "$mirror_commit^{commit}" 2>/dev/null ||
  fail "mirror commit is unavailable; use a full clone"
git cat-file -e "$vendor_commit^{commit}" 2>/dev/null ||
  fail "vendor snapshot is unavailable; use a full clone"

current_tree="$(git rev-parse HEAD:Sources/SwiftTerm)"
test "$current_tree" = "$vendor_tree" ||
  fail "HEAD Sources/SwiftTerm tree $current_tree differs from audited $vendor_tree"

git clone --quiet --no-checkout "$fork_url" "$tmpdir/fork"
fork_dir="$tmpdir/fork"

actual_tag_object="$(git -C "$fork_dir" rev-parse "refs/tags/$fork_tag")"
test "$actual_tag_object" = "$fork_tag_object" ||
  fail "tag object $actual_tag_object differs from $fork_tag_object"
test "$(git -C "$fork_dir" cat-file -t "refs/tags/$fork_tag")" = "tag" ||
  fail "$fork_tag is not annotated"
actual_fork_head="$(git -C "$fork_dir" rev-parse "refs/tags/$fork_tag^{}")"
test "$actual_fork_head" = "$fork_head" ||
  fail "tag target $actual_fork_head differs from $fork_head"
git -C "$fork_dir" merge-base --is-ancestor "$fork_base" "$fork_head" ||
  fail "fork base is not an ancestor of the anchor"
git -C "$fork_dir" checkout --quiet --detach "$fork_head"

git -C "$fork_dir" rev-list --reverse "$fork_base..$fork_head" \
  >"$tmpdir/expected-fork-commits"
tail -n +2 "$fork_table" | cut -f2 >"$tmpdir/recorded-fork-commits"
cmp -s "$tmpdir/expected-fork-commits" "$tmpdir/recorded-fork-commits" ||
  fail "fork commit inventory is incomplete or out of order"
test "$(wc -l <"$tmpdir/expected-fork-commits" | tr -d ' ')" = "31" ||
  fail "fork sequence is not exactly 31 commits"

while IFS=$'\t' read -r ordinal commit full_patch touches_vendor path_patch mirror subject; do
  test "$ordinal" != "ordinal" || continue
  test "$(patch_id_full "$fork_dir" "$commit")" = "$full_patch" ||
    fail "full patch-id mismatch for fork commit $commit"
  actual_subject="$(git -C "$fork_dir" show -s --format=%s "$commit")"
  test "$actual_subject" = "$subject" ||
    fail "subject mismatch for fork commit $commit"

  if git -C "$fork_dir" diff-tree --no-commit-id --name-only -r "$commit" \
    -- Sources/SwiftTerm | grep -q .; then
    test "$touches_vendor" = "yes" ||
      fail "$commit touches Sources/SwiftTerm but is marked $touches_vendor"
    test "$(patch_id_path "$fork_dir" "$commit")" = "$path_patch" ||
      fail "path patch-id mismatch for fork commit $commit"
    test "$mirror" != "-" ||
      fail "missing mirror commit for fork commit $commit"
    git cat-file -e "$mirror^{commit}" 2>/dev/null ||
      fail "mirror commit $mirror is unavailable"
    test "$(patch_id_path "$repo_root" "$mirror")" = "$path_patch" ||
      fail "mirror patch-id mismatch for $mirror"
  else
    test "$touches_vendor" = "no" ||
      fail "$commit is marked as a vendor change but does not touch the subtree"
    test "$path_patch" = "-" && test "$mirror" = "-" ||
      fail "$commit has unexpected vendor metadata"
  fi
done <"$fork_table"

actual_fork_tree="$(git -C "$fork_dir" rev-parse "$fork_head:Sources/SwiftTerm")"
test "$actual_fork_tree" = "$fork_vendor_tree" ||
  fail "fork vendor tree $actual_fork_tree differs from $fork_vendor_tree"
actual_mirror_tree="$(git rev-parse "$mirror_commit:Sources/SwiftTerm")"
test "$actual_mirror_tree" = "$fork_vendor_tree" ||
  fail "mirror tree $actual_mirror_tree differs from fork tree $fork_vendor_tree"

git rev-list --reverse "$mirror_commit..$vendor_commit" -- Sources/SwiftTerm \
  >"$tmpdir/expected-delta-commits"
tail -n +2 "$delta_table" | cut -f2 >"$tmpdir/recorded-delta-commits"
cmp -s "$tmpdir/expected-delta-commits" "$tmpdir/recorded-delta-commits" ||
  fail "vendored delta inventory is incomplete or out of order"
test "$(wc -l <"$tmpdir/expected-delta-commits" | tr -d ' ')" = "13" ||
  fail "vendored delta is not exactly 13 commits"

while IFS=$'\t' read -r ordinal commit path_patch subject; do
  test "$ordinal" != "ordinal" || continue
  test "$(patch_id_path "$repo_root" "$commit")" = "$path_patch" ||
    fail "vendored patch-id mismatch for commit $commit"
  actual_subject="$(git show -s --format=%s "$commit")"
  test "$actual_subject" = "$subject" ||
    fail "subject mismatch for vendored commit $commit"
done <"$delta_table"

actual_vendor_tree="$(git rev-parse "$vendor_commit:Sources/SwiftTerm")"
test "$actual_vendor_tree" = "$vendor_tree" ||
  fail "vendor tree $actual_vendor_tree differs from $vendor_tree"
actual_delta_patch_id="$(
  git diff --no-ext-diff --binary \
    --full-index \
    "$mirror_commit:Sources/SwiftTerm" \
    "$vendor_commit:Sources/SwiftTerm" |
    git patch-id --stable |
    awk 'NR == 1 { print $1 }'
)"
test "$actual_delta_patch_id" = "$vendor_delta_patch_id" ||
  fail "aggregate delta patch-id $actual_delta_patch_id differs from $vendor_delta_patch_id"

echo "SwiftTerm vendor provenance verified."
echo "fork_tag_object=$fork_tag_object"
echo "fork_head=$fork_head"
echo "fork_vendor_tree=$fork_vendor_tree"
echo "vendor_commit=$vendor_commit"
echo "vendor_tree=$vendor_tree"
echo "fork_commits=31"
echo "vendored_delta_commits=13"
