{{/*
Fail-fast guards for the gateway chart. Each one fails `helm install`
or `helm upgrade` with a clear message before a pod is created. Every
guard has a case in the safety-rails CI job.
*/}}

{{- define "secrets-bridge-gateway.validateURL" -}}
{{- /* args: list <field> <value> <insecureTransport> */ -}}
{{- $field := index . 0 -}}
{{- $url := toString (index . 1) -}}
{{- $insecure := index . 2 -}}
{{- if not $url -}}
{{- fail (printf "secrets-bridge-gateway: %s is required (an https:// URL)." $field) -}}
{{- end -}}
{{- $rest := regexReplaceAll "^[A-Za-z][A-Za-z0-9+.-]*://" $url "" -}}
{{- $authority := regexReplaceAll "[/?#].*$" $rest "" -}}
{{- if contains "@" $authority -}}
{{- fail (printf "secrets-bridge-gateway: %s must not carry userinfo (user:password@). Credentials come from mounted Secret files only." $field) -}}
{{- end -}}
{{- if contains "?" $url -}}
{{- fail (printf "secrets-bridge-gateway: %s=%q must not have a query string." $field $url) -}}
{{- end -}}
{{- if contains "#" $url -}}
{{- fail (printf "secrets-bridge-gateway: %s=%q must not have a fragment." $field $url) -}}
{{- end -}}
{{- if hasPrefix "http://" $url -}}
{{- if not $insecure -}}
{{- fail (printf "secrets-bridge-gateway: %s=%q is plain HTTP. The chart refuses to render unless insecureTransport=true, which is for local dev only." $field $url) -}}
{{- end -}}
{{- else if not (hasPrefix "https://" $url) -}}
{{- fail (printf "secrets-bridge-gateway: %s=%q is not an https:// URL." $field $url) -}}
{{- end -}}
{{- if not (regexMatch "^https?://([A-Za-z0-9.-]+|\\[[0-9a-fA-F:]+\\])(:[0-9]{1,5})?(/[^\\s]*)?$" $url) -}}
{{- fail (printf "secrets-bridge-gateway: %s=%q has no valid host." $field $url) -}}
{{- end -}}
{{- end -}}

{{- /* "true" when a label selector has no matchLabels and no
     matchExpressions entries, which matches every object. */ -}}
{{- define "secrets-bridge-gateway.selectsAll" -}}
{{- if and (empty (default (dict) .matchLabels)) (empty (default (list) .matchExpressions)) -}}true{{- end -}}
{{- end -}}

{{- define "secrets-bridge-gateway.validateEgress" -}}
{{- /* args: list <field> <egress dict> <allowSelectors> */ -}}
{{- $field := index . 0 -}}
{{- $e := default (dict) (index . 1) -}}
{{- $allowSelectors := index . 2 -}}
{{- $cidrs := default (list) $e.cidrs -}}
{{- $hasSelector := and $allowSelectors (or $e.namespaceSelector $e.podSelector) -}}
{{- if and (not $cidrs) (not $hasSelector) -}}
{{- if $allowSelectors -}}
{{- fail (printf "secrets-bridge-gateway: networkPolicy.enabled=true requires %s.cidrs or %s.namespaceSelector / podSelector. NetworkPolicy cannot match a hostname and the chart never falls back to egress to anywhere; list the peer or set networkPolicy.enabled=false." $field $field) -}}
{{- else -}}
{{- fail (printf "secrets-bridge-gateway: networkPolicy.enabled=true requires %s.cidrs. NetworkPolicy cannot match a hostname and the chart never falls back to egress to anywhere; list the CIDRs the endpoint resolves to or set networkPolicy.enabled=false." $field) -}}
{{- end -}}
{{- end -}}
{{- range $cidrs -}}
{{- if not (regexMatch (include "secrets-bridge-gateway.cidrRegex" $) (toString .)) -}}
{{- fail (printf "secrets-bridge-gateway: %s.cidrs entry %q is not a CIDR (for example 192.0.2.10/32)." $field (toString .)) -}}
{{- end -}}
{{- if hasSuffix "/0" (toString .) -}}
{{- fail (printf "secrets-bridge-gateway: %s.cidrs entry %q allows every address. List the addresses the endpoint resolves to, or set networkPolicy.enabled=false." $field (toString .)) -}}
{{- end -}}
{{- end -}}
{{- /* A selector with no matchLabels and no matchExpressions entries
     selects everything, so a peer made only of such selectors is egress
     to every pod (in this namespace, or in all of them). */ -}}
{{- if $hasSelector -}}
{{- $nsAll := and $e.namespaceSelector (include "secrets-bridge-gateway.selectsAll" $e.namespaceSelector) -}}
{{- $podAll := and $e.podSelector (include "secrets-bridge-gateway.selectsAll" $e.podSelector) -}}
{{- if or (and $nsAll (or (not $e.podSelector) $podAll)) (and $podAll (not $e.namespaceSelector)) -}}
{{- fail (printf "secrets-bridge-gateway: %s selects every pod (a selector needs at least one matchLabels or matchExpressions entry). Name the namespace and pods of the endpoint." $field) -}}
{{- end -}}
{{- end -}}
{{- $port := int (default 443 $e.port) -}}
{{- if or (lt $port 1) (gt $port 65535) -}}
{{- fail (printf "secrets-bridge-gateway: %s.port must be a TCP port between 1 and 65535." $field) -}}
{{- end -}}
{{- end -}}

