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

APP_PACKAGE := App
EXECUTABLE  := $(APP_PACKAGE)/.build/$(CONFIGURATION)/PRStackMonitorApp
BUNDLE      := build/$(APP_NAME).app

.PHONY: all help build bundle sign run install uninstall identity clean

all: sign

help:
	@echo "make run        build, sign and launch the menu bar app"
	@echo "make build      compile the executable only"
	@echo "make bundle     assemble build/$(APP_NAME).app"
	@echo "make sign       bundle, then codesign with '$(SIGN_IDENTITY)'"
	@echo "make install    copy the signed app to $(INSTALL_DIR)"
	@echo "make uninstall  remove it from $(INSTALL_DIR)"
	@echo "make identity   list the code signing identities this Mac can use"
	@echo "make clean      remove build products"

build:
	swift build --package-path $(APP_PACKAGE) -c $(CONFIGURATION)

bundle: build
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

clean:
	rm -rf build
	swift package --package-path $(APP_PACKAGE) clean
