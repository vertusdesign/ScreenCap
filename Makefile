APP_NAME    := ScreenCap
BUNDLE_ID   := com.vertusdesign.ScreenCap
VERSION     ?= 2.2.0
# "alpha", "beta", or empty for a stable build.
CHANNEL     ?=
BUILD       ?= 1
FULLVERSION := $(VERSION)$(if $(CHANNEL),-$(CHANNEL),)

DIST        := dist
APP         := $(DIST)/$(APP_NAME).app
CONTENTS    := $(APP)/Contents
BIN_DIR     := $(CONTENTS)/MacOS
RES_DIR     := $(CONTENTS)/Resources
PRODUCT     := .build/apple/Products/Release/$(APP_NAME)
ICONSET     := $(DIST)/AppIcon.iconset

# macOS ties the Screen Recording permission to the code signature, and an ad-hoc
# signature changes on every rebuild — which means re-granting the permission every
# time. So local builds prefer this project's own certificate, created by
# Scripts/create-signing-cert.sh.
#
# Only that exact name is looked for. Grabbing whatever identity happens to be in the
# keychain picks up certificates belonging to other projects, which then prompt for the
# password of a keychain this build has no business unlocking.
#
# Released disk images are signed ad-hoc on purpose: a self-signed certificate only one
# machine holds is worth nothing to anyone downloading the app.
#   make dmg                                     -> ad-hoc
#   make dmg SIGN_ID="Developer ID Application: Name (TEAMID)"
LOCAL_CERT  := ScreenCap Local Signing
# No -v: a self-signed certificate is reported CSSMERR_TP_NOT_TRUSTED and so is
# left out of the "valid identities" list, but codesign accepts it perfectly well
# and system trust is irrelevant for an app you built yourself.
DETECTED_ID := $(shell security find-identity -p codesigning 2>/dev/null | \
	grep -F "$(LOCAL_CERT)" >/dev/null 2>&1 && echo "$(LOCAL_CERT)")
ifeq ($(strip $(DETECTED_ID)),)
DETECTED_ID := -
endif
SIGN_ID     ?= $(DETECTED_ID)
# Distribution builds never use the local certificate.
dmg: SIGN_ID = -

.PHONY: all app run debug clean dmg install icon universal

all: app

## Debug build, straight from SwiftPM.
debug:
	swift build

## Universal (arm64 + x86_64) release binary.
universal:
	swift build -c release --arch arm64 --arch x86_64

## Assemble the .app bundle.
app: universal icon
	rm -rf "$(APP)"
	mkdir -p "$(BIN_DIR)" "$(RES_DIR)"
	cp "$(PRODUCT)" "$(BIN_DIR)/$(APP_NAME)"
	sed -e 's/__VERSION__/$(VERSION)/' -e 's/__BUILD__/$(BUILD)/' \
		-e 's/__CHANNEL__/$(CHANNEL)/' \
		Resources/Info.plist > "$(CONTENTS)/Info.plist"
	cp Resources/AppIcon.icns "$(RES_DIR)/AppIcon.icns"
	cp -R Resources/l10n/*.lproj "$(RES_DIR)/"
	mkdir -p "$(RES_DIR)/ThirdParty"
	cp Resources/ThirdParty/RNNoise-LICENSE.txt "$(RES_DIR)/ThirdParty/RNNoise-LICENSE.txt"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	codesign --force --deep --options runtime --entitlements Resources/ScreenCap.entitlements --sign "$(SIGN_ID)" "$(APP)"
	@echo "Готово: $(APP)"
	@lipo -archs "$(BIN_DIR)/$(APP_NAME)"

## Generate Resources/AppIcon.icns if it is missing or the script is newer.
icon: Resources/AppIcon.icns

Resources/AppIcon.icns: Scripts/make-icon.swift
	rm -rf "$(ICONSET)"
	mkdir -p "$(ICONSET)"
	swift Scripts/make-icon.swift "$(ICONSET)"
	iconutil -c icns "$(ICONSET)" -o Resources/AppIcon.icns
	rm -rf "$(ICONSET)"

## Build and launch, replacing any running copy.
run: app
	-pkill -x $(APP_NAME) || true
	open "$(APP)"

## Copy into /Applications.
install: app
	-pkill -x $(APP_NAME) || true
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" /Applications/
	@echo "Установлено в /Applications/$(APP_NAME).app"

## Build a distributable disk image.
dmg: app
	rm -f "$(DIST)/$(APP_NAME)-$(FULLVERSION).dmg"
	rm -rf "$(DIST)/dmg-root"
	mkdir -p "$(DIST)/dmg-root"
	cp -R "$(APP)" "$(DIST)/dmg-root/"
	ln -s /Applications "$(DIST)/dmg-root/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DIST)/dmg-root" \
		-ov -format UDZO "$(DIST)/$(APP_NAME)-$(FULLVERSION).dmg"
	rm -rf "$(DIST)/dmg-root"
	# Checksum records the bare filename: with the full path in it, a downloader
	# running `shasum -c` in their Downloads folder gets "No such file".
	cd "$(DIST)" && shasum -a 256 "$(APP_NAME)-$(FULLVERSION).dmg" > "$(APP_NAME)-$(FULLVERSION).dmg.sha256"
	@echo "Готово: $(DIST)/$(APP_NAME)-$(FULLVERSION).dmg"

clean:
	rm -rf .build "$(DIST)"
