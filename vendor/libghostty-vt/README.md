# libghostty-vt (prebuilt, pinned)

Terminal-emulation core of [Ghostty](https://github.com/ghostty-org/ghostty),
consumed as a prebuilt universal static library. Used by
`Frameworks/Terminal` for the integrated terminal pane. License: MIT
(bundled highway/simdutf: Apache-2.0/MIT) — GPLv3-compatible.

## Pin

- Upstream repo:   https://github.com/ghostty-org/ghostty
- Upstream commit: `c5a21edfcbc2d5b46540ad91b7980aca31f5f1f3` (2026-07-14)
- Source asset:    `ghostty-vt.xcframework.zip` from the `tip` release
                   (https://github.com/ghostty-org/ghostty/releases/tag/tip)
- Asset sha256:    `2bc7bbe06e14107d3d3e67cc79016e836af180f47ce2106c5f464b89ce5d5702`
- lib sha256:      `55263afdaaaef73a42f6c07f2d578214735744eab435e4662797480422e9034d`
  (`lib/libghostty-vt.a`, fat: x86_64 + arm64, from the
  `macos-arm64_x86_64` slice of the xcframework)

`include/ghostty/` is the `Headers/ghostty/` tree from the same slice,
byte-for-byte. Consumers must define `GHOSTTY_STATIC` (the CMake target
here does it via an INTERFACE definition).

## Why a committed binary

The C API we need (`terminal.h`, `render.h`, `selection.h`, …) exists
only on upstream tip; tagged releases (≤ v1.3.1) do not contain it. The
`tip` release asset is overwritten on every upstream commit, so a given
pin can never be re-downloaded — committing the artifact is the only
reproducible option. Building from source instead requires Zig 0.15.2+
(`zig build -Demit-lib-vt -Doptimize=ReleaseFast`), which we deliberately
keep out of TextMate's toolchain.

## Update procedure

Upstream declares this API unstable; expect compile breaks in
`Frameworks/Terminal` when bumping, and budget time accordingly.

1. Download `ghostty-vt.xcframework.zip` and its `.minisig` from the
   `tip` release; note the upstream commit the release page shows.
2. Verify the minisign signature against Ghostty's published public key
   (see https://ghostty.org/docs — "Binary verification").
3. Unzip; from `macos-arm64_x86_64/` copy `libghostty-vt.a` over
   `lib/libghostty-vt.a` and `Headers/ghostty/` over `include/ghostty/`
   (delete the old header tree first — files get removed upstream).
4. `lipo -info lib/libghostty-vt.a` must list `x86_64 arm64`.
5. Update the Pin section above (commit, date, both sha256 hashes).
6. Clean build (`make clean && make`), fix any API breaks in
   `Frameworks/Terminal`, and re-run its tests plus the manual
   spot-checks below.

## Manual spot-checks after a bump

The tests cover our wrapper, not the emulation itself; these exercise the
parts of it a bump can silently regress. Run them in the terminal pane:

- Full-screen TUIs render and behave correctly: `vim`, `less`, `htop`
  (or `top`), and an interactive `claude` session.
- Colors survive: `git log` (pager + colors), colored `make`/compiler
  output, and a truecolor test script.
- Resizing the pane reflows without corruption.
- Scrollback scrolls and snaps back to the bottom.
- Copy/paste works, including bracketed paste into a shell and an editor.
- `cat` on a multi-MB file stays responsive; typing latency stays
  imperceptible.
