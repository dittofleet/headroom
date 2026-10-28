VERSION ?= dev
# Universal builds need full Xcode; the default builds for this machine only.
# CI passes: ARCHS="--arch arm64 --arch x86_64"
ARCHS ?=
# Developer ID identity for a distributable build. Ad-hoc when empty, which
# is all a local install needs.
IDENTITY ?=
APP = dist/Headroom.app
CLI = $(APP)/Contents/MacOS/headroom-cli
BUILD = swift build -c release $(ARCHS)

app:
	$(BUILD)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp "$$($(BUILD) --show-bin-path)/Headroom" $(APP)/Contents/MacOS/Headroom
	cp "$$($(BUILD) --show-bin-path)/headroom-cli" $(CLI)
	sed 's/VERSION/$(VERSION:v%=%)/' Info.plist > $(APP)/Contents/Info.plist
# The CLI is nested code, so it is signed first and on its own: signing the
# app only seals it, and notarization rejects it unsigned.
ifeq ($(IDENTITY),)
	codesign --force --sign - --identifier io.github.dittofleet.headroom.cli $(CLI)
	codesign --force --sign - $(APP)
else
	codesign --force --sign "$(IDENTITY)" --options runtime --timestamp --identifier io.github.dittofleet.headroom.cli $(CLI)
	codesign --force --sign "$(IDENTITY)" --options runtime --timestamp $(APP)
endif
	codesign --verify --strict $(APP)

# Installs this build. It is ad-hoc signed, so unlike a release it does not
# update itself: pull and run this again.
install: app
	./install.sh $(APP)

zip: app
	cd dist && rm -f Headroom.zip && ditto -c -k --keepParent Headroom.app Headroom.zip

# The command on its own, for Linux: static, so it runs on any distribution.
# Needs the Static Linux SDK (swift.org/install), and on a Mac the swift.org
# toolchain rather than Xcode's. LINUX_ARCH is x64 or arm64, as the release
# assets are named.
LINUX_ARCH ?= x64
LINUX_SDK = $(if $(filter arm64,$(LINUX_ARCH)),aarch64,x86_64)-swift-linux-musl
LINUX_BUILD = swift build -c release --product headroom-cli --swift-sdk $(LINUX_SDK) -Xlinker -s

linux:
	$(LINUX_BUILD)
	mkdir -p dist
	cp "$$($(LINUX_BUILD) --show-bin-path)/headroom-cli" dist/headroom-linux-$(LINUX_ARCH)

test:
	swift test

# Redraws AppIcon.icns, which is committed so a build doesn't need this.
icon:
	swift scripts/make-icon.swift

clean:
	rm -rf .build dist

.PHONY: app install zip linux test icon clean
