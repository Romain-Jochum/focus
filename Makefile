# Focus: build, test and install. A fresh clone needs Swift and uv, then `make install` (see README.md).
.PHONY: test snapshots probe garden app identity install uninstall clean

# Override for private scratch builds, e.g. SWIFT_BUILD='swift build --scratch-path .scratch/pkg'
SWIFT_BUILD ?= swift build
IDENTITY := Focus Local Signing
MODEL := Resources/rfdetr-nano.mlpackage
APP := .build/Focus.app
INSTALLED := $(HOME)/Applications/Focus.app

# Engine, rules and store checks (an executable runner: the Command Line Tools ship no XCTest)
test:
	@$(SWIFT_BUILD) --product FocusTests -q && "$$($(SWIFT_BUILD) --product FocusTests --show-bin-path)/FocusTests"

# Every view in light and dark, as PNGs in .build/snapshots
snapshots:
	@$(SWIFT_BUILD) --product Focus -q && "$$($(SWIFT_BUILD) --product Focus --show-bin-path)/Focus" --snapshots .build/snapshots

# Live sensor readout and the CPU and memory budget check, on the release bundle
probe: app
	$(APP)/Contents/MacOS/Focus --probe

# The garden alone with a level slider, to see it grow level by level (nothing is saved)
garden: app
	$(APP)/Contents/MacOS/Focus --garden-preview

# Release binary, assembled into a signed bundle at .build/Focus.app
app: Resources/AppIcon.icns $(MODEL)
	$(SWIFT_BUILD) -c release --product Focus
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$($(SWIFT_BUILD) -c release --product Focus --show-bin-path)/Focus" $(APP)/Contents/MacOS/Focus
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	cp -R $(MODEL) $(APP)/Contents/Resources/
	cp -R Resources/Garden $(APP)/Contents/Resources/
	@if security find-identity -p codesigning | grep -q '"$(IDENTITY)"'; then \
		SIGN='$(IDENTITY)'; \
	else \
		echo "warning: identity '$(IDENTITY)' missing, falling back to ad-hoc signing (run make identity)"; \
		SIGN=-; \
	fi; \
	codesign --force --deep -s "$$SIGN" --identifier com.rj.focus $(APP)

# Phone detector (52 MB, not in git), exported once from the pinned RF-DETR release
$(MODEL):
	./scripts/make-model.sh $@

# App icon, drawn by scripts/make-icon.swift; regenerated when the script changes
Resources/AppIcon.icns: scripts/make-icon.swift
	rm -rf .build/AppIcon.iconset
	swift scripts/make-icon.swift .build/AppIcon.iconset
	iconutil -c icns .build/AppIcon.iconset -o $@
	rm -rf .build/AppIcon.iconset

identity:
	@./scripts/make-identity.sh

install: identity app
	-pkill -f "$(INSTALLED)/Contents/MacOS/Focus"
	mkdir -p $(HOME)/Applications
	rm -rf $(INSTALLED)
	ditto $(APP) $(INSTALLED)
	open $(INSTALLED)

uninstall:
	-pkill -f "$(INSTALLED)/Contents/MacOS/Focus"
	rm -rf $(INSTALLED)

# Build output only; the exported model is kept (delete $(MODEL) to export it again)
clean:
	rm -rf .build .scratch
