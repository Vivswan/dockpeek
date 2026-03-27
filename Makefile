SWIFT_FILES := $(shell find DockPeek -name '*.swift' -type f)
APP_NAME    := DockPeek
BUNDLE_ID   := com.dockpeek.app
VERSION     := 1.5.7
TARGET      := arm64-apple-macos14.0
SWIFT_FLAGS := -swift-version 5 -target $(TARGET) -parse-as-library \
               -framework AppKit -framework SwiftUI \
               -framework CoreGraphics -framework ApplicationServices \
               -framework ScreenCaptureKit

SIGN_ID     := DockPeek Development
INSTALL_APP := /Applications/$(APP_NAME).app
INSTALL_BIN := $(INSTALL_APP)/Contents/MacOS/$(APP_NAME)

.PHONY: build release clean install dev run dist open generate setup kill lint lint-fix format format-check check hooks test

# ============================================================
# DEVELOPMENT WORKFLOW (recommended)
#
#   1. First time:  make setup    (install + grant permissions)
#   2. After edits: make dev      (hot-swap binary, no re-grant)
#   3. Stop:        make kill
# ============================================================

# --- Shared helpers (called by build targets) ---

# Copy resources into an app bundle: $(call bundle-resources,<bundle-dir>)
define bundle-resources
	@cp DockPeek/Info.plist $(1)/Contents/Info.plist
	@cp DockPeek/Resources/AppIcon.icns $(1)/Contents/Resources/AppIcon.icns
	@cp -R DockPeek/Resources/en.lproj $(1)/Contents/Resources/
	@cp -R DockPeek/Resources/ko.lproj $(1)/Contents/Resources/
endef

# Sign an app bundle: $(call sign-app,<bundle-dir>)
define sign-app
	@codesign --force --sign "$(SIGN_ID)" $(1)
endef

# --- Development workflow ---

# First-time setup: build, install to /Applications, launch
setup: release
	@mkdir -p "$(INSTALL_APP)/Contents/MacOS" "$(INSTALL_APP)/Contents/Resources"
	@cp -R build/Release/$(APP_NAME).app/ "$(INSTALL_APP)/"
	@xattr -cr "$(INSTALL_APP)"
	@echo ""
	@echo "=== DockPeek installed to /Applications ==="
	@echo "Opening now — grant Accessibility permission when prompted."
	@echo "After granting, use 'make dev' for fast rebuilds (no re-grant needed)."
	@echo ""
	@open "$(INSTALL_APP)"

# Fast dev cycle: rebuild binary and swap into /Applications in-place
# Keeps the same app bundle so macOS preserves granted permissions
dev: kill
	@echo "Compiling..."
	@mkdir -p build/Debug
	@swiftc $(SWIFT_FLAGS) -Onone -g -o build/Debug/$(APP_NAME) $(SWIFT_FILES)
	@if [ ! -d "$(INSTALL_APP)" ]; then \
		echo "Error: Run 'make setup' first to install DockPeek.app"; exit 1; \
	fi
	@cp build/Debug/$(APP_NAME) "$(INSTALL_BIN)"
	$(call bundle-resources,"$(INSTALL_APP)")
	$(call sign-app,"$(INSTALL_APP)")
	@echo "Binary updated. Launching..."
	@open "$(INSTALL_APP)"

# Kill running instance
kill:
	@pkill -x $(APP_NAME) 2>/dev/null || true

# --- Standard builds (for distribution / CI) ---

build:
	@mkdir -p build/Debug/$(APP_NAME).app/Contents/MacOS \
	          build/Debug/$(APP_NAME).app/Contents/Resources
	swiftc $(SWIFT_FLAGS) -Onone -g -o build/Debug/$(APP_NAME).app/Contents/MacOS/$(APP_NAME) $(SWIFT_FILES)
	$(call bundle-resources,build/Debug/$(APP_NAME).app)
	$(call sign-app,build/Debug/$(APP_NAME).app)
	@echo "Built: build/Debug/$(APP_NAME).app"

release:
	@mkdir -p build/Release/$(APP_NAME).app/Contents/MacOS \
	          build/Release/$(APP_NAME).app/Contents/Resources
	swiftc $(SWIFT_FLAGS) -O -whole-module-optimization \
		-o build/Release/$(APP_NAME).app/Contents/MacOS/$(APP_NAME) $(SWIFT_FILES)
	$(call bundle-resources,build/Release/$(APP_NAME).app)
	$(call sign-app,build/Release/$(APP_NAME).app)
	@echo "Built: build/Release/$(APP_NAME).app"

