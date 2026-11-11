# Datadog on OpenShift: microservices demo

A ready-to-run microservices storefront for OpenShift, fully observed by Datadog:

- **Datadog Agent**, managed by the Red Hat-certified **Datadog Operator** from OperatorHub
- **Datadog Single Step Instrumentation (SSI)**: the Datadog tracer is added to each service when its
  pod starts. No image rebuilds, no code changes, no tracing libraries to install.
- **Database Monitoring**, logs, profiles, and OpenShift infrastructure, all correlated by
  Unified Service Tagging

Everything you need to go from an empty OpenShift cluster to data in Datadog is in this repository.

## What gets deployed

```
                      ┌──────────────┐
  load-generator ───▶ │   frontend   │ ──▶ ad (Java)
  (Locust)            │  (Node.js)   │ ──▶ recommendation (Python) ──┐
                      └──────┬───────┘                               ▼
                             └─────────────────────────────▶ catalog (Python) ──▶ PostgreSQL
                                                                     │
                          ad, recommendation, catalog ──────────▶ flagd (feature flags)
```

| Service | Language | Datadog |
|---|---|---|
| frontend | Node.js | APM via SSI (dd-trace-js), profiling, logs |
| ad | Java | APM via SSI (dd-java-agent), profiling, JVM metrics, logs |
| recommendation | Python | APM via SSI (ddtrace), profiling, logs |
| catalog | Python ([`src/catalog`](src/catalog)) | APM via SSI (ddtrace), profiling, logs, linked to Database Monitoring |
| postgresql | — | Postgres integration + Database Monitoring |
| flagd | — | Logs, container metrics |
| load-generator | Python (Locust) | Logs. Generates the traffic; traces start at `frontend` (see note) |

The application services are public prebuilt images (frontend, ad and recommendation come from an
open-source demo, see [NOTICE](NOTICE)), deployed unmodified. The manifests in [`app/`](app) switch
off the tracing library those images ship with, so the Datadog tracer is the only one running.

**What you get in Datadog:** APM traces and service map, Continuous Profiler, runtime metrics,
logs correlated with traces, Database Monitoring (query metrics, samples, explain plans, locks, all
linked to the calling traces), OpenShift infrastructure and Orchestrator Explorer, live containers
and processes, and Kubernetes events.

**Scope:** the storefront's browse, recommendation and ads paths are included; cart, checkout and
currency are not, so the browser UI loads but is partial. The load generator drives all the traffic.
It isn't traced itself, because the Datadog Python tracer and Locust's gevent runtime deadlock at
startup; its logs are collected.

## Prerequisites

