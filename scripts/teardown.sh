#!/usr/bin/env bash
# Removes the demo application and the Datadog Agent.
#   ./scripts/teardown.sh             # app + DatadogAgent; keeps the Operator
#   ./scripts/teardown.sh --operator  # also uninstalls the Datadog Operator
source "$(dirname "$0")/common.sh"
DD_NAMESPACE=openshift-operators

log "Deleting namespace $APP_NAMESPACE"
$KUBECTL delete namespace "$APP_NAMESPACE" --ignore-not-found --wait=true
log "Deleting the DatadogAgent resource and API key Secret"
$KUBECTL delete datadogagent datadog -n "$DD_NAMESPACE" --ignore-not-found
$KUBECTL delete secret datadog-secret datadog-postgres -n "$DD_NAMESPACE" --ignore-not-found

if [[ "${1:-}" == "--operator" ]]; then
  log "Uninstalling the Datadog Operator"
  csv="$($KUBECTL get subscription datadog-operator-certified -n "$DD_NAMESPACE" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  $KUBECTL delete subscription datadog-operator-certified -n "$DD_NAMESPACE" --ignore-not-found
  [[ -n "$csv" ]] && $KUBECTL delete csv "$csv" -n "$DD_NAMESPACE" --ignore-not-found
fi
log "Done."
