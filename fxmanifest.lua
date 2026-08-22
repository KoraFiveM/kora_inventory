fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'qbinventory'
author 'qbcore2'
version '0.1.0'
description 'Server-authoritative inventory with bundled NUI'

-- The NUI is only a renderer. `server.lua` remains the sole inventory authority
-- and client/ui.lua may only submit validated intents through client.lua.
-- Do not advertise qb-inventory or ox_inventory identities until their exact
-- upstream contracts are implemented and contract-tested. Calling a partial
-- provider by either name is more dangerous than a clear missing dependency.

dependency 'qblib'
dependency 'qbsql'
dependency 'qbcore'

shared_scripts {
    '@qblib/init.lua',
    '@qbsql/init.lua',
    '@qbcore/init.lua',
    'config.lua',
    'shared.lua',
}

server_scripts {
    -- Owns secondary-inventory schema, persistence and non-destructive legacy
    -- import. It is deliberately loaded before the inventory authority.
    'server/persistence.lua',
    'server.lua',
}

client_scripts {
    'client.lua',
    'client/ui.lua'
}

ui_page 'web/build/index.html'

files {
    'web/build/index.html',
    'web/build/assets/**/*'
}
