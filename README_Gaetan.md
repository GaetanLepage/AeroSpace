# Building AeroSpace (release) on a Nix machine

This document explains how to build the AeroSpace **release** artifact
(`AeroSpace.app` + `aerospace` CLI, both universal x86_64+arm64, codesigned and
zipped) on a macOS machine that uses Nix, and records every problem we hit
getting there and how each was fixed.

---

## TL;DR — the working build command

```
nix-shell -p ruby python3 openjdk asciidoctor --command '
  unset DEVELOPER_DIR SDKROOT CC CXX LD LD_DYLD_PATH LIBRARY_PATH \
        MACOSX_DEPLOYMENT_TARGET NIX_APPLE_SDK_VERSION NIX_BINTOOLS \
        NIX_BINTOOLS_WRAPPER_TARGET_HOST_arm64_apple_darwin NIX_CC \
        NIX_CC_WRAPPER_TARGET_HOST_arm64_apple_darwin NIX_CFLAGS_COMPILE \
        NIX_DONT_SET_RPATH NIX_DONT_SET_RPATH_FOR_BUILD NIX_ENFORCE_NO_NATIVE \
        NIX_HARDENING_ENABLE NIX_IGNORE_LD_THROUGH_GCC NIX_LDFLAGS \
        NIX_NO_SELF_RPATH
  ./build-release.sh
'
```

Two changes vs. the original naive command:
1. **`xcbuild` is removed** from `nix-shell -p`.
2. **All nix Darwin-stdenv toolchain env vars are unset** before running.

Original (broken) command was:
```
nix-shell -p ruby python3 openjdk xcbuild asciidoctor --command "./build-release.sh"
```

---

## Host prerequisites (NOT provided by nix)

The build compiles Swift via the **host** Xcode toolchain (not nix). You must
have all of the following set up on the machine before building:

