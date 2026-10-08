#!/usr/bin/env bats
# static.bats — repository hygiene for the airgap tooling (DESIGN test plan 1):
# executable scripts with a shebang, never-print rules, public site files,
# no key material, no writes to the test host's /etc/hosts.

load test_helper

airgap_scripts() {
  # every shell script under airgap/ (by extension or shebang), tracked or new
  local f
  while IFS= read -r f; do
    case "${f}" in
      *.sh|*.bash) printf '%s\n' "${f}" ;;
      *) head -c 64 "${f}" 2>/dev/null | grep -qE '^#!.*(ba)?sh' && printf '%s\n' "${f}" ;;
    esac
  done < <(cd "${REPO_ROOT}" && find airgap -type f ! -name '*.bats' ! -path '*/.work/*' | sort)
}

@test "every executable-style script under airgap/ has a shell shebang and the x bit" {
  local f bad=""
  while IFS= read -r f; do
    case "${f}" in *.bash|*/lib/*.sh|*/stubs/common.sh) continue ;; esac   # sourced libraries
    head -1 "${REPO_ROOT}/${f}" | grep -qE '^#!(/usr/bin/env (ba)?sh|/bin/(ba)?sh)' || bad+=" ${f}(shebang)"
    [ -x "${REPO_ROOT}/${f}" ] || bad+=" ${f}(mode)"
  done < <(airgap_scripts)
  [ -z "${bad}" ] || { echo "bad:${bad}"; return 1; }
}

@test "node and LAN code never enable xtrace (secrets would be printed)" {
  local hits
  hits="$(cd "${REPO_ROOT}" && grep -rnE '^[^#]*\bset -[a-zA-Z]*x\b|set -o xtrace|bash -x' \
            airgap/node airgap/teknoir-airgap 2>/dev/null || true)"
  [ -z "${hits}" ] || { echo "${hits}"; return 1; }
}

@test "the LAN entrypoint uses no bash 4 features (macOS /bin/bash is 3.2)" {
  require_file "${LAN_BIN}"
  local hits
  hits="$(grep -nE '^[^#]*(declare -A|local -A|typeset -A|mapfile|readarray|\$\{[A-Za-z_][A-Za-z_0-9]*(,,|\^\^|,|\^)\}|coproc|&>>|\|&|;;&|\$\{[^}]*@[QEPAa]\}|\$EPOCHSECONDS|\$EPOCHREALTIME|wait -n)' "${LAN_BIN}" || true)"
  [ -z "${hits}" ] || { echo "${hits}"; return 1; }
}

@test "site files are sourceable, complete, and public" {
  local f n=0
  for f in "${REPO_ROOT}"/airgap/site/*.env; do
    [ -f "${f}" ] || continue
    n=$((n + 1))
    run bash -c "set -eu; . '${f}'; for v in TEKNOIR_ENV TEKNOIR_DOMAIN NODE_IP NODE TEKNOIR_HOSTNAMES K3S_DATA_DIR; do eval \"[ -n \\\"\\\${\$v:-}\\\" ]\" || { echo \"\$v unset\"; exit 1; }; done
      [[ \"\${NODE_IP}\" =~ ^([0-9]{1,3}\\.){3}[0-9]{1,3}\$ ]] || { echo bad NODE_IP; exit 1; }
      [[ \"\${NODE}\" == *@* ]] || { echo bad NODE; exit 1; }
      [ \"\${K3S_DATA_DIR}\" = /opt/k3s ] || { echo bad K3S_DATA_DIR; exit 1; }"
    [ "${status}" -eq 0 ] || { echo "${f}: ${output}"; return 1; }
    ! grep -nE '^[[:space:]]*[A-Z_]*(PASS|PASSWORD|SECRET|TOKEN|PRIVATE|CREDENTIAL)[A-Z_]*=' "${f}"
  done
  [ "${n}" -ge 1 ]
}

@test "no private key material anywhere in the repo" {
  # a PEM private-key header followed within 3 lines by a base64 body line;
  # headers without a body (documentation examples) do not count. The build
  # gate's planted fixtures are excluded (gitleaks.toml allowlists them too).
  local hits
  hits="$(cd "${REPO_ROOT}" && git ls-files --cached --others --exclude-standard |
    grep -vE '^airgap/test/build/fixtures/' | while IFS= read -r f; do
      [ -f "${f}" ] || continue
      awk -v f="${f}" '
        /-----BEGIN ([A-Z]+ )?PRIVATE KEY-----/ { h = NR; next }
        h && NR - h <= 3 && /^[[:space:]#]*[A-Za-z0-9+\/=]{16,}[[:space:]]*$/ { print f ":" h; h = 0 }
      ' "${f}" 2>/dev/null
    done)"
  [ -z "${hits}" ] || { echo "${hits}"; return 1; }
}

@test "the test harness never writes the test host's /etc/hosts" {
  local hits
  hits="$(cd "${REPO_ROOT}" && grep -rnE '(>>?|tee( -a)?|sed -i[^|]*|install [^|]*|cp [^|]*|mv [^|]*)[[:space:]]+/etc/hosts\b' airgap/test 2>/dev/null | grep -vE '\.bats:' || true)"
  [ -z "${hits}" ] || { echo "${hits}"; return 1; }
}

@test "the test harness passes --context to every kubectl it runs on the host" {
  # e2e talks to the VM's k3s kubectl over ssh; k3d tests go through kc()
  local hits
  hits="$(cd "${REPO_ROOT}" && grep -rnE '(^[[:space:]]*|[;|&(][[:space:]]*|\$\([[:space:]]*)kubectl[[:space:]]' \
            airgap/test/k3d airgap/test/vm airgap/test/lib 2>/dev/null |
          grep -vE -- '--context|kc\(\)|^\S+:[0-9]+:[[:space:]]*#' || true)"
  [ -z "${hits}" ] || { echo "${hits}"; return 1; }
}
