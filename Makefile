APP_NAME    := ScreenCap
VERSION     ?= 3.0.0

# `base` is the public ScreenCap 3 product. `pro` adds the private Player
# source layer from a sibling checkout and is never installable by this target.
BUILD_FLAVOR ?= base
ifneq ($(filter base pro,$(BUILD_FLAVOR)),$(BUILD_FLAVOR))
$(error BUILD_FLAVOR must be base or pro)
endif

ifeq ($(BUILD_FLAVOR),pro)
BUNDLE_ID       := com.vertusdesign.ScreenCap.Pro3
BUNDLE_NAME     := ScreenCap 3 Pro
URL_SCHEME      := screencap-pro3
APP_BUNDLE      := ScreenCap 3 Pro.app
PRIVATE_DIR     ?= $(CURDIR)/../ScreenCap-Pro-Private
PLAYER_SOURCE   := $(PRIVATE_DIR)/Player
PRIVATE_L10N    := $(PRIVATE_DIR)/l10n
PLIST_TEMPLATE  := $(PRIVATE_DIR)/Info-Pro.plist
SCREENCAP_PRO   := 1
PRODUCT_LABEL   := ScreenCap-3-Pro
else
BUNDLE_ID       := com.vertusdesign.ScreenCap
BUNDLE_NAME     := ScreenCap 3
URL_SCHEME      := screencap
APP_BUNDLE      := ScreenCap 3.app
PLIST_TEMPLATE  := Resources/Info.plist
SCREENCAP_PRO   := 0
PRODUCT_LABEL   := ScreenCap-3
endif

CHANNEL     ?=
BUILD       ?= 1
FULLVERSION := $(VERSION)$(if $(CHANNEL),-$(CHANNEL),)

DIST        := dist
APP         := $(DIST)/$(APP_BUNDLE)
CONTENTS    := $(APP)/Contents
BIN_DIR     := $(CONTENTS)/MacOS
RES_DIR     := $(CONTENTS)/Resources
BUILD_PATH  := .build/$(BUILD_FLAVOR)
PRODUCT     := $(BUILD_PATH)/apple/Products/Release/$(APP_NAME)
ICONSET     := $(DIST)/AppIcon.iconset

# Local builds prefer the project's own certificate so rebuilding does not
# create a new TCC identity on every run. Distribution DMGs remain ad-hoc.
LOCAL_CERT  := ScreenCap Local Signing
DETECTED_ID := $(shell security find-identity -p codesigning 2>/dev/null | \
	grep -F "$(LOCAL_CERT)" >/dev/null 2>&1 && echo "$(LOCAL_CERT)")
ifeq ($(strip $(DETECTED_ID)),)
DETECTED_ID := -
endif
SIGN_ID     ?= $(DETECTED_ID)
dmg: SIGN_ID = -

.PHONY: all app run debug clean dmg install icon universal prepare-sources

all: app

## Stage the private Player source only for a Pro build.
prepare-sources:
ifeq ($(BUILD_FLAVOR),pro)
	@test -d "$(PLAYER_SOURCE)" || (echo "Missing private Pro sources: $(PLAYER_SOURCE)" >&2; exit 1)
	@test -f "$(PLIST_TEMPLATE)" || (echo "Missing private Pro Info.plist: $(PLIST_TEMPLATE)" >&2; exit 1)
	mkdir -p "Sources/ScreenCap/Player"
	find "Sources/ScreenCap/Player" -type f ! -name .gitkeep -delete
	cp -R "$(PLAYER_SOURCE)/." "Sources/ScreenCap/Player/"
else
	find "Sources/ScreenCap/Player" -type f ! -name .gitkeep -delete
endif

debug: prepare-sources
	SCREENCAP_PRO=$(SCREENCAP_PRO) swift build --build-path "$(BUILD_PATH)"

universal: prepare-sources
	SCREENCAP_PRO=$(SCREENCAP_PRO) swift build --build-path "$(BUILD_PATH)" -c release --arch arm64 --arch x86_64

app: universal icon
	rm -rf "$(APP)"
	mkdir -p "$(BIN_DIR)" "$(RES_DIR)"
	cp "$(PRODUCT)" "$(BIN_DIR)/$(APP_NAME)"
	sed -e 's/__BUNDLE_ID__/$(BUNDLE_ID)/' -e 's/__BUNDLE_NAME__/$(BUNDLE_NAME)/' \
		-e 's/__URL_SCHEME__/$(URL_SCHEME)/' -e 's/__VERSION__/$(VERSION)/' -e 's/__BUILD__/$(BUILD)/' \
		-e 's/__CHANNEL__/$(CHANNEL)/' "$(PLIST_TEMPLATE)" > "$(CONTENTS)/Info.plist"
	cp Resources/AppIcon.icns "$(RES_DIR)/AppIcon.icns"
	cp -R Resources/l10n/*.lproj "$(RES_DIR)/"
ifeq ($(BUILD_FLAVOR),pro)
	python3 Scripts/merge_pro_resources.py "$(RES_DIR)" "$(PRIVATE_L10N)"
endif
	mkdir -p "$(RES_DIR)/ThirdParty"
	cp Resources/ThirdParty/RNNoise-LICENSE.txt "$(RES_DIR)/ThirdParty/RNNoise-LICENSE.txt"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	codesign --force --deep --options runtime --entitlements Resources/ScreenCap.entitlements --sign "$(SIGN_ID)" "$(APP)"
	@echo "Built $(APP)"
	@lipo -archs "$(BIN_DIR)/$(APP_NAME)"

icon: Resources/AppIcon.icns

Resources/AppIcon.icns: Scripts/make-icon.swift
	rm -rf "$(ICONSET)"
	mkdir -p "$(ICONSET)"
	swift Scripts/make-icon.swift "$(ICONSET)"
	iconutil -c icns "$(ICONSET)" -o "Resources/AppIcon.icns"
	rm -rf "$(ICONSET)"

run: app
ifeq ($(BUILD_FLAVOR),base)
	-pkill -x $(APP_NAME) || true
endif
	open "$(APP)"

install: app
ifeq ($(BUILD_FLAVOR),pro)
	@echo "Refusing to install the Pro flavor; launch it from dist instead." >&2
	@exit 1
else
	-pkill -x $(APP_NAME) || true
	-rm -rf "/Applications/ScreenCap.app"
	-rm -rf "/Applications/ScreenCap 3.app"
	cp -R "$(APP)" "/Applications/ScreenCap 3.app"
	@echo "Installed /Applications/ScreenCap 3.app"
endif

dmg: app
	rm -f "$(DIST)/$(PRODUCT_LABEL)-$(FULLVERSION).dmg"
	rm -rf "$(DIST)/dmg-root"
	mkdir -p "$(DIST)/dmg-root"
	cp -R "$(APP)" "$(DIST)/dmg-root/"
	ln -s /Applications "$(DIST)/dmg-root/Applications"
	hdiutil create -volname "$(BUNDLE_NAME)" -srcfolder "$(DIST)/dmg-root" \
		-ov -format UDZO "$(DIST)/$(PRODUCT_LABEL)-$(FULLVERSION).dmg"
	rm -rf "$(DIST)/dmg-root"
	cd "$(DIST)" && shasum -a 256 "$(PRODUCT_LABEL)-$(FULLVERSION).dmg" > "$(PRODUCT_LABEL)-$(FULLVERSION).dmg.sha256"
	@echo "Created $(DIST)/$(PRODUCT_LABEL)-$(FULLVERSION).dmg"

clean:
	rm -rf .build "$(DIST)"
