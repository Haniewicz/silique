#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
./'Zbuduj macOS.command'
open /Applications/Silique.app
