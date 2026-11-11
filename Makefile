SHELL := /bin/bash
SCRIPTS := $(wildcard scripts/*.sh)
TESTS := $(wildcard tests/*.sh)

.PHONY: lint test build clean help

help:
	@echo "make lint | test | build CHANNEL=stable VERSION=4757.2.3 ARCH=amd64 VENDOR=upcloud | clean"
	@echo "build writes to out/<channel>-<version>/; set ALL_FORMATS=1 for the unpublished raw images"

lint:
	shellcheck -x $(SCRIPTS) $(TESTS)
	@if command -v actionlint >/dev/null; then actionlint; else echo "actionlint not installed: skipped (CI runs it)"; fi
	jq -e . config/*.json >/dev/null

test:
	tests/run.sh

build:
	@test -n "$(CHANNEL)" -a -n "$(VERSION)" -a -n "$(VENDOR)" || { echo "usage: make build CHANNEL=stable VERSION=4757.2.3 [ARCH=amd64] VENDOR=upcloud"; exit 2; }
	scripts/build.sh "$(CHANNEL)" "$(VERSION)" "$(or $(ARCH),amd64)" "$(VENDOR)"
	scripts/manifest.sh "out/$(CHANNEL)-$(VERSION)" "$(CHANNEL)" "$(VERSION)"

clean:
	rm -rf out work
