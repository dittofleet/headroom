VERSION ?= dev
# Universal builds need full Xcode; the default builds for this machine only.
# CI passes: ARCHS="--arch arm64 --arch x86_64"
ARCHS ?=
APP = dist/Headroom.app
BUILD = swift build -c release $(ARCHS)

app:
	$(BUILD)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp "$$($(BUILD) --show-bin-path)/Headroom" $(APP)/Contents/MacOS/Headroom
	sed 's/VERSION/$(VERSION:v%=%)/' Info.plist > $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

zip: app
	cd dist && rm -f Headroom.zip && ditto -c -k --keepParent Headroom.app Headroom.zip

test:
	swift test

clean:
	rm -rf .build dist

.PHONY: app zip test clean
