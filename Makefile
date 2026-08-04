# PR Stack Monitor — local build, sign, install and run.
#
# There is no .xcodeproj. `make run` assembles the .app bundle from the SwiftPM
# executable in App/ and signs it with a local identity, which keeps the whole build
# reproducible from the command line. One-time certificate setup: App/README.md.

APP_NAME      := PRStackMonitor
BUNDLE_ID     := com.jankuca.PRStackMonitor
SIGN_IDENTITY ?= PRStackMonitor Local
CONFIGURATION ?= debug
INSTALL_DIR   ?= /Applications

APP_PACKAGE  := App
CORE_PACKAGE := PRStackMonitor
BUNDLE       := build/$(APP_NAME).app

# Which fixture `make dump` derives. Any name from
# PRStackMonitor/Tests/PRStackCoreTests/Fixtures works.
FIXTURE ?= panel-2a

# Ask SwiftPM where it put the binary rather than assuming `.build/$(CONFIGURATION)`.
# That path is an internal detail — it varies by architecture and by build system, and
# `.build/debug` is only a convenience symlink the current one happens to create.
# Recursively expanded (`=`, not `:=`) so the query runs when a recipe needs the path,
# after `build` has produced it, rather than every time make parses this file.
BIN_DIR    = $(shell swift build --package-path $(APP_PACKAGE) -c $(CONFIGURATION) --show-bin-path)
EXECUTABLE = $(BIN_DIR)/PRStackMonitorApp

.PHONY: all help build bundle sign run install uninstall identity test dump clean

all: sign

help:
	@echo "make run        build, sign and launch the menu bar app"
	@echo "make build      compile the executable only"
	@echo "make bundle     assemble build/$(APP_NAME).app"
	@echo "make sign       bundle, then codesign with '$(SIGN_IDENTITY)'"
	@echo "make install    copy the signed app to $(INSTALL_DIR)"
	@echo "make uninstall  remove it from $(INSTALL_DIR)"
	@echo "make identity   list the code signing identities this Mac can use"
	@echo "make test       run the portable core's tests"
	@echo "make dump       derive a fixture and print the panel (FIXTURE=$(FIXTURE))"
	@echo "make clean      remove build products"

build:
	swift build --package-path $(APP_PACKAGE) -c $(CONFIGURATION)

bundle: build
	@test -x "$(EXECUTABLE)" || { echo "error: no executable at '$(EXECUTABLE)'"; exit 1; }
	rm -rf "$(BUNDLE)"
	mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	cp "$(EXECUTABLE)" "$(BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp "$(APP_PACKAGE)/Resources/Info.plist" "$(BUNDLE)/Contents/Info.plist"
	printf 'APPL????' > "$(BUNDLE)/Contents/PkgInfo"

# Signing with a stable self-signed identity is what keeps the designated requirement
# constant across rebuilds, which is what stops macOS re-prompting for Keychain access
# every time (IMPLEMENTATION_PLAN §0). Ad-hoc signing works but changes the hash on
# every build, so it is only the fallback.
sign: bundle
	@if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$(SIGN_IDENTITY)"; then \
		echo "codesign: $(SIGN_IDENTITY)"; \
		codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" "$(BUNDLE)"; \
	else \
		echo "warning: no code signing identity named '$(SIGN_IDENTITY)'; signing ad-hoc instead."; \
		echo "         The app runs either way, but the ad-hoc signature changes on every"; \
		echo "         rebuild, so macOS will re-prompt for Keychain access from M2 onwards."; \
		echo "         Create the certificate once — see App/README.md."; \
		codesign --force --sign - --identifier "$(BUNDLE_ID)" "$(BUNDLE)"; \
	fi
	@codesign --verify --verbose=1 "$(BUNDLE)"

run: sign
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	open "$(BUNDLE)"
	@echo "Launched. Look for the stack glyph in the menu bar and click it."

install: sign
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(BUNDLE)" "$(INSTALL_DIR)/"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"

uninstall:
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"

identity:
	@security find-identity -v -p codesigning || true

test:
	swift test --package-path $(CORE_PACKAGE)

# The panel model as text. Same renderer the golden tests compare, so the output for a
# fixture matches that fixture's golden exactly.
dump:
	@swift run --package-path $(CORE_PACKAGE) prstack-dump \
		$(CORE_PACKAGE)/Tests/PRStackCoreTests/Fixtures/$(FIXTURE).json

clean:
	rm -rf build
	swift package --package-path $(APP_PACKAGE) clean
	swift package --package-path $(CORE_PACKAGE) clean
