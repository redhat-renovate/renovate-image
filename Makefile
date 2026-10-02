.PHONY: lint
lint:
	hadolint --failure-threshold warning --config .hadolint.yaml Dockerfile
	shellcheck -x install-python-tool.sh hack/configure-netrc-secret.sh
	markdownlint-cli2 --config .markdownlint.json README.md AGENTS.md
	actionlint -shellcheck=shellcheck .github/workflows/*.yaml
