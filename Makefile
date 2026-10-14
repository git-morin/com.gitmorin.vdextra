# Recipes use `>` instead of a leading tab, so copy-pasting into this file cannot silently
# break it. Requires GNU Make 3.82+.
.RECIPEPREFIX := >
.DEFAULT_GOAL := help

DEVICE ?= 192.168.8.211:5555
VD_PKG := VirtualDesktop.Quest
MODULE := com.gitmorin.vdextra
NIM_MAIN := app/src/main/nim/vdextra.nim
NIM_SRC := $(wildcard app/src/main/nim/*.nim)
C_SRC := app/src/main/cpp/init.c
REPO := git-morin/vdextra
BRANCH = $(shell git rev-parse --abbrev-ref HEAD)
ADB := adb -s $(DEVICE)
APK_DIR := build/apk

.PHONY: help check fmt fmt-check lint build apk install run logs logs-dump connect device \
        tombstones tombstones-clean ship clean

help:
> @echo 'VDExtra - there is no local Android SDK, so compiling happens in CI.'
> @echo ''
> @echo '  make check             type-check the Nim against the real android target'
> @echo '  make lint              check + formatting (nimpretty, clang-format if present)'
> @echo '  make fmt               rewrite Nim formatting in place'
> @echo ''
> @echo '  make build             push this branch, run CI, wait for it'
> @echo '  make apk               download the newest APK built for this branch'
> @echo '  make install           adb install that APK'
> @echo '  make run               restart Virtual Desktop'
> @echo '  make ship              build + apk + install + run'
> @echo ''
> @echo '  make connect           reconnect wireless adb (the link drops when the headset idles)'
> @echo '  make device            device, Virtual Desktop pid, installed module version'
> @echo '  make logs              follow the VDExtra log'
> @echo '  make logs-dump         dump the VDExtra log so far'
> @echo '  make tombstones        list native crash dumps'
> @echo '  make tombstones-clean  delete them, so the next crash is unambiguous'
> @echo ''
> @echo '  DEVICE=ip:port overrides the headset address (currently $(DEVICE))'

check:
> @nim check --hints:off $(NIM_MAIN)

# nimpretty only rewrites in place, so compare against a copy to get a check out of it.
# maxLineLen matches the 100 columns the sources are written to; its default is 80.
fmt-check:
> @fail=0; tmp=$$(mktemp -d); \
> for f in $(NIM_SRC); do \
>   cp "$$f" "$$tmp/$$(basename $$f)"; \
>   nimpretty --maxLineLen:100 --out:"$$tmp/$$(basename $$f)" "$$f" >/dev/null 2>&1 || true; \
>   if ! diff -q "$$f" "$$tmp/$$(basename $$f)" >/dev/null; then \
>     echo "nimpretty: $$f is not formatted"; fail=1; \
>   fi; \
> done; rm -rf "$$tmp"; \
> if command -v clang-format >/dev/null 2>&1; then \
>   clang-format --dry-run -Werror $(C_SRC) || fail=1; \
> else \
>   echo "clang-format not installed, skipping C formatting"; \
> fi; \
> exit $$fail

fmt:
> @for f in $(NIM_SRC); do nimpretty --maxLineLen:100 "$$f"; done
> @command -v clang-format >/dev/null 2>&1 && clang-format -i $(C_SRC) || true

lint: check fmt-check

# A push to main or dev already triggers the workflow, so dispatching as well would run
# it twice; other branches need the dispatch because they match no push trigger.
build:
> git push origin $(BRANCH)
> @if [ "$(BRANCH)" != "main" ] && [ "$(BRANCH)" != "dev" ]; then \
>   gh workflow run release.yml --ref $(BRANCH); \
> fi
> @sleep 8
> @id=$$(gh run list --branch $(BRANCH) --limit 1 --json databaseId -q '.[0].databaseId'); \
> echo "watching run $$id"; gh run watch "$$id" --exit-status

apk:
> @rm -rf $(APK_DIR) && mkdir -p $(APK_DIR)
> @id=$$(gh run list --branch $(BRANCH) --limit 1 --json databaseId,status \
>   -q '.[] | select(.status=="completed") | .databaseId' | head -1); \
> echo "downloading artifacts from run $$id"; \
> gh run download "$$id" -R $(REPO) -D $(APK_DIR)
> @find $(APK_DIR) -name '*.apk'

install:
> @apk=$$(find $(APK_DIR) -name '*.apk' | head -1); \
> if [ -z "$$apk" ]; then echo 'no APK - run `make apk` first'; exit 1; fi; \
> $(MAKE) --no-print-directory connect; \
> $(ADB) install -r "$$apk"

run:
> @$(ADB) shell am force-stop $(VD_PKG)
> @$(ADB) shell monkey -p $(VD_PKG) -c android.intent.category.LAUNCHER 1 >/dev/null
> @echo 'launched $(VD_PKG)'

ship: build apk install run

# The link drops whenever the headset idles, and a stale connection reports `device` while
# every command fails, so disconnect first and keep trying until a shell actually answers.
connect:
> @for i in 1 2 3 4 5 6 7 8 9 10; do \
>   adb disconnect $(DEVICE) >/dev/null 2>&1; \
>   adb connect $(DEVICE) >/dev/null 2>&1; \
>   if $(ADB) shell true >/dev/null 2>&1; then echo "connected to $(DEVICE)"; exit 0; fi; \
> done; \
> echo 'could not reach $(DEVICE) - is the headset awake?'; exit 1

device:
> @$(ADB) shell getprop ro.product.model
> @echo "Virtual Desktop pid: $$($(ADB) shell pidof $(VD_PKG) | tr -d '\r\n' || echo 'not running')"
> @$(ADB) shell dumpsys package $(MODULE) 2>/dev/null | grep -m1 versionName || true

logs:
> @$(ADB) logcat -s VDExtra

# -t truncates before the tag filter is applied, which silently reports nothing at all.
logs-dump:
> @$(ADB) logcat -d -s VDExtra

tombstones:
> @$(ADB) shell su -c 'ls -lt /data/tombstones/ 2>/dev/null' || echo 'none'

tombstones-clean:
> @$(ADB) shell su -c 'rm -f /data/tombstones/*'
> @echo 'cleared'

clean:
> @rm -rf $(APK_DIR) app/build app/.cxx build
> @echo 'cleaned local build output'
