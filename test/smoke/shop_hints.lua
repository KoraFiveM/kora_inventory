-- Config.ShopHints: markers only at fixed shop points, per-shop opt-out, colour
-- from kora_theme, sleeping when far and drawing per frame only when near.
local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config.lua')
Config.qbinventory.shops = {
    a = { locations = { { x = 0.0, y = 0.0, z = 0.0 } } },
    b = { hint = false, locations = { { x = 500.0, y = 0.0, z = 0.0 } } },
    c = { enabled = false, locations = { { x = 600.0, y = 0.0, z = 0.0 } } },
    vending = { models = { 'prop_vend_soda_01' } },
}

local position = { x = 500.0, y = 0.0, z = 0.0 }
local markers, texts, waits, handlers, themeCalls = {}, {}, {}, {}, 0
local thread
GetEntityCoords = function() return position end
PlayerPedId = function() return 1 end
GetGameTimer = function() return 0 end
CreateThread = function(fn) thread = coroutine.create(fn) end
Wait = function(ms) waits[#waits + 1] = ms; coroutine.yield() end
AddEventHandler = function(name, fn) handlers[name] = fn end
DrawMarker = function(kind, x, y, z, _, _, _, _, _, _, _, _, _, r, g, b, a) markers[#markers + 1] = { kind = kind, r = r, g = g, b = b, a = a } end
Kora = { lang = function(key) return key end, drawing = { text3d = function(_, text) texts[#texts + 1] = text end } }
exports = { kora_theme = { getPrimaryColor = function() themeCalls = themeCalls + 1; return '#112233' end } }

local frame = 0
local function step(count)
    for _ = 1, count do
        coroutine.resume(thread)
    end
end
GetGameTimer = function() frame = frame + 1; return frame * 100 end

dofile('client/shop_hints.lua')
H.ok(thread, 'a thread is started when a shop has fixed points')

step(2)
H.equal(#markers, 0, 'nothing is drawn while far from every point')
H.equal(waits[1], 1000, 'the thread sleeps 1000 ms while far')

position = { x = 3.0, y = 0.0, z = 0.0 }
step(3)
local calls = themeCalls
H.ok(#markers > 0, 'a marker draws near a shop point')
H.equal(markers[1].r, 0x11, 'marker colour comes from kora_theme')
H.equal(markers[1].b, 0x33, 'marker colour blue channel comes from kora_theme')
H.equal(markers[1].a, 160, 'configured alpha is applied')
H.equal(texts[1], 'shop_hints.text', 'the locale hint is drawn')
step(5)
H.equal(themeCalls, calls, 'kora_theme is not queried per frame')

markers = {}
position = { x = 500.0, y = 0.0, z = 0.0 }
step(8)
H.equal(#markers, 0, 'hint = false and disabled shops get no marker')

Config.ShopHints.enabled = false
thread = nil
dofile('client/shop_hints.lua')
H.equal(thread, nil, 'ShopHints.enabled = false starts no thread')

H.finish()
