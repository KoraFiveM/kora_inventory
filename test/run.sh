#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
"${LUA:-lua}" test/smoke/shared.lua
"${LUA:-lua}" test/smoke/contract.lua
"${LUA:-lua}" test/smoke/persistence.lua
"${LUA:-lua}" test/smoke/client_compat.lua
"${LUA:-lua}" test/smoke/give_target.lua
"${LUA:-lua}" test/smoke/security.lua
"${LUA:-lua}" test/smoke/access_policy.lua
"${LUA:-lua}" test/smoke/vehicles.lua
"${LUA:-lua}" test/smoke/containers.lua
"${LUA:-lua}" test/smoke/qb_compat.lua
"${LUA:-lua}" test/smoke/ox_adapter.lua
"${LUA:-lua}" test/smoke/crafting.lua
"${LUA:-lua}" test/smoke/ammunation.lua
