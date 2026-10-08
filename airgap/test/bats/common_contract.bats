#!/usr/bin/env bats
# common_contract.bats — contract #3 of docs/airgap/DESIGN.md: the API that
# airgap/node/lib/common.sh provides to every phase library.
#
# Runs against COMMON_SH (default airgap/node/lib/common.sh). airgap/test/bats/run.sh
# runs it a second time against the test stub airgap/test/stubs/common.sh, which
# other phase libraries were developed against, so both stay equivalent.
# Every kubectl call goes to the recording stub (airgap/test/stubs/bin).

load test_helper

setup() {
  require_file "${COMMON_SH}"
  setup_stubs
  common_env
}

# ---------------------------------------------------------------------------
# log / warn / die
# ---------------------------------------------------------------------------
@test "log and warn write to stderr only" {
  run --separate-stderr with_common 'log "hello-log"; warn "hello-warn"; echo STDOUT'
  [ "${status}" -eq 0 ]
  [ "${output}" = STDOUT ]
  [[ "${stderr}" == *hello-log* ]]
  [[ "${stderr}" == *hello-warn* ]]
}

@test "die exits non-zero with its message on stderr" {
  run --separate-stderr with_common 'die "boom-message"; echo NOT-REACHED'
  [ "${status}" -ne 0 ]
  [[ "${stderr}" == *boom-message* ]]
  [[ "${output}" != *NOT-REACHED* ]]
}

@test "defaults: DRY_RUN=0 and KUBECTL='k3s kubectl'" {
  unset KUBECTL DRY_RUN
  run with_common 'printf "%s|%s" "${DRY_RUN}" "${KUBECTL}"'
  [ "${status}" -eq 0 ]
  [ "${output}" = "0|k3s kubectl" ]
}

# ---------------------------------------------------------------------------
# kc / in_cluster: an error is never "absent"
# ---------------------------------------------------------------------------
@test "kc runs \${KUBECTL} word-split, with the args, and preserves rc" {
  stub_handler <<'EOF'
stub_kubectl() { [ "$3" = get ] && return 3; return 0; }
EOF
  export KUBECTL="kubectl --context k3d-x"
  run with_common 'if kc get pods; then echo rc=0; else echo "rc=$?"; fi'
  [ "${status}" -eq 0 ]
  [ "${output}" = rc=3 ]
  [ "$(stub_calls kubectl)" = "kubectl --context k3d-x get pods" ]
}

@test "KUBECTL='k3s kubectl' reaches kubectl through k3s" {
  export KUBECTL="k3s kubectl"
  run with_common 'kc get ns'
  [ "${status}" -eq 0 ]
  stub_calls k3s | grep -q '^k3s kubectl get ns$'
}

@test "in_cluster: 0 when the object exists" {
  stub_handler <<'EOF'
stub_kubectl() { case " $* " in *" get "*) echo "secret/harbor-secret" ;; esac; return 0; }
EOF
  run with_common 'if in_cluster secret harbor-secret teknoir-system; then echo EXISTS; else echo "ABSENT rc=$?"; fi'
  [ "${status}" -eq 0 ]
  [ "${output}" = EXISTS ]
}

@test "in_cluster: 1 when the object is absent (kubectl --ignore-not-found prints nothing)" {
  stub_handler <<'EOF'
stub_kubectl() {
  case " $* " in
    *" --ignore-not-found "*) return 0 ;;
    *" get "*) echo 'Error from server (NotFound): secrets "x" not found' >&2; return 1 ;;
  esac
}
EOF
  run with_common 'if in_cluster secret x teknoir-system; then echo EXISTS; else echo "ABSENT rc=$?"; fi'
  [ "${status}" -eq 0 ]
  [ "${output}" = "ABSENT rc=1" ]
}

@test "in_cluster: an API error aborts (never read as absent)" {
  stub_handler <<'EOF'
stub_kubectl() { echo "The connection to the server 127.0.0.1:6443 was refused - did you specify the right host or port?" >&2; return 1; }
EOF
  run with_common 'if in_cluster secret x teknoir-system; then echo EXISTS; else echo "ABSENT rc=$?"; fi'
  [ "${status}" -ne 0 ]
  [[ "${output}" != *EXISTS* ]]
  [[ "${output}" != *ABSENT* ]]
}

