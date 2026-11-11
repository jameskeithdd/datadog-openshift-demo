#!/usr/bin/env bash
# End-to-end test on upstream MicroShift (OpenShift's kube-apiserver with SCC
# admission, Routes, OLM; https://github.com/microshift-io/microshift), for
# when no full OpenShift cluster is at hand.
#
# Installs the Datadog Operator through OLM from the OperatorHub.io catalog
# (MicroShift has no Red Hat certified catalog), validates the certified
# Subscription against the cluster's OLM API, then runs the regular
# scripts/deploy.sh unchanged.
#
#   export DD_CLUSTER_NAME=... DD_SITE=...   # and DD_API_KEY on the first run
#   ./test/microshift/run.sh
source "$(dirname "$0")/../../scripts/common.sh"
HERE="$REPO_ROOT/test/microshift"
DD_NAMESPACE=openshift-operators

log "Validating datadog/operator-subscription.yaml against the cluster's OLM API"
$KUBECTL apply --dry-run=server --validate=strict -f "$REPO_ROOT/datadog/operator-subscription.yaml"

if ! $KUBECTL get crd datadogagents.datadoghq.com >/dev/null 2>&1; then
  log "Installing the Datadog Operator through OLM (OperatorHub.io catalog)"
  $KUBECTL apply -f "$HERE/operator-community.yaml"
  for _ in $(seq 1 60); do
    $KUBECTL get crd datadogagents.datadoghq.com >/dev/null 2>&1 && break
    sleep 10
  done
fi
$KUBECTL get csv -n "$DD_NAMESPACE"

exec "$REPO_ROOT/scripts/deploy.sh"
