#!/usr/bin/env bash
# Turns a demo failure scenario on or off.
#
#   ./scripts/flag.sh                      # list flags and their state
#   ./scripts/flag.sh adFailure on
#   ./scripts/flag.sh adFailure off
#
# flagd re-reads its ConfigMap-mounted file; expect up to ~60-90s before the
# change takes effect (kubelet ConfigMap sync).
source "$(dirname "$0")/common.sh"

FLAGS=(adFailure adHighCpu adManualGc recommendationCacheFailure productCatalogFailure productCatalogLockContention)
current="$($KUBECTL get configmap flagd-config -n "$APP_NAMESPACE" -o jsonpath='{.data.demo\.flagd\.json}')"

if [[ $# -eq 0 ]]; then
  for f in "${FLAGS[@]}"; do
    state="$(printf '%s\n' "$current" | sed -nE "/\"$f\": \{/,/defaultVariant/ s/.*\"defaultVariant\": \"(on|off)\".*/\1/p")"
    printf '%-30s %s\n' "$f" "$state"
  done
  exit 0
fi

[[ $# -eq 2 ]] || die "usage: $0 [<flag> <on|off>]"
flag=$1 state=$2
[[ " ${FLAGS[*]} " == *" $flag "* ]] || die "unknown flag '$flag'. One of: ${FLAGS[*]}"
[[ "$state" == on || "$state" == off ]] || die "state must be 'on' or 'off'"

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$current" \
  | sed -E "/\"$flag\": \{/,/defaultVariant/ s/\"defaultVariant\": \"(on|off)\"/\"defaultVariant\": \"$state\"/" > "$tmp"
$KUBECTL create configmap flagd-config -n "$APP_NAMESPACE" --from-file=demo.flagd.json="$tmp" \
  --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
log "$flag -> $state (flagd picks it up within ~1-2 minutes)"
