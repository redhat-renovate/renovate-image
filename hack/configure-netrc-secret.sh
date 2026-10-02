#!/usr/bin/env bash

set -euo pipefail

usage() {
    printf 'Usage: %s <secret-name> <pipeline-run.yaml> [pipeline-run.yaml ...]\n' "$0" >&2
}

if [[ $# -lt 2 ]]; then
    usage
    exit 2
fi

secret_name=$1
shift

if [[ -z $secret_name ]]; then
    printf 'Error: secret name must not be empty.\n' >&2
    exit 2
fi

if ! command -v yq >/dev/null 2>&1; then
    printf 'Error: yq (Mike Farah yq v4) is required.\n' >&2
    exit 1
fi

# Validate every file before changing any of them.
for pipeline_file in "$@"; do
    if [[ ! -f $pipeline_file || ! -r $pipeline_file || ! -w $pipeline_file ]]; then
        printf 'Error: pipeline file must be readable and writable: %s\n' "$pipeline_file" >&2
        exit 1
    fi

    if ! yq -e '(.spec.pipelineSpec.tasks // []) | map(select(.name == "prefetch-dependencies")) | length > 0' \
        "$pipeline_file" >/dev/null; then
        printf 'Error: no prefetch-dependencies task found in %s\n' "$pipeline_file" >&2
        exit 1
    fi
done

for pipeline_file in "$@"; do
    NETRC_SECRET_NAME=$secret_name yq -c -i \
        '.spec.workspaces = ((.spec.workspaces // []) | map(select(.name != "netrc")) + [{"name": "netrc", "secret": {"secretName": strenv(NETRC_SECRET_NAME)}}])' \
        "$pipeline_file"

    yq -c -i \
        '.spec.pipelineSpec.tasks |= map(with(select(.name == "prefetch-dependencies"); .workspaces = (((.workspaces // []) | map(select(.name != "netrc"))) + [{"name": "netrc", "workspace": "netrc"}])))' \
        "$pipeline_file"
done