{{- define "secrets-bridge-gateway.validate" -}}
{{- $insecure := eq (toString .Values.insecureTransport) "true" -}}

{{- /* Image pin guard, identical to the agent chart. */ -}}
{{- $digest := toString (default "" .Values.image.digest) -}}
{{- if $digest -}}
{{- if not (regexMatch (include "secrets-bridge-gateway.digestRegex" .) $digest) -}}
{{- fail (printf "secrets-bridge-gateway: image.digest=%q is not a digest. Set it to the bare sha256:<64 hex> value (no repository, no @); the chart renders <repository>@<digest> itself." $digest) -}}
{{- end -}}
{{- else if ne (toString .Values.image.allowMutableTag) "true" -}}
{{- $tag := toString (default .Chart.AppVersion .Values.image.tag) -}}
{{- if or (not (regexMatch (include "secrets-bridge-gateway.pinnedTagRegex" .) $tag)) (regexMatch (include "secrets-bridge-gateway.chartDevVersionRegex" .) $tag) -}}
{{- fail (printf "secrets-bridge-gateway: image resolves to tag %q, which is not a pinned image. Set image.digest to a bare sha256:<64 hex> digest (preferred), or image.tag to a full release version (X.Y.Z or vX.Y.Z, optional -prerelease) or an immutable sha-<hex> build tag. Moving tags such as dev, latest, main, X.Y and X are refused, and so are chart dev versions (X.Y.Z-dev.<sha>); for local dev only, set image.allowMutableTag=true." $tag) -}}
{{- end -}}
{{- end -}}

{{- /* Control plane endpoint. */ -}}
{{- if not .Values.cp.endpoint -}}
{{- fail "secrets-bridge-gateway: cp.endpoint is required. Set it to the https:// URL of the control plane, for example https://cp.example.com." -}}
{{- end -}}
{{- include "secrets-bridge-gateway.validateURL" (list "cp.endpoint" .Values.cp.endpoint $insecure) -}}

{{- /* Identity: an existing Secret only. */ -}}
{{- if not .Values.identity.existingSecret -}}
{{- fail "secrets-bridge-gateway: identity.existingSecret is required. Enroll the Gateway once outside the cluster and store the returned {\"gateway_id\", \"gateway_secret\"} JSON in a Secret under identity.key (see the chart README). The chart takes no inline credential and no enrollment token." -}}
{{- end -}}
{{- $idKey := toString .Values.identity.key -}}
{{- if or (not $idKey) (not (regexMatch "^[-._a-zA-Z0-9]+$" $idKey)) (eq $idKey ".") (eq $idKey "..") -}}
{{- fail (printf "secrets-bridge-gateway: identity.key=%q must be a Secret key (letters, digits, '-', '_' and '.')." $idKey) -}}
{{- end -}}

