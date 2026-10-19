.PHONY: app debug run test clean

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
