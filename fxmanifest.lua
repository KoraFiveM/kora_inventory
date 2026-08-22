fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'qbinventory'
author 'qbcore2'
version '0.1.0'
description 'Server-authoritative inventory with bundled NUI plus qb-inventory and ox_inventory compatibility'

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
    '@qbcore/init.lua',
    'config.lua',
    'shared.lua',
}

server_script 'server.lua'

client_scripts {
    'client.lua',
    'client/ui.lua'
}

ui_page 'web/build/index.html'

files {
    'web/build/index.html',
    'web/build/assets/**/*'
}
