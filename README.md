# Firelink Backend

Backend REST API and WebSocket server for the Firelink project: a web GUI for [Bonfire][bonfire].
See the [Firelink frontend][firelink-frontend] for the other half of this app.

Firelink enables developers to manage ephemeral environment namespaces on an OpenShift cluster —
reserving and releasing namespaces, browsing and deploying applications, monitoring cluster and
namespace resource usage, and querying per-pod metrics. The backend wraps the Bonfire Python library
and the Kubernetes Python client, exposing these operations as REST endpoints and WebSocket events.

## Prerequisites

- Python >= 3.11
- pipenv
- Access to an OpenShift cluster (or a local kubecontext)
- A Prometheus instance accessible from the backend (for metrics endpoints)

## Configuration

Set your OpenShift token and server via environment variables before starting the app:

```bash
export OC_TOKEN="sha256~DEADBEEFDEADBEEFDEADBEEFDEADBEEF"
export OC_SERVER="https://api.secretlab.company.com:6443"
export PROMETHEUS_URL="https://metrics.company.com"
```

If `OC_TOKEN` and `OC_SERVER` are not set, the backend will assume you are already logged in with a
local kubecontext and will not attempt an OpenShift login.

## Development Setup

```bash
pipenv install
pipenv shell
make run
```

The Flask dev server will start on port 5001.

To work on both the frontend and backend at the same time, start the dev proxy that routes requests
between them. You will need [Caddy][caddy] installed:

```bash
make run-proxy
```

The dev proxy runs on port 8000 and routes `/api/*` to the backend (port 5001) and everything else
to the [frontend][firelink-frontend] dev server (port 3000).

### Running Tests

```bash
make test
```

Tests are integration tests that run against a live OpenShift cluster. They exercise namespace
reservation/release, app listing, deployment, and concurrency scenarios. A valid kubecontext is
required.

### Dependency Management

This project uses pipenv for dependency management. The container build uses a plain
`requirements.txt` file instead. If you add new dependencies, regenerate it:

```bash
make requirements
```

## Building

```bash
docker build -t firelink-backend:latest .
docker run --net=host -e OC_TOKEN -e OC_SERVER -p 8000:8000 firelink-backend:latest
```

The Dockerfile builds a UBI9 Python 3.11 image with Gunicorn serving on port 8000. The image is
rootless and runs on OpenShift.

## Deploying

### ClowdApp

Deploy to an OpenShift namespace running the [Clowder][clowder] operator with the provided
template. The namespace must have the credentials in a Secret:

```bash
oc process -f deploy/clowdapp.yaml \
  -p IMAGE="quay.io/rh_ee_addrew/firelink-backend" \
  -p IMAGE_TAG="latest" \
  -p ENV_NAME="env-ephemeral-arficv" \
  | oc apply -n ephemeral-arficv -f -
```

To supply credentials at the command line (e.g., in an ephemeral environment), use the ephemeral
template instead:

```bash
oc process -f deploy/ephemeral.yaml \
  -p OC_TOKEN=$TOKEN \
  -p OC_SERVER=$SERVER \
  -p IMAGE="quay.io/rh_ee_addrew/firelink-backend" \
  -p IMAGE_TAG="latest" \
  -p ENV_NAME="env-ephemeral-arficv" \
  | oc apply -n ephemeral-arficv -f -
```

### OpenShift Template

Deploy without Clowder using the standard template:

```bash
oc process -f deploy/template.yaml \
  -p OC_TOKEN=$OC_TOKEN \
  -p OC_SERVER=$OC_SERVER \
  -p IMAGE="quay.io/rh_ee_addrew/firelink-backend" \
  -p IMAGE_TAG="latest" \
  | oc apply -n $NS -f -
```

## Architecture

For details on the internal design, module structure, API endpoint catalog, WebSocket protocol, and
deployment pipeline, see the [architecture documentation][architecture].

## License

This project is licensed under the MIT License. See [LICENSE][license] for details.

[bonfire]: https://github.com/RedHatInsights/bonfire
[firelink-frontend]: https://github.com/RedHatInsights/firelink-frontend
[clowder]: https://github.com/RedHatInsights/clowder
[caddy]: https://caddyserver.com/
[architecture]: ./ARCHITECTURE.md
[license]: ./LICENSE
