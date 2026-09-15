APP_NAME := Kacha
APP_DIR := build/$(APP_NAME).app
BIN := .build/release/kacha

.PHONY: build app run test clean

build:
	swift build -c release

app: build
	rm -rf $(APP_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS
	cp $(BIN) $(APP_DIR)/Contents/MacOS/
	cp support/Info.plist $(APP_DIR)/Contents/Info.plist
	codesign --force --sign - $(APP_DIR)

run: app
	open $(APP_DIR)

test:
	swift test

clean:
	swift package clean
	rm -rf build
