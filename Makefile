.PHONY: app debug run test clean dmg icon

app:
	scripts/build-app.sh release

debug:
	scripts/build-app.sh debug

run: debug
	open build/debug/Snapora.app

test:
	cargo test --workspace

clean:
	cargo clean
	rm -rf build macos/.build macos/Generated macos/App/Generated

dmg:
	scripts/package.sh

icon:
	swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o macos/Resources/AppIcon.icns
