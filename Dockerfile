# Build with: podman build --secret id=netrc,src=$HOME/.netrc --ulimit nofile=65535:65535 . -t custom-renovate
# Run with: podman run --rm <additional args> custom-renovate renovate

FROM registry.redhat.io/rust-builder-image/rust-rhel10:latest@sha256:dde68333f8585d7805f456fee4d45a9b0630ad7c880db9a7799ed77efc72f5c7 AS rust

FROM registry.access.redhat.com/ubi10-minimal:latest@sha256:204e1531cee54562b107fb31e0b327062fc3d5d67af7cc0d2e66b2c572b9044f
LABEL description="Mintmaker - Renovate custom image" \
      summary="Mintmaker basic container image - a Renovate custom image" \
      maintainer="EXD Rebuilds Guild <exd-guild-rebuilds@redhat.com >" \
      io.k8s.description="Mintmaker - Renovate custom image" \
      com.redhat.component="mintmaker-renovate-image" \
      distribution-scope="public" \
      release="0.0.1" \
      url="https://github.com/konflux-ci/mintmaker-renovate-image/" \
      vendor="Red Hat, Inc."

# OpenShift preflight check requires licensing files under /licenses
COPY LICENSE /licenses/LICENSE

ARG PNPM_VERSION=11.25.0

# Support multiple Go versions
ENV GOTOOLCHAIN=auto

# Temporary fix for uv's cache dir permissions
ENV UV_NO_CACHE=true

# Using OpenSSL store allows for external modifications of the store. It is needed for the internal Red Hat cert.
ENV NODE_OPTIONS="--use-openssl-ca --max-old-space-size=2816"

ENV LANG=C.UTF-8

RUN microdnf update -y && \
    microdnf install -y \
        dotnet-sdk-10.0 \
        git \
        golang \
        java-21-openjdk-devel \
        krb5-devel \
        libpq-devel \
        nodejs \
        nodejs24 \
        openssl \
        python3-dnf \
        python3.12 \
        python3.12-pip \
        python3.14 \
        skopeo \
        subscription-manager-rhsm-certificates \
        tar \
        unzip \
        which \
        xz \
        zip \
        && \
    microdnf clean all

# Create a shim for NodeJS 24 so it works with tools that simply execute `npm`, e.g. `pnpm`.
RUN \
    mkdir -p /usr/local/node24/bin && \
    ln -sf "$(command -v node-24)" /usr/local/node24/bin/node && \
    ln -sf "$(command -v npm-24)"  /usr/local/node24/bin/npm && \
    ln -sf "$(command -v npx-24)"  /usr/local/node24/bin/npx && \
    chmod -R a+rX /usr/local/node24

WORKDIR /workspace

# Install pnpm - required to install Renovate itself
RUN npm install -g pnpm@${PNPM_VERSION} && npm cache clean --force

# Install python tools
COPY install-python-tool.sh /tmp/python-tools/
COPY tools/hashin/ /tmp/python-tools/hashin/
COPY tools/pip-tools/ /tmp/python-tools/pip-tools/
COPY tools/uv/ /tmp/python-tools/uv/
RUN --mount=type=secret,id=netrc,target=/root/.netrc \
    /tmp/python-tools/install-python-tool.sh /tmp/python-tools/hashin/requirements.txt && \
    /tmp/python-tools/install-python-tool.sh /tmp/python-tools/pip-tools/requirements.txt pip-compile pip-sync && \
    /tmp/python-tools/install-python-tool.sh /tmp/python-tools/uv/requirements.txt uv uvx && \
    rm -rf /tmp/python-tools

# Install Go-based packages from source:
COPY tools/helm/go.mod tools/helm/go.sum /tmp/helm/
RUN \
    export GOBIN=/usr/local/bin && \
    go -C /tmp/helm install -trimpath --mod=readonly helm.sh/helm/v4/cmd/helm && \
    rm -rf /tmp/helm && \
    helm version

# Install the latest Rust oolchain
COPY --from=rust /usr/local/share/rust /usr/local/share/rust
ENV PATH="/usr/local/share/rust/bin:${PATH}"

# Add renovate user and switch to it
RUN useradd -lms /bin/bash -u 1001 -g 0 renovate && \
    mkdir -p /home/renovate/.cache /home/renovate/.local && \
    chown -R 1001:0 /home/renovate && chmod -R 2775 /home/renovate

WORKDIR /home/renovate
USER 1001

# Ensure Python requests library uses system root certificates
# Particularly important for Python virtual environments
ENV REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt

# Set paths for openssl/urllib
ENV SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt
ENV SSL_CERT_DIR=/etc/pki/tls/certs

WORKDIR /home/renovate/renovate

# Enable ~/.local/bin for renovate cli
ENV PATH="/home/renovate/.local/bin:${PATH}"

# Renovate's source is checked out at the pinned submodule commit before the build.
COPY --chown=1001:0 tools/renovate/ ./

# Install project dependencies, build and install Renovate
RUN export PATH="/usr/local/node24/bin:${PATH}" \
    && pnpm install && pnpm build \
    && PNPM_HOME=/home/renovate/.local pnpm add -g . \
    && pnpm prune --prod --ignore-scripts \
    && pnpm store prune \
    && npm-24 cache clean --force

WORKDIR /workspace