1. **Full Xcode** installed (App Store) and selected:
   ```
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
   Command Line Tools alone are NOT enough — `xcodebuild -scheme` requires full
   Xcode. (We used Xcode 26.5 / Swift 6.3.2.)

2. **Xcode license accepted:**
   ```
   sudo xcodebuild -license accept
   ```
   Until this is done, `swift --version` errors out.

3. **Xcode first-launch components installed:**
   ```
   sudo xcodebuild -runFirstLaunch
   ```
   Without this, `/Library/Developer/PrivateFrameworks/CoreSimulator.framework`
   is missing and `xcodebuild` fails to load `IDESimulatorFoundation`, aborting
   the `.app` build.

4. **Self-signed code-signing certificate** named `aerospace-codesign-certificate`:
   - Keychain Access -> Certificate Assistant -> Create a Certificate
   - Name: `aerospace-codesign-certificate`
   - Identity Type: `Self-Signed Root`
   - Certificate Type: `Code Signing`
   - **Then set it to "Always Trust"** (double-click the cert -> Trust ->
     "When using this certificate: Always Trust"). A freshly created self-signed
     cert is `CSSMERR_TP_NOT_TRUSTED` until you do this.
   - Verify it is valid:
     ```
     security find-identity -v -p codesigning
     ```
     It must list `aerospace-codesign-certificate` under "valid identities".

Swift version note: the project pins Swift in `.swift-version` (e.g. 6.3.0) and
`Package.swift` declares `swift-tools-version: 6.2`. Upstream uses
[`swiftly`](https://github.com/swiftlang/swiftly) to get the exact toolchain.
We instead relied on the Swift bundled with full Xcode (6.3.2), which satisfies
the tools-version requirement. If you want reproducibility, `brew install
swiftly && swiftly install` and skip the Xcode-swift fallback.

---

## What `build-release.sh` actually does

For context, the release script (in order):
1. `build-docs.sh`   — site + man pages via `asciidoctor` (uses `pygments.rb`).
2. `build-shell-completion.sh` — builds `complgen` (Rust/cargo) then generates
   zsh/fish/bash completions.
3. `generate.sh`     — generates source files + `AeroSpace.xcodeproj` (xcodegen).
4. `check-uncommitted-files.sh` — fails if the git working tree is dirty.
5. `swift build ... --arch arm64 --arch x86_64 --product aerospace` — the CLI.
6. `xcodebuild ... -scheme AeroSpace` — the `.app`.
7. `codesign` the CLI + app, validate layout, check universal binaries + git hash.
8. zip into `.release/AeroSpace-v<version>.zip`, generate brew casks.

`script/setup.sh` (sourced by every entry script) does something important: it
**resets `PATH`** to a small whitelist:
```
${PWD}/.deps/bin:/bin:/usr/bin
```
and only bridges a hardcoded set of tools into `.deps/bin` (bash, fish, rustc,
cargo, brew, bundle, bundler, xcbeautify, git, swift, swiftly, ...). Anything
not on that list (and not in `/bin` or `/usr/bin`) becomes invisible to the
build. This is the source of several issues below.

---

## The debugging journey (every problem we hit, in order)

### 1. `error: tool 'python3' not found` (docs step)
**Symptom:**
```
Broken pipe - Failed to read response from Python process on a mentos
get_all_lexers call: error: tool 'python3' not found
```
**Cause:** `build-docs.sh` runs `asciidoctor`, which uses the `pygments.rb` gem
(see `Gemfile`) for syntax highlighting. `pygments.rb` spawns a Python
subprocess ("mentos"). But `script/setup.sh` had reset `PATH` and `python3` was
**not** on its whitelist, so even though `python3` was in the `nix-shell -p`
list, it was stripped before `asciidoctor` ran.

**Fix (committed):** add `python3` to the whitelist in `script/setup.sh`:
```
add-optional-dep-to-bin python3 # build-docs.sh (pygments.rb)
```

### 2. `error: tool 'clang' not found` (cargo / complgen step)
**Symptom:** building `complgen` (Rust) failed:
```
error: linking with `cc` failed ... error: tool 'clang' not found
```
**Cause:** same whitelist problem — `cargo`/`rustc` were whitelisted but the C
linker (`clang`/`cc`) they invoke was not.

**Initial fix (later reverted):** we temporarily whitelisted `clang`/`cc`
pointing at the nix clang wrapper. This worked for cargo BUT later **shadowed
Apple's clang** during `swift build` / `xcodebuild`, which is dangerous. Once
full Xcode was installed, Apple's `/usr/bin/cc` already satisfies cargo, so we
**removed** the nix clang/cc whitelist again. (Net result in `setup.sh`: only
the `python3` line is added.)

### 3. `error: package is using Swift tools version 6.2.0 but installed is 6.1.0`
**Cause:** the host had Swift 6.1.2 (from Command Line Tools), but
`Package.swift` requires tools-version 6.2 (and `.swift-version` pins 6.3.0).
`setup.sh`'s `swift()` function prefers `swiftly`; with no swiftly it falls back
to the host `swift`, which was too old.

**Fix:** install **full Xcode 26.5** and select it. Its bundled Swift is 6.3.2,
which satisfies the requirement. Also required accepting the Xcode license
(`sudo xcodebuild -license accept`).

### 4. Infinite `xcrun swift` recursion (fork bomb) — CPU spinning, never finishes
**Symptom:** hundreds of processes like:
```
/nix/store/...apple-sdk-14.4/usr/bin/xcrun swift --version
  -> /nix/store/...apple-sdk-14.4/usr/bin/xcrun swift --version
     -> ... (endless)
