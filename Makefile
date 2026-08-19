APP_NAME    := ScreenCap
VERSION     ?= 3.0.0

# `base` is the public ScreenCap 3 product. `pro` adds the private Player
# source layer from a sibling checkout. The two bundle identifiers are distinct,
# so both builds may be installed side by side while Pro is being validated.
BUILD_FLAVOR ?= base
ifneq ($(filter base pro,$(BUILD_FLAVOR)),$(BUILD_FLAVOR))
$(error BUILD_FLAVOR must be base or pro)
endif

# The Pro source checkout is intentionally independent from this public
# repository.  It must have its own private remote; this path is only a local
# build input and is never copied into the public Git history.
PRIVATE_DIR    ?= $(CURDIR)/../ScreenCap-Pro-Private
PRIVATE_REMOTE ?= origin

ifeq ($(BUILD_FLAVOR),pro)
BUNDLE_ID       := com.vertusdesign.ScreenCap.Pro3
BUNDLE_NAME     := ScreenCap 3 Pro
URL_SCHEME      := screencap-pro3
APP_BUNDLE      := ScreenCap 3 Pro.app
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
# Every packaging invocation gets a unique local CFBundleVersion unless a
# caller explicitly supplies BUILD (for example CI's run number). The number
# is shown in About and must never be reused for a different app build.
BUILD_STATE ?= .screencap-build-number
ifndef BUILD
BUILD       := $(shell Scripts/next-build-number.sh "$(BUILD_STATE)")
endif
FULLVERSION := $(VERSION)$(if $(CHANNEL),-$(CHANNEL),)

DIST        := dist
APP         := $(DIST)/$(APP_BUNDLE)
CONTENTS    := $(APP)/Contents
BIN_DIR     := $(CONTENTS)/MacOS
RES_DIR     := $(CONTENTS)/Resources
BUILD_PATH  := .build/$(BUILD_FLAVOR)
PRODUCT     := $(BUILD_PATH)/apple/Products/Release/$(APP_NAME)
ARM64_PRODUCT := $(BUILD_PATH)/arm64/arm64-apple-macosx/release/$(APP_NAME)
X86_PRODUCT   := $(BUILD_PATH)/x86_64/x86_64-apple-macosx/release/$(APP_NAME)
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

.PHONY: all app run debug clean dmg install icon universal prepare-sources \
	private-status private-sync-check

all: app

## Stage the private Player source only for a Pro build.
prepare-sources:
ifeq ($(BUILD_FLAVOR),pro)
	@test -d "$(PLAYER_SOURCE)" || (echo "Missing private Pro sources: $(PLAYER_SOURCE)" >&2; exit 1)
	@test -f "$(PLIST_TEMPLATE)" || (echo "Missing private Pro Info.plist: $(PLIST_TEMPLATE)" >&2; exit 1)
	@test "$$(git -C "$(PRIVATE_DIR)" rev-parse --is-inside-work-tree 2>/dev/null)" = true || (echo "Private Pro source directory is not a Git worktree: $(PRIVATE_DIR)" >&2; echo "Initialize it and configure its private remote before building Pro." >&2; exit 1)
	mkdir -p "Sources/ScreenCap/Player"
	find "Sources/ScreenCap/Player" -type f ! -name .gitkeep -delete
	cp -R "$(PLAYER_SOURCE)/." "Sources/ScreenCap/Player/"
else
	find "Sources/ScreenCap/Player" -type f ! -name .gitkeep -delete
endif

# Show the private checkout state without changing it.  This is deliberately
# separate from a build so local development can inspect the public and private
# histories independently.
private-status:
	@test -d "$(PRIVATE_DIR)" || (echo "Missing private Pro checkout: $(PRIVATE_DIR)" >&2; exit 1)
	@test "$$(git -C "$(PRIVATE_DIR)" rev-parse --is-inside-work-tree 2>/dev/null)" = true || (echo "Private Pro source directory is not a Git worktree: $(PRIVATE_DIR)" >&2; exit 1)
	@echo "Private Pro checkout: $(PRIVATE_DIR)"
	@git -C "$(PRIVATE_DIR)" status --short --branch
	@git -C "$(PRIVATE_DIR)" remote -v

