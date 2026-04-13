# This is the release toolchain for Swift 5.7.3, but you need the Swift download, the Xcode version lacks the fuzzer
# To get this number, run:
# plutil -extract CFBundleIdentifier raw /Library/Developer/Toolchains/swift-5.7.3-RELEASE.xctoolchain/Info.plist
TOOLCHAINS=org.swift.573202201171a

SCHEME=Soyeht
PROJECT=TerminalApp/Soyeht.xcodeproj
SIMULATOR_NAME ?= iPhone 16
DESTINATION_ID ?= $(shell xcrun simctl list devices available | awk -F '[()]' -v name='$(SIMULATOR_NAME)' '{gsub(/^[[:space:]]+|[[:space:]]+$$/, "", $$1); if ($$1 == name) id=$$2} END {print id}')
DESTINATION ?= $(if $(DESTINATION_ID),id=$(DESTINATION_ID),platform=iOS Simulator,name=$(SIMULATOR_NAME))

.PHONY: all build test test-spm clean regen-unicode-width build-fuzzer run-fuzzer clone-esctest

all: build

# --- Main targets ---

build:
	set -o pipefail && xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
		2>&1 | xcbeautify

test:
	set -o pipefail && xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
		2>&1 | xcbeautify

test-spm:
	SWIFT_TEST_DISABLE_PARALLELIZATION=1 swift test -v

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	swift package clean

# --- Utilities ---

regen-unicode-width:
	python3 scripts/regen_unicode_width_data.py

build-fuzzer:
	xcrun --toolchain $(TOOLCHAINS) swift build -Xswiftc "-sanitize=fuzzer" -Xswiftc "-parse-as-library"

run-fuzzer:
	./.build/debug/SwiftTermFuzz ../SwiftTermFuzzerCorpus -rss_limit_mb=40480 -jobs=12

clone-esctest:
	@if [ -d esctest ]; then \
		echo "esctest directory already exists, updating..."; \
		cd esctest && git fetch && git checkout python3 && git pull; \
	else \
		git clone --branch python3 https://github.com/migueldeicaza/esctest.git esctest; \
	fi
