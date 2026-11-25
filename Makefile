APP := dist/Pointer.app

.PHONY: build run clean

build:
	swift build -c release
	install -d "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	install -m 644 Info.plist "$(APP)/Contents/Info.plist"
	install -m 644 Resources/Pointer.icns "$(APP)/Contents/Resources/Pointer.icns"
	install "$$(swift build -c release --show-bin-path)/Pointer" "$(APP)/Contents/MacOS/Pointer"
	codesign --force --sign - "$(APP)"

run: build
	open "$(APP)"

clean:
	swift package clean
	rm -rf "$(APP)"