```
Low core usage, no real compilation, build never progressed past the
`swift build` step.

**Causes (two, related):**
- Passing **`xcbuild`** into the nix-shell put a fake `xcrun`/`xcodebuild`
  (a 2019-era reimplementation, `xcbuild-0.1.1`) on `PATH`, shadowing the real
  Apple tools.
- The nixpkgs Darwin stdenv exported `DEVELOPER_DIR` and `SDKROOT` pointing at a
  **nix apple-sdk**. `/usr/bin/xcrun` and `/usr/bin/swift` honor
  `DEVELOPER_DIR`, so they dispatched into the nix SDK's `xcrun`, which
  re-invoked `swift`, which re-entered `xcrun`... -> infinite recursion.

**Fix:**
- **Remove `xcbuild`** from `nix-shell -p` (real Xcode provides
  `xcrun`/`xcodebuild`/`swift`).
- **`unset DEVELOPER_DIR SDKROOT`** before building so the real toolchain
  selected via `xcode-select` is used.

### 5. `ld: unknown options: -Xlinker -isysroot -iframework -nostdlib ...`
**Symptom:** `swift build` (CLI) succeeded, but the `xcodebuild` link step failed:
```
ld: unknown options: -Xlinker -isysroot -iframework -nostdlib ...
Build failed
```
plus many `ld: warning: search path '/nix/store/.../lib' not found`.

**Cause:** the nix Darwin stdenv also exports compiler/linker wrapper variables
(`CC`, `CXX`, `LD`, `NIX_LDFLAGS`, `NIX_CFLAGS_COMPILE`, `LIBRARY_PATH`, etc.).
These leaked into Apple's build, feeding malformed flags to Apple's `ld`.

**Fix:** `unset` the full set of nix toolchain variables (see the big `unset`
in the build command above). After this, `swift build` and `xcodebuild` use the
real Xcode clang (`XcodeDefault.xctoolchain`) and the Mac SDK
(`MacOSX26.5.sdk`) cleanly for both arm64 and x86_64.

### 6. `xcodebuild failed to load a required plug-in` (CoreSimulator)
**Symptom:**
```
DVTPlugInLoading: Failed to load code for plug-in
com.apple.dt.IDESimulatorFoundation ...
Library not loaded: .../CoreSimulator.framework/.../CoreSimulator
A required plugin failed to load ... try running 'xcodebuild -runFirstLaunch'
```
**Cause:** Xcode's first-launch components were never installed;
`/Library/Developer/PrivateFrameworks/` did not even exist.
`xcodebuild -checkFirstLaunchStatus` returned non-zero.

**Fix:** `sudo xcodebuild -runFirstLaunch` (installs CoreSimulator and friends).

### 7. Code-signing certificate present but `0 valid identities`
**Symptom:** `security find-identity -v -p codesigning` showed 0 valid
identities even after creating the cert; with the policy filter it showed:
```
"aerospace-codesign-certificate" (CSSMERR_TP_NOT_TRUSTED)
```
**Cause:** a freshly created self-signed root is **not trusted** by default, so
it is excluded from "valid identities".

**Fix:** in Keychain Access, set the cert's trust to "Always Trust" (for Code
Signing). After that, `codesign -s aerospace-codesign-certificate` works and
the validation step (`codesign -v`) passes.

---

## Things that bit us around the git working tree

`build-release.sh` runs `check-uncommitted-files.sh`, which fails if
`git status --porcelain` is non-empty. Gotcha to watch for:

- **`Sources/Common/gitHashGenerated.swift`** is a generated file that must be
  committed as `"SNAPSHOT"`. During the build, `generate.sh --generate-git-hash`
  rewrites it to the real hash and `build-release.sh` does `git checkout .` at
  the end to restore it. If the build is interrupted before that `git checkout`,
  this file stays dirty — reset it with:
  ```
  git checkout -- Sources/Common/gitHashGenerated.swift
  ```
  Be careful not to accidentally commit the real-hash version.

- More generally: any uncommitted change or untracked file makes the tree dirty
  and fails the uncommitted-files check. Commit (or stash) before building.

---

## Long build time / low core usage (not a bug)

The release effectively compiles everything **twice** as a **universal binary**
(arm64 + x86_64): once via SPM (`swift build`) for the CLI, once via
`xcodebuild` for the `.app`. The Swift frontend's whole-module phases are
largely serial, so you will see long stretches with low CPU utilization. This
is expected — be patient (tens of minutes). It is not the recursion bug from #4
(that one spawns hundreds of `xcrun swift` processes and never writes to
`.build`).

---

## Final artifacts (on success)

In `.release/`:
- `aerospace` — universal CLI binary (x86_64 + arm64), codesigned
- `AeroSpace.app` — universal app bundle, codesigned
- `AeroSpace-v0.0.0-SNAPSHOT.zip` — packaged release
- `aerospace.rb`, `aerospace-dev.rb` — generated brew casks
- `xcodebuild.log` — full xcodebuild log

Verify:
```
file .release/aerospace                                   # universal binary, 2 archs
file .release/AeroSpace.app/Contents/MacOS/AeroSpace      # universal binary, 2 archs
codesign -v .release/aerospace && echo OK
codesign -v .release/AeroSpace.app && echo OK
```

---

## Installing it on your system

You have two options. The build produces a `.app`, a CLI binary, shell
completions, and man pages, plus a generated Homebrew cask
(`.release/aerospace-dev.rb`).

### Option A — Homebrew cask (recommended; matches upstream)

The project ships `install-from-sources.sh`, which rebuilds and installs the
`aerospace-dev` cask via Homebrew. It must run inside the same nix-shell with
the same env fixes as the build, because it sources `script/setup.sh`:

```
nix-shell -p ruby python3 openjdk asciidoctor --command '
  unset DEVELOPER_DIR SDKROOT CC CXX LD LD_DYLD_PATH LIBRARY_PATH \
        MACOSX_DEPLOYMENT_TARGET NIX_APPLE_SDK_VERSION NIX_BINTOOLS \
        NIX_BINTOOLS_WRAPPER_TARGET_HOST_arm64_apple_darwin NIX_CC \
        NIX_CC_WRAPPER_TARGET_HOST_arm64_apple_darwin NIX_CFLAGS_COMPILE \
        NIX_DONT_SET_RPATH NIX_DONT_SET_RPATH_FOR_BUILD NIX_ENFORCE_NO_NATIVE \
        NIX_HARDENING_ENABLE NIX_IGNORE_LD_THROUGH_GCC NIX_LDFLAGS \
        NIX_NO_SELF_RPATH
  ./install-from-sources.sh            # add --dont-rebuild to skip the rebuild
