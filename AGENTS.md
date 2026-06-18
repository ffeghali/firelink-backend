# AGENTS.md

## Project Overview

Firelink Backend is a Python Flask REST API and WebSocket server that provides the backend for
Firelink, a web GUI for Bonfire. It wraps the Bonfire Python library and the Kubernetes Python
client, exposing namespace lifecycle operations (list, reserve, release, describe), application
catalog browsing, app deployment with real-time progress streaming, and cluster/namespace resource
metrics via Prometheus. The backend is deployed as a container on OpenShift, served by Gunicorn with
a gevent worker.

## Dependencies

**Runtime:** Flask, Flask-SocketIO, Flask-CORS, Flask-Caching, crc-bonfire, kubernetes (Python
client), prometheus-api-client, GQL, Gunicorn, gevent, urllib3, multidict

**Dev/Test:** pytest

## Development Commands

See [Development Setup][readme-dev] in the README for the full command reference.

```bash
pipenv install       # Install dependencies
pipenv shell         # Activate virtualenv
make run             # Start Flask dev server on port 5001
make run-proxy       # Start Caddy dev proxy on port 8000
make test            # Run integration tests (requires live cluster)
make requirements    # Regenerate requirements.txt from Pipfile.lock
make build           # Build Docker image
```

CI runs Tekton pipelines (`.tekton/`) that build the container image and run security scans (SAST,
SBOM generation). There is no separate lint or test step in CI — tests require a live OpenShift
cluster and are run manually.

## Architecture

The app is organized as a Flask server (`server.py`) with route handlers delegating to four modules
under `firelink/`: `apps.py` (app catalog and deployment), `openshift_resources.py` (Kubernetes API
wrappers for nodes, namespaces, and reservations), `metrics.py` (Prometheus query classes for
cluster, pod, and namespace metrics), and `flask_app_helpers.py` (OpenShift login, health check,
GraphQL client initialization).

See [ARCHITECTURE.md][architecture] for the full API endpoint catalog, WebSocket protocol, module
details, environment variables, and design decisions.

## Code Style

- No linter or formatter is configured in the repository
- Python >= 3.11
- Classes follow an adaptor pattern: `Apps` and `Namespace` accept a `jsonify` callable for
  dependency injection, defaulting to a no-op lambda for testing
- Prometheus queries are organized into separate query classes (`ClusterQueries`, `PodQueries`,
  `MemoryQueries`, `CPUQueries`) consumed by metrics handler classes

## Common Mistakes

- **Bonfire private API coupling.** The backend calls Bonfire's internal functions directly
  (`bonfire._process`, `bonfire._get_namespace`, `bonfire._get_apps_config`). These are prefixed
  with an underscore because they are private — their signatures can change between Bonfire
  releases without notice. Any Bonfire version upgrade must be verified against the call sites in
  `apps.py` and `openshift_resources.py`.
- **requirements.txt drift.** The container build uses `requirements.txt`, not the Pipfile. Adding
  dependencies via `pipenv install` without running `make requirements` will cause them to be
  missing in the Docker image. This is the most common source of "works locally, breaks in
  container" issues.
- **Dev port mismatch.** The Makefile starts Flask on port 5001 (`make run`), and the Caddy dev
  proxy (`proxy/Caddyfile`) routes to port 5001. The `server.py` default port constant is 5000
  (used only when run directly via `socketio.run`). If you change the Flask port in the Makefile,
  update `proxy/Caddyfile` to match.
- **Global GraphQL client.** `flask_app_helpers.py` assigns the GQL client to a module-level global
  `_client` via `create_gql_client()`, which runs as a `before_request` handler. This means the
  client is re-created on every request. The global is consumed by Bonfire's qontract module, not
  by the Firelink code directly — do not remove it even though it appears unused in this codebase.
- **Integration tests require a live cluster.** All tests in `tests/` are integration tests that
  reserve and release real namespaces on an OpenShift cluster. They cannot run in isolation, in CI,
  or without a valid kubecontext. Running them against a cluster with limited namespace capacity
  may cause intermittent failures.

## Testing

```bash
make test
```

Tests use pytest and exercise the full stack against a live OpenShift cluster. Test files:

- `tests/test_apps.py` — App listing and deployment with concurrency tests
- `tests/test_namespaces.py` — Namespace reserve/release/describe lifecycle with concurrency tests

No mocking framework is used — tests call the real Bonfire and Kubernetes APIs.

## Deployment

The app is containerized with a Dockerfile that builds a UBI9 Python 3.11 image with Gunicorn
serving on port 8000. Three OpenShift deployment templates are provided in `deploy/`: a ClowdApp
template (requires Clowder operator), an ephemeral template (inline credentials), and a standard
Deployment + Service template. Tekton pipelines in `.tekton/` build and push images to Quay on
every push to `master`.

[readme-dev]: ./README.md#development-setup
[architecture]: ./ARCHITECTURE.md