- OpenShift 4.12 or later, with access to OperatorHub (`certified-operators` catalog)
- `cluster-admin` (installing an Operator and the Agent DaemonSet require it)
- `oc` CLI logged in to the cluster, `openssl`, `bash`
- Outbound internet access from the cluster to:
  - `registry.datadoghq.com` (Datadog Agent and tracer images)
  - `registry.connect.redhat.com` (the certified Datadog Operator image; OpenShift's default pull secret covers it)
  - `ghcr.io` and `docker.io` (application images)
  - your Datadog site's intake endpoints (see [Network traffic](https://docs.datadoghq.com/agent/configuration/network/))

  Images on `docker.io` (`postgres`, `locust`) are pulled anonymously, which Docker Hub rate-limits per
  IP address. On clusters that share an egress IP, mirror them into your own registry and change
  `image:` in [`app/infrastructure.yaml`](app/infrastructure.yaml) and [`app/services.yaml`](app/services.yaml).
- A Datadog [API key](https://app.datadoghq.com/organization-settings/api-keys) and your
  [Datadog site](https://docs.datadoghq.com/getting_started/site/) (e.g. `datadoghq.com`, `datadoghq.eu`, `us3.datadoghq.com`)
- Capacity: about 2 vCPU and 3 GiB of memory across worker nodes, plus one Agent per node

## Quick start

```bash
git clone https://github.com/jameskeithdd/datadog-openshift-demo.git
cd datadog-openshift-demo

oc login ...                                   # as a cluster-admin

export DD_API_KEY=<your-datadog-api-key>       # only needed on the first run
export DD_SITE=datadoghq.com                   # your Datadog site
export DD_CLUSTER_NAME=my-openshift            # how the cluster appears in Datadog

./scripts/deploy.sh
```

`deploy.sh` is idempotent and takes 5–10 minutes the first time. It:

1. Installs the Datadog Operator from OperatorHub ([`datadog/operator-subscription.yaml`](datadog/operator-subscription.yaml))
   into `openshift-operators`, if it isn't installed already.
2. Creates the `datadog-secret` Secret from `DD_API_KEY` (passed on stdin, never written to disk),
   and a `postgres-credentials` Secret with randomly generated passwords.
3. Deploys the Datadog Agent ([`datadog/datadog-agent.yaml`](datadog/datadog-agent.yaml)) and waits for it.
   The Agent has to be running before the app starts, because SSI injects tracers when a pod is created.
4. Deploys the demo into the `datadog-demo` namespace, plus a Route for the storefront.

After that, run `unset DD_API_KEY`, then check that every app pod got a tracer:

```bash
./scripts/verify.sh
```

Each pod labeled with a tracer should list `datadog-init-apm-inject` and `datadog-lib-<language>-init`
init containers. Data shows up in Datadog within a few minutes. Filter on `env:datadog-demo`:

- **APM → Software Catalog / Service Map**: frontend, ad, recommendation, catalog
- **Database Monitoring**: the `postgresql` host, with query samples linked to `catalog` traces
- **Infrastructure → Kubernetes**: cluster `$DD_CLUSTER_NAME`
- **Logs**: `env:datadog-demo`, with "View Trace" on correlated log lines

<details>
<summary>Prefer the OpenShift web console for the Operator?</summary>

Go to **Operators → OperatorHub**, search for **Datadog Operator** (the *Certified* one), and install it with
the defaults (channel `stable`, all namespaces, `openshift-operators`). Then run `./scripts/deploy.sh`.
It detects the existing Operator and skips step 1.
</details>

<details>
<summary>Prefer to create the API key Secret yourself?</summary>

```bash
oc create secret generic datadog-secret -n openshift-operators --from-literal=api-key=<your-datadog-api-key>
```

`deploy.sh` uses an existing `datadog-secret` and doesn't need `DD_API_KEY` set.
</details>

## Failure scenarios

The services read feature flags from flagd. Toggle them with `scripts/flag.sh`. Changes take effect
in about 1–2 minutes.

```bash
./scripts/flag.sh                     # list flags and their state
./scripts/flag.sh adFailure on
./scripts/flag.sh adFailure off
```

| Flag | Effect | Where to look in Datadog |
|---|---|---|
| `adFailure` | ~10% of `GetAds` calls fail with `UNAVAILABLE` | APM error rate on `ad`, error traces from `frontend` |
| `adHighCpu` | ad burns CPU on every request | Latency on `ad`, Continuous Profiler CPU hotspots, container CPU |
| `adManualGc` | ad runs full garbage collections | JVM runtime metrics (GC pauses), latency spikes |
| `recommendationCacheFailure` | recommendation leaks memory through a broken cache | Container memory growth on `recommendation`, latency, eventual OOM restart |
| `productCatalogFailure` | `GetProduct` fails for product `OLJCESPC7Z` | Errors on `catalog`, propagating to `frontend` |
| `productCatalogLockContention` | catalog holds an exclusive table lock for 30 s at a time | Database Monitoring lock waits and blocking queries, slow `catalog` spans |

## Configuration

| What | Where |
|---|---|
| Load (number of simulated users) | `LOCUST_USERS` in [`app/services.yaml`](app/services.yaml), or live in the Locust UI: `oc port-forward -n datadog-demo svc/load-generator 8089`, then open http://localhost:8089 |
| Datadog features (APM, logs, processes, etc.) | [`datadog/datadog-agent.yaml`](datadog/datadog-agent.yaml). Re-apply with `./scripts/deploy.sh` |
| Tracer versions and tracer settings | `features.apm.instrumentation.targets` in the same file |
| Environment / service / version tags | `tags.datadoghq.com/*` pod labels in [`app/`](app) |

Network Performance Monitoring and Universal Service Monitoring are not enabled, because they need
the privileged system-probe. To add them, set `features.npm.enabled: true` and/or
`features.usm.enabled: true` in the DatadogAgent and re-run `deploy.sh`.

### OpenShift specifics, and why

- **The Agent runs in `openshift-operators`**, the Operator's namespace. The OperatorHub install creates
  the `datadog-agent-scc` ServiceAccount and SecurityContextConstraints there, which the Agent uses.
- **APM uses a hostPort (8126) instead of a Unix socket.** A socket would need hostPath volumes
  in the app pods, which the default `restricted-v2` SCC forbids. App pods run under `restricted-v2`, unmodified.
- **The SSI init containers get a restricted security context**
  (`DD_ADMISSION_CONTROLLER_AUTO_INSTRUMENTATION_INIT_SECURITY_CONTEXT`), so instrumented pods still pass the SCC.
- **The Agent runs with the `spc_t` SELinux type** for container log collection, and `kubelet.tlsVerify: false`
  because of how OpenShift signs kubelet certificates. Both follow
  [Datadog's OpenShift guidance](https://docs.datadoghq.com/containers/kubernetes/distributions/?tab=datadogoperator#openshift).
- **SSI does not instrument the namespace the Agent runs in**, so the demo has its own namespace (`datadog-demo`).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `verify.sh` shows no `datadog-lib-*` init containers | The pods started while the Cluster Agent wasn't ready (for example during an Agent upgrade or config change). The admission webhook fails open, so they ran without a tracer. Wait for `oc rollout status deployment/datadog-cluster-agent -n openshift-operators`, then `oc rollout restart deployment -n datadog-demo` |
| Changed `datadog/datadog-agent.yaml` but the pods don't pick it up | Tracer settings are applied when a pod starts. Re-run `./scripts/deploy.sh`, then restart the app as above |
| Agent pods not starting | `oc get datadogagent datadog -n openshift-operators -o yaml` (see `status`), then `oc describe pod -n openshift-operators -l app.kubernetes.io/component=agent` |
| No data in Datadog | Check the API key and site: `oc exec -n openshift-operators ds/datadog-agent -c agent -- agent status`, under "API Keys status" |
| `catalog` stuck in `ImagePullBackOff` | The cluster can't reach `ghcr.io`, or the image isn't public. See [Building the catalog image](#building-the-catalog-image) |
| No Database Monitoring data | `oc exec -n openshift-operators ds/datadog-agent -c agent -- agent status`, under "postgres". The check runs on the Agent on the same node as the `postgresql` pod |

## Clean up

```bash
./scripts/teardown.sh              # removes the demo and the Datadog Agent; keeps the Operator
./scripts/teardown.sh --operator   # also uninstalls the Datadog Operator
```

## Building the catalog image

The `catalog` image is built by [GitHub Actions](.github/workflows/catalog-image.yaml) and published to
`ghcr.io/jameskeithdd/datadog-openshift-demo/catalog`. To use your own registry instead:

```bash
docker build -t <registry>/catalog:1.0.0 src/catalog && docker push <registry>/catalog:1.0.0
# then change images[].newName in app/kustomization.yaml
```

If you can't use an external registry, build it inside OpenShift:

```bash
oc new-build --name catalog --strategy docker --binary -n datadog-demo
oc start-build catalog --from-dir src/catalog --follow -n datadog-demo
# then set images[].newName in app/kustomization.yaml to
# image-registry.openshift-image-registry.svc:5000/datadog-demo/catalog and newTag to latest
```

## How this was tested

**On OpenShift (MicroShift 4.22, OKD build).** [`test/microshift/run.sh`](test/microshift/run.sh) runs the
unchanged `scripts/deploy.sh` with `oc` against OpenShift's kube-apiserver, SCC admission, router and OLM,
on CentOS Stream 10 with SELinux enforcing and firewalld on. Verified:

- The certified `datadog/operator-subscription.yaml` validates against OLM, and OLM installs Datadog
  Operator 1.31.2 (same bundle as the certified one; `datadog-agent-scc` can use the `privileged` and
  `hostaccess` SCCs).
- The Agent runs under the `privileged` SCC; every app pod, including the tracer init containers that SSI
  injects, is admitted under `restricted-v2` with an OpenShift-assigned UID.
- Traces (port 8126) and OTLP logs (port 4317) reach the node Agent from app pods through firewalld.
  Container logs are collected under SELinux enforcing. Database Monitoring and the failure flags work.
- The storefront answers through the OpenShift router on the edge-TLS Route, with HTTP redirected to HTTPS.

MicroShift has no certified-operators catalog, so the test installs the identical bundle from OperatorHub.io.
On Apple Silicon it runs Kindnet networking (OKD has no ARM build of OVN-Kubernetes); the app's
pod-to-node traffic over OVN-Kubernetes, the default on OpenShift, is the one path not exercised.

```bash
export DD_API_KEY=... DD_SITE=datadoghq.com DD_CLUSTER_NAME=my-microshift
./test/microshift/run.sh
```

**On Kubernetes (kind).** [`test/kind/run.sh`](test/kind/run.sh) runs the same manifests on a local
[kind](https://kind.sigs.k8s.io) cluster with the Operator from Helm, enforcing Pod Security `restricted`
and an arbitrary UID in group 0 for every pod.

```bash
export DD_API_KEY=... DD_SITE=datadoghq.com DD_CLUSTER_NAME=datadog-demo-kind
./test/kind/run.sh
./test/kind/run.sh delete
```

## Repository layout

```
datadog/                 Datadog Operator Subscription and DatadogAgent (OpenShift)
app/                     Demo application (Kustomize): services, PostgreSQL, flagd, Routes
app/config/              flagd flags, database seed + Datadog DBM user, Locust scenario
src/catalog/             Product catalog service (Python, gRPC)
scripts/                 deploy, verify, flag, teardown
test/                    End-to-end tests: MicroShift (OpenShift) and kind
```

## License

Apache License 2.0. Includes material from an open-source upstream project; see [NOTICE](NOTICE).
