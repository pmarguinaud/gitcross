#!/bin/bash
# Produce the conflict reports for ACCORD-NWP/IAL.
#
# Usage: run_ial.sh [WORKDIR] [gitcross options...]
#
#   WORKDIR   where the mirror (IAL.git) and the reports are kept
#             (default: current directory)
#   options   passed to gitcross, e.g. --no-drafts, --base develop, --no-fetch, -v
#
# Results: WORKDIR/IAL-gitcross.html and WORKDIR/IAL-gitcross.fods

set -euo pipefail

here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

workdir=.
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
  workdir=$1
  shift
fi
mkdir -p "$workdir"
cd "$workdir"

for cmd in git gh perl; do
  command -v $cmd >/dev/null || { echo "Error: $cmd not found in PATH" >&2; exit 1; }
done
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh is not authenticated; run 'gh auth login' first" >&2
  exit 1
fi

"$here/bin/gitcross" --repo ACCORD-NWP/IAL "$@"

echo "Open with: xdg-open $PWD/IAL-gitcross.html   or   libreoffice $PWD/IAL-gitcross.fods"
