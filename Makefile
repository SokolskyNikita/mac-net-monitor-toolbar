SWIFT_FLAGS=-O
SIGN_ID?=-

build:
	mkdir -p build && swiftc $(SWIFT_FLAGS) netmenu.swift -o build/NetMenu

check: build
	./build/NetMenu --sample > /tmp/netmenu_check.txt
	cat /tmp/netmenu_check.txt
	tail -n 1 /tmp/netmenu_check.txt | /usr/bin/env python3 -m json.tool > /dev/null

app: build
	mkdir -p NetMenu.app/Contents/MacOS
	cp build/NetMenu NetMenu.app/Contents/MacOS/NetMenu
	cp Info.plist NetMenu.app/Contents/
	codesign --force --sign "$(SIGN_ID)" NetMenu.app

run: app
	open NetMenu.app
