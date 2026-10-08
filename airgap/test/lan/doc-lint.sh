#!/usr/bin/env bash
# doc-lint.sh - the airgap docs and the CLI agree:
#   * every `./teknoir-airgap COMMAND --flag ...` in the docs names a command
#     and flags that `teknoir-airgap help` lists;
#   * every command in `teknoir-airgap help` is documented in OPERATE.md;
#   * relative Markdown links between the docs resolve.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "${here}/../../.." && pwd)
help=$("${repo}/airgap/teknoir-airgap" help)
commands=$(printf '%s\n' "${help}" | awk '/^Commands:/ { c = 1; next } /^$/ { c = 0 } c && /^  [a-z]/ { print $1 }')
flags=$(printf '%s\n' "${help}" | grep -oE -- '--[a-z][a-z-]*' | sort -u)
docs=("${repo}"/docs/airgap/BUILD.md "${repo}"/docs/airgap/HOST-SETUP.md "${repo}"/docs/airgap/OPERATE.md
      "${repo}"/docs/airgap/CHANGELOG.md "${repo}"/README.md "${repo}"/README_infra.md)
errors=0 uses=0

for f in "${docs[@]}"; do
  [ -f "${f}" ] || { echo "missing doc: ${f}"; errors=$((errors + 1)); continue; }
  while IFS= read -r hit; do
    line=${hit%%:*}
    use=${hit#*:}
    use=${use%% #*}
    uses=$((uses + 1))
    # shellcheck disable=SC2086  # split the command line into words
    set -- ${use#./teknoir-airgap}
    if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then
      if ! printf '%s\n' "${commands}" | grep -qx -- "$1"; then
        echo "${f#"${repo}"/}:${line}: unknown command '$1' in: ${use}"
        errors=$((errors + 1))
      fi
    fi
    for w in "$@"; do
      case ${w} in
        --*) w=${w%%=*}; w=${w%%[!a-z-]*}
             if ! printf '%s\n' "${flags}" | grep -qx -- "${w}"; then
               echo "${f#"${repo}"/}:${line}: unknown flag '${w}' in: ${use}"
               errors=$((errors + 1))
             fi ;;
      esac
    done
  done < <(grep -noE '\./teknoir-airgap( [^`|)]*)?' "${f}" || true)
  # relative links to other Markdown files
  while IFS= read -r hit; do
    line=${hit%%:*}
    target=${hit#*](}
    target=${target%)}
    target=${target%%#*}
    case ${target} in http*|mailto:*|'') continue ;; esac
    if [ ! -e "$(dirname "${f}")/${target}" ]; then
      echo "${f#"${repo}"/}:${line}: broken link to ${target}"
      errors=$((errors + 1))
    fi
  done < <(grep -noE '\]\([^)]+\)' "${f}" || true)
done

for c in ${commands}; do
  if ! grep -qE "\./teknoir-airgap ${c}( |\$|\`)" "${repo}/docs/airgap/OPERATE.md"; then
    echo "docs/airgap/OPERATE.md does not document ./teknoir-airgap ${c}"
    errors=$((errors + 1))
  fi
done

if [ "${errors}" -gt 0 ]; then
  echo "doc lint: ${errors} problem(s) in ${uses} uses of ./teknoir-airgap"
  exit 1
fi
echo "doc lint: ${uses} uses of ./teknoir-airgap match the CLI; links resolve"
