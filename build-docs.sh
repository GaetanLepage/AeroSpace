#!/bin/bash
cd "$(dirname "$0")"
source ./script/setup.sh

# Use asciidoctor directly if on PATH (e.g. via nix-shell), otherwise use bundler
if command -v asciidoctor &> /dev/null; then
    run-asciidoctor() { asciidoctor "$@"; }
else
    ./script/install-dep.sh --bundler
    run-asciidoctor() { bundler exec asciidoctor "$@"; }
fi

rm -rf .site && mkdir .site
rm -rf .man && mkdir .man

cp-docs() {
    cp -r ./docs/*.adoc "$1"
    cp -r ./docs/assets "$1"
    cp -r ./docs/util "$1"
    cp -r ./docs/config-examples "$1"
}

build-site() {
    cp-docs ./.site
    cp ./docs/index.html ./.site

    cd .site
        # Delete "aerospace " prefifx in synopsis
        # Portable in-place sed (macOS sed uses -i '', GNU sed uses -i)
        if sed --version 2>/dev/null | grep -q GNU; then
            sed -E -i '/tag::synopsis/, /end::synopsis/ s/^(aerospace | {10})//' aerospace*
        else
            sed -E -i '' '/tag::synopsis/, /end::synopsis/ s/^(aerospace | {10})//' aerospace*
        fi
        run-asciidoctor ./guide.adoc ./commands.adoc ./goodies.adoc
        cp goodies.html goodness.html # backwards compatibility
        rm -rf ./*.adoc
    cd - > /dev/null

    git rev-parse HEAD > .site/version.html
    if ! test -z "$(git status --porcelain)"; then
        echo "git working directory is dirty" >> .site/version.html
    fi
}

build-man() {
    cp-docs .man
    cd .man
        run-asciidoctor -b manpage aerospace*.adoc

        # Comment by AI:
        #   gman (the g Dai client) renders bare .~ and /~ as ligatures (~ becomes ˜).
        #   We use groff's \[ti] escape (which produces a literal tilde) instead.
        #   Note: escaping .~ in asciidoc via pass:[] doesn't work because asciidoctor
        #   converts \\ to \(rs) before groff sees the input.
        # Portable in-place sed (macOS sed uses -i '', GNU sed uses -i)
        if sed --version 2>/dev/null | grep -q GNU; then
            sed -E -i 's|\.~|\.\\[ti]|g; s|/~|/\\[ti]|g' aerospace-test.1
        else
            sed -E -i '' 's|\.~|\.\\[ti]|g; s|/~|/\\[ti]|g' aerospace-test.1
        fi

        rm -rf -- *.adoc
    cd - > /dev/null
}

build-site
build-man
