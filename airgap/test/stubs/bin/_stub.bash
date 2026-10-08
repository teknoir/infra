# shellcheck shell=bash
# _stub.bash — shared implementation of the recording command stubs in this
# directory (kubectl, k3s, ssh, crane, helm, systemctl). Put the directory
# first on PATH in a test; every call is then
#   1. recorded as one line in $STUB_LOG: "<name> <args, each %q-quoted>";
#   2. refused with rc 97 when the args match $STUB_FAIL_ON (an ERE), which
#      lets a test prove that a mode (dry-run) makes no mutating call;
#   3. answered by the function stub_<name> (dashes as underscores) when the
#      file $STUB_HANDLER defines it; its return code becomes the exit code
#      and it may call stub_default to fall through;
#   4. otherwise answered by the default: exit $STUB_DEFAULT_RC (0), no
#      output, except `k3s kubectl ...`, which is forwarded to the kubectl
#      stub (so KUBECTL="k3s kubectl" reaches stub_kubectl).
# stdin is passed through to the handler untouched.
#
# Each stub sets STUB_NAME and sources this file. Bash 3.2 compatible.

stub_record() {
  [ -n "${STUB_LOG:-}" ] || return 0
  {
    printf '%s' "${STUB_NAME}"
    local a
    for a in "$@"; do printf ' %q' "${a}"; done
    printf '\n'
  } >> "${STUB_LOG}"
}

stub_default() {
  case "${STUB_NAME}" in
    k3s)
      if [ "${1:-}" = kubectl ]; then
        shift
        exec "${STUB_DIR}/kubectl" "$@"
      fi
      ;;
  esac
  return "${STUB_DEFAULT_RC:-0}"
}

STUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
stub_record "$@"

# `-f -` / `--filename=-`: read stdin now (so the writer never gets SIGPIPE)
# into $STUB_STDIN, kept next to $STUB_LOG as stdin.<call number>.
STUB_STDIN=""
_prev=""
for _a in "$@"; do
  if { [ "${_prev}" = -f ] || [ "${_prev}" = --filename ]; } && [ "${_a}" = - ] || [ "${_a}" = --filename=- ]; then
    if [ -n "${STUB_LOG:-}" ]; then
      STUB_STDIN="${STUB_LOG}.stdin.$(wc -l < "${STUB_LOG}" | tr -d ' ')"
    else
      STUB_STDIN="$(mktemp)"
    fi
    cat > "${STUB_STDIN}"
    break
  fi
  _prev="${_a}"
done
unset _a _prev
export STUB_STDIN

if [ -n "${STUB_FAIL_ON:-}" ] && printf '%s %s\n' "${STUB_NAME}" "$*" | grep -Eq -- "${STUB_FAIL_ON}"; then
  printf 'stub %s: refused by STUB_FAIL_ON: %s %s\n' "${STUB_NAME}" "${STUB_NAME}" "$*" >&2
  exit 97
fi

_stub_fn="stub_$(printf '%s' "${STUB_NAME}" | tr '-' '_')"
if [ -n "${STUB_HANDLER:-}" ] && [ -f "${STUB_HANDLER}" ]; then
  # shellcheck source=/dev/null
  . "${STUB_HANDLER}"
fi
if declare -F "${_stub_fn}" >/dev/null 2>&1; then
  "${_stub_fn}" "$@"
  exit $?
fi
stub_default "$@"
exit $?
