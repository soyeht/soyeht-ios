#!/usr/bin/env bash
# Battery for the release workflow's signing preflight.
#
# The body under test is EXTRACTED from macos-release.yml rather than copied
# here, so this cannot drift from what ships. A test that reimplements the
# thing it tests cannot catch the thing it tests.
#
# `security` is stubbed. The runner's /bin/bash is 3.2, so this runs under
# /bin/bash deliberately: a body that needs bash 4 must fail here, not in a
# release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="${ROOT}/.github/workflows/macos-release.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Extract the run body of the named step, stripping the 10-space block indent.
awk '
  /^      - name: Verify signing identity matches release metadata$/ {instep=1}
  instep && /^        run: \|$/ {inrun=1; next}
  inrun && /^      - name: / {exit}
  inrun {sub(/^          /, ""); print}
' "${WORKFLOW}" > "${TMP}/body.sh"

if [[ ! -s "${TMP}/body.sh" ]]; then
  echo "error: could not extract the preflight body from the workflow." >&2
  exit 1
fi
if ! grep -q 'find-identity' "${TMP}/body.sh"; then
  echo "error: extracted body does not invoke find-identity; the extractor is wrong, not the body." >&2
  exit 1
fi

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/security" <<'STUB'
#!/bin/sh
cat "${STUB_ROSTER}"
STUB
chmod 755 "${TMP}/bin/security"

pass=0; fail=0
run_case() { # name expected_rc roster identity team [expect_substring]
  local name="$1" want="$2" roster="$3" ident="$4" team="$5" needle="${6:-}"
  printf '%s' "${roster}" > "${TMP}/roster.txt"
  local out rc=0
  out="$(
    STUB_ROSTER="${TMP}/roster.txt" \
    PATH="${TMP}/bin:${PATH}" \
    APPLE_SIGNING_KEYCHAIN="${TMP}/k.keychain-db" \
    APPLE_CODESIGN_IDENTITY="${ident}" \
    APPLE_TEAM_ID="${team}" \
    /bin/bash "${TMP}/body.sh" 2>&1
  )" && rc=0 || rc=$?
  local ok=1
  [[ "${rc}" -eq "${want}" ]] || ok=0
  if [[ -n "${needle}" ]] && ! printf '%s' "${out}" | grep -Fq "${needle}"; then ok=0; fi
  # Non-disclosure, asserted on EVERY case rather than on one: the step must
  # report the outcome and nothing about the values it compared. Length is
  # metadata about a secret -- it narrows the search space for anyone reading
  # the log -- so a message that carries it is a regression even though it
  # never prints the value.
  # Needles are trimmed before use. A value carrying a newline would otherwise
  # reach grep -F as TWO patterns, the second empty, and an empty pattern
  # matches every line -- a leak reported where none exists. The whitespace
  # cases are exactly the ones that would trip it.
  local n_ident n_team
  n_ident="$(printf '%s' "${ident}" | tr -d '[:space:]')"
  n_team="$(printf '%s' "${team}" | tr -d '[:space:]')"
  if [[ -n "${n_ident}" ]] && printf '%s' "${out}" | grep -Fq "${n_ident}"; then
    ok=0; printf '    (leak) output contains the stored identity\n'
  fi
  if [[ -n "${n_team}" ]] && printf '%s' "${out}" | grep -Fq "${n_team}"; then
    ok=0; printf '    (leak) output contains the stored team\n'
  fi
  if printf '%s' "${out}" | grep -qi 'length'; then
    ok=0; printf '    (leak) output discloses a length\n'
  fi
  if [[ "${ok}" -eq 1 ]]; then
    pass=$((pass+1)); printf '  PASS  %-34s rc=%s\n' "${name}" "${rc}"
  else
    fail=$((fail+1)); printf '  FAIL  %-34s rc=%s (wanted %s)\n%s\n' "${name}" "${rc}" "${want}" "${out}"
  fi
}

ONE='  1) 95D53BFDFF81DF1D44E176CFC8EB44E430885609 "Developer ID Application: Gilberto Filho (W7677A5BK2)"
     1 valid identities found
'
TWO='  1) 95D53BFDFF81DF1D44E176CFC8EB44E430885609 "Developer ID Application: Gilberto Filho (W7677A5BK2)"
  2) 11111111111111111111111111111111111111AA "Developer ID Application: Other Person (ZZZZZZZZZZ)"
     2 valid identities found
'
NONE='     0 valid identities found
'
NOCOUNT='  1) 95D53BFDFF81DF1D44E176CFC8EB44E430885609 "Developer ID Application: Gilberto Filho (W7677A5BK2)"
'
NOTEAM='  1) 95D53BFDFF81DF1D44E176CFC8EB44E430885609 "Developer ID Application: No Team Suffix"
     1 valid identities found
'
GOOD_ID='Developer ID Application: Gilberto Filho (W7677A5BK2)'

# The only green. Everything else must be red.
run_case "green: identity and team match"  0 "${ONE}"     "${GOOD_ID}"          "W7677A5BK2"
run_case "zero identities"                 1 "${NONE}"    "${GOOD_ID}"          "W7677A5BK2"  "no codesigning identity"
run_case "two identities"                  1 "${TWO}"     "${GOOD_ID}"          "W7677A5BK2"  "cannot choose"
run_case "roster count absent"             1 "${NOCOUNT}" "${GOOD_ID}"          "W7677A5BK2"  "not understood"
run_case "team unparseable"                1 "${NOTEAM}"  "Developer ID Application: No Team Suffix" "W7677A5BK2" "could not read a team"
run_case "identity differs"                1 "${ONE}"     "Developer ID Application: Someone Else (W7677A5BK2)" "W7677A5BK2" "APPLE_CODESIGN_IDENTITY does not match"
run_case "team differs"                    1 "${ONE}"     "${GOOD_ID}"          "AAAAAAAAAA"  "APPLE_TEAM_ID does not match"
# The reason this whole lane exists: a stored value with a trailing newline.
run_case "identity trailing newline"       1 "${ONE}"     "${GOOD_ID}
"                                                                                "W7677A5BK2"  "ONLY by surrounding whitespace"
run_case "team trailing space"             1 "${ONE}"     "${GOOD_ID}"          "W7677A5BK2 " "ONLY by surrounding whitespace"

printf '\n  %s passed, %s failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
