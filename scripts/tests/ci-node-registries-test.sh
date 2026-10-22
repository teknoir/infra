#!/usr/bin/env bash
# Test of scripts/lib/registries.sh (the registries.yaml of ci-node-setup.sh --registry-mirror)
# and of the option checks of ci-node-setup.sh. Runs without root and without a cluster, in a temp
# dir; nothing outside it is touched.
#   scripts/tests/ci-node-registries-test.sh          (UPDATE_GOLDEN=1 rewrites the golden file)
# Cases: golden output, file mode, marker refusal, no-op re-run, change, `none`, missing / empty /
# malformed / world-readable auth file, YAML quoting, host validation, no password in any output,
# and ci-node-setup.sh's argument checks (run with a stub `id` that says root; every case fails
# before the script changes anything).
# shellcheck disable=SC2015  # "test && ok || bad": ok and bad always return 0
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${HERE}/.." && pwd)"
GOLDEN="${HERE}/fixtures/registries.golden.yaml"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT
fail=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

# shellcheck source=../lib/registries.sh
. "${SCRIPTS}/lib/registries.sh"

PASS='s3cr3tPassw0rdFORtest'
HOST=harbor.example.test
AUTH="${TMP}/auth"
TARGET="${TMP}/etc/rancher/k3s/registries.yaml"
mkauth() { printf '%s\n' "$1" >"$AUTH"; chmod 600 "$AUTH"; }
mkauth "robot\$nodes:${PASS}"
sha() { sha256sum "$1" | cut -d' ' -f1; }
run_apply() { # <host|none>; stdout -> $TMP/out, stderr -> $TMP/err, status in $rc
	rc=0
	registries_apply "$1" "$AUTH" "$TARGET" >"${TMP}/out" 2>"${TMP}/err" || rc=$?
}
no_password() { ! grep -qF -e "$PASS" "${TMP}/out" "${TMP}/err" 2>/dev/null; }

# --- golden output
registries_render "$HOST" "$AUTH" >"${TMP}/rendered"
if [ "${UPDATE_GOLDEN:-}" = 1 ]; then cp "${TMP}/rendered" "$GOLDEN"; fi
diff -u "$GOLDEN" "${TMP}/rendered" >"${TMP}/golden.diff" && ok "golden output" || { bad "golden output"; cat "${TMP}/golden.diff"; }
[ "$(head -n1 "${TMP}/rendered")" = '# managed by ci-node-setup.sh' ] && ok "marker is the first line" || bad "marker is the first line"
python3 -I - "${TMP}/rendered" <<'PY' && ok "valid YAML with the six mirrors, rewrites and auth" || bad "valid YAML with the six mirrors, rewrites and auth"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
want = {"docker.io": "dockerhub", "ghcr.io": "ghcr", "gcr.io": "gcr", "quay.io": "quay", "registry.k8s.io": "k8s", "nvcr.io": "nvcr"}
assert set(d["mirrors"]) == set(want), d["mirrors"].keys()
for reg, proj in want.items():
    m = d["mirrors"][reg]
    assert m["endpoint"] == ["https://harbor.example.test"], m
    assert m["rewrite"] == {"^(.*)$": proj + "/$1"}, m
assert d["configs"]["harbor.example.test"]["auth"] == {"username": "robot$nodes", "password": "s3cr3tPassw0rdFORtest"}
PY

# --- fresh write: mode 0600, "changed", no password in the output
run_apply "$HOST"
[ "$rc" = 0 ] && [ "$(cat "${TMP}/out")" = changed ] && ok "first apply writes and reports changed" || bad "first apply writes and reports changed (rc=$rc out=$(cat "${TMP}/out"))"
[ "$(stat -c %a "$TARGET")" = 600 ] && ok "target is mode 0600" || bad "target is mode 0600"
cmp -s "$TARGET" "${TMP}/rendered" && ok "target equals the rendering" || bad "target equals the rendering"
no_password && ok "no password in stdout or stderr (apply)" || bad "no password in stdout or stderr (apply)"
ls "${TMP}/etc/rancher/k3s" | grep -q tmp && bad "no temp file left behind" || ok "no temp file left behind"

# --- no-op re-run
before=$(sha "$TARGET"); inode_before=$(stat -c %i "$TARGET")
run_apply "$HOST"
[ "$rc" = 0 ] && [ ! -s "${TMP}/out" ] && [ "$(sha "$TARGET")" = "$before" ] && [ "$(stat -c %i "$TARGET")" = "$inode_before" ] \
	&& ok "re-run is a no-op (no output, file untouched)" || bad "re-run is a no-op (rc=$rc out=$(cat "${TMP}/out"))"
chmod 644 "$TARGET"
run_apply "$HOST"
[ "$rc" = 0 ] && [ ! -s "${TMP}/out" ] && [ "$(stat -c %a "$TARGET")" = 600 ] && ok "a loosened mode is repaired without reporting a change" || bad "a loosened mode is repaired"

