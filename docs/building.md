# Building

## Requirements

* macOS 14.0 (Sonoma) or later — this is also the deployment target.
* Xcode, a full install rather than just the Command Line Tools: the build
  shells out to `xcrun ibtool` and `xcrun actool` to compile the nibs and the
  asset catalog. Point the active developer directory at it if needed:

  ```sh
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```

* [ninja][] — the generator CMake drives.
* [cmake][] 3.21 or later.
* [swift][] — optional. It builds `Frameworks/OakSwiftUI`, which provides the
  SwiftUI parts of the UI (the command palette and the completion popup).
  Without it the build still succeeds; those features are compiled out.

```sh
brew install ninja cmake
```

## Getting the source

The repository uses submodules (CxxTest, the document icons, Onigmo, kvdb):

```sh
git clone --recursive https://github.com/robios/textmate.git
cd textmate
```

If you already cloned without `--recursive`:

```sh
git submodule update --init --recursive
```

## Build commands

```sh
make            # same as `make debug`
make debug      # incremental debug build (-Os, -g, AddressSanitizer)
make release    # incremental release build (thin LTO, dead stripping, no ASan)
make run        # build debug and launch the result
make clean      # remove build-debug and build-release
```

`make` first builds OakSwiftUI via `Frameworks/OakSwiftUI/build.sh`, then
configures and runs ninja. If `swift` is not on `PATH` the Swift step is
skipped with a message.

The built application lands in the build tree:

| Configuration | Path                                              | Bundle identifier              |
|---------------|---------------------------------------------------|--------------------------------|
| Debug         | `build-debug/Applications/TextMate/TextMate.app`   | `com.macromates.TextMate-dev`  |
| Release       | `build-release/Applications/TextMate/TextMate.app` | `com.macromates.TextMate`      |

The debug build carries its own identifier and is named *TextMate-dev*, so it
coexists with an installed TextMate instead of replacing it.

If a Debug build keeps bouncing in the Dock before any window appears, sample
the process to check whether it is stuck in AddressSanitizer initialization.
Some macOS Tahoe/toolchain combinations have an
[ASan startup deadlock](https://github.com/llvm/llvm-project/pull/182943).
For that case, disable ASan and rebuild:

```sh
cmake -B build-debug -G Ninja -DCMAKE_BUILD_TYPE=Debug -DTEXTMATE_ENABLE_ASAN=OFF
make run
```

This keeps debug symbols and assertions, but disables ASan's memory-error
checks. The setting persists in `build-debug` for subsequent builds. To restore
ASan, configure with `-DTEXTMATE_ENABLE_ASAN=ON` and rebuild.

## CMake presets

`CMakePresets.json` defines two configure presets that match what the Makefile
does, for when you would rather drive CMake yourself or point an IDE at the
project:

```sh
cmake --preset debug     # → build-debug/
cmake --preset release   # → build-release/
ninja -C build-debug
```

Re-run the configure step after switching branches in a way that adds or
removes source files: the source globs are not `CONFIGURE_DEPENDS`, so ninja
will otherwise link stale objects.

## Tests

Tests are built when `BUILD_TESTING` is on, which is CMake's default for the
debug preset (`make release` turns it off). They run through CTest:

```sh
cd build-debug && ctest --output-on-failure
```

## Building from within TextMate

Install the *Ninja* bundle from *Preferences → Bundles*, then press ⌘B. You
may need `PATH` to include the directory holding `ninja` and `cmake` — set it
in *Preferences → Variables* or in `~/.tm_properties`.

## Packaging a release

```sh
make package patch    # bump the patch component
make package minor    # bump the minor component
```

This runs `scripts/prepare_release.rb` — which requires a clean worktree, bumps
the latest `v*` tag and tags the commit — followed by `scripts/package.sh`,
which does a signed release build, notarizes it with `notarytool` and staples
the ticket. Signing and notarization need a *Developer ID Application*
certificate and a `notarytool` keychain profile; the machine that publishes
releases names them in an untracked `scripts/package.conf` (`CS_IDENTITY`,
`NOTARY_PROFILE`), so this path is only useful to whoever does.

The version number itself comes from `git describe --tags --match "v*"`, so a
checkout without tags reports the fallback version.

[ninja]: https://ninja-build.org/
[cmake]: https://cmake.org/
[swift]: https://www.swift.org/
