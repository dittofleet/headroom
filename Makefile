VERSION ?= dev
# Universal builds need full Xcode; the default builds for this machine only.
# CI passes: ARCHS="--arch arm64 --arch x86_64"
ARCHS ?=
# Developer ID identity for a distributable build. Ad-hoc when empty, which
# is all a local install needs.
IDENTITY ?=
APP = dist/Headroom.app
BUILD = swift build -c release $(ARCHS)

app:
	$(BUILD)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp "$$($(BUILD) --show-bin-path)/Headroom" $(APP)/Contents/MacOS/Headroom
	sed 's/VERSION/$(VERSION:v%=%)/' Info.plist > $(APP)/Contents/Info.plist
ifeq ($(IDENTITY),)
	codesign --force --sign - $(APP)
else
	codesign --force --sign "$(IDENTITY)" --options runtime --timestamp $(APP)
endif
	codesign --verify --strict $(APP)

zip: app
	cd dist && rm -f Headroom.zip && ditto -c -k --keepParent Headroom.app Headroom.zip

test:
	swift test

clean:
	rm -rf .build dist

.PHONY: app zip test clean
