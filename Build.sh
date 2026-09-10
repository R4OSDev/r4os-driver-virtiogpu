#!/bin/sh
set -eu
module_root=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
exec pwsh -NoProfile -File "$module_root/Build.ps1" "$@"
