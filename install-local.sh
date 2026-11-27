#!/bin/bash
# Build this checkout and install it as /Applications/AeroSpork.app, replacing whatever is there,
# then relaunch it. For running your own fork day to day; install-from-sources.sh goes through a
# Homebrew cask instead, which a later `brew upgrade` can swap for the official build.
#
#   ./install-local.sh                  build (release, signed, no docs), install, relaunch
#   ./install-local.sh --dont-rebuild   install the .release/AeroSpork.app already built
#
# Uncommitted changes stop the build, as they do for build-release.sh. Set
# AEROSPORK_ALLOW_UNCOMMITTED=1 to build them anyway.
cd "$(dirname "$0")"
source ./script/setup.sh

rebuild=1
while test $# -gt 0; do
    case $1 in
        --dont-rebuild) rebuild=0; shift ;;
        *) echo "Unknown option $1" > /dev/stderr; exit 1 ;;
    esac
done

app=/Applications/AeroSpork.app
built=.release/AeroSpork.app

if test $rebuild == 1; then
    # The last tag, then the commit: 1.3.4-fork.4ed9ec8. The commit says exactly what is installed;
    # `aerospork --version` prints it.
    last_tag="$(git describe --tags --abbrev=0 2> /dev/null || echo v0.0.0)"
    ./build-release.sh --app-only --build-version "${last_tag#v}-fork.$(git rev-parse --short HEAD)"
fi
if ! test -d "$built"; then
    echo "No $built. Run without --dont-rebuild." > /dev/stderr
    exit 1
fi

# Quit through AppKit, so AeroSpork saves its workspace memory on the way out.
if /usr/bin/pgrep -x AeroSpork > /dev/null; then
    /usr/bin/osascript -e 'quit app "AeroSpork"'
    for _ in $(seq 1 20); do
        /usr/bin/pgrep -x AeroSpork > /dev/null || break
        sleep 0.5
    done
    if /usr/bin/pgrep -x AeroSpork > /dev/null; then
        echo "AeroSpork did not quit. Quit it from the menu bar and run again." > /dev/stderr
        exit 1
    fi
fi

# Kept for a rollback until the next build, which wipes .release/:
#   ditto .release/previous/AeroSpork.app /Applications/AeroSpork.app
if test -d "$app"; then
    rm -rf .release/previous
    mkdir -p .release/previous
    mv "$app" .release/previous/
fi
/usr/bin/ditto "$built" "$app"

# The CLI. Homebrew's cask made this link; without the cask, nothing else does.
prefix="$(brew --prefix 2> /dev/null || echo /usr/local)"
if test -d "$prefix/bin" && test -w "$prefix/bin"; then
    ln -sf "$app/Contents/MacOS/aerospork-cli" "$prefix/bin/aerospork"
else
    echo "warning: $prefix/bin is missing or not writable, so the aerospork CLI is not linked" > /dev/stderr
fi
# Shell completions, where the cask put them. Copies, not links: they come from this checkout,
# which can move. Man pages need the docs build, so they are left out.
install_completion() {
    if test -d "$(dirname "$2")" && test -w "$(dirname "$2")"; then cp "$1" "$2"; fi
}
install_completion shell-completion/zsh/_aerospork "$prefix/share/zsh/site-functions/_aerospork"
install_completion shell-completion/bash/aerospork "$prefix/etc/bash_completion.d/aerospork"
install_completion shell-completion/fish/aerospork.fish "$prefix/share/fish/vendor_completions.d/aerospork.fish"

/usr/bin/open -a "$app"
for _ in $(seq 1 20); do
    if "$app/Contents/MacOS/aerospork-cli" list-workspaces --focused > /dev/null 2>&1; then
        "$app/Contents/MacOS/aerospork-cli" --version
        exit 0
    fi
    sleep 0.5
done
# A new signature, or a first install: macOS asks for Accessibility again and AeroSpork quits
# until it has it (checkAccessibilityPermissions).
echo "AeroSpork is not answering. If it asked for Accessibility, allow it in System Settings >" > /dev/stderr
echo "Privacy & Security > Accessibility, then open /Applications/AeroSpork.app again." > /dev/stderr
exit 1
