# UBI9 Python 3.12
FROM registry.access.redhat.com/ubi9/python-312:latest

USER 0

# Keep tools minimal; don't install python3/python3-pip (pulls 3.9)
RUN dnf -y install dnf-plugins-core && dnf clean all

# (Optional) oc CLI — if truly needed
RUN curl -sSL "https://github.com/openshift/origin/releases/download/v3.11.0/openshift-origin-client-tools-v3.11.0-0cbc58b-linux-64bit.tar.gz" \
      -o /tmp/oc.tar.gz \
 && tar zxf /tmp/oc.tar.gz -C /tmp/ \
 && mv /tmp/openshift-origin-client-tools-v3.11.0-0cbc58b-linux-64bit/oc /usr/bin/ \
 && rm -rf /tmp/oc.tar.gz /tmp/openshift-origin-client-tools-v3.11.0-0cbc58b-linux-64bit

# App dir per UBI convention
ENV APP_ROOT=/opt/app-root \
    APP_SRC=/opt/app-root/src \
    HOME=/opt/app-root

RUN mkdir -p $APP_SRC \
 && chgrp -R 0 $APP_ROOT \
 && chmod -R g+rwX $APP_ROOT

WORKDIR $APP_SRC

# Install deps with the correct interpreter
COPY requirements.txt .
RUN /usr/bin/python3.12 -m pip install -U pip setuptools wheel \
 && /usr/bin/python3.12 -m pip install --no-cache-dir -r requirements.txt

# Copy source
COPY . .

# Ensure everything is group-writable for arbitrary UID in GID 0
RUN chgrp -R 0 $APP_ROOT \
 && chmod -R g+rwX $APP_ROOT

# Run as non-root, arbitrary UID (OpenShift may override this anyway)
USER 1001

# App env
ENV FLASK_APP="server.py" \
    FLASK_RUN_HOST="0.0.0.0" \
    FLASK_RUN_PORT="8000" \
    KUBECONFIG="$HOME/.kube/config" \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

EXPOSE 8000

CMD ["gunicorn", "-k", "gevent", "-w", "1", "-b", ":8000", "server:app"]