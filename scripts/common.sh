# Shared helpers for the scripts in this directory. Source, don't execute.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAMESPACE=datadog-demo

if [[ -z "${KUBECTL:-}" ]]; then
  if command -v oc >/dev/null 2>&1; then KUBECTL=oc; else KUBECTL=kubectl; fi
fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Fill the ${DD_CLUSTER_NAME} / ${DD_SITE} placeholders in a manifest stream.
render_datadog_agent() {
  sed -e "s|\${DD_CLUSTER_NAME}|${DD_CLUSTER_NAME}|g" -e "s|\${DD_SITE}|${DD_SITE}|g"
}

validate_dd_settings() {
  [[ -n "${DD_CLUSTER_NAME:-}" ]] || die "Set DD_CLUSTER_NAME (e.g. export DD_CLUSTER_NAME=my-openshift)"
  [[ "$DD_CLUSTER_NAME" =~ ^[a-z0-9]([a-z0-9.-]{0,78}[a-z0-9])?$ ]] \
    || die "DD_CLUSTER_NAME must be lowercase letters, digits, dots and dashes"
  DD_SITE="${DD_SITE:-datadoghq.com}"
  [[ "$DD_SITE" =~ ^[a-z0-9.]+$ ]] || die "DD_SITE looks wrong: $DD_SITE (e.g. datadoghq.com, datadoghq.eu, us3.datadoghq.com)"
}

# Create the Datadog API key Secret from $DD_API_KEY if it does not exist yet.
# The key is passed on stdin so it never appears in process arguments.
ensure_datadog_secret() {
  local ns=$1
  if $KUBECTL get secret datadog-secret -n "$ns" >/dev/null 2>&1; then
    log "Secret $ns/datadog-secret already exists"
    return
  fi
  [[ -n "${DD_API_KEY:-}" ]] || die "No Secret $ns/datadog-secret. Export DD_API_KEY, or create it yourself:
    $KUBECTL create secret generic datadog-secret -n $ns --from-literal=api-key=<YOUR_API_KEY>"
  printf '%s' "$DD_API_KEY" | $KUBECTL create secret generic datadog-secret -n "$ns" --from-file=api-key=/dev/stdin >/dev/null
  log "Created Secret $ns/datadog-secret"
}

# Random per-install database passwords (only on first deploy), plus a copy
# of the Datadog monitoring user's password in the Agent's namespace for the
# Postgres check. Passwords move between commands on stdin only.
ensure_postgres_secret() {
  local dd_ns=$1
  if $KUBECTL get secret postgres-credentials -n "$APP_NAMESPACE" >/dev/null 2>&1; then
    log "Secret $APP_NAMESPACE/postgres-credentials already exists"
  else
    $KUBECTL create secret generic postgres-credentials -n "$APP_NAMESPACE" \
      --from-literal=postgres-password="$(openssl rand -hex 16)" \
      --from-literal=app-password="$(openssl rand -hex 16)" \
      --from-literal=datadog-password="$(openssl rand -hex 16)" >/dev/null
    log "Created Secret $APP_NAMESPACE/postgres-credentials with generated passwords"
  fi
  if ! $KUBECTL get secret datadog-postgres -n "$dd_ns" >/dev/null 2>&1; then
    $KUBECTL get secret postgres-credentials -n "$APP_NAMESPACE" -o jsonpath='{.data.datadog-password}' \
      | base64 -d \
      | $KUBECTL create secret generic datadog-postgres -n "$dd_ns" --from-file=password=/dev/stdin >/dev/null
    log "Created Secret $dd_ns/datadog-postgres for the Agent's Postgres check"
  fi
}

wait_for_datadog() {
  local ns=$1
  log "Waiting for the Datadog Cluster Agent and node Agents in $ns"
  # Give the Operator a moment to roll out any change to the DatadogAgent.
  sleep 15
  until $KUBECTL get deployment datadog-cluster-agent -n "$ns" >/dev/null 2>&1; do sleep 5; done
  $KUBECTL rollout status deployment/datadog-cluster-agent -n "$ns" --timeout=10m
  until $KUBECTL get daemonset datadog-agent -n "$ns" >/dev/null 2>&1; do sleep 5; done
  $KUBECTL rollout status daemonset/datadog-agent -n "$ns" --timeout=10m
}

APP_DEPLOYMENTS="postgresql flagd catalog ad recommendation frontend load-generator"

# Deployments whose running pods should carry the Datadog tracer but don't.
uninstrumented_deployments() {
  $KUBECTL get pods -n "$APP_NAMESPACE" -l datadog-demo/tracer \
    -o jsonpath='{range .items[*]}{.metadata.labels.app\.kubernetes\.io/name}{"|d:"}{.metadata.deletionTimestamp}{"|"}{.spec.initContainers[*].name}{"\n"}{end}' \
    | while IFS='|' read -r app deleting inits; do
        if [[ "$deleting" == "d:" && "$inits" != *datadog-init-apm-inject* ]]; then echo "$app"; fi
      done | sort -u
}

# Called after wait_for_datadog: app pods must start after the SSI admission
# webhook is live, or they come up without a tracer (the webhook fails open).
# Any pod that slipped through, for example while the Cluster Agent was
# restarting, is restarted once.
deploy_app() {
  local kustomize_dir=$1 dd_ns=$2 missing
  log "Deploying the demo application to $APP_NAMESPACE"
  $KUBECTL apply -k "$kustomize_dir"
  for d in $APP_DEPLOYMENTS; do
    $KUBECTL rollout status "deployment/$d" -n "$APP_NAMESPACE" --timeout=10m
  done

  missing="$(uninstrumented_deployments)"
  if [[ -n "$missing" ]]; then
    warn "Started without the Datadog tracer: $(echo $missing). Restarting them."
    $KUBECTL rollout status deployment/datadog-cluster-agent -n "$dd_ns" --timeout=10m
    for d in $missing; do
      $KUBECTL rollout restart "deployment/$d" -n "$APP_NAMESPACE"
      $KUBECTL rollout status "deployment/$d" -n "$APP_NAMESPACE" --timeout=10m
    done
    missing="$(uninstrumented_deployments)"
    [[ -z "$missing" ]] || die "Still no Datadog tracer in: $(echo $missing). Check the Cluster Agent: $KUBECTL logs -n $dd_ns deploy/datadog-cluster-agent"
  fi
  log "Datadog tracer present in every instrumented service"
}
