#!/bin/sh
# Quality gate: compile (warnings as errors), xref, dialyzer, eunit, ct.
set -eu
cd "$(dirname "$0")/.."
rebar3 compile
rebar3 xref
rebar3 dialyzer
rebar3 eunit
rebar3 ct
