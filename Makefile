# SkiLo (SkiLo target) — build a SwiftUI macOS .app with Command Line Tools only (no Xcode license).
#
#   make            -> release build + assemble build/SkiLo.app + ad-hoc codesign
#   make debug      -> same, from a debug build
#   make run        -> build then `open build/SkiLo.app`
#   make test       -> swift test (swift-testing; XCTest is NOT shipped with CLT)
#   make verify     -> launch the .app headless, self-screenshot, check Bundle.module, quit
#   make sync-data  -> run tools/build_catalog.py (data/*.json -> Resources/trails.json)
#   make clean
#
# Every swift invocation runs with DEVELOPER_DIR pointed at CLT so xcodebuild (which needs the
# Xcode license) is never touched.
#
# GOTCHA: /usr/bin/make is itself an xcode-select shim and dies with the license error before
# this file is read. Invoke it one of these ways:
#     tools/build_app.sh <target>                                   # recommended wrapper
#     DEVELOPER_DIR=/Library/Developer/CommandLineTools make <target>
#     /Library/Developer/CommandLineTools/usr/bin/make <target>

SHELL        := /bin/bash
.SHELLFLAGS  := -eu -o pipefail -c

export DEVELOPER_DIR := /Library/Developer/CommandLineTools

APP_NAME     := SkiLo
# User-facing name of the .app; the executable, module and data folder keep APP_NAME.
PRODUCT_NAME := SkiLo
BUNDLE_ID    := com.calebsuh.SkiLo
CONFIG       ?= release
ARCH         ?= $(shell uname -m)

BUILD_DIR    := build
APP          := $(BUILD_DIR)/$(PRODUCT_NAME).app
CONTENTS     := $(APP)/Contents
MACOS_DIR    := $(CONTENTS)/MacOS
RES_DIR      := $(CONTENTS)/Resources
SWIFT_BIN    := .build/$(ARCH)-apple-macosx/$(CONFIG)
RES_BUNDLE   := $(APP_NAME)_$(APP_NAME).bundle
ICON_SRC     ?= assets/AppIcon.icns
PLIST_SRC    := tools/Info.plist

SWIFT_SOURCES := $(shell find Sources -type f 2>/dev/null) Package.swift

.PHONY: all release debug build app run test verify sync-data clean print-env

all: release

release:
	$(MAKE) app CONFIG=release

debug:
	$(MAKE) app CONFIG=debug

print-env:
	@echo "DEVELOPER_DIR=$(DEVELOPER_DIR)"
	@swift --version
	@echo "CONFIG=$(CONFIG) ARCH=$(ARCH) SWIFT_BIN=$(SWIFT_BIN)"

# --- compile ---------------------------------------------------------------------------
build:
	swift build -c $(CONFIG)

# --- assemble the .app bundle ----------------------------------------------------------
# The SwiftPM resource bundle goes in Contents/Resources (the only codesign-legal spot). NB: the
# generated Bundle.module does NOT look there (only <app root> and the .build path), which is
# why app code must use Bundle.appResources (Sources/SkiLo/AppResources.swift).
app: build
	@echo ">> assembling $(APP) ($(CONFIG))"
	rm -rf "$(APP)"
	mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	cp "$(SWIFT_BIN)/$(APP_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	cp -R "$(SWIFT_BIN)/$(RES_BUNDLE)" "$(RES_DIR)/$(RES_BUNDLE)"
	cp "$(PLIST_SRC)" "$(CONTENTS)/Info.plist"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@if [ -f "$(ICON_SRC)" ]; then \
	    cp "$(ICON_SRC)" "$(RES_DIR)/AppIcon.icns"; echo ">> icon: $(ICON_SRC)"; \
	else \
	    echo ">> no icon at $(ICON_SRC) (optional); generic icon will be used"; \
	    /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$(CONTENTS)/Info.plist" >/dev/null 2>&1 || true; \
	fi
	plutil -lint "$(CONTENTS)/Info.plist"
	codesign --force --deep --sign - "$(APP)"
	codesign --verify --verbose=2 "$(APP)"
	@echo ">> built $(APP)"

run: app
	open "$(APP)"

# --- tests -----------------------------------------------------------------------------
# CLT ships Testing.framework (swift-testing) but NOT XCTest.framework. Keep tests on
# `import Testing`; `import XCTest` will fail to link under CLT. Package.swift adds the -F/-rpath
# flags CLT needs when DEVELOPER_DIR points at CLT (it always does here).
test:
	tools/run_tests.sh

# --- headless verification -------------------------------------------------------------
# Launches the bundled app with HT_SCREENSHOT set; the app polls for its window, captures it,
# writes <png>.txt with the resource-bundle status, and exits (see SelfCapture.swift).
# -ApplePersistenceIgnoreState YES is required: after the app has been launched once through
# LaunchServices (`make run`), launching Contents/MacOS/<binary> directly never creates a window
# (NSApp.windows stays empty). With the flag it always does; `open` is unaffected.
VERIFY_PNG ?= $(BUILD_DIR)/verify.png
verify: app
	rm -f "$(VERIFY_PNG)" "$(VERIFY_PNG).txt"
	HT_SCREENSHOT="$(abspath $(VERIFY_PNG))" HT_SCREENSHOT_TIMEOUT=25 \
	    timeout 40 "$(MACOS_DIR)/$(APP_NAME)" -ApplePersistenceIgnoreState YES \
	    || { echo "verify: app exited non-zero ($$?)"; exit 1; }
	@echo ">> Bundle.appResources status:"; cat "$(VERIFY_PNG).txt"; echo
	@test -s "$(VERIFY_PNG)" && echo ">> screenshot: $(VERIFY_PNG)" || { echo "verify: no screenshot written"; exit 1; }

# --- data ------------------------------------------------------------------------------
PY ?= /Users/calebsuh/miniconda3/bin/python3
sync-data:
	@test -f data/trails.json || { echo "data/trails.json not found (run tools/build_trails.py first)"; exit 1; }
	$(PY) -I tools/build_catalog.py
	@echo ">> wrote Sources/$(APP_NAME)/Resources/trails.json"

clean:
	rm -rf .build "$(BUILD_DIR)"
