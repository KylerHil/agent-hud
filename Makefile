# Agent HUD build entry points. Run `make help` for the list.
SHELL := /bin/bash
BUILD_DIR := .build/release
REPORTER_DEST := $(HOME)/.agenthud/bin/agenthud-report
APP := build/AgentHUD.app
APP_DEST := $(HOME)/Applications/AgentHUD.app
LEGACY_APP := $(HOME)/Applications/AgentWatch.app

.PHONY: help icon build test fake fake-loop fake-clear hooks-diff install-hooks uninstall-hooks hooks-status app run install install-reporter clean release-direct release-appstore upload-appstore

help:
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

build: ## Build everything (release)
	swift build -c release

test: ## Run unit tests
	swift test

fake: build ## Play a scripted set of fake sessions through the reporter
	scripts/fake-events.sh

fake-loop: build ## Replay fake sessions forever (Ctrl-C ends them)
	scripts/fake-events.sh --loop

app: build ## Assemble and ad-hoc sign build/AgentHUD.app (for local use)
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(BUILD_DIR)/AgentHUD $(BUILD_DIR)/agenthud-report $(APP)/Contents/MacOS/
	cp Resources/AppIcon.icns Resources/PrivacyInfo.xcprivacy $(APP)/Contents/Resources/
	codesign --force --sign - --timestamp=none $(APP)/Contents/MacOS/agenthud-report
	codesign --force --sign - --timestamp=none $(APP)
	@echo "built $(APP)"

run: app ## Build and launch the app from build/
	@pkill -x AgentHUD 2>/dev/null; sleep 0.3; open $(APP)

install: app install-reporter ## Install to ~/Applications (plus the reporter); replaces AgentWatch
	@pkill -x AgentHUD 2>/dev/null; pkill -x AgentWatch 2>/dev/null; sleep 0.3
	@if [ -d "$(LEGACY_APP)" ]; then rm -rf "$(LEGACY_APP)" && echo "removed $(LEGACY_APP) (renamed to Agent HUD)"; fi
	@mkdir -p $(HOME)/Applications
	rm -rf $(APP_DEST) && cp -R $(APP) $(APP_DEST)
	open $(APP_DEST)
	@echo "installed $(APP_DEST)"

fake-clear: build ## End every fake session
	scripts/fake-events.sh --clear

install-reporter: build ## Copy the reporter to ~/.agenthud/bin
	@mkdir -p $(dir $(REPORTER_DEST))
	install -m 0755 $(BUILD_DIR)/agenthud-report $(REPORTER_DEST)
	@echo "installed $(REPORTER_DEST)"

hooks-diff: build ## Show the exact config changes install-hooks would make
	$(BUILD_DIR)/agenthud-report install-hooks --dry-run

install-hooks: install-reporter ## Back up configs, show the diff, confirm, merge hooks in
	$(REPORTER_DEST) install-hooks

uninstall-hooks: build ## Back up configs, show the diff, confirm, remove Agent HUD hooks
	$(BUILD_DIR)/agenthud-report uninstall-hooks

hooks-status: build ## Show whether hooks are installed
	$(BUILD_DIR)/agenthud-report hooks-status

icon: ## Regenerate Resources/AppIcon.icns from scripts/make-icon.swift
	@rm -rf build/AppIcon.iconset && mkdir -p build
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

release-direct: ## Developer ID build: sign, notarize, staple, DMG (docs/DISTRIBUTION.md)
	scripts/release.sh direct

release-appstore: ## Sandboxed App Store build: sign and package a .pkg (docs/DISTRIBUTION.md)
	scripts/release.sh appstore

upload-appstore: ## Build the App Store .pkg and upload it to App Store Connect (TestFlight)
	scripts/release.sh appstore --upload

clean: ## Remove build outputs
	rm -rf .build build
