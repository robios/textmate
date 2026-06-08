.PHONY: all debug release clean clean-debug clean-release run package swift-build-debug swift-build-release

all: debug

swift-build-debug:
	@if command -v swift >/dev/null 2>&1; then \
		Frameworks/OakSwiftUI/build.sh debug build-debug; \
	else \
		echo "Swift not found — skipping OakSwiftUI build"; \
	fi

swift-build-release:
	@if command -v swift >/dev/null 2>&1; then \
		Frameworks/OakSwiftUI/build.sh release build-release; \
	else \
		echo "Swift not found — skipping OakSwiftUI build"; \
	fi

debug: swift-build-debug
	cmake -B build-debug -G Ninja -DCMAKE_BUILD_TYPE=Debug
	ninja -C build-debug

CS_IDENTITY ?= -

release: swift-build-release
	cmake -B build-release -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DCS_IDENTITY="$(CS_IDENTITY)"
	ninja -C build-release

package:
	@bash scripts/package.sh

run: debug
	open build-debug/Applications/TextMate/TextMate.app

clean: clean-debug clean-release

clean-debug:
	rm -rf build-debug

clean-release:
	rm -rf build-release
