#!/usr/bin/env bash
# site-age-recipients-test.sh — unit test of the one BACKUP_AGE_RECIPIENTS
# validator (R9, SEC-C8), site_age_recipients_check. The node library
# (airgap/node/lib/common.sh), the LAN entrypoint (airgap/teknoir-airgap, bash
# 3.2, self-contained) and the build (airgap/build/lib-build.sh) share no
# sourced code, so each holds the same function text:
#
#   1. the three copies are byte-identical;
#   2. every caller uses it and no other age-key check is left: load_site,
#      backup_recipients_load and `backup --recipient` (node), site_load and
#      backup_recipients_count (LAN), site_values_check (build);
#   3. each copy, on this bash: valid lists pass silently; a private key
#      (SECRET-KEY in any case, anywhere in the value, also after a valid or
#      an invalid entry) gives exactly the PRIVATE key message and nothing of
#      the key; any other bad entry is shown with at most its first 8
#      characters (control and glob characters as '?');
#   4. the LAN copy gives the same answers under bash 3.2 (docker bash:3.2,
#      pinned as in run-static.sh; skipped without docker or the image unless
#      CI is set).
#
# Usage: airgap/test/unit/site-age-recipients-test.sh   (NO_DOCKER=1 skips 4)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
BASH32_IMAGE="${BASH32_IMAGE:-docker.io/library/bash:3.2@sha256:0fd7cb8499c63a3c9345e7088a9cd83bb69f6e895e83833859aff838a0312091}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tkn-age-recip.XXXXXX")"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then ok "${d}"; else bad "${d}"; fi; }

COPIES=(airgap/node/lib/common.sh airgap/teknoir-airgap airgap/build/lib-build.sh)

echo "# 1. one text in three places"
for c in "${COPIES[@]}"; do
  awk '/^site_age_recipients_check\(\) \{$/ { on = 1 } on { print } on && /^\}$/ { exit }' \
    "${REPO}/${c}" > "${WORK}/$(basename "${c}").fn"
  check "${c} defines site_age_recipients_check once" \
    [ "$(grep -c '^site_age_recipients_check() {$' "${REPO}/${c}")" == 1 ]
done
check "the node, LAN and build copies are byte-identical" \
  bash -c "cmp -s '${WORK}/common.sh.fn' '${WORK}/teknoir-airgap.fn' && cmp -s '${WORK}/common.sh.fn' '${WORK}/lib-build.sh.fn'"
check "the copy is a complete function (ends with its closing brace)" \
  bash -c "[ \"\$(tail -1 '${WORK}/common.sh.fn')\" = '}' ] && [ \$(wc -l < '${WORK}/common.sh.fn') -gt 20 ]"

echo "# 2. every caller uses it; no other age-key check is left"
body() {
  # body <file> <function>: the text of one top-level function
  awk -v f="$2" '$0 ~ "^" f "\\(\\) \\{$" { on = 1 } on { print } on && /^\}$/ { exit }' "${REPO}/$1"
}
for site in "airgap/node/lib/common.sh load_site" "airgap/node/lib/backup.sh backup_recipients_load" \
            "airgap/node/lib/backup.sh cmd_backup" "airgap/teknoir-airgap site_load" \
            "airgap/teknoir-airgap backup_recipients_count" "airgap/build/lib-build.sh site_values_check"; do
  # shellcheck disable=SC2086  # "file function"
  set -- ${site}
  check "$2 ($1) calls site_age_recipients_check" bash -c "grep -q 'site_age_recipients_check \"' <<<\"\$1\"" _ "$(body "$1" "$2")"
done
# code lines (not comments) that test the age key format or the private-key
# prefix themselves, outside the validator
others="$(for c in "${COPIES[@]}" airgap/node/lib/backup.sh; do
  awk -v c="${c}" '/^site_age_recipients_check\(\) \{$/ { skip = 1 } skip { if (/^\}$/) skip = 0; next }
    /^[[:space:]]*#/ { next }
    /age1\[0-9a-z\]|\^age1|AGE-SECRET-KEY-\*|age_recipient_ok|backup_recipient_check|BACKUP_RECIPIENT_RE/ { print c ":" NR ": " $0 }' "${REPO}/${c}"
done)"
check "no other age-key check in the node, LAN or build code${others:+ (found: ${others})}" [ -z "${others}" ]

