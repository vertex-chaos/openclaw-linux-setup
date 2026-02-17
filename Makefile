SHELL := bash
.SHELLFLAGS := -e -o pipefail -c
.ONESHELL:
export BASH_ENV := /dev/null

SCRIPTS := $(wildcard *.sh)

.PHONY: lint test test-bash test-docs

lint:
	shellcheck -x $(SCRIPTS)

test: lint test-bash test-docs

test-bash:
	bash -n $(SCRIPTS)

test-docs:
	tmpdir="$$(mktemp -d)"
	trap 'rm -rf "$$tmpdir"' EXIT
	cp scaffold_openclaw_docs.sh "$$tmpdir/"
	chmod +x "$$tmpdir/scaffold_openclaw_docs.sh"
	cp README.md "$$tmpdir/README.md"
	mkdir -p "$$tmpdir/docs"
	cp docs/*.md "$$tmpdir/docs/"
	REPO_DIR="$$tmpdir" "$$tmpdir/scaffold_openclaw_docs.sh" >/dev/null
	diff -u README.md "$$tmpdir/README.md"
	for f in docs/*.md; do
		diff -u "$$f" "$$tmpdir/$$f"
	done