# --- changes are written
mkauth "robot\$nodes:${PASS}-rotated"
run_apply "$HOST"
[ "$(cat "${TMP}/out")" = changed ] && grep -qF "${PASS}-rotated" "$TARGET" && ok "a rotated password is written" || bad "a rotated password is written"
run_apply other.example.test
[ "$(cat "${TMP}/out")" = changed ] && grep -qF 'https://other.example.test' "$TARGET" && ok "a changed host is written" || bad "a changed host is written"
mkauth "robot\$nodes:${PASS}"
run_apply "$HOST"

# --- none removes a managed file, is a no-op without one
run_apply none
[ "$rc" = 0 ] && [ "$(cat "${TMP}/out")" = changed ] && [ ! -e "$TARGET" ] && ok "none removes a managed file" || bad "none removes a managed file"
run_apply none
[ "$rc" = 0 ] && [ ! -s "${TMP}/out" ] && ok "none without a file is a no-op" || bad "none without a file is a no-op"

# --- foreign file: refused, untouched
printf 'mirrors:\n  docker.io:\n    endpoint:\n      - "https://mine.example"\n' >"$TARGET"
chmod 640 "$TARGET"
foreign=$(sha "$TARGET")
run_apply "$HOST"
[ "$rc" = 2 ] && [ ! -s "${TMP}/out" ] && [ "$(sha "$TARGET")" = "$foreign" ] && [ "$(stat -c %a "$TARGET")" = 640 ] \
	&& grep -q "not managed by ci-node-setup.sh" "${TMP}/err" && ok "a file without the marker is refused and untouched" || bad "a file without the marker is refused and untouched (rc=$rc)"
no_password && ok "no password in the refusal output" || bad "no password in the refusal output"
run_apply none
[ "$rc" = 2 ] && [ "$(sha "$TARGET")" = "$foreign" ] && grep -q "not removing it" "${TMP}/err" && ok "none does not remove a foreign file" || bad "none does not remove a foreign file"
registries_check "$HOST" "$AUTH" "$TARGET" 2>/dev/null && bad "check refuses a foreign file" || ok "check refuses a foreign file"
# the marker text inside another line is not the marker
printf '# not managed by ci-node-setup.sh\nmirrors: {}\n' >"$TARGET"
run_apply "$HOST"
[ "$rc" = 2 ] && ok "a comment that merely contains the marker text does not count" || bad "a comment that merely contains the marker text does not count"
rm -f "$TARGET"

# --- unusable auth files: error, nothing written
unusable() { # <description> <setup command...>
	local d=$1; shift
	rm -f "$AUTH" "$TARGET"; "$@"
	run_apply "$HOST"
	[ "$rc" = 1 ] && [ ! -e "$TARGET" ] && [ ! -s "${TMP}/out" ] && no_password && ! ls "${TMP}/etc/rancher/k3s" | grep -q tmp \
		&& ok "$d: refused, nothing written" || bad "$d: refused, nothing written (rc=$rc)"
}
mk() { printf '%b' "$1" >"$AUTH"; chmod 600 "$AUTH"; }
mkmode() { printf 'robot$nodes:%s\n' "$PASS" >"$AUTH"; chmod "$1" "$AUTH"; }
unusable "missing auth file" true
unusable "empty auth file" mk ""
unusable "password only" mk "justapassword\n"
unusable "username only" mk "robot\$nodes:\n"
unusable "no username" mk ":${PASS}\n"
unusable "two lines" mk "robot\$nodes:${PASS}\nsecond:line\n"
unusable "control character" mk "robot\$nodes:${PASS}\001x\n"
unusable "group-readable mode" mkmode 640
unusable "world-readable mode" mkmode 644
grep -qF "chmod 600" "${TMP}/err" && ok "the mode error says how to fix it" || bad "the mode error says how to fix it"
mkauth "robot\$nodes:${PASS}"
registries_apply "$HOST" "" "$TARGET" >/dev/null 2>"${TMP}/err" && bad "no auth file argument is refused" || ok "no auth file argument is refused"
# CRLF and trailing blank lines are fine
printf 'robot$nodes:%s\r\n\n' "$PASS" >"$AUTH"; chmod 600 "$AUTH"
run_apply "$HOST"
[ "$rc" = 0 ] && grep -qxF "      password: \"${PASS}\"" "$TARGET" && ok "CRLF and trailing blank lines are accepted, CR stripped" || bad "CRLF and trailing blank lines are accepted (rc=$rc)"
rm -f "$TARGET"

