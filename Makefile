BIN     := apple-stt-wyoming
RELEASE := .build/release/AppleSTT
DEBUG   := .build/debug/AppleSTT
PREFIX  := /usr/local/bin

.PHONY: build release run run-debug run-local-mic run-oww-local oww-local tts-local run-all run-ha satellite install uninstall clean

## Default: debug build
build:
	swift build

## Optimized release build
release:
	swift build -c release

## Run Wyoming STT server only
run: release
	$(RELEASE)

## Run the debug binary with verbose logging
run-debug: build
	$(DEBUG) --debug

## Run with local mic passthru only (no wake word)
run-local-mic: release
	$(RELEASE) --local-mic

## Start wake word server locally — creates .oww-venv on first run
oww-local:
	./scripts/run-oww-local.sh

## Start TTS server locally — creates tts/.venv on first run
tts-local:
	./scripts/run-tts-local.sh

## STT daemon wired to local OWW (run after oww-local)
run-oww-local: release
	$(RELEASE) --local-mic | jq --unbuffered -c .

## Run all three servers — LOCAL mode (Mac orchestrates: wake→STT→LLM/HA→say)
## Requires oww.host set in config.json. Fast, fewest round trips.
run-all: release
	@command -v .oww-venv/bin/honcho >/dev/null 2>&1 || \
		(./scripts/run-oww-local.sh --setup-only && .oww-venv/bin/pip install --quiet honcho)
	.oww-venv/bin/honcho start

## Run all three servers — HA mode (HA orchestrates the full pipeline)
## Mac exposes OWW (10400), STT (10300), TTS (10200), satellite (10700).
## Add satellite in HA: Settings → Devices → Wyoming Protocol → mac-ip:10700
run-ha: release
	@command -v .oww-venv/bin/honcho >/dev/null 2>&1 || \
		(./scripts/run-oww-local.sh --setup-only && .oww-venv/bin/pip install --quiet honcho)
	.oww-venv/bin/honcho start -f Procfile.ha

## Run the Wyoming satellite only (streams Mac mic to HA)
satellite:
	./scripts/run-satellite.sh

## Install to /usr/local/bin (or PREFIX=...)
install: release
	install -m 755 $(RELEASE) $(PREFIX)/$(BIN)
	@echo "Installed to $(PREFIX)/$(BIN)"

## Remove installed binary
uninstall:
	rm -f $(PREFIX)/$(BIN)
	@echo "Removed $(PREFIX)/$(BIN)"

## Clean build artifacts and venvs
clean:
	swift package clean
	rm -rf .oww-venv tts/.venv
