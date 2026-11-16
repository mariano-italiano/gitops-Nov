#!/usr/bin/env bash
# Exports all objects of a namespace as clean YAML manifests (no status, runtime metadata, server defaults or ArgoCD tracking) plus kustomization.yaml.
# Usage: ./export-namespace.sh <namespace> [output-dir]
# $ ./export-namespace.sh nginx-prod ./out-log
# $ kubectl kustomize ./out-log 
# Env:   KUBECONFIG / KUBE_CONTEXT select the cluster; KEEP_NAMESPACE=1 keeps metadata.namespace; SKIP_SECRETS=1 skips Secrets.
set -euo pipefail

NS="${1:-}"
[ -n "$NS" ] || { echo "Usage: $0 <namespace> [output-dir]" >&2; exit 1; }
OUT="${2:-./$NS}"
KEEP_NAMESPACE="${KEEP_NAMESPACE:-0}"
SKIP_SECRETS="${SKIP_SECRETS:-0}"
for b in kubectl jq yq; do command -v "$b" >/dev/null || { echo "Missing tool: $b" >&2; exit 1; }; done
yq --version 2>&1 | grep -q mikefarah || { echo "yq must be mikefarah/yq v4" >&2; exit 1; }

K=(kubectl)
[ -n "${KUBE_CONTEXT:-}" ] && K+=(--context "$KUBE_CONTEXT")
"${K[@]}" get ns "$NS" >/dev/null
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then echo "Output dir $OUT is not empty" >&2; exit 1; fi
mkdir -p "$OUT"

# Runtime or controller-generated types, never part of desired state.
SKIP_TYPES='^(events|events\.events\.k8s\.io|endpointslices\.discovery\.k8s\.io|controllerrevisions\.apps|leases\.coordination\.k8s\.io|pods\.metrics\.k8s\.io|csistoragecapacities\.storage\.k8s\.io|localsubjectaccessreviews\.authorization\.k8s\.io|bindings)$'
TYPES=$("${K[@]}" api-resources --namespaced --verbs=list,get -o name 2>/dev/null | grep -Ev "$SKIP_TYPES" | sort)
[ "$SKIP_SECRETS" = 1 ] && TYPES=$(printf '%s\n' "$TYPES" | grep -v '^secrets$')

# jq: drop generated objects, then strip runtime fields and server defaults.
read -r -d '' JQ <<'EOF' || true
def unwanted_ann: test("^(kubectl\\.kubernetes\\.io/last-applied-configuration|kubectl\\.kubernetes\\.io/restartedAt|deployment\\.kubernetes\\.io/|deprecated\\.daemonset\\.template\\.generation|pv\\.kubernetes\\.io/|volume\\.beta\\.kubernetes\\.io/|volume\\.kubernetes\\.io/|endpoints\\.kubernetes\\.io/|control-plane\\.alpha\\.kubernetes\\.io/|argocd\\.argoproj\\.io/tracking-id|meta\\.helm\\.sh/|objectset\\.rio\\.cattle\\.io/|kubernetes\\.io/service-account\\.|kubernetes\\.io/limit-ranger)");
def unwanted_lbl: test("^(argocd\\.argoproj\\.io/instance|controller-uid|batch\\.kubernetes\\.io/controller-uid|job-name|batch\\.kubernetes\\.io/job-name|objectset\\.rio\\.cattle\\.io/)");
def tidy_map(f): if . == null then null else with_entries(select(.key | f | not)) | if . == {} then null else . end end;
def tidy_meta:
  (.annotations |= tidy_map(unwanted_ann)) | (.labels |= tidy_map(unwanted_lbl))
  | del(.uid, .resourceVersion, .generation, .creationTimestamp, .managedFields, .selfLink, .ownerReferences, .finalizers, .deletionTimestamp, .deletionGracePeriodSeconds)
  | del(.. | nulls?) ;
def drop_if($k; $v): if has($k) and .[$k] == $v then del(.[$k]) else . end;
def tidy_container:
  (if .ports then .ports |= map(drop_if("protocol"; "TCP")) else . end)
  | drop_if("terminationMessagePath"; "/dev/termination-log") | drop_if("terminationMessagePolicy"; "File") | drop_if("resources"; {});
