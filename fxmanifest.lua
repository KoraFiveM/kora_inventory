fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'kora_inventory'
-- Keep the legacy resource name resolvable for exports['qbinventory'] callers.
provide 'qbinventory'
author 'qbcore2'
version '0.2.1'
description 'Server-authoritative inventory with bundled NUI'

-- The NUI is only a renderer. `server.lua` remains the sole inventory authority
-- and client/ui.lua may only submit validated intents through client.lua.
provide 'qb-inventory'
provide 'ox_inventory'
-- qb-inventory now owns the weapon lifecycle too.  Keep this provider alias
-- so resources which only declare qb-weapons as a dependency can be migrated
-- without a second weapon controller running beside the inventory.
provide 'qb-weapons'

dependency 'kora_theme'
dependency 'kora_lib'
dependency 'kora_sql'
dependency 'kora_core'
dependency 'kora_target'

shared_scripts {
    '@kora_lib/init.lua',
    'config.lua',
    'config/shops/ammunation.lua',
    'config/shops/vendingmachine.lua',
    'config/shops/liquorstore.lua',
    'config/shops/convenience.lua',
    'shared.lua',
}

server_scripts {
    '@kora_sql/init.lua',
    -- Owns secondary-inventory schema, persistence and non-destructive legacy
    -- import. It is deliberately loaded before the inventory authority.
    'server/schema.lua',
    'server/persistence.lua',
    'server.lua',
    'server/recovery.lua',
    'server/exchange.lua',
    'server/crafting.lua',
    -- Weapon/consumable use handlers.  This follows crafting.lua because the
    -- ammunition loader uses its server-only per-round ballistics API.
    'server/useables.lua',
    'server/vehicles.lua',
    'server/containers.lua',
    -- Visible weapon carry + draw/holster pacing. Loads after useables.lua,
    -- whose weapon handler delegates to it at call time, and after
    -- crafting.lua so weapon metadata rules are already in place.
    'server/weaponcarry.lua',
    -- Narrow adapter for the legacy qb-weapons event/callback names.  This
    -- comes after the authoritative weapon modules so it can resolve slots,
    -- ammunition and durability from kora_inventory state rather than trusting
    -- the old client item payloads.
    'server/compat/qb_weapons.lua',
    'server/shops/location_policy.lua',
    'server/shops/ammunation.lua',
    'server/shops/vendingmachine.lua',
    'server/shops/liquorstore.lua',
    'server/shops/convenience.lua',
    -- Server-only compatibility helpers. Each builds a table which
    -- server/compat/providers.lua publishes under its provider identity; a
    -- compat module never calls exports() itself. The identities are LIVE and
    -- their surfaces are enforced against test/contracts/upstream.lua by
    -- test/smoke/provider_contract.lua.
    'server/compat/qb.lua',
    -- AddHook/AddListener registry; subscribes to the engine's hook dispatcher.
    'server/compat/qb_hooks.lua',
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
    '@kora_theme/client/bridge.lua',
    'client.lua',
    -- Resolves nearby recipients locally; it never exposes them to the NUI.
    'client/give_target.lua',
    -- Slot 1-5 hotbar keybinds. Loads after client.lua for QbInventory.useGate
    -- and the legacy QBCore:Server:UseItem transport it reuses.
    'client/hotbar.lua',
    -- Ground-drop props. Presentation only; see the file header.
    'client/drops.lua',
    -- Inventory-key access to glovebox/trunk; intent only, the server resolves the vehicle.
    'client/vehicles.lua',
    -- ALT-menu trunk/hood toggles and the /trunk and /hood commands.
    'client/vehicle_doors.lua',
    'client/shops/ammunation.lua',
    'client/shops/vendingmachine.lua',
    'client/shops/liquorstore.lua',
    'client/shops/convenience.lua',
    -- Clerk peds at the 24/7 and liquor counters (Config.ShopClerks). Before
    -- shop_hints so it can drop the label where a clerk stands.
    'client/shop_clerks.lua',
    -- Optional marker/text at fixed shop points (Config.ShopHints).
    'client/shop_hints.lua',
    -- Legacy qb-inventory event/command adapter. It has no NUI authority and
    -- only routes requested targets through client.lua's validated transport.
    'client/compat.lua',
    'client/compat/ox.lua',
    'client/ui.lua',
    'client/useables.lua',
    -- Renders every player's carried weapons from the server-set state bag,
    -- and plays out the draw/holster this client was asked for. It owns the
    -- weapon half of the old client/useables.lua toggle.
    'client/weaponcarry.lua',
    -- Legacy qb-weapons client events, translated into the server-owned
    -- kora_inventory weapon lifecycle above.
    'client/compat/qb_weapons.lua'
}

ui_page 'web/build/index.html'

files {
    'locales/*.json',
    'web/build/index.html',
    'web/build/assets/**/*',
    -- Locally hosted item artwork, served as nui://kora_inventory/images/<file>.
    -- Outside web/ deliberately: web/build is Vite's output directory, and art
    -- a server owner dropped in must not be something `pnpm build` can delete.
    --
    -- '**/*' is the recursive form FiveM honours; a bare '**' matches nothing.
    'images/**/*',
    -- Legacy consumers embed this path directly in their own NUI. The relative
    -- directory link keeps custom artwork shared with the native image path.
    'html/images/**/*'
}
