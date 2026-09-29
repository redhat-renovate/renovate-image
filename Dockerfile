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

# The version number is from upstream Renovate, while the `-rpm` suffix
# is to differentiate the rpm lockfile enabled fork
ARG RENOVATE_VERSION=44.71.0-rpm

# Specific git commit hash from the redhat-exd-rebuilds/renovate fork
ARG RENOVATE_REVISION=6a2542ca879a3e0945f3090c6c3507de5345cbf7

# Version for the rpm-lockfile-prototype executable from
# https://github.com/konflux-ci/rpm-lockfile-prototype/tags
# Do not remove the following line, renovate uses it to propose version updates
# renovate: datasource=github-tags depName=konflux-ci/rpm-lockfile-prototype versioning=semver
ARG RPM_LOCKFILE_PROTOTYPE_VERSION=0.30.1

# Version for the refresh-rpm-lockfiles executable from
# https://github.com/konflux-ci/refresh-rpm-lockfiles/tags
# Do not remove the following line, renovate uses it to propose version updates
# renovate: datasource=github-tags depName=konflux-ci/refresh-rpm-lockfiles versioning=semver
ARG REFRESH_RPM_LOCKFILES_VERSION=0.1.3

# Version for the update-artifacts-lockfile executable from
# https://github.com/konflux-ci/update-artifacts-lockfile/tags
# Do not remove the following line, renovate uses it to propose version updates
# renovate: datasource=github-tags depName=konflux-ci/update-artifacts-lockfile versioning=semver
ARG UPDATE_ARTIFACTS_LOCKFILE_VERSION=0.2.0

# NodeJS version used for Renovate, has to satisfy the version
# specified in Renovate's package.json
ARG NODEJS_VERSION=24.20.0

ARG PNPM_VERSION=11.25.0

# Do not remove the following line, renovate uses it to propose version updates
# renovate: datasource=pypi depName=pipx
ARG PIPX_VERSION=1.17.4

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
        subscription-manager-rhsm-certificates \
        git \
        nodejs \
        nodejs24 \
        openssl \
        python3.12 \
        python3.12-pip \
        python3.14 \
        python3-dnf \
        golang \
        skopeo \
        xz \
        tar \
        zip unzip \
        java-21-openjdk-devel \
        which \
        libpq-devel \
        krb5-devel && \
    microdnf clean all

# Create a shim for NodeJS 24 so it works with tools that simply execute `npm`, e.g. `pnpm`.
RUN \
    mkdir -p /usr/local/node24/bin && \
    ln -sf "$(command -v node-24)" /usr/local/node24/bin/node && \
    ln -sf "$(command -v npm-24)"  /usr/local/node24/bin/npm && \
    ln -sf "$(command -v npx-24)"  /usr/local/node24/bin/npx && \
    chmod -R a+rX /usr/local/node24

WORKDIR /workspace
RUN npm install -g pnpm@${PNPM_VERSION} && npm cache clean --force

# Add renovate user and switch to it
RUN useradd -lms /bin/bash -u 1001 -g 0 renovate
RUN mkdir -p /home/renovate/.cache /home/renovate/.local /home/renovate/.rustup/tmp /home/renovate/.local/share/pnpm/.tools/pnpm
RUN chown -R 1001:0 /home/renovate && chmod -R 2775 /home/renovate

WORKDIR /home/renovate
USER 1001

# Enable renovate user's bin dirs,
#   ~/.local/bin for Python executables
#   ~/node_modules/.bin for renovate
ENV PATH="/home/renovate/.local/bin:/home/renovate/node_modules/.bin:/home/renovate/go/bin:/tmp/renovate/cache/others/go/bin:/usr/local/share/rust/bin:${PATH}"

# Use virtualenv isolation to avoid dependency issues with other global packages
RUN pip3.12 install --user pipx==${PIPX_VERSION} && pip3.12 cache purge

COPY install-python-tool.sh /home/renovate/install-python-tool.sh
COPY --chown=1001:0 tools /tmp/tools
RUN --mount=type=secret,id=netrc,target=/home/renovate/.netrc,uid=1001,gid=0,mode=0400 \
    ./install-python-tool.sh /tmp/tools/hashin/requirements.txt && \
    ./install-python-tool.sh /tmp/tools/pip-tools/requirements.txt pip-compile pip-sync && \
    ./install-python-tool.sh /tmp/tools/uv/requirements.txt uv uvx && \
    rm -rf /tmp/tools /home/renovate/install-python-tool.sh

# Ensure Python requests library uses system root certificates
# Particularly important for Python virtual environments
ENV REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt

# Set paths for openssl/urllib
ENV SSL_CERT_FILE=/etc/pki/tls/certs/ca-bundle.crt
ENV SSL_CERT_DIR=/etc/pki/tls/certs

# Install Go-based packages from source:
# * helmv4
RUN \
    go install -a helm.sh/helm/v4/cmd/helm@v${HELM_V4_VERSION} && \
    go clean -cache -modcache

# Install the latest Rust toolchain
COPY --from=rust /usr/local/share/rust /usr/local/share/rust

WORKDIR /home/renovate/renovate

# Clone Renovate from the fork and checkout the specific commit that includes custom
# features for RPM lockfile support and Red Hat Container/RPM vulnerability alerts
RUN git clone --depth=1 --branch renovate-43-268-1 https://github.com/redhat-exd-rebuilds/renovate.git . \
    && git fetch --depth 1 origin ${RENOVATE_REVISION} \
    && git checkout ${RENOVATE_REVISION}

# Replace package.json version for this build
RUN sed -i "s/0.0.0-semantic-release/${RENOVATE_VERSION}/g" package.json
# Install project dependencies, build and install Renovate

RUN export PATH="/usr/local/node24/bin:${PATH}" \
    && pnpm install && pnpm build \
    && PNPM_HOME=/home/renovate/.local pnpm add -g . \
    && pnpm prune --prod --ignore-scripts \
    && pnpm store prune \
    && npm-24 cache clean --force

# Run pipx install with the --system-site-packages so rpm-lockfile-prototype can use the system's python3-dnf package
RUN pipx install --python python3.12 git+https://github.com/konflux-ci/rpm-lockfile-prototype.git@v${RPM_LOCKFILE_PROTOTYPE_VERSION} --system-site-packages && \
    rm -fr ~/.cache/pipx && pip3.12 cache purge

RUN pipx install --python python3.12 git+https://github.com/konflux-ci/refresh-rpm-lockfiles.git@v${REFRESH_RPM_LOCKFILES_VERSION} && \
    rm -fr ~/.cache/pipx && pip3.12 cache purge

RUN pipx install --python python3.12 git+https://github.com/konflux-ci/update-artifacts-lockfile.git@v${UPDATE_ARTIFACTS_LOCKFILE_VERSION} && \
    rm -fr ~/.cache/pipx && pip3.12 cache purge

WORKDIR /workspace
