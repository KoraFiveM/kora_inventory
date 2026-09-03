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
dependency 'qbtarget'

shared_scripts {
    '@qblib/init.lua',
    '@qbsql/init.lua',
    'config.lua',
    'config/shops/ammunation.lua',
    'config/shops/vendingmachine.lua',
    'config/shops/liquorstore.lua',
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
    -- Visible weapon carry + draw/holster pacing. Loads after useables.lua,
    -- whose weapon handler delegates to it at call time, and after
    -- crafting.lua so weapon metadata rules are already in place.
    'server/weaponcarry.lua',
    'server/shops/ammunation.lua',
    'server/shops/vendingmachine.lua',
    'server/shops/liquorstore.lua',
    -- Server-only compatibility helpers. Each builds a table which
    -- server/compat/providers.lua publishes under its provider identity; a
    -- compat module never calls exports() itself. The identities are LIVE and
    -- their surfaces are enforced against test/contracts/upstream.lua by
    -- test/smoke/provider_contract.lua.
    'server/compat/qb.lua',
    -- Upstream qb-inventory's net-event transport, translated onto the
    -- validated transfer funnel. Loads after server.lua (needs I.api/I.internal)
    -- and after compat/qb.lua purely to keep the qb surface together.
    'server/compat/qb_events.lua',
    -- Upstream qb-inventory's QBCore callbacks (drops, purchase, give).
    'server/compat/qb_callbacks.lua',
    'server/compat/ox.lua',
    'server/compat/providers.lua',
}

client_scripts {
    'client.lua',
    -- Resolves nearby recipients locally; it never exposes them to the NUI.
    'client/give_target.lua',
    -- Slot 1-5 hotbar keybinds. Loads after client.lua for QbInventory.useGate
    -- and the legacy QBCore:Server:UseItem transport it reuses.
    'client/hotbar.lua',
    -- Ground-drop props. Presentation only; see the file header.
    'client/drops.lua',
    'client/shops/ammunation.lua',
    'client/shops/vendingmachine.lua',
    'client/shops/liquorstore.lua',
    -- Legacy qb-inventory event/command adapter. It has no NUI authority and
    -- only routes requested targets through client.lua's validated transport.
    'client/compat.lua',
    'client/compat/ox.lua',
    'client/ui.lua',
    'client/useables.lua',
    -- Renders every player's carried weapons from the server-set state bag,
    -- and plays out the draw/holster this client was asked for. It owns the
    -- weapon half of the old client/useables.lua toggle.
    'client/weaponcarry.lua'
}

ui_page 'web/build/index.html'

files {
    'web/build/index.html',
    'web/build/assets/**/*',
    -- Locally hosted item artwork, served as nui://qbinventory/images/<file>.
    -- Outside web/ deliberately: web/build is Vite's output directory, and art
    -- a server owner dropped in must not be something `pnpm build` can delete.
    --
    -- '**/*' is the recursive form FiveM honours; a bare '**' matches nothing.
    'images/**/*'
}
