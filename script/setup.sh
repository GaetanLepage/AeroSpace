#!/bin/bash
set -e # Exit if one of commands exit with non-zero exit code
set -u # Treat unset variables and parameters other than the special parameters '@' or '*' as an error
set -o pipefail # Any command failed in the pipe fails the whole pipe
# set -x # Print shell commands as they are executed (or you can try -v which is less verbose)

# Don't forget to also update ./ShellParserGenerated/Package.swift
export antlr_version="4.13.1"

# Nix stdenv on macOS injects toolchain wrappers (xcbuild, clang, cctools, ld)
# and sets DEVELOPER_DIR/SDKROOT/NIX_CC/NIX_LDFLAGS/etc. to Nix store paths.
# These are incompatible with Apple's native tooling (swift, xcodebuild, xcrun).
# Reset all Nix compiler/linker env vars and filter Nix toolchain paths.
if [[ "${IN_NIX_SHELL:-}" == "impure" || "${IN_NIX_SHELL:-}" == "pure" ]]; then
    unset DEVELOPER_DIR SDKROOT
    unset NIX_CC NIX_CFLAGS_COMPILE NIX_LDFLAGS
    unset NIX_CC_WRAPPER_TARGET_HOST_arm64_apple_darwin
    unset NIX_BINTOOLS_WRAPPER_TARGET_HOST_arm64_apple_darwin
    unset NIX_ENFORCE_NO_NATIVE
    unset LIBRARY_PATH LD LD_DYLD_PATH
    _filtered_path=""
    IFS=: read -ra _path_parts <<< "$PATH"
    for _p in "${_path_parts[@]}"; do
        case "$_p" in
            *xcbuild*|*clang*|*cctools*) ;;
            *) _filtered_path="${_filtered_path:+${_filtered_path}:}$_p" ;;
        esac
    done
    export PATH="$_filtered_path"
    unset _filtered_path _path_parts _p
fi

# Alias: 'not-outdated-bash' points to bash (used by build-shell-completion.sh)
not-outdated-bash() { bash "$@"; }

swift() {
    if command -v swiftly &> /dev/null; then
        swiftly run swift "$@"
    else
        echo "warning: swiftly is not installed. Fallback to plain swift. Swift compilation might not be reproducible" > /dev/stderr
        command swift --version
        command swift "$@"
    fi
}

xcodebuild-pretty() {
    log_file="$1"
    shift
    # Mute stderr
    # 2024-02-12 23:48:11.713 xcodebuild[60777:7403664] [MT] DVTAssertions: Warning in /System/Volumes/Data/SWE/Apps/DT/BuildRoots/BuildRoot11/ActiveBuildRoot/Library/Caches/com.apple.xbs/Sources/IDEFrameworks/IDEFrameworks-22269/IDEFoundation/Provisioning/Capabilities Infrastructure/IDECapabilityQuerySelection.swift:103
    # Details:  createItemModels creation requirements should not create capability item model for a capability item model that already exists.
    # Function: createItemModels(for:itemModelSource:)
    # Thread:   <_NSMainThread: 0x6000037202c0>{number = 1, name = main}
    # Please file a bug at https://feedbackassistant.apple.com with this warning message and any useful information you can provide.
    if command -v xcbeautify &> /dev/null; then
        /usr/bin/xcrun xcodebuild "$@" 2>&1 | tee "$log_file" | xcbeautify --quiet # Only print tasks that have warnings or errors
        echo "The full unmodified xcodebuild log is saved to $log_file"
    else
        /usr/bin/xcrun xcodebuild "$@" 2>&1 | tee "$log_file"
    fi
}
