# Build with: podman build --secret id=netrc,src=$HOME/.netrc --ulimit nofile=65535:65535 . -t custom-renovate
# Run with: podman run --rm <additional args> custom-renovate renovate

FROM registry.redhat.io/rust-builder-image/rust-rhel10 AS rust

FROM registry.access.redhat.com/ubi10-minimal
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

# Specific git commit hash from the redhat-exd-rebuilds/renovate fork
ARG RENOVATE_REVISION=556b1be775ea0d92733a4bcc985cb87623e80e5f

ARG PNPM_VERSION=11.25.0

# Do not remove the following line, renovate uses it to propose version updates
# renovate: datasource=github-tags depName=helm/helm
ARG HELM_V4_VERSION=4.3.0

# Support multiple Go versions
ENV GOTOOLCHAIN=auto

# Temporary fix for uv's cache dir permissions
ENV UV_NO_CACHE=true

# Using OpenSSL store allows for external modifications of the store. It is needed for the internal Red Hat cert.
ENV NODE_OPTIONS="--use-openssl-ca --max-old-space-size=2816"

ENV LANG=C.UTF-8

RUN microdnf update -y && \
    microdnf install -y \
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
COPY install-python-tool.sh tools /tmp/python-tools/
RUN --mount=type=secret,id=netrc,target=/root/.netrc \
    /tmp/python-tools/install-python-tool.sh /tmp/python-tools/hashin/requirements.txt && \
    /tmp/python-tools/install-python-tool.sh /tmp/python-tools/pip-tools/requirements.txt pip-compile pip-sync && \
    /tmp/python-tools/install-python-tool.sh /tmp/python-tools/uv/requirements.txt uv uvx && \
    rm -rf /tmp/python-tools

# Install Go-based packages from source:
# * helmv4
RUN \
    export GOBIN=/usr/local/bin && \
    go install -a helm.sh/helm/v4/cmd/helm@v${HELM_V4_VERSION} && \
    go clean -cache -modcache


# Add renovate user and switch to it
RUN useradd -lms /bin/bash -u 1001 -g 0 renovate && \
    mkdir -p /home/renovate/.cache /home/renovate/.local && \
    chown -R 1001:0 /home/renovate && chmod -R 2775 /home/renovate

WORKDIR /home/renovate
USER 1001

# Enable renovate user's bin dirs,
#   ~/.local/bin for renovate cli
#   /usr/local/share/rust for rust tools
ENV PATH="/home/renovate/.local/bin:/usr/local/share/rust/bin:${PATH}"

# Ensure Python requests library uses system root certificates
# Particularly important for Python virtual environments
ENV REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt

# Set paths for openssl/urllib
ENV SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt
ENV SSL_CERT_DIR=/etc/pki/tls/certs

# Install the latest Rust toolchain
COPY --from=rust /usr/local/share/rust /usr/local/share/rust

WORKDIR /home/renovate/renovate

# Clone Renovate from the fork and checkout the specific commit that includes custom
# features for RPM lockfile support and Red Hat Container/RPM vulnerability alerts
RUN git clone --depth=1 --branch 43.268.1 https://github.com/renovatebot/renovate.git . \
    && git fetch --depth 1 origin ${RENOVATE_REVISION} \
    && git checkout ${RENOVATE_REVISION}

# Install project dependencies, build and install Renovate
RUN export PATH="/usr/local/node24/bin:${PATH}" \
    && pnpm install && pnpm build \
    && PNPM_HOME=/home/renovate/.local pnpm add -g . \
    && pnpm prune --prod --ignore-scripts \
    && pnpm store prune \
    && npm-24 cache clean --force

WORKDIR /workspace
