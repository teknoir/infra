#!/bin/sh
set -eu

usage() {
  cat <<EOF
Usage: $(basename "$0") [--max-change-pct N]

Runs chart lint, renders infra.yaml to a temp file, compares against the cached
infra.yaml, and only updates/deploys if the change percentage is within the
threshold.

Change percentage = max(added_lines, deleted_lines) / old_line_count * 100.
Default threshold is 10%.
EOF
}

MAX_CHANGE_PCT=10

while [ $# -gt 0 ]; do
  case "$1" in
    --max-change-pct)
      if [ $# -lt 2 ]; then
        echo "ERROR: --max-change-pct requires a value." >&2
        exit 2
      fi
      MAX_CHANGE_PCT="$2"
      shift 2
      ;;
    --max-change-pct=*)
      MAX_CHANGE_PCT="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$MAX_CHANGE_PCT" in
  ''|*[!0-9]*)
    echo "ERROR: --max-change-pct must be an integer between 0 and 100." >&2
    exit 2
    ;;
esac
if [ "$MAX_CHANGE_PCT" -lt 0 ] || [ "$MAX_CHANGE_PCT" -gt 100 ]; then
  echo "ERROR: --max-change-pct must be between 0 and 100." >&2
  exit 2
fi

# Add repositories for external dependencies
helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update

# Build/Update dependencies for the infra chart
echo "Building dependencies for charts/infra..."
helm dependency update charts/infra

# Dry-run check first: validate chart structure and renderability.
helm lint ./charts/infra

render_tmp="$(mktemp)"
diff_tmp="$(mktemp)"
trap 'rm -f "$render_tmp" "$diff_tmp"' EXIT

helm template infra ./charts/infra -n istio-system > "$render_tmp"

if [ ! -s "$render_tmp" ]; then
  echo "ERROR: Rendered infra.yaml is empty or missing." >&2
  exit 1
fi

if [ ! -s infra.yaml ]; then
  echo "ERROR: Cached infra.yaml is missing or empty; cannot compare changes." >&2
  exit 1
fi

diff -U 0 infra.yaml "$render_tmp" > "$diff_tmp" || true

set -- $(awk '
  /^@@/ {next}
  /^---/ {next}
  /^\+\+\+/ {next}
  /^\+/ {a++}
  /^-/ {d++}
  END {printf "%d %d", a+0, d+0}
' "$diff_tmp")
added_lines="$1"
deleted_lines="$2"

old_lines=$(wc -l < infra.yaml | tr -d ' ')
if [ "$old_lines" -eq 0 ]; then
  echo "ERROR: Cached infra.yaml has zero lines; cannot compute change percentage." >&2
  exit 1
fi

if [ "$added_lines" -gt "$deleted_lines" ]; then
  changed_lines="$added_lines"
else
  changed_lines="$deleted_lines"
fi

change_pct=$(( changed_lines * 100 / old_lines ))

echo "Diff stats: +$added_lines -$deleted_lines (old lines: $old_lines)"
echo "Change percentage: ${change_pct}% (max allowed: ${MAX_CHANGE_PCT}%)"

if [ "$change_pct" -gt "$MAX_CHANGE_PCT" ]; then
  echo "ERROR: Change percentage exceeds limit; refusing to update or deploy." >&2
  exit 1
fi

# Update cached infra.yaml only after checks pass.
mv "$render_tmp" infra.yaml

# Deploy to the remote K3s cluster
ssh anders@r415 \
  "sudo tee /opt/k3s/server/manifests/teknoir-infra.yaml >/dev/null" \
  < infra.yaml

echo "Infra chart deployed successfully."