@test "in_cluster: an RBAC error aborts (never read as absent)" {
  stub_handler <<'EOF'
stub_kubectl() { echo 'Error from server (Forbidden): secrets "x" is forbidden: User "u" cannot get resource "secrets"' >&2; return 1; }
EOF
  run with_common 'if in_cluster secret x teknoir-system; then echo EXISTS; else echo "ABSENT rc=$?"; fi'
  [ "${status}" -ne 0 ]
  [[ "${output}" != *ABSENT* ]]
}

# ---------------------------------------------------------------------------
# run / DRY_RUN
# ---------------------------------------------------------------------------
@test "run executes the command when DRY_RUN=0" {
  export DRY_RUN=0
  run with_common 'run systemctl restart k3s'
  [ "${status}" -eq 0 ]
  [ "$(stub_calls systemctl)" = "systemctl restart k3s" ]
}

@test "run prints instead of executing when DRY_RUN=1" {
  export DRY_RUN=1
  run with_common 'run systemctl restart k3s'
  [ "${status}" -eq 0 ]
  [ -z "$(stub_calls systemctl)" ]
  [[ "${output}" == *"systemctl restart k3s"* ]]
}

# ---------------------------------------------------------------------------
# apply_ssa
# ---------------------------------------------------------------------------
cm_file() {
  cat > "${BATS_TEST_TMPDIR}/cm.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  k: v
EOF
}

# kubectl diff exits 1 when the live object differs (here: always); every
# manifest kubectl gets with -f (a file, or - for stdin) is appended to applied.yaml
DIFFERS='stub_kubectl() {
  case " $* " in *" diff "*) return 1 ;; esac
  local p="" a
  for a in "$@"; do
    if [ "$p" = -f ]; then if [ "$a" = - ]; then cat "$STUB_STDIN"; else cat "$a"; fi >> "$BATS_TEST_TMPDIR/applied.yaml"; fi
    p="$a"
  done
  return 0
}'

@test "apply_ssa <file>: server-side apply as field manager teknoir-bootstrap" {
  cm_file
  stub_handler <<<"${DIFFERS}"
  run with_common "apply_ssa '${BATS_TEST_TMPDIR}/cm.yaml'"
  [ "${status}" -eq 0 ]
  stub_calls kubectl | grep -E ' apply( |$)' | grep -- '--server-side' | grep -qE -- '--field-manager(=| )teknoir-bootstrap'
}

@test "apply_ssa <file> <manager>: uses the given field manager" {
  cm_file
  stub_handler <<<"${DIFFERS}"
  run with_common "apply_ssa '${BATS_TEST_TMPDIR}/cm.yaml' argocd-controller"
  [ "${status}" -eq 0 ]
  stub_calls kubectl | grep -E ' apply( |$)' | grep -qE -- '--field-manager(=| )argocd-controller'
}

@test "apply_ssa - reads the manifest from stdin" {
  cm_file
  stub_handler <<<"${DIFFERS}"
  run with_common "apply_ssa - < '${BATS_TEST_TMPDIR}/cm.yaml'"
  [ "${status}" -eq 0 ]
  stub_calls kubectl | grep -E ' apply( |$)' | grep -q -- '--server-side'
  grep -q 'name: coredns-custom' "${BATS_TEST_TMPDIR}/applied.yaml"
}

@test "apply_ssa in DRY_RUN=1 makes no mutating call" {
  cm_file
  stub_handler <<<"${DIFFERS}"
  export DRY_RUN=1
  run with_common "apply_ssa '${BATS_TEST_TMPDIR}/cm.yaml'"
  [ "${status}" -eq 0 ]
  [ -z "$(mutating_calls)" ]
}

@test "apply_ssa: a failing apply aborts" {
  cm_file
  stub_handler <<'EOF'
stub_kubectl() { case " $* " in *" diff "*) return 1 ;; *" apply "*) echo "admission webhook denied" >&2; return 1 ;; esac; return 0; }
EOF
  run with_common "apply_ssa '${BATS_TEST_TMPDIR}/cm.yaml'; echo NOT-REACHED"
  [ "${status}" -ne 0 ]
  [[ "${output}" != *NOT-REACHED* ]]
}

