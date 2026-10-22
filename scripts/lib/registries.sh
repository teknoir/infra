#!/usr/bin/env bash
# registries.sh: render and apply k3s's /etc/rancher/k3s/registries.yaml for the Harbor
# pull-through mirror (plans/harbor-proxy-staging.md). Sourced by ci-node-setup.sh and by
# scripts/tests/ci-node-registries-test.sh (which runs without root).
#
# containerd tries Harbor first and falls back to the upstream registry (k3s keeps its default
# endpoint last), so a Harbor outage never blocks public images.
#
#   registries_render HOST AUTH_FILE        the file on stdout (marker line first)
#   registries_apply  HOST|none AUTH_FILE TARGET
#                                           writes TARGET (0600) when it differs, removes a managed
#                                           file for `none`, refuses a file without the marker.
#                                           stdout: "changed" when it wrote or removed, else nothing.
#                                           return 0 ok, 1 invalid input, 2 refused (foreign file).
#
# AUTH_FILE: one line `username:password`, owned by the caller and not readable by group/other
# (mode 0600). The password is never printed.

REGISTRIES_MARKER='# managed by ci-node-setup.sh'
# upstream registry = Harbor proxy-cache project (the airgap list plus nvcr)
REGISTRIES_MIRRORS=(docker.io=dockerhub ghcr.io=ghcr gcr.io=gcr quay.io=quay registry.k8s.io=k8s nvcr.io=nvcr)

_reg_log() { printf 'ci-node-setup: %s\n' "$*" >&2; }
_reg_err() { printf 'ci-node-setup: ERROR: %s\n' "$*" >&2; }

# A double-quoted YAML scalar: backslash and double quote escaped.
_reg_quote() {
	local s=$1
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	printf '"%s"' "$s"
}

registries_valid_host() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]]; }

# Reads AUTH_FILE into REG_USER and REG_PASS; returns 1 with a message when it is unusable.
_reg_read_auth() {
	local f=$1 line mode
	[ -n "$f" ] || { _reg_err "no --registry-auth-file (the Harbor proxy projects are private)"; return 1; }
	[ -f "$f" ] || { _reg_err "auth file $f does not exist"; return 1; }
	[ -s "$f" ] || { _reg_err "auth file $f is empty"; return 1; }
	mode=$(stat -c %a "$f")
	if [ $((8#$mode & 8#077)) -ne 0 ]; then
		_reg_err "auth file $f has mode $mode; it must not be readable by group or others (chmod 600)"
		return 1
	fi
	[ "$(stat -c %u "$f")" = "$(id -u)" ] || { _reg_err "auth file $f is not owned by the running user"; return 1; }
	IFS= read -r line <"$f" || true
	line=${line%$'\r'}
	if [[ $line != ?*:?* ]]; then
		_reg_err "auth file $f must hold one line username:password"
		return 1
	fi
	if [ "$(wc -l <"$f")" -gt 1 ] && [ -n "$(sed -n '2,$p' "$f" | tr -d ' \t\r\n')" ]; then
		_reg_err "auth file $f must hold exactly one line"
		return 1
	fi
	REG_USER=${line%%:*}
	REG_PASS=${line#*:}
	if [[ $REG_USER == *[[:cntrl:]]* || $REG_PASS == *[[:cntrl:]]* ]]; then
		_reg_err "auth file $f holds control characters"
		return 1
	fi
}

registries_render() { # <host> <auth-file>
	local host=$1 pair reg proj
	registries_valid_host "$host" || { _reg_err "invalid registry host '$host'"; return 1; }
	_reg_read_auth "$2" || return 1
	printf '%s\n' "$REGISTRIES_MARKER"
	printf '# k3s private registry mirrors: pull-through cache on %s (plans/harbor-proxy-staging.md).\n' "$host"
	printf '# containerd asks Harbor first and falls back to the upstream registry. Do not edit: rerun\n'
	printf '# ci-node-setup.sh (--registry-mirror none removes this file).\n'
	printf 'mirrors:\n'
	for pair in "${REGISTRIES_MIRRORS[@]}"; do
		reg=${pair%%=*}
		proj=${pair#*=}
		# shellcheck disable=SC2016  # the $1 is the literal rewrite back-reference
		printf '  %s:\n    endpoint:\n      - "https://%s"\n    rewrite:\n      "^(.*)$": "%s/$1"\n' "$reg" "$host" "$proj"
	done
	printf 'configs:\n  "%s":\n    auth:\n      username: %s\n      password: %s\n' \
		"$host" "$(_reg_quote "$REG_USER")" "$(_reg_quote "$REG_PASS")"
}

# Everything registries_apply would refuse, checked without touching anything (so a node setup
# fails before it changes the first thing).
registries_check() { # <host|none> <auth-file> <target>
	local want=$1 auth=$2 target=$3
	if [ -e "$target" ] && ! grep -qxF "$REGISTRIES_MARKER" "$target"; then
		_reg_err "$target exists and is not managed by ci-node-setup.sh (no '$REGISTRIES_MARKER' line); refusing to touch it"
		return 2
	fi
	[ "$want" = none ] || registries_render "$want" "$auth" >/dev/null || return 1
}

registries_apply() { # <host|none> <auth-file> <target>
	local want=$1 auth=$2 target=$3 tmp rc=0
	if [ "$want" = none ]; then
		[ -e "$target" ] || return 0
		if ! grep -qxF "$REGISTRIES_MARKER" "$target"; then
			_reg_err "$target is not managed by ci-node-setup.sh (no '$REGISTRIES_MARKER' line); not removing it"
			return 2
		fi
		rm -f "$target"
		_reg_log "removed $target"
		echo changed
		return 0
	fi
	if [ -e "$target" ] && ! grep -qxF "$REGISTRIES_MARKER" "$target"; then
		_reg_err "$target exists and is not managed by ci-node-setup.sh (no '$REGISTRIES_MARKER' line); refusing to overwrite it"
		return 2
	fi
	install -d -m 0755 "$(dirname "$target")" || return 1
	tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
	chmod 0600 "$tmp"
	registries_render "$want" "$auth" >"$tmp" || rc=$?
	if [ "$rc" -ne 0 ]; then rm -f "$tmp"; return 1; fi
	if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
		rm -f "$tmp"
		if [ "$(stat -c %a "$target")" != 600 ]; then chmod 0600 "$target"; _reg_log "set $target to mode 0600"; fi
		return 0
	fi
	mv -f "$tmp" "$target"
	_reg_log "wrote $target"
	echo changed
}
