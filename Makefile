APP_NAME    := ScreenCap
BUNDLE_ID   := com.vertusdesign.ScreenCap
VERSION     ?= 1.0.0
BUILD       ?= 1

DIST        := dist
APP         := $(DIST)/$(APP_NAME).app
CONTENTS    := $(APP)/Contents
BIN_DIR     := $(CONTENTS)/MacOS
RES_DIR     := $(CONTENTS)/Resources
PRODUCT     := .build/apple/Products/Release/$(APP_NAME)
ICONSET     := $(DIST)/AppIcon.iconset

# macOS ties the Screen Recording permission to the code signature, and an ad-hoc
# signature changes on every rebuild — which means re-granting the permission every
# time. So prefer any real signing identity in the keychain, and fall back to
# ad-hoc only when there is none. Override explicitly for distribution:
#   make dmg SIGN_ID="Developer ID Application: Name (TEAMID)"
DETECTED_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | \
	awk -F'"' '/Developer ID Application/ && NF>2 {print $$2; exit}')
ifeq ($(strip $(DETECTED_ID)),)
DETECTED_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | \
	awk -F'"' 'NF>2 {print $$2; exit}')
endif
ifeq ($(strip $(DETECTED_ID)),)
DETECTED_ID := -
endif
SIGN_ID     ?= $(DETECTED_ID)

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
		Resources/Info.plist > "$(CONTENTS)/Info.plist"
	cp Resources/AppIcon.icns "$(RES_DIR)/AppIcon.icns"
	cp -R Resources/l10n/*.lproj "$(RES_DIR)/"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	codesign --force --deep --options runtime --sign "$(SIGN_ID)" "$(APP)"
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
	rm -f "$(DIST)/$(APP_NAME)-$(VERSION).dmg"
	rm -rf "$(DIST)/dmg-root"
	mkdir -p "$(DIST)/dmg-root"
	cp -R "$(APP)" "$(DIST)/dmg-root/"
	ln -s /Applications "$(DIST)/dmg-root/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DIST)/dmg-root" \
		-ov -format UDZO "$(DIST)/$(APP_NAME)-$(VERSION).dmg"
	rm -rf "$(DIST)/dmg-root"
	@echo "Готово: $(DIST)/$(APP_NAME)-$(VERSION).dmg"

clean:
	rm -rf .build "$(DIST)"
