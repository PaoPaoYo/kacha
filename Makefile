APP_NAME := Kacha
APP_DIR := build/$(APP_NAME).app
BIN := .build/release/kacha
# 固定开发证书签名：同证书 + 同 bundle id 下，重编译安装后 TCC 屏幕录制授权保持有效
IDENTITY := E02BEC5A142A44F2412C9A351B81B41CDC515482

.PHONY: build app install run test clean

build:
	swift build -c release

app: build
	rm -rf $(APP_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS
	cp $(BIN) $(APP_DIR)/Contents/MacOS/
	cp support/Info.plist $(APP_DIR)/Contents/Info.plist
	codesign --force --sign $(IDENTITY) $(APP_DIR)

install: app
	-@osascript -e 'quit app "Kacha"' 2>/dev/null || true
	-@sleep 1
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP_DIR) /Applications/
	open /Applications/$(APP_NAME).app
	rm -rf $(APP_DIR)

run: app
	open $(APP_DIR)

test:
	swift test

clean:
	swift package clean
	rm -rf build