'
```

If you already built and just want to install the existing artifacts, use
`--dont-rebuild` to skip straight to the brew step.

What it installs:
- `AeroSpace.app` into the cask `appdir` (e.g. `/Applications`)
- the `aerospace` CLI into your Homebrew prefix `bin`
- zsh/bash/fish completions and man pages
- strips the `com.apple.quarantine` attribute so the app opens

To uninstall later: `brew uninstall aerospace-dev`.

Note: `install-from-sources.sh` also runs `brew install
nikitabobko/tap/brew-install-path` (a helper to install a cask from a local
`.rb` file). This needs network access the first time.

### Option B — Manual install (no Homebrew)

Copy the app and CLI out of `.release/` yourself:

```
# App bundle
cp -R .release/AeroSpace.app /Applications/

# CLI (pick a dir on your PATH; here ~/.local/bin)
mkdir -p ~/.local/bin
cp .release/aerospace ~/.local/bin/

# Remove Gatekeeper quarantine (self-signed app)
xattr -dr com.apple.quarantine /Applications/AeroSpace.app
xattr -d  com.apple.quarantine ~/.local/bin/aerospace 2>/dev/null || true
```

Optional — shell completions and man pages (from the unpacked release dir
`.release/AeroSpace-v0.0.0-SNAPSHOT/`):
```
rel=.release/AeroSpace-v0.0.0-SNAPSHOT
# zsh completion (adjust to a dir in your $fpath)
cp "$rel/shell-completion/zsh/_aerospace"      ~/.zsh/completions/   # example
# fish
cp "$rel/shell-completion/fish/aerospace.fish" ~/.config/fish/completions/
# bash
cp "$rel/shell-completion/bash/aerospace"      ~/.local/share/bash-completion/completions/aerospace
# man pages
cp "$rel"/manpage/*.1 ~/.local/share/man/man1/   # ensure this is on your MANPATH
```

### First launch (either option)

1. Launch `AeroSpace.app` (it lives in the menu bar).
2. Grant **Accessibility** permission when prompted:
   System Settings -> Privacy & Security -> Accessibility -> enable AeroSpace.
   (Required for a window manager; it cannot move windows without it.)
3. Because the app is signed with a **self-signed** cert, Gatekeeper may warn on
   first open. If you didn't strip quarantine above, right-click the app ->
   Open, or run the `xattr -dr com.apple.quarantine ...` command.
4. Config lives at `~/.aerospace.toml` (or `~/.config/aerospace/aerospace.toml`).
   The default config is bundled at
   `AeroSpace.app/Contents/Resources/default-config.toml`.

### Start at login

Either enable "Start AeroSpace at login" from the app's menu-bar icon, or add
`start-at-login = true` to your `~/.aerospace.toml`.

---

## Summary of repo changes made this session

- `script/setup.sh`: added `add-optional-dep-to-bin python3` so `pygments.rb`
  (asciidoctor docs) can find Python.
