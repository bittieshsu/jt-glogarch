#!/bin/bash
# jt-glogarch — TLS / proxy environment helper (sourced by install.sh & upgrade.sh)
#
# Why this exists: some customer networks sit behind a corporate TLS-inter-
# ception proxy (a "man-in-the-middle" that re-signs HTTPS with its own root
# CA), or ship a broken/empty system CA store ("CAfile: none"). In those
# environments `git`/`pip`/`playwright` refuse to verify GitHub / PyPI even
# though plain `curl` may work. This helper lets the operator tell our scripts
# how to reach the internet WITHOUT us silently weakening security:
#
#   --ca-bundle <file>  (or env JT_CA_BUNDLE=<file>)
#       Verify against this CA file. Use it to point at the corporate proxy's
#       root CA. Still fully verified — the SECURE choice. Applies to git, pip,
#       curl and Playwright/Node in one shot.
#
#   --insecure          (or env JT_INSECURE=1)
#       Skip TLS verification for this run (the equivalent of `curl -k`).
#       Opt-in only, prints a loud warning. Prefer --ca-bundle or fixing the
#       system CA store; only use this if you accept the risk.
#
# It also makes git strictly non-interactive so a proxy that demands auth can
# never leave the upgrade hanging on a hidden username/password prompt.
#
# Consumes: JT_CA_BUNDLE, JT_INSECURE (set by the caller's arg parsing or env).
# Exports:  GIT_TLS_OPTS, PIP_TLS_OPTS (extra flags the caller adds to its
#           git / pip invocations) plus the relevant *_CA_* / *_NO_VERIFY env.

# Never block on a credential prompt (turns a hang into a fast, clear failure).
export GIT_TERMINAL_PROMPT=0

GIT_TLS_OPTS=""     # extra 'git -c ...' options
PIP_TLS_OPTS=""     # extra 'pip ...' options

if [ -n "${JT_CA_BUNDLE:-}" ]; then
    if [ ! -f "$JT_CA_BUNDLE" ]; then
        echo "  ⚠ --ca-bundle: file not found: $JT_CA_BUNDLE (ignoring)" >&2
    else
        echo "  TLS: verifying against custom CA bundle → $JT_CA_BUNDLE"
        export GIT_SSL_CAINFO="$JT_CA_BUNDLE"
        export CURL_CA_BUNDLE="$JT_CA_BUNDLE"
        export REQUESTS_CA_BUNDLE="$JT_CA_BUNDLE"
        export PIP_CERT="$JT_CA_BUNDLE"
        export SSL_CERT_FILE="$JT_CA_BUNDLE"
        export NODE_EXTRA_CA_CERTS="$JT_CA_BUNDLE"
        GIT_TLS_OPTS="-c http.sslCAInfo=$JT_CA_BUNDLE"
    fi
elif [ "${JT_INSECURE:-0}" = "1" ]; then
    echo "  ⚠⚠ TLS: INSECURE mode — certificate verification DISABLED for this run"
    echo "       (equivalent to 'curl -k'; prefer --ca-bundle or repairing the CA store)"
    export GIT_SSL_NO_VERIFY=1
    export NODE_TLS_REJECT_UNAUTHORIZED=0
    GIT_TLS_OPTS="-c http.sslVerify=false"
    PIP_TLS_OPTS="--trusted-host pypi.org --trusted-host files.pythonhosted.org --trusted-host pypi.python.org"
fi

export GIT_TLS_OPTS PIP_TLS_OPTS
