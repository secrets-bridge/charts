#!/usr/bin/env bash
# Safety-rails helper for ci.yml.
#
#   expect-render.sh reject '<expected error text>' <chart dir> [helm template args...]
#   expect-render.sh accept <chart dir> [helm template args...]
#
# `reject` passes only when `helm template` fails AND its output contains
# the expected text, so a case can't pass because some other guard tripped
# first. `accept` passes only when the render succeeds.
set -uo pipefail

mode=${1:?usage: expect-render.sh reject|accept ...}
shift
case "$mode" in
  reject)
    want=${1:?expected error text missing}
    shift
    ;;
  accept) ;;
  *)
    echo "::error::unknown mode $mode"
    exit 2
    ;;
esac
chart=${1:?chart dir missing}
shift

out=$(helm template r "$chart" "$@" 2>&1)
rc=$?

if [ "$mode" = accept ]; then
  if [ "$rc" -ne 0 ]; then
    echo "::error::render failed but should have been accepted (helm template $chart $*)"
    echo "$out" | grep -E '^Error' || echo "$out" | tail -5
    exit 1
  fi
  echo "OK: rendered (helm template $chart $*)"
  exit 0
fi

if [ "$rc" -eq 0 ]; then
  echo "::error::rendered successfully, safety rail BROKEN (helm template $chart $*)"
  exit 1
fi
if ! grep -qF -- "$want" <<<"$out"; then
  echo "::error::render failed, but not with the expected error: $want"
  echo "$out" | grep -E '^Error' || echo "$out" | tail -5
  exit 1
fi
echo "OK: rejected with: $want"
