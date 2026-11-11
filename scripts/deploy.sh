#!/usr/bin/env bash
# Deploys the Datadog Operator, the Datadog Agent and the demo application to
# an OpenShift cluster. Safe to re-run.
#
#   export DD_API_KEY=<your API key>     # only needed the first time
#   export DD_CLUSTER_NAME=my-openshift
#   export DD_SITE=datadoghq.com         # your Datadog site, default datadoghq.com
#   ./scripts/deploy.sh
source "$(dirname "$0")/common.sh"

DD_NAMESPACE=openshift-operators

command -v openssl >/dev/null || die "openssl is required"
$KUBECTL whoami >/dev/null 2>&1 || $KUBECTL auth can-i '*' '*' -A >/dev/null 2>&1 \
  || die "Not logged in to a cluster (run: oc login ...)"
$KUBECTL api-resources --api-group=route.openshift.io -o name 2>/dev/null | grep -q routes \
  || die "This doesn't look like OpenShift (no Route API). For other clusters see test/kind/."
validate_dd_settings

# 1. Datadog Operator (OperatorHub / OLM)
if ! $KUBECTL get crd datadogagents.datadoghq.com >/dev/null 2>&1; then
  log "Installing the Datadog Operator from OperatorHub"
  $KUBECTL apply -f "$REPO_ROOT/datadog/operator-subscription.yaml"
  log "Waiting for the Operator install to finish (a few minutes)"
  for _ in $(seq 1 60); do
    $KUBECTL get crd datadogagents.datadoghq.com >/dev/null 2>&1 && break
    sleep 10
  done
  if ! $KUBECTL get crd datadogagents.datadoghq.com >/dev/null 2>&1; then
    $KUBECTL get subscription datadog-operator-certified -n "$DD_NAMESPACE" \
      -o jsonpath='{range .status.conditions[*]}  {.type}: {.message}{"\n"}{end}' >&2 || true
    die "The Datadog Operator didn't install within 10 minutes (Subscription status above).
    Check that the certified-operators catalog is available: $KUBECTL get catalogsource -n openshift-marketplace"
  fi
fi
$KUBECTL wait --for=condition=Established crd/datadogagents.datadoghq.com --timeout=5m >/dev/null
for _ in $(seq 1 30); do
  $KUBECTL get deployment -n "$DD_NAMESPACE" -l app.kubernetes.io/name=datadog-operator -o name 2>/dev/null | grep -q . && break
  sleep 10
done
$KUBECTL get deployment -n "$DD_NAMESPACE" -l app.kubernetes.io/name=datadog-operator -o name | grep -q . \
  || die "The Datadog Operator CRDs exist but its Deployment isn't in $DD_NAMESPACE. The Agent must run in the Operator's namespace; see README."
$KUBECTL rollout status -n "$DD_NAMESPACE" \
  "$($KUBECTL get deployment -n "$DD_NAMESPACE" -l app.kubernetes.io/name=datadog-operator -o name | head -1)" --timeout=5m

# 2. Secrets
ensure_datadog_secret "$DD_NAMESPACE"
$KUBECTL apply -f "$REPO_ROOT/app/namespace.yaml" >/dev/null
ensure_postgres_secret "$DD_NAMESPACE"

# 3. Datadog Agent (must be running before the app, so SSI can inject tracers)
log "Applying the DatadogAgent resource (cluster: $DD_CLUSTER_NAME, site: $DD_SITE)"
render_datadog_agent < "$REPO_ROOT/datadog/datadog-agent.yaml" | $KUBECTL apply -f -
wait_for_datadog "$DD_NAMESPACE"

# 4. Application + Routes
deploy_app "$REPO_ROOT/app" "$DD_NAMESPACE"
$KUBECTL apply -f "$REPO_ROOT/app/routes.yaml"

log "Done."
for r in frontend; do
  printf '  %-15s https://%s\n' "$r" "$($KUBECTL get route "$r" -n "$APP_NAMESPACE" -o jsonpath='{.spec.host}')"
done
echo "  Load generator UI:      $KUBECTL port-forward -n $APP_NAMESPACE svc/load-generator 8089  (then http://localhost:8089)"
echo "  Check tracer injection: ./scripts/verify.sh"
