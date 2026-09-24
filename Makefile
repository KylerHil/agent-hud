# AgentWatch build entry points. Run `make help` for the list.
SHELL := /bin/bash
BUILD_DIR := .build/release
REPORTER_DEST := $(HOME)/.agentwatch/bin/agentwatch-report
APP := build/AgentWatch.app
APP_DEST := $(HOME)/Applications/AgentWatch.app

.PHONY: help build test fake fake-loop fake-clear hooks-diff install-hooks uninstall-hooks hooks-status app run install install-reporter clean

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

app: build ## Assemble and ad-hoc sign build/AgentWatch.app
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(BUILD_DIR)/AgentWatch $(BUILD_DIR)/agentwatch-report $(APP)/Contents/MacOS/
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(APP)/Contents/Resources/; fi
	codesign --force --sign - --timestamp=none $(APP)/Contents/MacOS/agentwatch-report
	codesign --force --sign - --timestamp=none $(APP)
	@echo "built $(APP)"

run: app ## Build and launch the app from build/
	@pkill -x AgentWatch 2>/dev/null; sleep 0.3; open $(APP)

install: app install-reporter ## Install to ~/Applications (plus the reporter)
	@pkill -x AgentWatch 2>/dev/null; sleep 0.3
	@mkdir -p $(HOME)/Applications
	rm -rf $(APP_DEST) && cp -R $(APP) $(APP_DEST)
	open $(APP_DEST)
	@echo "installed $(APP_DEST)"

fake-clear: build ## End every fake session
	scripts/fake-events.sh --clear

install-reporter: build ## Copy the reporter to ~/.agentwatch/bin
	@mkdir -p $(dir $(REPORTER_DEST))
	install -m 0755 $(BUILD_DIR)/agentwatch-report $(REPORTER_DEST)
	@echo "installed $(REPORTER_DEST)"

hooks-diff: build ## Show the exact config changes install-hooks would make
	$(BUILD_DIR)/agentwatch-report install-hooks --dry-run

install-hooks: install-reporter ## Back up configs, show the diff, confirm, merge hooks in
	$(REPORTER_DEST) install-hooks

uninstall-hooks: build ## Back up configs, show the diff, confirm, remove AgentWatch hooks
	$(BUILD_DIR)/agentwatch-report uninstall-hooks

hooks-status: build ## Show whether hooks are installed
	$(BUILD_DIR)/agentwatch-report hooks-status

clean: ## Remove build outputs
	rm -rf .build build
