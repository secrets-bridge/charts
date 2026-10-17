#!/usr/bin/env bash
# Publish gate for chart-publish.yml (charts#31).
#
#   check-image-refs.sh <rendered manifests>
#
# Reads every `image:` reference from a `helm template` render and asks
# GHCR, with an anonymous pull token, whether that manifest exists. Exits
# non-zero when any reference is missing or can't be checked, so a chart
# is never pushed with a default image that can't be pulled.
set -uo pipefail

manifests=${1:?usage: check-image-refs.sh <rendered manifests>}

# The images are multi-arch indexes. GHCR answers 404 for an index unless
# the request accepts the index and manifest-list media types.
accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

refs=$(sed -nE 's/^[[:space:]]+image:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' "$manifests" | sort -u)
if [ -z "$refs" ]; then
  echo "::error::no image references found in $manifests"
  exit 1
fi

failed=0
for ref in $refs; do
  registry=${ref%%/*}
  rest=${ref#*/}
  if [[ "$rest" == *@* ]]; then
    repo=${rest%@*}
    reference=${rest#*@}
  else
    repo=${rest%:*}
    reference=${rest##*:}
  fi
  if [ "$registry" != ghcr.io ] || [ "$repo" = "$rest" ]; then
    echo "::error::$ref is not a ghcr.io/<repository>:<tag> or @<digest> reference, so it can't be checked"
    failed=1
    continue
  fi

  if ! token=$(curl -fsS --retry 3 "https://ghcr.io/token?scope=repository:${repo}:pull" | jq -er .token); then
    echo "::error::no anonymous pull token for $repo; the package is missing or not public"
    failed=1
    continue
  fi
  code=$(curl -sS --retry 3 -o /dev/null -w '%{http_code}' --head \
    -H "Authorization: Bearer $token" -H "Accept: $accept" \
    "https://ghcr.io/v2/${repo}/manifests/${reference}")
  case "$code" in
    200) echo "OK: $ref" ;;
    404)
      echo "::error::$ref does not exist on GHCR (manifest 404)"
      failed=1
      ;;
    *)
      echo "::error::$ref: GHCR answered HTTP $code"
      failed=1
      ;;
  esac
done
exit "$failed"
