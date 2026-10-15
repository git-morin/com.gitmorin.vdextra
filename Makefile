SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

DEVICE ?= 192.168.8.211:5555
VD_PKG := VirtualDesktop.Quest
MODULE := com.gitmorin.vdextra
REPO := git-morin/vdextra
NIM_MAIN := app/src/main/nim/vdextra.nim
NIM_SRC := $(wildcard app/src/main/nim/*.nim)
C_SRC := app/src/main/cpp/init.c
APK_DIR := dist/apk
BRANCH = $(shell git rev-parse --abbrev-ref HEAD)
ADB := adb -s $(DEVICE)
CLANG_FORMAT_VERSION := 23.1.3

### Without this, `clean` would be considered satisfied by the directory of the same name.
.PHONY: help help-more lint check fmt fmt-check build apk install run ship connect device \
        logs logs-dump tombstones tombstones-clean clean

lint: check fmt-check ## Type-check the Nim and check formatting (needs no Android SDK)

check: # Type-check the Nim against the real android target
	@nim check --hints:off $(NIM_MAIN)

### nimpretty only rewrites in place, so compare against a copy to get a check out of it.
### maxLineLen matches the 100 columns the sources are written to; its default is 80.
fmt-check: # Check formatting without rewriting anything
	@fail=0; tmp=$$(mktemp -d); \
	for f in $(NIM_SRC); do \
	  cp "$$f" "$$tmp/$$(basename $$f)"; \
	  nimpretty --maxLineLen:100 --out:"$$tmp/$$(basename $$f)" "$$f" >/dev/null 2>&1 || true; \
	  if ! diff -q "$$f" "$$tmp/$$(basename $$f)" >/dev/null; then \
	    echo "nimpretty: $$f is not formatted (run 'make fmt')"; fail=1; \
	  fi; \
	done; rm -rf "$$tmp"; \
	if command -v clang-format >/dev/null 2>&1; then \
	  clang-format --dry-run -Werror $(C_SRC) || fail=1; \
	else \
	  echo "clang-format missing: pip install 'clang-format==$(CLANG_FORMAT_VERSION)'"; \
	fi; \
	exit $$fail

fmt: ## Reformat the Nim and C sources in place
	@for f in $(NIM_SRC); do nimpretty --maxLineLen:100 "$$f"; done
	@command -v clang-format >/dev/null 2>&1 && clang-format -i $(C_SRC) || true

### A push to main or dev already triggers the workflow, so dispatching as well would run it
### twice; any other branch matches no push trigger and needs the dispatch.
build: ## Push this branch, build it in CI and wait for the result
	@set -euo pipefail; \
	git push origin $(BRANCH); \
	if [ "$(BRANCH)" != "main" ] && [ "$(BRANCH)" != "dev" ]; then \
	  gh workflow run release.yml --ref $(BRANCH); \
	fi; \
	sleep 8; \
	id=$$(gh run list --branch $(BRANCH) --limit 1 --json databaseId --jq '.[0].databaseId'); \
	echo "watching run $$id"; \
	gh run watch "$$id" --exit-status

### Scoped to one run id and one artifact pattern: given neither, gh downloads every artifact
### in the repository instead.
apk: ## Download the APK built for this branch
	@set -euo pipefail; \
	id=$$(gh run list --branch $(BRANCH) --limit 1 --json databaseId,status \
	      --jq '.[] | select(.status == "completed") | .databaseId'); \
	if [ -z "$$id" ]; then echo "no completed run for $(BRANCH)"; exit 1; fi; \
	rm -rf $(APK_DIR); mkdir -p $(APK_DIR); \
	echo "downloading from run $$id"; \
	gh run download "$$id" -R $(REPO) -D $(APK_DIR) -p 'vdextra-*'; \
	find $(APK_DIR) -name '*.apk'

install: ## Install the downloaded APK on the headset
	@set -euo pipefail; \
	apk=$$(find $(APK_DIR) -name '*.apk' | head -1); \
	if [ -z "$$apk" ]; then echo "no APK - run 'make apk' first"; exit 1; fi; \
	$(MAKE) --no-print-directory connect; \
	$(ADB) install -r "$$apk"

run: ## Restart Virtual Desktop
	@$(ADB) shell am force-stop $(VD_PKG)
	@$(ADB) shell monkey -p $(VD_PKG) -c android.intent.category.LAUNCHER 1 >/dev/null
	@echo "launched $(VD_PKG)"

ship: build apk install run ## Build in CI, install on the headset and restart Virtual Desktop

### The link drops whenever the headset idles, and a stale connection reports `device` while
### every command fails, so disconnect first and keep trying until a shell actually answers.
connect: ## Reconnect wireless adb to the headset
	@for i in $$(seq 1 10); do \
	  adb disconnect $(DEVICE) >/dev/null 2>&1 || true; \
	  adb connect $(DEVICE) >/dev/null 2>&1 || true; \
	  if $(ADB) shell true >/dev/null 2>&1; then echo "connected to $(DEVICE)"; exit 0; fi; \
	done; \
	echo "could not reach $(DEVICE) - is the headset awake?"; exit 1

device: # Show the device, Virtual Desktop's pid and the installed module version
	@$(ADB) shell getprop ro.product.model
	@echo "Virtual Desktop pid: $$($(ADB) shell pidof $(VD_PKG) | tr -dc '0-9')"
	@$(ADB) shell dumpsys package $(MODULE) 2>/dev/null | grep -m1 versionName || true

logs: ## Follow the VDExtra log
	@$(ADB) logcat -s VDExtra

### Never pass -t here: it truncates before the tag filter is applied, so it silently reports
### nothing at all.
logs-dump: # Dump the VDExtra log so far
	@$(ADB) logcat -d -s VDExtra

tombstones: # List native crash dumps
	@$(ADB) shell su -c 'ls -lt /data/tombstones/ 2>/dev/null' || echo "none"

tombstones-clean: # Delete native crash dumps, so the next crash is unambiguous
	@$(ADB) shell su -c 'rm -f /data/tombstones/*'
	@echo "cleared"

clean: # Remove local build output
	@rm -rf dist app/build app/.cxx build
	@echo "cleaned"

### Commands with ## after and on the same line as the subcommand name are shown in the help message using the comment as the command description.
help: ## Output help about the make commands.
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

### Same rule as above but for a singular # and it will output every subcommand.
help-more: # Output extra help about the make commands.
	@grep -E '^[a-zA-Z_-]+:.*?# .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?# "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
