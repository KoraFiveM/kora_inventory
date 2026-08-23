fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'qbinventory'
author 'qbcore2'
version '0.1.0'
description 'Server-authoritative inventory with bundled NUI'

-- The NUI is only a renderer. `server.lua` remains the sole inventory authority
-- and client/ui.lua may only submit validated intents through client.lua.
provide 'qb-inventory'
provide 'ox_inventory'

dependency 'qblib'
dependency 'qbsql'
dependency 'qbcore'

shared_scripts {
    '@qblib/init.lua',
    '@qbsql/init.lua',
    'config.lua',
    'config/shops/ammunation.lua',
    'shared.lua',
}

server_scripts {
    -- Owns secondary-inventory schema, persistence and non-destructive legacy
    -- import. It is deliberately loaded before the inventory authority.
    'server/persistence.lua',
    'server.lua',
    -- Weapon/consumable use handlers. Must load after server.lua (needs its
    -- global createUseable/removeItem) but has no dependency on the files
    -- below it, so it sits here.
    'server/useables.lua',
    'server/vehicles.lua',
    'server/containers.lua',
    'server/crafting.lua',
    'server/shops/ammunation.lua',
    -- Direct, server-only compatibility helpers. Provider identities remain
    -- intentionally disabled until full upstream contracts are verified.
    'server/compat/qb.lua',
    'server/compat/ox.lua',
    'server/compat/providers.lua',
}

client_scripts {
    'client.lua',
    -- Resolves nearby recipients locally; it never exposes them to the NUI.
    'client/give_target.lua',
    'client/shops/ammunation.lua',
    -- Legacy qb-inventory event/command adapter. It has no NUI authority and
    -- only routes requested targets through client.lua's validated transport.
    'client/compat.lua',
    'client/compat/ox.lua',
    'client/ui.lua',
    'client/useables.lua'
}

ui_page 'web/build/index.html'

files {
    'web/build/index.html',
    'web/build/assets/**/*'
}
