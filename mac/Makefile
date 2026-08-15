# HermesNag — Mac app (SwiftPM, no Xcode required)
#
# Command Line Tools ship Testing.framework but NOT on the default search
# paths, and DYLD_* env vars are stripped by SIP. So the framework/library
# locations are baked in as rpaths at link time — that's what CLT_FLAGS is for.
# Without them: "no such module 'Testing'" or a dlopen failure at run time.

APP        := HermesNag
BUNDLE     := .build/$(APP).app
CONFIG     ?= release

CLT_FW     := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIB    := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
CLT_FLAGS  := -Xswiftc -F -Xswiftc $(CLT_FW) \
              -Xlinker -F -Xlinker $(CLT_FW) \
              -Xlinker -rpath -Xlinker $(CLT_FW) \
              -Xlinker -rpath -Xlinker $(CLT_LIB)

.PHONY: help build test bundle run clean

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Build the executable
	swift build -c $(CONFIG)

test: ## Run unit tests (swift-testing)
	swift test $(CLT_FLAGS)

bundle: build ## Assemble and ad-hoc sign HermesNag.app
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp .build/$(CONFIG)/$(APP) $(BUNDLE)/Contents/MacOS/
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/
	@codesign --force --sign - $(BUNDLE)
	@codesign --verify --verbose $(BUNDLE) 2>&1 | sed 's/^/    /'
	@echo "==> $(BUNDLE)"

run: bundle ## Build, bundle, and launch
	@pkill -x $(APP) 2>/dev/null || true
	@open $(BUNDLE)
	@echo "==> launched — look for the bell in your menu bar"

clean: ## Remove build artifacts
	rm -rf .build