run: build
	@xattr -cr build/Debug/$(APP_NAME).app
	open build/Debug/$(APP_NAME).app

dist: release
	cd build/Release && zip -r ../../$(APP_NAME).zip $(APP_NAME).app
	@echo "Created $(APP_NAME).zip"
	@shasum -a 256 $(APP_NAME).zip

install: release
	cp -R build/Release/$(APP_NAME).app /Applications/
	@xattr -cr /Applications/$(APP_NAME).app
	@echo "Installed to /Applications/$(APP_NAME).app"

clean:
	rm -rf build DerivedData DockPeek.xcodeproj $(APP_NAME).zip

# --- Tests ---
# Compiles all production + test sources with -DTESTING and runs via XCTest.
# Uses Xcode's toolchain and SDK since XCTest requires the full platform SDK
# (the Command Line Tools SDK doesn't include the Swift XCTest overlay).

XCODE_DEV     := /Applications/Xcode.app/Contents/Developer
XCODE_SWIFTC  := $(XCODE_DEV)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
MACOS_PLAT    := $(XCODE_DEV)/Platforms/MacOSX.platform/Developer
MACOS_SDK     := $(MACOS_PLAT)/SDKs/MacOSX.sdk
XCTEST_FW     := $(MACOS_PLAT)/Library/Frameworks
XCTEST_PFW    := $(MACOS_PLAT)/Library/PrivateFrameworks
XCTEST_LIB    := $(MACOS_PLAT)/usr/lib
TEST_SOURCES  := $(shell find DockPeek -name '*.swift' -type f) $(shell find Tests -name '*.swift' -type f)

test:
	@mkdir -p build/Test
	@echo "Compiling tests..."
	@$(XCODE_SWIFTC) $(SWIFT_FLAGS) -DTESTING \
		-sdk $(MACOS_SDK) \
		-F $(XCTEST_FW) \
		-F $(XCTEST_PFW) \
		-I $(XCTEST_LIB) \
		-L $(XCTEST_LIB) \
		-Xlinker -rpath -Xlinker $(XCTEST_FW) \
		-Xlinker -rpath -Xlinker $(XCTEST_PFW) \
		-Xlinker -rpath -Xlinker $(XCTEST_LIB) \
		-o build/Test/DockPeekTests $(TEST_SOURCES)
	@echo "Running tests..."
	@./build/Test/DockPeekTests

# --- Code Quality ---
# Requires: brew install swiftlint swiftformat
# Note: SwiftLint requires Xcode.app (not just Command Line Tools).
#   If you see SourceKit errors, run: sudo xcode-select -s /Applications/Xcode.app

# Lint Swift sources (excludes Vendor/ per .swiftlint.yml)
lint:
	@command -v swiftlint >/dev/null 2>&1 || { echo "Install SwiftLint: brew install swiftlint"; exit 1; }
	swiftlint lint --config .swiftlint.yml

# Lint and auto-fix what can be fixed
lint-fix:
	@command -v swiftlint >/dev/null 2>&1 || { echo "Install SwiftLint: brew install swiftlint"; exit 1; }
	swiftlint lint --fix --config .swiftlint.yml
	swiftlint lint --config .swiftlint.yml

# Format Swift sources (excludes Vendor/ per .swiftformat)
format:
	@command -v swiftformat >/dev/null 2>&1 || { echo "Install SwiftFormat: brew install swiftformat"; exit 1; }
	swiftformat DockPeek

# Check formatting without modifying files (CI-friendly)
format-check:
	@command -v swiftformat >/dev/null 2>&1 || { echo "Install SwiftFormat: brew install swiftformat"; exit 1; }
	swiftformat --lint DockPeek

# Run all code quality checks (lint + format check)
check:
	@echo "=== SwiftLint ==="
	@$(MAKE) lint
	@echo ""
	@echo "=== SwiftFormat ==="
	@$(MAKE) format-check
	@echo ""
	@echo "✅ All checks passed"

# Install git hooks from hooks/ directory
hooks:
	git config core.hooksPath hooks
	@echo "Git hooks installed (using hooks/ directory)"

# --- Xcode project (requires XcodeGen + Xcode.app) ---

generate:
	@command -v xcodegen >/dev/null 2>&1 || { echo "Install XcodeGen: brew install xcodegen"; exit 1; }
	xcodegen generate
	@echo "Generated DockPeek.xcodeproj"

open: generate
	open DockPeek.xcodeproj
