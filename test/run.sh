#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
"${LUA:-lua}" test/smoke/shared.lua
"${LUA:-lua}" test/smoke/contract.lua