echo "# 3. answers, on bash ${BASH_VERSION}"
# The driver runs under bash 3.2 too: no ${x,,}, no mapfile, no declare -A.
# Fixture keys are assembled at run time: no key-shaped literal in the repo.
cat > "${WORK}/driver.sh" <<'DRIVER'
. "$1"
OK=age1qpzry9x8gf2tvdw0s3jn54khce6mua7lqpzry9x8gf2tvdw0s3jn54khce
BODY=QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7LQPZRY9X8GF2TVDW0S3JN54KHCE
PRIV="AGE-SECRET-KEY-""1${BODY}"
priv_lower=$(printf '%s' "${PRIV}" | tr 'A-Z' 'a-z')
ok_upper=$(printf '%s' "${OK}" | tr 'a-z' 'A-Z')
nl='
'
tab='	'
i=0
t() {
  # t VALUE [LABEL]: "<i> <rc> [<output>]" on one line
  local out rc=0
  out=$(site_age_recipients_check "$@") || rc=$?
  printf '%s %s [%s]\n' "${i}" "${rc}" "${out}"
  i=$((i + 1))
}
t ''
t "${OK}"
t "${OK} ${OK}"
t "  ${OK}   ${OK}  "
t age1short
t "${ok_upper}"
t "${OK} x"
t "${OK}q"
t "${PRIV}"
t "${priv_lower}"
t "${OK} ${PRIV}"
t "x ${PRIV}"
t "AGE-SECRET-KEY1${BODY}"
t "${OK}${tab}${OK}"
t "a${nl}b"
t 'a*b'
t 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5'
t "${PRIV}" --recipient
t age1short --recipient
t ' '
DRIVER
P="BACKUP_AGE_RECIPIENTS holds an age PRIVATE key (AGE-SECRET-KEY-...): remove it now (only public keys, age1..., belong there) and treat that identity as exposed"
E="is not an age public key (age1 followed by 58 lower-case letters and digits, separated by spaces)"
cat > "${WORK}/expected" <<EOF
0 0 []
1 0 []
2 0 []
3 0 []
4 1 [BACKUP_AGE_RECIPIENTS entry 'age1shor...' ${E}]
5 1 [BACKUP_AGE_RECIPIENTS entry 'AGE1QPZR...' ${E}]
6 1 [BACKUP_AGE_RECIPIENTS entry 'x...' ${E}]
7 1 [BACKUP_AGE_RECIPIENTS entry 'age1qpzr...' ${E}]
8 1 [${P}]
9 1 [${P}]
10 1 [${P}]
11 1 [${P}]
12 1 [${P}]
13 1 [BACKUP_AGE_RECIPIENTS entry 'age1qpzr...' ${E}]
14 1 [BACKUP_AGE_RECIPIENTS entry 'a?b...' ${E}]
15 1 [BACKUP_AGE_RECIPIENTS entry 'a?b...' ${E}]
16 1 [BACKUP_AGE_RECIPIENTS entry 'ssh-ed25...' ${E}]
17 1 [${P/#BACKUP_AGE_RECIPIENTS/--recipient}]
18 1 [--recipient entry 'age1shor...' ${E}]
19 0 []
EOF
names=("empty" "one key" "two keys" "extra spaces" "too short" "upper case" "a valid key, then junk"
       "one character too long" "a private key" "a lower-case private key" "a private key after a valid one"
       "a private key after an invalid entry" "a private key without the dash after KEY" "a tab between keys"
       "a newline inside" "a glob character" "an ssh key" "a private key as --recipient" "a bad --recipient"
       "only a space")
for c in common.sh teknoir-airgap lib-build.sh; do
  bash "${WORK}/driver.sh" "${WORK}/${c}.fn" > "${WORK}/${c}.out" 2>&1 || true
done
check "the three copies answer alike" bash -c "cmp -s '${WORK}/common.sh.out' '${WORK}/teknoir-airgap.out' && cmp -s '${WORK}/common.sh.out' '${WORK}/lib-build.sh.out'"
n=0
while IFS= read -r want; do
  got="$(sed -n "$(( n + 1 ))p" "${WORK}/common.sh.out")"
  if [[ "${got}" == "${want}" ]]; then
    ok "${names[${n}]}: ${want#* }"
  else
    bad "${names[${n}]}: got '${got}', want '${want}'"
  fi
  n=$((n + 1))
done < "${WORK}/expected"
check "every fixture ran" [ "$(wc -l < "${WORK}/common.sh.out")" == "${n}" ]
check "no answer holds 9 or more characters of a key body" \
  bash -c "! grep -qiE 'QPZRY9X8G|SECRET-KEY-1' '${WORK}/common.sh.out'"

echo "# 4. the LAN copy under bash 3.2"
if [[ -n "${NO_DOCKER:-}" ]]; then
  echo "  SKIP NO_DOCKER is set"
elif ! command -v docker >/dev/null 2>&1; then
  [[ -z "${CI:-}" ]] || bad "docker is needed in CI"
  echo "  SKIP docker not available"
elif ! docker image inspect "${BASH32_IMAGE}" >/dev/null 2>&1 && [[ -z "${CI:-}" ]]; then
  echo "  SKIP image ${BASH32_IMAGE} not present (CI pulls it)"
else
  docker run --rm --network none --user "$(id -u):$(id -g)" -v "${WORK}:/w:ro" "${BASH32_IMAGE}" \
    bash /w/driver.sh /w/teknoir-airgap.fn > "${WORK}/bash32.out" 2>&1 || true
  check "bash 3.2 runs it: $(head -c 200 "${WORK}/bash32.out" | head -1)" [ "$(wc -l < "${WORK}/bash32.out")" == "${n}" ]
  check "bash 3.2 gives the same answers as this bash" cmp -s "${WORK}/bash32.out" "${WORK}/common.sh.out"
fi

echo
echo "passed ${PASS}, failed ${FAIL}"
(( FAIL == 0 ))