# Verify that the private checkout is committed and aligned with its private
# upstream.  Run `git fetch --prune $(PRIVATE_REMOTE)` first, or pass
# PRIVATE_FETCH=1 to let this target refresh the remote-tracking refs.
private-sync-check:
	@test -d "$(PRIVATE_DIR)" || (echo "Missing private Pro checkout: $(PRIVATE_DIR)" >&2; exit 1)
	@test "$$(git -C "$(PRIVATE_DIR)" rev-parse --is-inside-work-tree 2>/dev/null)" = true || (echo "Private Pro source directory is not a Git worktree: $(PRIVATE_DIR)" >&2; exit 1)
	@if [ "$(PRIVATE_FETCH)" = "1" ]; then git -C "$(PRIVATE_DIR)" fetch --prune "$(PRIVATE_REMOTE)"; fi
	@test -n "$$(git -C "$(PRIVATE_DIR)" remote get-url "$(PRIVATE_REMOTE)" 2>/dev/null)" || (echo "Private Pro checkout has no '$(PRIVATE_REMOTE)' remote; configure its private repository before syncing." >&2; exit 1)
	@test -n "$$(git -C "$(PRIVATE_DIR)" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || (echo "Private Pro checkout has no upstream; push its branch to $(PRIVATE_REMOTE) and set the upstream before syncing." >&2; exit 1)
	@test -z "$$(git -C "$(PRIVATE_DIR)" status --porcelain)" || (echo "Private Pro checkout has uncommitted changes; commit them before syncing." >&2; exit 1)
	@set -- $$(git -C "$(PRIVATE_DIR)" rev-list --left-right --count HEAD...@{u}); test "$$1" = 0 && test "$$2" = 0 || (echo "Private Pro checkout is not synchronized with its upstream (ahead $$1, behind $$2)." >&2; exit 1)
	@echo "Private Pro checkout is clean and synchronized with $(PRIVATE_REMOTE)."

debug: prepare-sources
	SCREENCAP_PRO=$(SCREENCAP_PRO) swift build --build-path "$(BUILD_PATH)"

universal: prepare-sources
	# SwiftPM/Xcode 16.4 rejects a combined multi-architecture invocation for
	# targets using Swift language mode 6. Build each slice explicitly and merge
	# the finished executables; this keeps the release artifact universal while
	# remaining compatible with older and newer Swift 6 toolchains.
	SCREENCAP_PRO=$(SCREENCAP_PRO) swift build --build-path "$(BUILD_PATH)/arm64" -c release --arch arm64
	SCREENCAP_PRO=$(SCREENCAP_PRO) swift build --build-path "$(BUILD_PATH)/x86_64" -c release --arch x86_64
	mkdir -p "$(dir $(PRODUCT))"
	lipo -create "$(ARM64_PRODUCT)" "$(X86_PRODUCT)" -output "$(PRODUCT)"

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
	-pkill -f '/Applications/ScreenCap 3\.app/Contents/MacOS/ScreenCap$$' || true
	-pkill -f '/Applications/ScreenCap\.app/Contents/MacOS/ScreenCap$$' || true
	-pkill -f '$(CURDIR)/dist/ScreenCap 3\.app/Contents/MacOS/ScreenCap$$' || true
endif
	open "$(APP)"

install: app
ifeq ($(BUILD_FLAVOR),pro)
	-pkill -f '/Applications/ScreenCap 3 Pro\.app/Contents/MacOS/ScreenCap$$' || true
	-rm -rf "/Applications/ScreenCap 3 Pro.app"
	cp -R "$(APP)" "/Applications/ScreenCap 3 Pro.app"
	@echo "Installed /Applications/ScreenCap 3 Pro.app"
else
	-pkill -f '/Applications/ScreenCap 3\.app/Contents/MacOS/ScreenCap$$' || true
	-pkill -f '/Applications/ScreenCap\.app/Contents/MacOS/ScreenCap$$' || true
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