def tidy_podspec:
  drop_if("dnsPolicy"; "ClusterFirst") | drop_if("schedulerName"; "default-scheduler") | drop_if("securityContext"; {})
  | drop_if("terminationGracePeriodSeconds"; 30) | drop_if("restartPolicy"; "Always") | drop_if("serviceAccountName"; "default")
  | drop_if("enableServiceLinks"; true) | drop_if("preemptionPolicy"; "PreemptLowerPriority") | drop_if("priority"; 0)
  | del(.serviceAccount)
  | if .containers then .containers |= map(tidy_container) else . end
  | if .initContainers then .initContainers |= map(tidy_container) else . end;
def tidy_template: (.metadata |= (tidy_meta | if . == {} then null else . end)) | del(.metadata | nulls) | (.spec |= tidy_podspec);
def keep:
  (.status.phase? // "") as $p
  | (.metadata.ownerReferences // []) == []
  and [.kind, $p] != ["Pod", "Succeeded"] and [.kind, $p] != ["Pod", "Failed"]
  and ([.kind, .metadata.name] != ["ConfigMap", "kube-root-ca.crt"])
  and ([.kind, .metadata.name] != ["Service", "kubernetes"])
  and ((.kind == "ServiceAccount" and .metadata.name == "default" and ((.imagePullSecrets // []) == [])) | not)
  and ((.kind == "Secret" and ((.type // "") | test("^(kubernetes\\.io/service-account-token|helm\\.sh/release\\.v1)$"))) | not)
  and ((.kind == "Endpoints" and (.metadata.name | IN($selsvcs[]))) | not)
  and ((.kind == "PersistentVolumeClaim" and (.metadata.name as $n | any($stspvc[]; . as $pre | $n | test("^" + $pre + "[0-9]+$")))) | not);
.items[] | select(keep)
| del(.status)
| (.metadata |= tidy_meta)
| if $keepns == "1" then . else del(.metadata.namespace) end
| if .kind == "Deployment" then
    .spec |= (drop_if("progressDeadlineSeconds"; 600) | drop_if("revisionHistoryLimit"; 10)
      | drop_if("strategy"; {"type":"RollingUpdate","rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"}}))
    | .spec.template |= tidy_template
  elif .kind == "StatefulSet" then
    .spec |= (drop_if("podManagementPolicy"; "OrderedReady") | drop_if("revisionHistoryLimit"; 10)
      | drop_if("updateStrategy"; {"type":"RollingUpdate","rollingUpdate":{"partition":0}})
      | drop_if("persistentVolumeClaimRetentionPolicy"; {"whenDeleted":"Retain","whenScaled":"Retain"}))
    | .spec.template |= tidy_template
    | if .spec.volumeClaimTemplates then .spec.volumeClaimTemplates |= map(del(.status, .metadata.creationTimestamp, .apiVersion, .kind) | .spec |= drop_if("volumeMode"; "Filesystem")) else . end
  elif .kind == "DaemonSet" then
    .spec |= (drop_if("revisionHistoryLimit"; 10) | drop_if("updateStrategy"; {"type":"RollingUpdate","rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}))
    | .spec.template |= tidy_template
  elif .kind == "ReplicaSet" or .kind == "ReplicationController" or .kind == "PodTemplate" then
    .spec.template |= tidy_template
  elif .kind == "Job" then
    del(.spec.selector, .spec.manualSelector) | .spec |= (drop_if("completionMode"; "NonIndexed") | drop_if("suspend"; false) | drop_if("podReplacementPolicy"; "TerminatingOrFailed")
      | drop_if("completions"; 1) | drop_if("parallelism"; 1) | drop_if("backoffLimit"; 6))
    | .spec.template |= tidy_template
  elif .kind == "CronJob" then
    .spec |= (drop_if("concurrencyPolicy"; "Allow") | drop_if("suspend"; false) | drop_if("successfulJobsHistoryLimit"; 3) | drop_if("failedJobsHistoryLimit"; 1))
    | .spec.jobTemplate.spec.template |= tidy_template
    | .spec.jobTemplate |= (.metadata |= (tidy_meta | if . == {} then null else . end) | del(.metadata | nulls))
  elif .kind == "Pod" then
    .spec |= (tidy_podspec | del(.nodeName)
      | .volumes |= ((. // []) | map(select(.name | startswith("kube-api-access-") | not)) | if . == [] then null else . end)
      | .containers |= map(.volumeMounts |= ((. // []) | map(select(.name | startswith("kube-api-access-") | not)) | if . == [] then null else . end))
      | .tolerations |= ((. // []) | map(select(.key | IN("node.kubernetes.io/not-ready", "node.kubernetes.io/unreachable") | not)) | if . == [] then null else . end))
    | del(.. | nulls?)
  elif .kind == "Service" then
    .spec |= (if .clusterIP == "None" then . else del(.clusterIP) end | del(.clusterIPs, .ipFamilies, .healthCheckNodePort, .allocateLoadBalancerNodePorts)
      | .ports |= ((. // []) | map(del(.nodePort) | drop_if("protocol"; "TCP")) | if . == [] then null else . end) | del(.ports | nulls)
      | drop_if("externalTrafficPolicy"; "Cluster")
      | drop_if("ipFamilyPolicy"; "SingleStack") | drop_if("internalTrafficPolicy"; "Cluster") | drop_if("sessionAffinity"; "None") | drop_if("type"; "ClusterIP"))
  elif .kind == "PersistentVolumeClaim" then
    del(.spec.volumeName) | .spec |= drop_if("volumeMode"; "Filesystem")
  elif .kind == "ServiceAccount" then
    del(.secrets)
  else . end
EOF

# Endpoints of Services with a selector are generated; only manual ones (selectorless Services) are kept.
SELSVCS=$("${K[@]}" get svc -n "$NS" -o json | jq -c '[.items[] | select(.spec.selector) | .metadata.name]')
# PVCs created from StatefulSet volumeClaimTemplates (<template>-<sts>-<ordinal>) belong to the StatefulSet.
STSPVC=$("${K[@]}" get sts -n "$NS" -o json 2>/dev/null | jq -c '[.items[] | .metadata.name as $s | (.spec.volumeClaimTemplates // [])[] | "\(.metadata.name)-\($s)-"]' || echo '[]')
COUNT=0
for t in $TYPES; do
  JSON=$("${K[@]}" get "$t" -n "$NS" -o json 2>/dev/null) || continue
  [ "$(jq '.items | length' <<<"$JSON")" -gt 0 ] || continue
  OBJS=$(jq -c --arg keepns "$KEEP_NAMESPACE" --argjson selsvcs "$SELSVCS" --argjson stspvc "$STSPVC" "$JQ" <<<"$JSON")
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    KIND=$(jq -r '.kind | ascii_downcase' <<<"$obj")
    NAME=$(jq -r '.metadata.name' <<<"$obj" | tr ':/' '__')
    FILE="$KIND-$NAME.yaml"
    [ -e "$OUT/$FILE" ] && FILE="$KIND-$(tr '.' '-' <<<"$t")-$NAME.yaml"
    yq -P '.' <<<"$obj" > "$OUT/$FILE"
    COUNT=$((COUNT + 1))
    echo "  $t/$NAME"
  done <<<"$OBJS"
done

[ "$COUNT" -gt 0 ] || { echo "No exportable objects in namespace $NS" >&2; rmdir "$OUT" 2>/dev/null || true; exit 1; }

{
  echo "apiVersion: kustomize.config.k8s.io/v1beta1"
  echo "kind: Kustomization"
  echo "resources:"
  (cd "$OUT" && ls -1 *.yaml | grep -vx kustomization.yaml | sed 's/^/  - /')
} > "$OUT/kustomization.yaml"

echo
echo "Exported $COUNT objects from namespace $NS to $OUT"
echo "Check: kubectl kustomize $OUT"
if ls "$OUT"/secret-*.yaml >/dev/null 2>&1; then
  echo "WARNING: $OUT/secret-*.yaml hold plain base64 data. Do not push them to Git, use SealedSecrets or External Secrets instead."
fi
