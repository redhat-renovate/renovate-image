# Renovate container image

This repository builds a custom [Renovate](https://docs.renovatebot.com/)
container image based on UBI 10 minimal. It includes the tools Renovate needs
for dependency updates across several ecosystems and for running in Tekton.

The Dockerfile defines the image contents. The Renovate configuration that
determines which managers are enabled is maintained separately from this
repository. `.github/renovate.json` configures dependency updates **to this
repository**.

## Running the image

The image runs as the `renovate` user (UID 1001) and uses `/workspace` as its
working directory. Run Renovate with:

```bash
podman run --rm <additional args> custom-renovate renovate
```

For example, a Tekton task running the image can set the working directory and
user as follows:

```yaml
apiVersion: tekton.dev/v1beta1
kind: Task
spec:
  stepTemplate:
    workingDir: /workspace
    securityContext:
      runAsUser: 1001
```

The image does not set `renovate` as its entrypoint, so pass it as the command.

To install a hash-locked Python CLI tool for all users, run the helper as root, for example:
`./install-python-tool.sh tools/<tool-name>/requirements.txt`. By default, the helper exposes a
command matching the requirements directory name. If the package provides multiple commands, pass
the command names after the requirements file, for example
`./install-python-tool.sh tools/pip-tools/requirements.txt pip-compile pip-sync`. The helper
creates an isolated environment under `/opt/python-tools/<tool-name>/` and links the selected
commands into `/usr/local/bin`.

## Development

### Renovate source

Renovate is pinned as a Git submodule under `tools/renovate`. Initialize it before
building locally:

```bash
git submodule update --init tools/renovate
```

The Dockerfile copies that checkout into the image and builds Renovate with
pnpm. CI must initialize the submodule before dependency prefetch and the image
build. To prefetch Renovate's locked npm dependencies with Hermeto, process
`tools/renovate` as a pnpm package.

### Lint

Install the linters locally, then run `make lint`.

**macOS (Homebrew + npm):**

```bash
brew install hadolint shellcheck actionlint
npm install -g markdownlint-cli2@0.17.2
make lint
```

**Run individual checks:**

```bash
hadolint --failure-threshold warning --config .hadolint.yaml Dockerfile
shellcheck -x install-python-tool.sh hack/configure-netrc-secret.sh
markdownlint-cli2 --config .markdownlint.json README.md AGENTS.md
actionlint -shellcheck=shellcheck .github/workflows/*.yaml
```

`--failure-threshold warning` skips hadolint *info* findings (e.g. intentional single quotes in the pyenv profile setup).

### Build

```bash
podman build --secret id=netrc,src=$HOME/.netrc --ulimit nofile=65535:65535 . -t custom-renovate
```

The build uses the Red Hat Lightwell Python index for the hash-locked python tools, so `~/.netrc`
must contain credentials for `packages.redhat.com`.

To access that content from Konflux,
[create](https://konflux-ci.dev/docs/building/prefetching-dependencies/#creating-the-netrc-secret)
a `.netrc` Secret in your Konflux namespace, then run the helper on the PipelineRun files:

```bash
./hack/configure-netrc-secret.sh <secret-name> \
  .tekton/<pull-request-pipeline>.yaml .tekton/<push-pipeline>.yaml
```

### Lint coverage

Lint coverage:

| Location                                                   | Linter                                   |
| -----------------------------------------------------      | ---------------------------------------- |
| `Dockerfile` `RUN` shell                                   | hadolint (+ shellcheck where applicable) |
| `install-python-tool.sh`, `hack/configure-netrc-secret.sh` | shellcheck                               |
| `.github/workflows/*.yaml` inline `run:`                   | actionlint + shellcheck                  |
| `README.md`, `AGENTS.md`                                   | markdownlint                             |

The `.hadolint.yaml` and `.markdownlint.json` files contain the lint baselines.
