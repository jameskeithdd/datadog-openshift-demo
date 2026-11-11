#!/usr/bin/env bash
# Shows, per demo pod, whether Datadog Single Step Instrumentation injected a
# tracer and which Unified Service Tags it carries.
source "$(dirname "$0")/common.sh"

printf '%-34s %-9s %-18s %s\n' POD READY SERVICE "INJECTED (init containers)"
$KUBECTL get pods -n "$APP_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"|d:"}{.metadata.deletionTimestamp}{"|"}{.status.containerStatuses[0].ready}{"|"}{.metadata.labels.tags\.datadoghq\.com/service}{"|"}{.spec.initContainers[*].name}{"\n"}{end}' \
  | while IFS='|' read -r pod deleting ready svc inits; do
      [[ "$deleting" != "d:" ]] && continue   # terminating
      printf '%-34s %-9s %-18s %s\n' "$pod" "$ready" "${svc:--}" "${inits:--}"
    done
echo
echo "Pods labeled datadog-demo/tracer should list datadog-init-apm-inject and a datadog-lib-<language>-init container."
echo "If they don't, the pod started before the Datadog Cluster Agent was ready. Restart it:"
echo "  $KUBECTL rollout restart deployment -n $APP_NAMESPACE"