# ---------------------------------------------------------------------------
# wait_for
# ---------------------------------------------------------------------------
@test "wait_for returns once the command succeeds" {
  printf '0' > "${BATS_TEST_TMPDIR}/n"
  run with_common "ready() { local n; n=\$(( \$(cat '${BATS_TEST_TMPDIR}/n') + 1 )); printf '%s' \"\$n\" > '${BATS_TEST_TMPDIR}/n'; [ \"\$n\" -ge 2 ]; }; wait_for 'the thing' 30 ready; echo DONE"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *DONE* ]]
}

@test "wait_for aborts after its timeout" {
  run with_common "wait_for 'never' 2 false; echo NOT-REACHED"
  [ "${status}" -ne 0 ]
  [ "${status}" -ne 124 ]   # not killed by timeout(1): wait_for gave up by itself
  [[ "${output}" != *NOT-REACHED* ]]
}

# ---------------------------------------------------------------------------
# changed / summary
# ---------------------------------------------------------------------------
@test "summary lists every recorded change" {
  run with_common 'changed "wrote registries.yaml"; changed "restarted k3s"; summary'
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"wrote registries.yaml"* ]]
  [[ "${output}" == *"restarted k3s"* ]]
  [[ "${output}" =~ 2\ change ]]
}

@test "summary reports 0 changes when nothing changed" {
  run with_common 'summary'
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ (^|[^0-9])0\ change|[Nn]o\ change ]]
}

# ---------------------------------------------------------------------------
# sha256_file
# ---------------------------------------------------------------------------
@test "sha256_file prints the hex sha256 of a file" {
  printf 'teknoir\n' > "${BATS_TEST_TMPDIR}/f"
  want="$(sha256sum "${BATS_TEST_TMPDIR}/f" | cut -d' ' -f1)"
  run with_common "sha256_file '${BATS_TEST_TMPDIR}/f'"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${want}" ]
}

# ---------------------------------------------------------------------------
# secret_value: the value goes to stdout for capture, nowhere else
# ---------------------------------------------------------------------------
secret_handler() {
  # serves Secret teknoir-system/harbor-secret {HARBOR_ADMIN_PASSWORD: $1}
  # through every read form an implementation may use (a template or
  # jsonpath naming the key, or the whole object as JSON)
  local b64
  b64="$(printf '%s' "$1" | base64 | tr -d '\n')"
  stub_handler <<EOF
stub_kubectl() {
  case " \$* " in
    *" get secret harbor-secret "*HARBOR_ADMIN_PASSWORD*base64decode*) printf '%s' '$1' ;;
    *" get secret harbor-secret "*HARBOR_ADMIN_PASSWORD*) printf '%s' '${b64}' ;;
    *" get secret harbor-secret "*go-template*|*" get secret harbor-secret "*jsonpath*) printf '' ;;
    *" get secret harbor-secret "*json*) printf '{"kind":"Secret","data":{"HARBOR_ADMIN_PASSWORD":"%s"}}' '${b64}' ;;
    *" get secret "*) echo 'Error from server (NotFound): secrets not found' >&2; return 1 ;;
  esac
  return 0
}
EOF
}

@test "secret_value prints exactly the decoded value on stdout, nothing on stderr" {
  secret_handler 'Xq7-not-a-real-password-91'
  run --separate-stderr with_common 'v="$(secret_value teknoir-system harbor-secret HARBOR_ADMIN_PASSWORD)"; printf "%s" "$v"'
  [ "${status}" -eq 0 ]
  [ "${output}" = 'Xq7-not-a-real-password-91' ]
  [[ "${stderr}" != *Xq7-not-a-real-password-91* ]]
}

@test "secret_value aborts on a missing key" {
  secret_handler 'Xq7-not-a-real-password-91'
  run --separate-stderr with_common 'v="$(secret_value teknoir-system harbor-secret NO_SUCH_KEY)"; echo "got:$v"'
  [ "${status}" -ne 0 ]
  [[ "${output}" != *got:* ]]
}

@test "secret_value aborts on a missing Secret" {
  secret_handler 'Xq7-not-a-real-password-91'
  run --separate-stderr with_common 'v="$(secret_value teknoir-system no-such-secret K)"; echo "got:$v"'
  [ "${status}" -ne 0 ]
  [[ "${output}" != *got:* ]]
}

# ---------------------------------------------------------------------------
# never print
# ---------------------------------------------------------------------------
@test "common.sh never enables xtrace" {
  ! grep -nE '^[^#]*set -[a-zA-Z]*x|set -o xtrace' "${COMMON_SH}"
}
