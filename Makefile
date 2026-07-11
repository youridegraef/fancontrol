APP_NAME = FanControl
BUILD_DIR = .build/release
APP_BUNDLE = build/$(APP_NAME).app
PREFIX = /usr/local

.PHONY: all build app install uninstall clean

all: app

build:
	swift build -c release

app: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp $(BUILD_DIR)/FanControlApp $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp $(BUILD_DIR)/fanctl $(APP_BUNDLE)/Contents/Resources/fanctl
	codesign --force --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

# Installs the fanctl helper setuid root (SMC writes require root) and
# copies the app to /Applications. Run `make app` as your own user first;
# building as root leaves root-owned files in .build/ and build/.
install:
	@test -d $(APP_BUNDLE) || { echo "run 'make app' first (as your own user, not root)"; exit 1; }
	install -o root -g wheel -m 4755 $(BUILD_DIR)/fanctl $(PREFIX)/bin/fanctl
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP_BUNDLE) /Applications/
	@echo "Installed $(PREFIX)/bin/fanctl (setuid root) and /Applications/$(APP_NAME).app"

uninstall:
	rm -f $(PREFIX)/bin/fanctl
	rm -rf /Applications/$(APP_NAME).app

clean:
	swift package clean
	rm -rf build
