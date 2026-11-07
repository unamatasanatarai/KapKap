.DEFAULT_GOAL := help
.PHONY: help setup signing-setup build run kill test dmg release revoke clean

APP_NAME  ?= $(shell bash -c 'source ./scripts/config.sh && echo "$$APP_NAME"')
BUNDLE_ID ?= $(shell bash -c 'source ./scripts/config.sh && echo "$$BUNDLE_ID"')
APP_BUNDLE := build/$(APP_NAME).app

## help: Display this help message
help:
	@echo "Usage: make [target]   (release: make release <x.y.z>)"
	@echo ""
	@echo "Targets:"
	@awk '/^##/ { printf "  \033[36m%-20s\033[0m %s\n", substr($$2, 1, length($$2)-1), substr($$0, index($$0, $$3)) }' $(MAKEFILE_LIST)

## setup: Configure app ID and app name
setup:
	@./scripts/setup.sh

## signing-setup: Create the self-signed code-signing certificate (once; no Apple account)
signing-setup:
	@./scripts/signing_setup.sh

## build: Compile application bundle (.app), incrementing BUILD_NUMBER
build:
	@./scripts/build.sh

## run: Kill running app, rebuild, and launch application
run: kill build
	@echo "==> Launching $(APP_NAME).app..."
	@open "$(APP_BUNDLE)"

## kill: Terminate running application instances
kill:
	@echo "==> Terminating running $(APP_NAME) instances..."
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@sleep 0.2

## test: Run native Swift unit test suite
test:
	@./scripts/test.sh

## dmg: Build styled DMG distribution package
dmg:
	@./scripts/build_dmg.sh

# Capture positional arguments for release targets (e.g. make release 1.1.0)
ifeq ($(firstword $(MAKECMDGOALS)),release)
  RELEASE_TARGET_VERSION := $(word 2,$(MAKECMDGOALS))
  ifneq ($(RELEASE_TARGET_VERSION),)
    $(eval $(RELEASE_TARGET_VERSION):;@:)
  endif
endif

# Only accept VERSION from the make command line, never from the environment.
RELEASE_VERSION := $(or $(RELEASE_TARGET_VERSION),$(if $(filter command line,$(origin VERSION)),$(VERSION)))

## release: Release a new, higher version (make release <x.y.z>), build DMG, tag & publish
release:
	@if [ -z "$(RELEASE_VERSION)" ]; then \
		echo "Error: A version is required: make release <x.y.z> (current: $$(cat VERSION))" >&2; \
		exit 1; \
	fi
	@./scripts/release.sh "$(RELEASE_VERSION)"

## revoke: Reset permissions and clear macOS caches
revoke:
	@echo "==> Revoking macOS permissions for $(BUNDLE_ID) and resetting caches..."
	@tccutil reset All "$(BUNDLE_ID)" 2>/dev/null || true
	@touch "$(APP_BUNDLE)" 2>/dev/null || true
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$(APP_BUNDLE)" 2>/dev/null || true
	@qlmanage -r 2>/dev/null || true
	@qlmanage -r cache 2>/dev/null || true
	@killall Dock 2>/dev/null || true
	@echo "✅ Revoke and cache reset complete."

## clean: Remove build artifacts and temporary files
clean:
	@echo "==> Cleaning build artifacts..."
	@rm -rf build .build /tmp/RunSwiftTests*
	@echo "✅ Clean complete."
