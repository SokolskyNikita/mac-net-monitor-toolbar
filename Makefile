.DEFAULT_GOAL := build

SWIFT_FLAGS ?= -O
SWIFT_TEST_FLAGS ?=
SWIFTC ?= swiftc
SWIFT_JOBS ?= 4
MACOS_SDK ?= $(shell xcrun --sdk macosx --show-sdk-path)
SIGN_ID ?= -
MIN_OS ?= 14.0
ARCHS ?= arm64 x86_64
NOTARY_PROFILE ?= netmenu-notary

PLIST := Resources/Info.plist
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $(PLIST))
BUILD := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' $(PLIST))
DIST_DIR := dist
DIST_ZIP := $(DIST_DIR)/NetMenu-$(VERSION).zip
ICON := Resources/AppIcon.icns

.PHONY: build check test test-build app run dist notarize icon clean FORCE

# Command Line Tools ship Swift Testing outside the default search path; Xcode finds it on its own.
# Their _Testing_Foundation overlay lacks module interfaces; these tests need only core Testing.
TESTING_FW := $(shell xcode-select -p)/Library/Developer/Frameworks
TESTING_LIB := $(shell xcode-select -p)/Library/Developer/usr/lib
TEST_FLAGS := $(if $(wildcard $(TESTING_FW)/Testing.framework),\
	-Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
	-Xswiftc -F -Xswiftc $(TESTING_FW) -Xlinker -F -Xlinker $(TESTING_FW) \
	-Xlinker -rpath -Xlinker $(TESTING_FW) -Xlinker -rpath -Xlinker $(TESTING_LIB))

SOURCES := $(shell find Sources/NetMenu -type f -name '*.swift' | sort)
ARCH_BINS = $(foreach a,$(ARCHS),build/NetMenu-$(a))
ARCH_CONFIGS = $(foreach a,$(ARCHS),build/objects/$(a)/config.json)
RUN_IF_STALE = python3 scripts/run-if-stale.py $@ $(filter-out FORCE,$^) --

# These recipes check configuration on every invocation, but only change the
# prerequisite timestamps when inputs change. Unchanged builds never run swiftc.
FORCE:

$(ARCH_CONFIGS): build/objects/%/config.json: FORCE scripts/prepare-swift-build.py
	@python3 scripts/prepare-swift-build.py --cache $(@D) --compiler "$(SWIFTC)" \
		--sdk "$(MACOS_SDK)" --target "$*-apple-macos$(MIN_OS)" --jobs $(SWIFT_JOBS) -- $(SWIFT_FLAGS)

build/NetMenu-%: $(SOURCES) build/objects/%/config.json Makefile scripts/prepare-swift-build.py scripts/run-if-stale.py FORCE
	@$(RUN_IF_STALE) $(SWIFTC) $(SWIFT_FLAGS) -incremental -enable-batch-mode -j $(SWIFT_JOBS) \
		-module-name NetMenu -sdk "$(MACOS_SDK)" -target $*-apple-macos$(MIN_OS) \
		-output-file-map build/objects/$*/output-file-map.json $(SOURCES) -o $@

# Switching ARCHS must rebuild the fat binary even when its inputs are older.
build/architectures: FORCE
	@mkdir -p build
	@printf '%s\n' "$(ARCHS)" > $@.tmp
	@cmp -s $@.tmp $@ && rm $@.tmp || mv $@.tmp $@

build/NetMenu: $(ARCH_BINS) build/architectures scripts/run-if-stale.py FORCE
	@$(RUN_IF_STALE) lipo -create -output $@ $(ARCH_BINS)

build: build/NetMenu

check: build/NetMenu
	./build/NetMenu --sample > /tmp/netmenu_check.txt
	cat /tmp/netmenu_check.txt
	tail -n 1 /tmp/netmenu_check.txt | /usr/bin/env python3 -m json.tool > /dev/null

test-build:
	python3 -B -m unittest discover -s scripts/tests -v

test:
	swift test $(SWIFT_TEST_FLAGS) $(TEST_FLAGS)

$(ICON): scripts/generate-icon.swift
	swift scripts/generate-icon.swift
	rm -rf Resources/AppIcon.iconset
	mkdir -p Resources/AppIcon.iconset
	sips -z 16 16     Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_16x16.png >/dev/null
	sips -z 32 32     Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_16x16@2x.png >/dev/null
	sips -z 32 32     Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_32x32.png >/dev/null
	sips -z 64 64     Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_32x32@2x.png >/dev/null
	sips -z 128 128   Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_128x128.png >/dev/null
	sips -z 256 256   Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_128x128@2x.png >/dev/null
	sips -z 256 256   Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_256x256.png >/dev/null
	sips -z 512 512   Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_256x256@2x.png >/dev/null
	sips -z 512 512   Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_512x512.png >/dev/null
	sips -z 1024 1024 Resources/AppIcon-1024.png --out Resources/AppIcon.iconset/icon_512x512@2x.png >/dev/null
	iconutil -c icns Resources/AppIcon.iconset -o $(ICON)
	rm -rf Resources/AppIcon.iconset Resources/AppIcon-1024.png

icon: $(ICON)

BUNDLE_BINARY := NetMenu.app/Contents/MacOS/NetMenu
BUNDLE_PLIST := NetMenu.app/Contents/Info.plist
BUNDLE_ICON := NetMenu.app/Contents/Resources/AppIcon.icns
BUNDLE_SIGNATURE := NetMenu.app/Contents/_CodeSignature/CodeResources

build/sign-identity: FORCE
	@mkdir -p build
	@printf '%s\n' "$(SIGN_ID)" > $@.tmp
	@cmp -s $@.tmp $@ && rm $@.tmp || mv $@.tmp $@

$(BUNDLE_BINARY): build/NetMenu scripts/run-if-stale.py FORCE
	@$(RUN_IF_STALE) sh -ec 'mkdir -p $(@D); cp $< $@.tmp; mv $@.tmp $@'

$(BUNDLE_PLIST): $(PLIST) scripts/run-if-stale.py FORCE
	@$(RUN_IF_STALE) sh -ec 'mkdir -p $(@D); cp $< $@'

$(BUNDLE_ICON): $(ICON) scripts/run-if-stale.py FORCE
	@$(RUN_IF_STALE) sh -ec 'mkdir -p $(@D); cp $< $@'

$(BUNDLE_SIGNATURE): $(BUNDLE_BINARY) $(BUNDLE_PLIST) $(BUNDLE_ICON) build/sign-identity Makefile scripts/run-if-stale.py FORCE
	@$(RUN_IF_STALE) sh -ec 'if [ "$(SIGN_ID)" = "-" ]; then \
		codesign --force --sign - NetMenu.app; \
	else \
		codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" NetMenu.app; \
	fi; touch $@'

app: $(BUNDLE_SIGNATURE)

run: app
	open NetMenu.app

dist: app
	mkdir -p $(DIST_DIR)
	rm -f $(DIST_ZIP)
	ditto -c -k --keepParent --norsrc --noextattr --noqtn NetMenu.app $(DIST_ZIP)
	@echo "version $(VERSION) (build $(BUILD))"
	shasum -a 256 $(DIST_ZIP)

notarize: dist
	xcrun notarytool submit $(DIST_ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple NetMenu.app
	rm -f $(DIST_ZIP)
	ditto -c -k --keepParent --norsrc --noextattr --noqtn NetMenu.app $(DIST_ZIP)
	shasum -a 256 $(DIST_ZIP)

clean:
	rm -rf build .build NetMenu.app $(DIST_DIR)
