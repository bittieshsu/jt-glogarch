#!/bin/bash
# jt-glogarch — PDF Reports runtime dependencies (Chromium + CJK font)
# Author: Jason Cheng (Jason Tools)
#
# The PDF Reports feature renders HTML via a headless Chromium (Playwright) and
# needs a CJK font so Traditional-Chinese reports don't come out as blank tofu
# boxes. The `playwright` Python package itself is installed by pip (the
# [report] extra); this helper installs the two HOST-level pieces pip can't:
#
#   1. The Chromium browser binary — into a SHARED path ($INSTALL_DIR/.playwright)
#      that the unprivileged service user (jt-glogarch) can read. (The default
#      ~/.cache/ms-playwright lands in root's home, unreadable by the service.)
#   2. A CJK font (WenQuanYi Zen Hei).
#
# Everything here is BEST-EFFORT: core archiving works without PDF reports, so a
# failure warns loudly but never aborts the install/upgrade.
#
# Sourced by install.sh / upgrade.sh (online) and upgrade-offline.sh (offline).
#   install_report_deps <PIP_FLAGS> [BUNDLE_DIR]
# When BUNDLE_DIR is given (offline), Chromium + font come from the bundle
# instead of the network; BUNDLE_DIR/chromium-*.tar.gz and BUNDLE_DIR/fonts/*.

