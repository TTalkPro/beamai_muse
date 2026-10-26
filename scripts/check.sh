#!/bin/sh
# Quality gate: compile (warnings as errors), xref, dialyzer, eunit, ct,
# and the mail sidecar's unit tests. The mail sidecar's pinned npm packages
# (sidecars/mail/package-lock.json) are installed first when missing.
set -eu
cd "$(dirname "$0")/.."
[ -d sidecars/mail/node_modules ] || (cd sidecars/mail && npm ci --no-audit --no-fund)
(cd sidecars/mail && npm test --silent)
rebar3 compile
rebar3 xref
rebar3 dialyzer
rebar3 eunit
rebar3 ct