{{- /* Connectors: Argo CD only, at least one. */ -}}
{{- $argocd := default (list) .Values.connectors.argocd -}}
{{- if not $argocd -}}
{{- fail "secrets-bridge-gateway: connectors.argocd needs at least one entry. Release 1 observes Argo CD only; a Gateway with no connector has nothing to observe." -}}
{{- end -}}
{{- $names := dict -}}
{{- range $i, $c := $argocd -}}
{{- $where := printf "connectors.argocd[%d]" $i -}}
{{- $name := toString (default "" $c.name) -}}
{{- if not (regexMatch (include "secrets-bridge-gateway.dnsLabelRegex" $) $name) -}}
{{- fail (printf "secrets-bridge-gateway: %s.name=%q must be a DNS label (lower case letters, digits and '-', at most 63 characters)." $where $name) -}}
{{- end -}}
{{- if hasKey $names $name -}}
{{- fail (printf "secrets-bridge-gateway: connector name %q is used more than once; connector names must be unique." $name) -}}
{{- end -}}
{{- $_ := set $names $name true -}}
{{- include "secrets-bridge-gateway.validateURL" (list (printf "%s.baseURL" $where) $c.baseURL $insecure) -}}
{{- $tok := default (dict) $c.tokenSecret -}}
{{- if or (not $tok.name) (not $tok.key) -}}
{{- fail (printf "secrets-bridge-gateway: %s.tokenSecret.name and .key are required. Store the read-only Argo CD token in an existing Secret; the chart mounts it as a file and never puts it in values or env." $where) -}}
{{- end -}}
{{- $ca := default (dict) $c.caSecret -}}
{{- if and $ca.name (not $ca.key) -}}
{{- fail (printf "secrets-bridge-gateway: %s.caSecret.key is required when caSecret.name is set." $where) -}}
{{- end -}}
{{- with $c.timeout -}}
{{- if not (regexMatch "^[0-9]+(ms|s|m)$" (toString .)) -}}
{{- fail (printf "secrets-bridge-gateway: %s.timeout=%q must be a duration such as 10s (1s to 60s)." $where (toString .)) -}}
{{- end -}}
{{- end -}}
{{- $projects := default (list) $c.allowedProjects -}}
{{- if not $projects -}}
{{- fail (printf "secrets-bridge-gateway: %s.allowedProjects must list at least one Argo CD AppProject." $where) -}}
{{- end -}}
{{- range $projects -}}
{{- if not (regexMatch (include "secrets-bridge-gateway.objectNameRegex" $) (toString .)) -}}
{{- fail (printf "secrets-bridge-gateway: %s.allowedProjects entry %q is not an AppProject name." $where (toString .)) -}}
{{- end -}}
{{- end -}}
{{- $apps := default (list) $c.applications -}}
{{- if not $apps -}}
{{- fail (printf "secrets-bridge-gateway: %s.applications must list at least one Application." $where) -}}
{{- end -}}
{{- $ids := dict -}}
{{- range $j, $a := $apps -}}
{{- $id := toString (default "" $a.id) -}}
{{- if not (regexMatch (include "secrets-bridge-gateway.dnsLabelRegex" $) $id) -}}
{{- fail (printf "secrets-bridge-gateway: %s.applications[%d].id=%q must be a DNS label." $where $j $id) -}}
{{- end -}}
{{- if hasKey $ids $id -}}
{{- fail (printf "secrets-bridge-gateway: %s.applications id %q is used more than once." $where $id) -}}
{{- end -}}
{{- $_ := set $ids $id true -}}
{{- if not (regexMatch (include "secrets-bridge-gateway.objectNameRegex" $) (toString (default "" $a.name))) -}}
{{- fail (printf "secrets-bridge-gateway: %s.applications[%d].name must be an Argo CD Application name." $where $j) -}}
{{- end -}}
{{- with $a.appNamespace -}}
{{- if not (regexMatch (include "secrets-bridge-gateway.dnsLabelRegex" $) (toString .)) -}}
{{- fail (printf "secrets-bridge-gateway: %s.applications[%d].appNamespace=%q must be a DNS label." $where $j (toString .)) -}}
{{- end -}}
{{- end -}}
{{- with $a.uid -}}
{{- if not (regexMatch (include "secrets-bridge-gateway.uidRegex" $) (toString .)) -}}
{{- fail (printf "secrets-bridge-gateway: %s.applications[%d].uid=%q must be the Application's metadata.uid, a lower-case UUID." $where $j (toString .)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $.Values.networkPolicy.enabled -}}
{{- include "secrets-bridge-gateway.validateEgress" (list (printf "%s.egress" $where) $c.egress true) -}}
{{- end -}}
{{- end -}}

{{- /* NetworkPolicy: explicit egress peers, no fallback. */ -}}
{{- if .Values.networkPolicy.enabled -}}
{{- include "secrets-bridge-gateway.validateEgress" (list "cp.egress" .Values.cp.egress false) -}}
{{- end -}}

{{- $lp := int .Values.localPort -}}
{{- if or (lt $lp 1) (gt $lp 65535) -}}
{{- fail "secrets-bridge-gateway: localPort must be a TCP port between 1 and 65535." -}}
{{- end -}}
{{- end -}}
