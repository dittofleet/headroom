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
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp "$$($(BUILD) --show-bin-path)/Headroom" $(APP)/Contents/MacOS/Headroom
	sed 's/VERSION/$(VERSION:v%=%)/' Info.plist > $(APP)/Contents/Info.plist
ifeq ($(IDENTITY),)
	codesign --force --sign - $(APP)
else
	codesign --force --sign "$(IDENTITY)" --options runtime --timestamp $(APP)
endif
	codesign --verify --strict $(APP)

# Installs this build. It is ad-hoc signed, so unlike a release it does not
# update itself: pull and run this again.
install: app
	./install.sh $(APP)

zip: app
	cd dist && rm -f Headroom.zip && ditto -c -k --keepParent Headroom.app Headroom.zip

test:
	swift test

# Redraws AppIcon.icns, which is committed so a build doesn't need this.
icon:
	swift scripts/make-icon.swift

clean:
	rm -rf .build dist

.PHONY: app install zip test icon clean
