-- Config.ShopHints: markers only at fixed shop points, per-shop opt-out, colour
-- from kora_theme, no polling when far and a draw thread only while inside a zone.
local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config.lua')
H.equal(Config.ShopHints.showText, false, 'the floating [ALT] Shop text is off by default')
Config.ShopHints.showText = true -- the draw path below is exercised with the text switched on
Config.qbinventory.shops = {
    a = { locations = { { x = 0.0, y = 0.0, z = 0.0 } } },
    b = { hint = false, locations = { { x = 500.0, y = 0.0, z = 0.0 } } },
    c = { enabled = false, locations = { { x = 600.0, y = 0.0, z = 0.0 } } },
    vending = { models = { 'prop_vend_soda_01' } },
}

local markers, texts, waits, handlers, themeCalls = {}, {}, {}, {}, 0
local threads, zones = {}, {}
vector3 = vector3 or function(x, y, z) return { x = x, y = y, z = z } end
CreateThread = function(fn) threads[#threads + 1] = coroutine.create(fn) end
Wait = function(ms) waits[#waits + 1] = ms; coroutine.yield() end
AddEventHandler = function(name, fn) handlers[name] = fn end
PlayerPedId = function() error('shop hints must not poll the player ped') end
GetEntityCoords = function() error('shop hints must not poll player coords') end
DrawMarker = function(kind, x, y, z, _, _, _, _, _, _, _, _, _, r, g, b, a) markers[#markers + 1] = { kind = kind, r = r, g = g, b = b, a = a } end
Kora = {
    lang = function(key) return key end,
    drawing = { text3d = function(_, text) texts[#texts + 1] = text end },
    zones = { sphere = function(opts) zones[#zones + 1] = opts; return { remove = function() end } end },
}
exports = { kora_theme = { getPrimaryColor = function() themeCalls = themeCalls + 1; return '#112233' end } }

local frame = 0
GetGameTimer = function() frame = frame + 1; return frame * 100 end

local function step(count)
    for _ = 1, count do
        for i = #threads, 1, -1 do
            if coroutine.status(threads[i]) == 'dead' then
                table.remove(threads, i)
            else
                assert(coroutine.resume(threads[i]))
            end
        end
    end
end

dofile('client/shop_hints.lua')
H.equal(#zones, 1, 'one sphere zone per fixed point; hint = false and disabled shops get none')
H.equal(zones[1].radius, Config.ShopHints.drawDistance, 'the zone radius is the configured draw distance')
H.equal(#threads, 0, 'no thread runs while far from every point')

step(3)
H.equal(#markers, 0, 'nothing is drawn while far from every point')
H.equal(#waits, 0, 'no idle polling')

zones[1].onEnter()
H.equal(#threads, 1, 'entering a zone starts the draw thread')
zones[1].onEnter()
H.equal(#threads, 1, 'a second enter does not start a second draw thread')
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
zones[1].onExit()
step(2)
zones[1].onExit()
step(2)
H.equal(#threads, 0, 'the draw thread ends once every zone is left')
local drawn = #markers
step(3)
H.equal(#markers, drawn, 'nothing is drawn after leaving')

zones[1].onEnter()
H.equal(#threads, 1, 'entering again restarts the draw thread')
step(2)
H.ok(#markers > drawn, 'the marker draws again after re-entering')

Config.ShopHints.enabled = false
zones, threads = {}, {}
dofile('client/shop_hints.lua')
H.equal(#zones, 0, 'ShopHints.enabled = false registers no zones')

H.finish()
