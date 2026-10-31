-- client.lua and client/hotbar.lua use FiveM natives this plain-Lua harness
-- cannot execute, so this is source-pattern coverage (same style as
-- test/smoke/ui_bridge.lua and test/smoke/contract.lua) for:
--   * the useTime progress-bar gate, shared between the NUI 'use' intent and
--     the hotbar keybinds through QbInventory.useGate;
--   * the panel auto-closing after a completed use unless the item's
--     preventClose came back true;
--   * slot 1-5 hotbar keybinds that reuse the existing legacy
--     QBCore:Server:UseItem transport rather than adding a second
--     server-side use path.
local H = dofile('test/harness.lua')

local function read(path)
    local file = assert(io.open(path, 'r'))
    local text = file:read('*a')
    file:close()
    return text
end

local client = read('client.lua')
local hotbar = read('client/hotbar.lua')
local manifest = read('fxmanifest.lua')

H.ok(client:find('function QbInventory.useGate(item)', 1, true),
    'client.lua exposes the shared use-time progress bar gate')
H.ok(client:find('Kora.progressbar.start(', 1, true),
    'the gate actually runs kora_lib\'s progress bar')
H.ok(client:find('if not QbInventory.useGate(item) then', 1, true),
    'submitIntent gates a use behind the progress bar before contacting the server')
H.ok(client:find("return false, 'cancelled'", 1, true),
    'a cancelled/never-started bar is treated as a rejected use, without a server round trip')
H.ok(client:find('result.preventClose ~= true', 1, true),
    'submitIntent inspects the server\'s preventClose signal')
H.ok(client:find('closeInventory()', client:find("action == 'use' and", 1, true), true),
    'a completed use without preventClose closes the panel')

H.ok(hotbar:find('QbInventory.useGate(item)', 1, true),
    'the hotbar keybinds reuse the same progress-bar gate as the NUI use intent')
H.ok(hotbar:find("TriggerServerEvent('QBCore:Server:UseItem'", 1, true),
    'the hotbar reuses the existing legacy use-item transport rather than a new server event')
H.ok(hotbar:find('IsNuiFocused()', 1, true),
    'the hotbar does not fire while the inventory panel owns keyboard focus')
H.ok(hotbar:find('Config.qbinventory.hotbarSlots', 1, true),
    'the hotbar range comes from config, so weaponCarry\'s hotbar visibility cannot disagree with it')
H.ok(hotbar:find('for slot = 1, HOTBAR_SLOTS do', 1, true), 'slots 1-5 each register a keybind')
H.ok(hotbar:find('Kora.keybind.add({', 1, true) and hotbar:find('name = command', 1, true),
    'hotbar mappings use Kora.keybind lifecycle ownership')
H.ok(not hotbar:find('qbinventory:server:useSlot', 1, true),
    'no new bespoke server-side use transport was introduced for the hotbar')

H.ok(hotbar:find("name = 'qbinventory:hotbarshow'", 1, true) and hotbar:find('Config.qbinventory.ui', 1, true),
    'a rebindable key shows the hotbar overlay for the configured seconds, read at press time')
H.ok(read('config.lua'):find('hotbarSeconds = 5', 1, true), 'the hotbar display time defaults to 5 seconds')

H.ok(manifest:find("'client/hotbar.lua'", 1, true), 'the hotbar module is loaded by the manifest')

H.finish()