# --- quoting: a password with a quote, a backslash, a hash, a colon and a space survives a YAML round trip
WEIRD='pa"ss\word#with:colon $x'
mkauth "robot\$nodes:${WEIRD}"
run_apply "$HOST"
python3 -I - "$TARGET" "$WEIRD" <<'PY' && ok "quote, backslash, hash, colon and space in the password round-trip through YAML" || bad "special characters in the password round-trip through YAML"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["configs"]["harbor.example.test"]["auth"]["password"] == sys.argv[2], d["configs"]
PY
rm -f "$TARGET"; mkauth "robot\$nodes:${PASS}"

# --- host validation
for h in 'a b' 'a/b' 'a"b' 'https://harbor.example.test' '-x' '' 'a;b' 'a:b:c' 'x:99999999'; do
	registries_render "$h" "$AUTH" >/dev/null 2>&1 && bad "host '$h' is refused" || ok "host '$h' is refused"
done
for h in harbor.teknoir.cloud harbor.example.test:8443 localhost 10.0.0.5; do
	registries_render "$h" "$AUTH" >/dev/null 2>&1 && ok "host '$h' is accepted" || bad "host '$h' is accepted"
done

# --- the applier creates the directory when it is missing
rm -rf "${TMP:?}/etc"
run_apply "$HOST"
[ "$rc" = 0 ] && [ -f "$TARGET" ] && ok "the target directory is created" || bad "the target directory is created"

# --- ci-node-setup.sh argument checks (stub id = root; each case dies before changing anything)
mkdir -p "${TMP}/bin"
printf '#!/bin/sh\n[ "$1" = "-u" ] && echo 0 && exit 0\nexec /usr/bin/id "$@"\n' >"${TMP}/bin/id"
chmod +x "${TMP}/bin/id"
setup() { # <args...>: runs ci-node-setup.sh with REGISTRIES_FILE in the temp dir; status in $rc
	rc=0
	PATH="${TMP}/bin:${PATH}" REGISTRIES_FILE="${TMP}/setup-registries.yaml" bash "${SCRIPTS}/ci-node-setup.sh" "$@" >"${TMP}/out" 2>&1 || rc=$?
}
rm -f "${TMP}/setup-registries.yaml"
setup server --registry-mirror "$HOST"
[ "$rc" = 1 ] && grep -q "needs --registry-auth-file" "${TMP}/out" && ok "ci-node-setup: --registry-mirror HOST needs the auth file" || bad "ci-node-setup: --registry-mirror HOST needs the auth file"
setup agent --server-ip 10.0.0.1 --node-ip 10.0.0.2 --registry-auth-file "$AUTH"
[ "$rc" = 1 ] && grep -q "needs --registry-mirror" "${TMP}/out" && ok "ci-node-setup: the auth file alone is refused" || bad "ci-node-setup: the auth file alone is refused"
setup server --registry-mirror 'bad host' --registry-auth-file "$AUTH"
[ "$rc" = 1 ] && grep -q "invalid --registry-mirror" "${TMP}/out" && ok "ci-node-setup: an invalid host is refused" || bad "ci-node-setup: an invalid host is refused"
setup server --registry-mirror "$HOST" --registry-auth-file "${TMP}/missing"
[ "$rc" = 1 ] && grep -q "does not exist" "${TMP}/out" && ok "ci-node-setup: a missing auth file stops before any change" || bad "ci-node-setup: a missing auth file stops before any change"
: >"${TMP}/empty"; chmod 600 "${TMP}/empty"
setup server --registry-mirror "$HOST" --registry-auth-file "${TMP}/empty"
[ "$rc" = 1 ] && grep -q "is empty" "${TMP}/out" && ok "ci-node-setup: an empty auth file stops before any change" || bad "ci-node-setup: an empty auth file stops before any change"
printf 'mirrors: {}\n' >"${TMP}/setup-registries.yaml"
setup agent --server-ip 10.0.0.1 --node-ip 10.0.0.2 --registry-mirror "$HOST" --registry-auth-file "$AUTH"
[ "$rc" = 1 ] && grep -q "not managed by ci-node-setup.sh" "${TMP}/out" && [ "$(cat "${TMP}/setup-registries.yaml")" = 'mirrors: {}' ] \
	&& ok "ci-node-setup: a foreign registries.yaml stops the run before any change" || bad "ci-node-setup: a foreign registries.yaml stops the run"
setup server --registry-mirror none
[ "$rc" = 1 ] && grep -q "not managed by ci-node-setup.sh" "${TMP}/out" && ok "ci-node-setup: none on a foreign file is refused" || bad "ci-node-setup: none on a foreign file is refused"
grep -q "$PASS" "${TMP}/out" && bad "ci-node-setup: no password in its output" || ok "ci-node-setup: no password in its output"
grep -q -e '--registry-mirror HOST|none' "${SCRIPTS}/ci-node-setup.sh" && ok "ci-node-setup: documented in the header" || bad "ci-node-setup: documented in the header"

[ "$fail" = 0 ] && echo "ALL OK" || { echo "FAILED"; exit 1; }
