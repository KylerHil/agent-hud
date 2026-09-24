# AgentWatch build entry points. Run `make help` for the list.
SHELL := /bin/bash
BUILD_DIR := .build/release
REPORTER_DEST := $(HOME)/.agentwatch/bin/agentwatch-report

.PHONY: help build test fake fake-loop install-reporter clean

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

install-reporter: build ## Copy the reporter to ~/.agentwatch/bin
	@mkdir -p $(dir $(REPORTER_DEST))
	install -m 0755 $(BUILD_DIR)/agentwatch-report $(REPORTER_DEST)
	@echo "installed $(REPORTER_DEST)"

clean: ## Remove build outputs
	rm -rf .build build
