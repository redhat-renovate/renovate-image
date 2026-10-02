#!/bin/bash
set -euo pipefail
set -x

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PIPELINERUN_FILE="$(printf .tekton/rh-renovate-image-*-push.yaml)"

PREFETCH_DEPS_IMAGE="$(
    < "${PIPELINERUN_FILE}" \
    yq '.spec.pipelineSpec.tasks[] |
        select(.name == "prefetch-dependencies").taskRef.params[] |
        select(.name == "bundle") | .value'
)"

# HERMETO_IMAGE="quay.io/konflux-ci/hermeto:latest"
HERMETO_IMAGE="$(
    tkn bundle list -o json "${PREFETCH_DEPS_IMAGE}" | \
    jq -r '.spec.steps[] | select(.name == "prefetch-dependencies") | .image'
)"

hermeto() {
    podman run --rm \
        -v "$(pwd):/mnt/workdir:Z" \
        -v "${HOME}/.netrc:/mnt/netrc:Z" -e NETRC=/mnt/netrc \
        -w /mnt/workdir \
        "${HERMETO_IMAGE}" "$@"
}

hermeto --version

HERMETO_WORKDIR='hermeto-workdir'
HERMETO_OUTPUT_DIR="${HERMETO_WORKDIR}/output"
HERMETO_ENV_FILE="${HERMETO_WORKDIR}/hermeto.env"

HERMETO_BUILD_DOCKERFILE='Dockerfile.hermeto'
HERMETO_BUILD_VOLUME="/hermeto"

ORIGINAL_DOCKERFILE='Dockerfile'

HERMETO_CONF="$(
    < "${PIPELINERUN_FILE}" yq '.spec.params[] | select(.name == "prefetch-input") | .value'
)"

echo "${HERMETO_CONF}"

rm -rf "${HERMETO_WORKDIR}"
mkdir "${HERMETO_WORKDIR}"

# TODO: Check that current remote is https, not ssh - hermeto fails to git fetch that way
hermeto fetch-deps --output "${HERMETO_OUTPUT_DIR}" "${HERMETO_CONF}"

hermeto generate-env --output "${HERMETO_ENV_FILE}" --format env "${HERMETO_OUTPUT_DIR}"\
    --for-output-dir "${HERMETO_BUILD_VOLUME}/output"

cp "${ORIGINAL_DOCKERFILE}" "${HERMETO_BUILD_DOCKERFILE}"

# Read in the whole file (https://unix.stackexchange.com/questions/533277), then
# for each RUN ... line insert the cachi2.env command *after* any options like --mount
sed -E -i \
    -e 'H;1h;$!d;x' \
    -e 's@^\s*(run((\s|\\\n)+-\S+)*(\s|\\\n)+)@\1. /hermeto/hermeto.env \&\& \\\n    @igM' \
    "${HERMETO_BUILD_DOCKERFILE}"

buildah build \
    --network=none \
    --no-cache \
    --volume "${PWD}/${HERMETO_WORKDIR}:${HERMETO_BUILD_VOLUME}:Z" \
    -f "${HERMETO_BUILD_DOCKERFILE}" \
    -t "rh-renovate:hermetic" .
