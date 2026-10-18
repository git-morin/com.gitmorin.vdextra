SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

DEVICE ?=
VD_PKG := VirtualDesktop.Quest
MODULE := com.gitmorin.vdextra
REPO := git-morin/com.gitmorin.vdextra
NIM_MAIN := app/src/main/nim/vdextra.nim
NIM_SRC := $(wildcard app/src/main/nim/*.nim app/src/main/nim/hooks/*.nim)
C_SRC := app/src/main/cpp/init.c
APK_DIR := dist/apk
BRANCH = $(shell git rev-parse --abbrev-ref HEAD)
ADB := adb -s $(DEVICE)
CLANG_FORMAT_VERSION := 23.1.3
KTLINT_VERSION := 1.8.0
DETEKT_VERSION := 1.23.8
TOOLS_DIR := .tools
KTLINT_JAR := $(TOOLS_DIR)/ktlint-$(KTLINT_VERSION).jar
DETEKT_JAR := $(TOOLS_DIR)/detekt-cli-$(DETEKT_VERSION)-all.jar
KT_SRC := app/src/main/kotlin
# The java on PATH can be an old JRE, so prefer JAVA_HOME: it is what CI sets and what these
# jars need. The subst keeps a Windows JAVA_HOME usable from bash.
JAVA_BIN := $(if $(JAVA_HOME),$(subst \,/,$(JAVA_HOME))/bin/java,java)

.PHONY: help help-more lint check fmt fmt-check build apk install run ship \
        connect device require-device logs logs-dump tombstones \
        tombstones-clean clean tools kt-check kt-fmt kt-fmt-check

lint: check fmt-check kt-check kt-fmt-check ## Lint the Nim, C and Kotlin (needs no Android SDK)

check: # Type-check the Nim against the real android target
	@nim check --hints:off $(NIM_MAIN)

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

fmt: kt-fmt ## Reformat the Nim, C and Kotlin sources in place
	@for f in $(NIM_SRC); do nimpretty --maxLineLen:100 "$$f"; done
	@command -v clang-format >/dev/null 2>&1 && clang-format -i $(C_SRC) || true

tools: $(KTLINT_JAR) $(DETEKT_JAR) # Download the pinned Kotlin lint tools

$(KTLINT_JAR):
	@mkdir -p $(TOOLS_DIR)
	@echo "fetching ktlint $(KTLINT_VERSION)"
	@curl -fsSL -o $(TOOLS_DIR)/ktlint.zip https://github.com/ktlint/ktlint/releases/download/$(KTLINT_VERSION)/ktlint-$(KTLINT_VERSION).zip
	@cd $(TOOLS_DIR) && unzip -oq ktlint.zip && mv -f ktlint-$(KTLINT_VERSION)/bin/ktlint $(notdir $(KTLINT_JAR)) && rm -rf ktlint-$(KTLINT_VERSION) ktlint.zip

$(DETEKT_JAR):
	@mkdir -p $(TOOLS_DIR)
	@echo "fetching detekt $(DETEKT_VERSION)"
	@curl -fsSL -o $(DETEKT_JAR) https://github.com/detekt/detekt/releases/download/v$(DETEKT_VERSION)/$(notdir $(DETEKT_JAR))

# Findings already in the tree are recorded in the baseline, so this fails only on new ones.
kt-check: $(DETEKT_JAR) # Static analysis of the Kotlin sources
	@"$(JAVA_BIN)" -jar $(DETEKT_JAR) --input $(KT_SRC) --config config/detekt.yml --build-upon-default-config --baseline config/detekt-baseline.xml

kt-fmt-check: $(KTLINT_JAR) # Check Kotlin formatting without rewriting anything
	@"$(JAVA_BIN)" -jar $(KTLINT_JAR) "$(KT_SRC)/**/*.kt"

kt-fmt: $(KTLINT_JAR) # Reformat the Kotlin sources in place
	@"$(JAVA_BIN)" -jar $(KTLINT_JAR) --format "$(KT_SRC)/**/*.kt"

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

apk: ## Download the APK built for this branch
	@set -euo pipefail; \
	id=$$(gh run list --branch $(BRANCH) --limit 1 --json databaseId,status \
	      --jq '.[] | select(.status == "completed") | .databaseId'); \
	if [ -z "$$id" ]; then echo "no completed run for $(BRANCH)"; exit 1; fi; \
	rm -rf $(APK_DIR); mkdir -p $(APK_DIR); \
	echo "downloading from run $$id"; \
	gh run download "$$id" -R $(REPO) -D $(APK_DIR) -p 'vdextra-*'; \
	find $(APK_DIR) -name '*.apk'

require-device:
	@test -n "$(DEVICE)" || { echo "DEVICE is not set: export DEVICE=<ip>:<port>"; exit 1; }

install: require-device ## Install the downloaded APK on the headset
	@set -euo pipefail; \
	apk=$$(find $(APK_DIR) -name '*.apk' | head -1); \
	if [ -z "$$apk" ]; then echo "no APK - run 'make apk' first"; exit 1; fi; \
	$(MAKE) --no-print-directory connect; \
	$(ADB) install -r "$$apk"

run: require-device ## Restart Virtual Desktop
	@$(ADB) shell am force-stop $(VD_PKG)
	@$(ADB) shell monkey -p $(VD_PKG) -c android.intent.category.LAUNCHER 1 >/dev/null
	@echo "launched $(VD_PKG)"

ship: build apk install run ## Build in CI, install on the headset and restart Virtual Desktop


connect: require-device ## Reconnect wireless adb to the headset
	@for i in $$(seq 1 10); do \
	  adb disconnect $(DEVICE) >/dev/null 2>&1 || true; \
	  adb connect $(DEVICE) >/dev/null 2>&1 || true; \
	  if $(ADB) shell true >/dev/null 2>&1; then echo "connected to $(DEVICE)"; exit 0; fi; \
	done; \
	echo "could not reach $(DEVICE) - is the headset awake?"; exit 1

device: require-device # Show the device, Virtual Desktop's pid and the installed module version
	@$(ADB) shell getprop ro.product.model
	@echo "Virtual Desktop pid: $$($(ADB) shell pidof $(VD_PKG) | tr -dc '0-9')"
	@$(ADB) shell dumpsys package $(MODULE) 2>/dev/null | grep -m1 versionName || true

logs: require-device ## Follow the VDExtra log
	@$(ADB) logcat -s VDExtra

logs-dump: require-device # Dump the VDExtra log so far
	@$(ADB) logcat -d -s VDExtra

tombstones: require-device # List native crash dumps
	@$(ADB) shell su -c 'ls -lt /data/tombstones/ 2>/dev/null' || echo "none"

tombstones-clean: require-device # Delete native crash dumps, so the next crash is unambiguous
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