install_report_deps() {
    local pip_flags="$1"
    local bundle_dir="$2"
    local service_user="jt-glogarch"
    local install_dir="${JT_INSTALL_DIR:-/opt/jt-glogarch}"
    local browsers_dir="$install_dir/.playwright"

    echo ""
    echo "=== PDF Reports runtime deps (Chromium + CJK font) ==="

    # --- 1. CJK font (so Chinese reports aren't blank boxes) ---
    if fc-list :lang=zh 2>/dev/null | grep -qiE "wenquanyi|noto sans cjk|noto.*cjk"; then
        echo "  [font] CJK font already present — skip."
    elif [ -n "$bundle_dir" ]; then
        local font
        font=$(ls "$bundle_dir"/fonts/*.ttc "$bundle_dir"/fonts/*.ttf 2>/dev/null | head -1)
        if [ -n "$font" ]; then
            mkdir -p /usr/share/fonts/truetype/jt-glogarch
            cp "$font" /usr/share/fonts/truetype/jt-glogarch/
            fc-cache -f >/dev/null 2>&1 || true
            echo "  [font] installed from bundle: $(basename "$font")"
        else
            echo "  [font] ⚠ no bundled CJK font — Chinese PDFs may show blank boxes."
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        if apt-get install -y fonts-wqy-zenhei >/dev/null 2>&1; then
            fc-cache -f >/dev/null 2>&1 || true
            echo "  [font] installed fonts-wqy-zenhei via apt."
        else
            echo "  [font] ⚠ could not apt-install fonts-wqy-zenhei — install a CJK font manually."
        fi
    else
        echo "  [font] ⚠ apt-get not found — install a CJK font (e.g. WenQuanYi) manually."
    fi

    # --- 2. Chromium browser into the shared, service-readable path ---
    # Present means the revision THIS Playwright needs, not just any Chromium:
    # an upgrade that brings a newer Playwright (the --ignore-installed path
    # above installs the latest) needs a newer browser build, and "chromium-1228
    # exists, skip" left a customer with "Executable doesn't exist at
    # .../chromium_headless_shell-1243/...".
    mkdir -p "$browsers_dir"
    local missing
    missing=$(_report_browser_dirs_missing "$browsers_dir")
    if [ -z "$missing" ] && _report_browser_dirs_known "$browsers_dir"; then
        echo "  [chromium] the build this Playwright needs is already in $browsers_dir — skip."
    elif [ -n "$bundle_dir" ]; then
        local tb
        tb=$(ls "$bundle_dir"/chromium-*.tar.gz 2>/dev/null | head -1)
        if [ -n "$tb" ]; then
            tar xzf "$tb" -C "$browsers_dir"
            echo "  [chromium] extracted from bundle: $(basename "$tb")"
        else
            echo "  [chromium] ⚠ no bundled Chromium — PDF rendering unavailable offline."
        fi
    else
        if PLAYWRIGHT_BROWSERS_PATH="$browsers_dir" python3 -m playwright install chromium >/dev/null 2>&1; then
            echo "  [chromium] installed via playwright."
        else
            echo "  [chromium] ⚠ 'playwright install chromium' failed — PDF rendering unavailable."
            echo "             (is the [report] extra installed? pip install '$install_dir'[report])"
        fi
        # Chromium's shared-library prerequisites (libnss3, libatk, …). Needs apt.
        if command -v apt-get >/dev/null 2>&1; then
            python3 -m playwright install-deps chromium >/dev/null 2>&1 \
                || echo "  [chromium] (note: install-deps for OS libraries failed — see 'playwright install-deps')"
        fi
    fi

    # Builds an older Playwright needed are dead weight (~300 MB each) once the
    # required one is present; never remove anything before that.
    if [ -z "$(_report_browser_dirs_missing "$browsers_dir")" ] && _report_browser_dirs_known "$browsers_dir"; then
        _report_prune_stale_browsers "$browsers_dir"
    fi

    # The service reads Chromium as jt-glogarch; hand ownership over.
    chown -R "$service_user":"$service_user" "$browsers_dir" 2>/dev/null || true
    echo "=== Reports deps step complete ==="
}

# These helpers run inside install.sh / upgrade.sh, which use `set -e`: each one
# must end with status 0 except _report_browser_dirs_known (only ever used as an
# `if` condition). A helper whose last test happened to be false aborted the
# whole upgrade between installing the new code and restarting the service.

# Browser directories the INSTALLED Playwright expects under $1 (one per line),
# from its own `install --dry-run`. Empty when Playwright is missing or too old
# to answer — callers treat that as "unknown", never as "present".
_report_browser_dirs_needed() {
    local browsers_dir="$1"
    { PLAYWRIGHT_BROWSERS_PATH="$browsers_dir" python3 -m playwright install --dry-run chromium 2>/dev/null \
        | sed -n 's/^ *Install location: *//p' | sort -u; } || true
    return 0
}

_report_browser_dirs_known() {
    [ -n "$(_report_browser_dirs_needed "$1")" ]
}

_report_browser_dirs_missing() {
    local d
    while read -r d; do
        if [ -n "$d" ] && [ ! -d "$d" ]; then
            echo "$d"
        fi
    done <<EOF_NEEDED
$(_report_browser_dirs_needed "$1")
EOF_NEEDED
    return 0
}

_report_prune_stale_browsers() {
    local browsers_dir="$1" d keep
    keep=$(_report_browser_dirs_needed "$browsers_dir")
    [ -n "$keep" ] || return 0
    # Never remove a build before every one this Playwright needs is in place.
    [ -z "$(_report_browser_dirs_missing "$browsers_dir")" ] || return 0
    for d in "$browsers_dir"/chromium-* "$browsers_dir"/chromium_headless_shell-*; do
        [ -d "$d" ] || continue
        if ! printf '%s\n' "$keep" | grep -qxF "$d"; then
            if rm -rf "$d"; then
                echo "  [chromium] removed $(basename "$d") — this Playwright no longer uses it."
            fi
        fi
    done
    return 0
}

# --- Verify the render engine actually WORKS ------------------------------
#
# Installing the Chromium tarball is NOT proof that reports will render. The
# browser needs OS shared libraries (libnss3, libatk1.0-0, libxkbcommon0,
# libgbm1, libasound2, …) that a tarball cannot carry, and in offline mode
# `playwright install-deps` is deliberately skipped (it needs apt + network).
# Before this check, an air-gapped upgrade printed "Complete" and the first
# scheduled report failed hours later with a browser launch error.
#
# So: actually launch Chromium AS THE SERVICE USER and render a page. If it
# fails, name the missing shared libraries (ldd) — that is the one thing the
# operator can act on, and they cannot apt-get it.
#
#   verify_report_engine        -> 0 = renders, 1 = does not (never fatal)
verify_report_engine() {
    local service_user="jt-glogarch"
    local install_dir="${JT_INSTALL_DIR:-/opt/jt-glogarch}"
    local browsers_dir="$install_dir/.playwright"
    local out rc

    echo ""
    echo "=== Verifying the PDF render engine (real Chromium launch) ==="

    if ! python3 -c "import playwright" >/dev/null 2>&1; then
        echo "  ⚠ playwright is not installed — PDF Reports are unavailable."
        echo "    Everything else works; install the [report] extra to enable them."
        return 1
    fi

    local probe
    probe=$(mktemp /tmp/jt-render-check-XXXXXX.py)
    cat > "$probe" <<'PYEOF'
import asyncio, os, sys
os.makedirs(os.environ.get("TMPDIR", "/tmp"), exist_ok=True)
from playwright.async_api import async_playwright


async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(args=["--no-sandbox"])
        page = await browser.new_page()
        await page.set_content("<h1>jt-glogarch render check</h1>")
        pdf = await page.pdf(format="A4")
        await browser.close()
        if not pdf or len(pdf) < 500:
            print("PDF came back empty", file=sys.stderr)
            sys.exit(2)


asyncio.run(main())
print("OK")
PYEOF
    chmod 644 "$probe"
    out=$(sudo -u "$service_user" env \
            PLAYWRIGHT_BROWSERS_PATH="$browsers_dir" \
            TMPDIR="$browsers_dir/tmp" \
            python3 "$probe" 2>&1)
    rc=$?
    rm -f "$probe"

    if [ $rc -eq 0 ]; then
        echo "  ✅ Chromium launched and rendered a PDF — PDF Reports are ready."
        return 0
    fi

    echo "  ❌ PDF rendering does NOT work on this host."
    echo "     (Archiving, restore and every other feature are unaffected.)"
    echo ""
    # Playwright pads the tail with process-teardown chatter; show the lines that
    # actually say what went wrong, and fall back to the tail if none match.
    echo "  Error:"
    local why
    why=$(echo "$out" | grep -viE '^\s*- \[pid=' \
            | grep -iE 'error|missing|cannot|failed|shared librar' | head -6)
    [ -z "$why" ] && why=$(echo "$out" | tail -6)
    echo "$why" | sed 's/^/    /'

    # A Chromium is there but not the build this Playwright launches (an upgrade
    # brought a newer Playwright): say exactly which, and the one-line fix.
    local need
    need=$(_report_browser_dirs_missing "$browsers_dir")
    if [ -n "$need" ]; then
        echo ""
        echo "  This Playwright needs a browser build that is not installed:"
        echo "$need" | sed 's/^/    /'
        echo "  Online hosts fix it with:"
        echo "    sudo PLAYWRIGHT_BROWSERS_PATH=$browsers_dir python3 -m playwright install chromium"
        echo "    sudo chown -R $service_user:$service_user $browsers_dir"
        echo "  Air-gapped hosts: upgrade with an offline bundle built for this version."
        return 1
    fi

    # Name the missing OS libraries — the actionable part on an air-gapped box.
    # Playwright's layout moves around (chrome-linux/ vs chrome-linux64/, plus a
    # separate headless-shell build), so FIND the binaries instead of guessing a
    # path: a wrong guess prints "no Chromium installed" at the exact moment the
    # operator needs the library list, which is worse than saying nothing.
    local bins
    bins=$(find "$browsers_dir" -maxdepth 4 -type f \
             \( -name chrome -o -name headless_shell -o -name chrome-headless-shell \) \
             2>/dev/null)
    if [ -n "$bins" ] && command -v ldd >/dev/null 2>&1; then
        local missing
        missing=$(echo "$bins" | while read -r b; do
                      ldd "$b" 2>/dev/null | awk '/not found/{print $1}'
                  done | sort -u)
        if [ -n "$missing" ]; then
            echo ""
            echo "  Missing shared libraries (install these from your distro media):"
            echo "$missing" | sed 's/^/    /'
            echo ""
            echo "  On Debian/Ubuntu these usually come from:"
            echo "    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2"
            echo "    libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3"
            echo "    libxrandr2 libgbm1 libasound2 libpango-1.0-0 libcairo2"
            echo "  Online hosts can simply run:  python3 -m playwright install-deps chromium"
        fi
    elif [ -z "$bins" ]; then
        echo ""
        echo "  No Chromium binary found under $browsers_dir —"
        echo "  the browser was never installed (offline bundle without Chromium?)."
    fi
    return 1
}
