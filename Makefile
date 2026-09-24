SWIFT_FLAGS ?= -O
SIGN_ID ?= -
MIN_OS ?= 14.0
ARCHS ?= arm64 x86_64
NOTARY_PROFILE ?= netmenu-notary

VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
BUILD := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)
DIST_DIR := dist
DIST_ZIP := $(DIST_DIR)/NetMenu-$(VERSION).zip
ICON := images/AppIcon.icns

.PHONY: build check test app run dist notarize icon clean

# Command Line Tools ship Swift Testing outside the default search path; Xcode finds it on its own.
TESTING_FW := $(shell xcode-select -p)/Library/Developer/Frameworks
TESTING_LIB := $(shell xcode-select -p)/Library/Developer/usr/lib
TEST_FLAGS := $(if $(wildcard $(TESTING_FW)/Testing.framework),\
	-Xswiftc -F -Xswiftc $(TESTING_FW) -Xlinker -F -Xlinker $(TESTING_FW) \
	-Xlinker -rpath -Xlinker $(TESTING_FW) -Xlinker -rpath -Xlinker $(TESTING_LIB))

SOURCES = constants.swift latency.swift health.swift netmenu.swift main.swift
ARCH_BINS = $(foreach a,$(ARCHS),build/NetMenu-$(a))

build/NetMenu-%: $(SOURCES)
	mkdir -p build
	swiftc $(SWIFT_FLAGS) -target $*-apple-macos$(MIN_OS) $(SOURCES) -o $@

build/NetMenu: $(ARCH_BINS)
	lipo -create -output $@ $(ARCH_BINS)

build: build/NetMenu

check: build/NetMenu
	./build/NetMenu --sample > /tmp/netmenu_check.txt
	cat /tmp/netmenu_check.txt
	tail -n 1 /tmp/netmenu_check.txt | /usr/bin/env python3 -m json.tool > /dev/null

test:
	swift test $(TEST_FLAGS)

$(ICON): scripts/generate-icon.swift
	swift scripts/generate-icon.swift
	rm -rf images/AppIcon.iconset
	mkdir -p images/AppIcon.iconset
	sips -z 16 16     images/AppIcon-1024.png --out images/AppIcon.iconset/icon_16x16.png >/dev/null
	sips -z 32 32     images/AppIcon-1024.png --out images/AppIcon.iconset/icon_16x16@2x.png >/dev/null
	sips -z 32 32     images/AppIcon-1024.png --out images/AppIcon.iconset/icon_32x32.png >/dev/null
	sips -z 64 64     images/AppIcon-1024.png --out images/AppIcon.iconset/icon_32x32@2x.png >/dev/null
	sips -z 128 128   images/AppIcon-1024.png --out images/AppIcon.iconset/icon_128x128.png >/dev/null
	sips -z 256 256   images/AppIcon-1024.png --out images/AppIcon.iconset/icon_128x128@2x.png >/dev/null
	sips -z 256 256   images/AppIcon-1024.png --out images/AppIcon.iconset/icon_256x256.png >/dev/null
	sips -z 512 512   images/AppIcon-1024.png --out images/AppIcon.iconset/icon_256x256@2x.png >/dev/null
	sips -z 512 512   images/AppIcon-1024.png --out images/AppIcon.iconset/icon_512x512.png >/dev/null
	sips -z 1024 1024 images/AppIcon-1024.png --out images/AppIcon.iconset/icon_512x512@2x.png >/dev/null
	iconutil -c icns images/AppIcon.iconset -o $(ICON)
	rm -rf images/AppIcon.iconset images/AppIcon-1024.png

icon: $(ICON)

app: build/NetMenu $(ICON)
	rm -rf NetMenu.app
	mkdir -p NetMenu.app/Contents/MacOS NetMenu.app/Contents/Resources
	cp build/NetMenu NetMenu.app/Contents/MacOS/NetMenu
	cp Info.plist NetMenu.app/Contents/
	cp $(ICON) NetMenu.app/Contents/Resources/AppIcon.icns
	@if [ "$(SIGN_ID)" = "-" ]; then \
		codesign --force --sign - NetMenu.app; \
	else \
		codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" NetMenu.app; \
	fi

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
