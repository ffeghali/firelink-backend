# Architecture

## System Overview

Firelink Backend is a Python REST API and WebSocket server that provides the backend for
[Firelink][firelink-frontend], a web GUI for [Bonfire][bonfire]. The server wraps the Bonfire Python
library and the Kubernetes Python client, exposing namespace lifecycle operations (list, reserve,
release, describe), application catalog browsing, app deployment, and cluster/namespace resource
metrics as HTTP endpoints and WebSocket events.

The backend is deployed as a container on OpenShift, served by Gunicorn with a gevent worker. It
communicates directly with the OpenShift API (via the `oc` CLI and Kubernetes client), Prometheus
(for metrics), and the app-interface GraphQL API (via Bonfire's qontract module).

### Firelink Ecosystem

```
Browser  -->  OAuth Proxy  -->  Caddy Proxy (firelink-proxy)  -->  Firelink Backend (this repo)  -->  OpenShift / Bonfire
                                          |                                                      -->  Prometheus
                                  Caddy (firelink-frontend, static files only)                   -->  app-interface (GraphQL)
                                          |
                                    React SPA
```

In production, a separate [firelink-proxy][firelink-proxy] component — an OpenShift OAuth Proxy
paired with a Caddy reverse proxy — sits in front of both the frontend and backend. The proxy
handles OAuth authentication and routes `/api/*` requests to this backend. During local development,
a Caddy config in `proxy/Caddyfile` serves the same routing role, forwarding `/api/*` to the Flask
dev server on port 5001 and all other requests to the frontend dev server on port 3000.

The backend has no authentication logic of its own — it trusts the `requester` value the frontend
sends in API request payloads. All access control relies on the OAuth proxy layer.

## Technology Stack

- **Language**: Python >= 3.11
- **Web framework**: Flask
- **WebSocket**: Flask-SocketIO (gevent async mode)
- **CORS**: Flask-CORS
- **Caching**: Flask-Caching (simple in-memory cache)
- **WSGI server**: Gunicorn with gevent worker
- **Kubernetes interaction**: Kubernetes Python client, `oc` CLI (subprocess)
- **Namespace management**: crc-bonfire (Bonfire library)
- **Metrics**: Prometheus API Client
- **GraphQL**: GQL (via Bonfire's qontract module for app-interface queries)
- **Dev proxy**: Caddy
- **CI/CD**: Tekton pipelines via Konflux

## Module Structure

```
server.py                          # Flask app, route definitions, SocketIO event handlers
firelink/
  __init__.py
  apps.py                          # App catalog listing and deployment logic
  openshift_resources.py           # Kubernetes API wrappers: Node, EphemeralResources, Namespace
  metrics.py                       # Prometheus query classes for cluster, pod, and namespace metrics
  flask_app_helpers.py             # OpenShift login, health check, GraphQL client initialization
  adaptor_class_helpers.py         # Route guard (namespace operator availability check)
proxy/
  Caddyfile                        # Dev proxy: routes API to backend, everything else to frontend
tests/
  test_apps.py                     # App listing and deployment integration tests
  test_namespaces.py               # Namespace lifecycle integration tests
deploy/
  clowdapp.yaml                    # Clowder ClowdApp deployment template
  clowdenv.yaml                    # ClowdEnvironment template
  ephemeral.yaml                   # Ephemeral environment template (inline credentials)
  template.yaml                    # Standard OpenShift Deployment + Service template
```

### `server.py` — Application Entry Point

Defines the Flask application, configures CORS, logging, and caching, and registers all HTTP routes
and the SocketIO event handler. Before each request, the app runs two setup functions via
`before_request`: `login_to_openshift()` authenticates against the OpenShift API if `OC_TOKEN` and
`OC_SERVER` environment variables are set, and `create_gql_client()` initializes a GraphQL client
for Bonfire's app-interface queries.

### `firelink/apps.py` — App Catalog and Deployment

The `Apps` class wraps Bonfire's internal `_process` and `_get_apps_config` functions to expose app
listing and deployment as API operations.

- **`list()`** — Queries Bonfire for all deployable applications from the app-interface source,
  generates friendly display names (capitalizing words with vowels, uppercasing acronyms), and
  returns a sorted array of app objects with name, friendly_name, and components.
- **`deploy()`** — Orchestrates the full deployment flow: acquires a namespace via
  `bonfire._get_namespace`, resolves the ClowdEnvironment, processes app templates via
  `bonfire._process`, and applies the configuration via `bonfire.apply_config`. Progress, errors,
  and completion are emitted as SocketIO events (`monitor-deploy-app`, `error-deploy-app`,
  `end-deploy-app`). On failure, the handler optionally releases the namespace if the deployment
  reserved a new one.
- **Telemetry** — Optional Elastic logging controlled by the `ENABLE_TELEMETRY` environment
  variable.

### `firelink/openshift_resources.py` — Kubernetes Resource Wrappers

Three classes provide structured access to OpenShift/Kubernetes resources:

- **`Node`** — Uses the Kubernetes Python client to list cluster nodes with capacity, allocatable
  resources, status, roles, and instance type metadata.
- **`EphemeralResources`** — Queries the Kubernetes API for ephemeral namespaces (filtered by the
  `ephemeral-` prefix, `operator-ns` label, and active phase) and namespace reservations (via the
  `cloud.redhat.com/v1alpha1` CRD).
- **`Namespace`** — High-level namespace lifecycle operations (list, reserve, release, describe)
  that delegate to Bonfire library functions. The `list()` method cross-references namespaces with
  reservations to build a combined view. The `release()` method includes a polling loop (up to 30
  retries at 1-second intervals) to verify the reservation was actually removed. The `describe()`
  method parses Bonfire's text output into structured JSON including Keycloak admin and gateway
  login details.

### `firelink/metrics.py` — Prometheus Metrics

Four query classes (`ClusterQueries`, `PodQueries`, `MemoryQueries`, `CPUQueries`) define PromQL
query templates. Three metrics classes consume them:

- **`PrometheusClusterMetrics`** — Cluster-wide CPU usage ratio, memory usage ratio, and per-node
  capacity/allocatable/usage breakdown. Usage is derived by subtracting allocatable from capacity.
- **`PrometheusPodMetrics`** — Per-pod CPU and memory usage within a namespace, combining two
  queries to produce a unified result. Memory values are converted from bytes to GB.
- **`PrometheusNamespaceMetrics`** — Per-namespace CPU and memory limits, requests, and usage.
  Supports batch queries across multiple namespaces using PromQL regex alternation. CPU values
  handle millicore-to-core conversion; memory values are converted from bytes to MB.

All three metrics classes authenticate to Prometheus using the `OC_TOKEN` bearer token with TLS
verification disabled.

### `firelink/flask_app_helpers.py` — Application Helpers

- **`health()`** — Health check that verifies connectivity to the OpenShift API by running
  `oc whoami` as a subprocess.
- **`login_to_openshift()`** — Performs `oc login` using `OC_TOKEN` and `OC_SERVER` environment
  variables. Falls back to assuming a local kubecontext if the variables are not set.
- **`create_gql_client()`** — Initializes a global GraphQL client via Bonfire's qontract module
  for querying app-interface.

### `firelink/adaptor_class_helpers.py` — Route Guard

The `AdaptorClassHelpers` class provides a `route_guard()` method called at the start of namespace
and app operations. It checks whether the namespace reservation operator is present on the cluster
and raises a Bonfire `FatalError` if not. This prevents operations from silently failing on clusters
without the ephemeral namespace infrastructure.

## API Endpoints

| Method | Path | Handler | Description |
|--------|------|---------|-------------|
| GET | `/health` | `health()` | Health check (OpenShift API connectivity) |
| GET | `/api/firelink/namespace/list` | `namespaces_list()` | List all ephemeral namespaces with reservation status |
| POST | `/api/firelink/namespace/reserve` | `namespace_reserve()` | Reserve an ephemeral namespace |
| POST | `/api/firelink/namespace/release` | `namespace_release()` | Release a namespace reservation |
| GET | `/api/firelink/namespace/describe/<ns>` | `namespace_describe()` | Describe a namespace (routes, logins, deployed apps) |
| GET | `/api/firelink/namespace/resource_metrics` | `namespace_resource_metrics()` | CPU/memory metrics for all reserved namespaces |
| GET | `/api/firelink/namespace/resource_metrics/<ns>` | `namespace_resource_metrics_single()` | CPU/memory metrics for a single namespace |
| POST | `/api/firelink/namespace/top_pods` | `namespace_top_pods()` | Top pods by CPU/memory in a namespace |
| GET | `/api/firelink/apps/list` | `apps_list()` | List deployable applications |
| POST | `/api/firelink/get_template` | `get_template()` | Get processed deployment template for an app |
| GET | `/api/firelink/cluster/top_nodes` | `cluster_top_nodes()` | Per-node capacity and usage metrics |
| GET | `/api/firelink/cluster/cpu_usage` | `cluster_cpu_usage()` | Cluster-wide CPU usage ratio |
| GET | `/api/firelink/cluster/memory_usage` | `cluster_memory_usage()` | Cluster-wide memory usage ratio |

## WebSocket Protocol

WebSocket communication uses socket.io at the path `/api/firelink/socket.io`. The backend listens
for a single event:

- **`deploy-app`** — Receives a deployment options payload and initiates the deployment flow.

During deployment, the server emits three event types back to the client:

- **`monitor-deploy-app`** — Progress updates (`{message, completed, error, namespace?}`)
- **`error-deploy-app`** — Error notifications (`{message, completed, error}`)
- **`end-deploy-app`** — Deployment completion (`{message, completed, error}`)

The SocketIO server is configured with a 600-second ping timeout to accommodate long-running
deployments.

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OC_TOKEN` | No | OpenShift API bearer token. If unset, assumes local kubecontext. |
| `OC_SERVER` | No | OpenShift API server URL. Required if `OC_TOKEN` is set. |
| `PROMETHEUS_URL` | Yes | Prometheus server URL for metrics queries. |
| `PORT` | No | Server port (default: 5000 in dev, 8000 in container). |
| `ENABLE_TELEMETRY` | No | Set to `true` to enable Elastic deployment telemetry logging. |

## Build and Deployment

### Container Image

The `Dockerfile` builds a single-stage image from `registry.access.redhat.com/ubi9/python-311`.
It installs the `oc` CLI for OpenShift API operations, copies `requirements.txt` (generated from
`Pipfile.lock` via `make requirements`), installs Python dependencies, and runs Gunicorn with a
gevent worker on port 8000. The image is rootless (UID 1001) and compatible with OpenShift's
arbitrary UID enforcement.

### Dependency Management

Development uses Pipenv for dependency management. However, the UBI-based container image uses a
plain `requirements.txt` file instead. The `make requirements` target regenerates this file from the
Pipfile lock. Adding new dependencies without regenerating `requirements.txt` will cause them to be
missing in the container build.

### OpenShift Deployment

Three deployment templates in `deploy/` cover different scenarios:

- **`clowdapp.yaml`** — Deploys as a Clowder-managed ClowdApp. Expects cluster credentials in a
  pre-existing Secret. Requires the Clowder operator.
- **`ephemeral.yaml`** — Deploys with inline credentials passed as template parameters. Used for
  ephemeral/testing environments where Secrets are not pre-provisioned.
- **`template.yaml`** — Standard OpenShift Deployment and Service without Clowder. Accepts
  credentials as template parameters.

### CI/CD with Tekton

Tekton pipelines in `.tekton/` automate the build on push to `master` and on pull requests:

- **Pull request pipeline** — Builds the container image, runs security scans (SAST), and generates
  an SBOM. Built images expire after 5 days.
- **Push pipeline** — Same steps as the PR pipeline but produces permanent images pushed to
  `quay.io/redhat-user-workloads/hcm-eng-prod-tenant/firelink/firelink-backend` and applies release
  tags.

## Key Design Decisions

- **Bonfire as the core abstraction.** The backend is a thin REST/WebSocket wrapper around the
  Bonfire Python library. Nearly all namespace and app operations delegate directly to Bonfire
  functions — many of them private (`_process`, `_get_namespace`, `_get_apps_config`). This keeps
  the backend lightweight but creates a tight coupling to Bonfire's internal API surface.
- **Single gevent worker.** Gunicorn runs with one gevent worker (`-w 1`). This is sufficient
  because the server's workload is I/O-bound (Kubernetes API calls, Prometheus queries, WebSocket
  streaming) and gevent's cooperative scheduling handles concurrency within the single worker.
- **No authentication layer.** The backend trusts the `requester` identity sent by the frontend in
  request payloads. Authentication is handled upstream by the OAuth proxy in
  [firelink-proxy][firelink-proxy]. This simplifies the backend but means it must always run behind
  the proxy in production.
- **Prometheus over Kubernetes metrics API.** Resource metrics (CPU, memory, pod usage) are queried
  from Prometheus rather than the Kubernetes Metrics API. This provides richer query capabilities
  (historical data, aggregation, per-namespace batch queries) but requires a Prometheus instance to
  be accessible.
- **Subprocess-based OpenShift login.** The health check and OpenShift login use `oc` CLI subprocess
  calls rather than the Kubernetes Python client's authentication. This aligns with Bonfire's own
  authentication model, which assumes an active `oc` session.
- **Dependency injection via `jsonify`.** The `Namespace` and `Apps` classes accept a `jsonify`
  callable (defaulting to a no-op lambda or `json.dumps`). In production, Flask's `jsonify` is
  injected to produce proper HTTP responses. In tests, omitting the argument returns raw Python
  objects, avoiding the need for a Flask application context during testing.

[bonfire]: https://github.com/RedHatInsights/bonfire
[firelink-frontend]: https://github.com/RedHatInsights/firelink-frontend
[firelink-proxy]: https://github.com/RedHatInsights/firelink-proxy
