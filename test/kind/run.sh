#!/usr/bin/env bash
# Local end-to-end test on kind (no OpenShift needed). Exercises the same app
# manifests and DatadogAgent spec; the Operator comes from Helm instead of
# OperatorHub.
#
#   export DD_API_KEY=... DD_CLUSTER_NAME=datadog-demo-kind DD_SITE=datadoghq.com
#   ./test/kind/run.sh          # create cluster + deploy
#   ./test/kind/run.sh delete   # delete the cluster
KUBECTL=kubectl
source "$(dirname "$0")/../../scripts/common.sh"
HERE="$REPO_ROOT/test/kind"
CLUSTER=datadog-demo
DD_NAMESPACE=openshift-operators

if [[ "${1:-}" == delete ]]; then kind delete cluster --name "$CLUSTER"; exit 0; fi
validate_dd_settings

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --config "$HERE/kind-config.yaml"
kubectl config use-context "kind-$CLUSTER" >/dev/null

log "Building and loading the catalog image"
docker build -q -t datadog-demo-catalog:dev "$REPO_ROOT/src/catalog" >/dev/null
kind load docker-image datadog-demo-catalog:dev --name "$CLUSTER"

log "Installing the Datadog Operator (Helm)"
helm repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
helm repo update datadog >/dev/null
helm upgrade --install datadog-operator datadog/datadog-operator -n "$DD_NAMESPACE" --create-namespace --wait >/dev/null

ensure_datadog_secret "$DD_NAMESPACE"
kubectl apply -f "$REPO_ROOT/app/namespace.yaml" >/dev/null
kubectl label namespace "$APP_NAMESPACE" pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null
ensure_postgres_secret "$DD_NAMESPACE"

kubectl kustomize "$HERE/datadog" | render_datadog_agent | kubectl apply -f -
wait_for_datadog "$DD_NAMESPACE"
deploy_app "$HERE/app" "$DD_NAMESPACE"
log "Done. Locust UI: kubectl port-forward -n $APP_NAMESPACE svc/load-generator 8089"
