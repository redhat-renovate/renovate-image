#!/usr/bin/env bash

set -euo pipefail

usage() {
    printf 'Usage: %s <tool-directory>/requirements.txt [command ...]\n' "$0" >&2
}

if [[ $# -lt 1 ]]; then
    usage
    exit 2
fi

requirements_file=$1
if [[ ! -f $requirements_file || ! -r $requirements_file ]]; then
    printf 'Error: requirements file is not readable: %s\n' "$requirements_file" >&2
    exit 1
fi

requirements_dir=${requirements_file%/*}
if [[ $requirements_dir == "$requirements_file" ]]; then
    requirements_dir=.
fi
venv_name=${requirements_dir##*/}
if [[ -z $venv_name || $venv_name == . || $venv_name == .. || ! $venv_name =~ ^[[:alnum:]_.-]+$ ]]; then
    printf 'Error: put requirements.txt in a directory named for the tool command.\n' >&2
    printf 'Example: tools/hatch/requirements.txt exposes the "hatch" command.\n' >&2
    exit 1
fi

commands=()
if [[ $# -gt 1 ]]; then
    shift
    commands=("$@")
else
    commands=("$venv_name")
fi

for command in "${commands[@]}"; do
    if [[ -z $command || $command == . || $command == .. || ! $command =~ ^[[:alnum:]_.-]+$ ]]; then
        printf 'Error: command names must contain only letters, numbers, dots, underscores, or hyphens.\n' >&2
        exit 1
    fi
done

venv_dir="/opt/python-tools/$venv_name"
bin_dir=/usr/local/bin

if [[ -L $venv_dir ]]; then
    printf 'Error: refusing to clear symlinked environment path: %s\n' "$venv_dir" >&2
    exit 1
fi

for command in "${commands[@]}"; do
    launcher="$bin_dir/$command"
    tool_executable="$venv_dir/bin/$command"
    if [[ -e $launcher || -L $launcher ]]; then
        if [[ ! -L $launcher || $(readlink "$launcher") != "$tool_executable" ]]; then
            printf 'Error: command path already exists: %s\n' "$launcher" >&2
            exit 1
        fi
    fi
done

mkdir -p "$(dirname "$venv_dir")" "$bin_dir"
if ! python3.12 -m venv --clear "$venv_dir"; then
    printf 'Error: failed to create a virtual environment. Ensure this Python includes venv and ensurepip.\n' >&2
    exit 1
fi

"$venv_dir/bin/python" -m pip install \
    --require-hashes \
    --only-binary=:all: \
    -r "$requirements_file"

for command in "${commands[@]}"; do
    tool_executable="$venv_dir/bin/$command"
    if [[ ! -x $tool_executable ]]; then
        printf 'Error: installation succeeded, but no "%s" executable was created.\n' "$command" >&2
        printf 'Check the requirements directory name or pass the desired command names explicitly.\n' >&2
        exit 1
    fi
done

for command in "${commands[@]}"; do
    launcher="$bin_dir/$command"
    tool_executable="$venv_dir/bin/$command"
    if [[ ! -e $launcher && ! -L $launcher ]]; then
        ln -s "$tool_executable" "$launcher"
    fi
done

printf 'Installed Python tools in %s\n' "$venv_dir"
for command in "${commands[@]}"; do
    printf 'Command link: %s/%s\n' "$bin_dir" "$command"
done
case ":${PATH:-}:" in
    *":$bin_dir:"*) ;;
    *) printf 'Add %s to PATH to run these commands from any directory.\n' "$bin_dir" ;;
esac
