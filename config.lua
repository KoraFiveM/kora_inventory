Config = Config or {}

Config.qbinventory = {
    playerSlots = 41,
    playerMaxWeight = 120000,
    -- Slots 1..hotbarSlots double as the hotbar. client/hotbar.lua binds the
    -- number keys to exactly this range, and weaponCarry's 'hotbar'
    -- visibility mode treats exactly this range as "openly carried", so the
    -- two can never drift apart into two different meanings of "hotbar".
    hotbarSlots = 5,
    defaultSlots = 50,
    defaultMaxWeight = 100000,
    interactionDistance = 3.0,
    -- Opening another player's inventory is denied by default. Supply a
    -- trusted server callback here (or register one at runtime) to opt into
    -- police/admin/consent rules; proximity alone is never authority.
    playerInspection = { access = nil },
    sessionTtl = 120000,
    dropDistance = 2.0,

    -- A dropped item leaves a real bag on the floor to walk up to, rather than
    -- an invisible interaction point.
    --
    -- The prop is PRESENTATION ONLY and lives entirely on each client: it is a
    -- local, non-networked object, it carries no inventory identity, and
    -- interacting with it opens the drop by the id the server broadcast --
    -- which the server re-checks for access, distance and routing bucket like
    -- any other inventory. Deleting or spoofing the prop gains nothing.
    drops = {
        enabled = true,
        model = 'prop_med_bag_01b',
        -- Drop coordinates come from the player's ped, which is roughly a metre
        -- off the floor. Trace down to the ground so the bag sits on the
        -- surface instead of hovering at waist height.
        placeOnGround = true,
        -- Metres. Kept at or below dropDistance so the prompt can never appear
        -- at a range the server will refuse to open the drop from.
        interactionDistance = 1.5,
        label = 'Pick up',
        icon = 'package',
    },

    -- Presentation only. Everything in here is pushed to the browser on
    -- `qbinventory:nui:config` and changes nothing the server decides -- the
    -- inventory engine never reads it. Kept in one sub-table so it is obvious
    -- at a glance which config values cross into the NUI and which do not.
    ui = {
        -- With no second inventory open, show a compact centred player grid.
        -- Selecting an item opens its inspector/actions in a side drawer.
        centreWhenSolo = true,

        -- Outline the first `hotbarSlots` slots in the accent colour so the
        -- keys 1-5 already bound in client/hotbar.lua are visible rather than
        -- folklore. Purely a border: the slots behave identically either way.
        showHotbar = true,

        -- Item artwork resolution. `localPath` is tried before any remote
        -- `imageUrl` when `preferLocal` is set, and always as the fallback when
        -- a remote image 404s.
        --
        -- Extensions are tried in order for `<localPath>/<item name>.<ext>`, so
        -- put the format you actually ship first. Animated WebP and GIF need no
        -- special handling -- CEF animates both in a plain <img> -- so they are
        -- listed purely to allow the extension.
        images = {
            localPath = 'nui://qbinventory/images',
            extensions = { 'webp', 'png', 'gif', 'jpg' },
            -- Try the local file before the remote URL. Leave false to keep
            -- qbcore's remote catalogue as the primary source and use local
            -- files only for items it has no artwork for.
            preferLocal = false,
            -- Set false to never make an outbound image request at all. Items
            -- with no local file fall back to the first-letter placeholder.
            allowRemote = true,
        },
    },
    auditLimit = 1000,
    requireSameBucket = true,
    -- Physical cash is opt-in. When enabled, the configured qbcore account is
    -- represented exclusively by this stackable item: it can be given, moved,
    -- stashed and dropped like any other inventory item. qbcore remains the
    -- only money API; qbinventory's AddItem/RemoveItem cash compatibility
    -- calls are routed back through it so no second balance can be minted.
    -- Enabling/disabling this on an established server is a data migration:
    -- qbinventory converts ledger cash when it activates and deliberately
    -- fails closed if its provider is stopped. Do not flip it mid-session.
    cash = {
        asItem = false,
        item = 'cash',
        account = 'cash',
    },
    -- Item receipts are owned by qbinventory, never by the resource which
    -- grants an item.  Leave this disabled for a completely silent/headless
    -- inventory, or tune the single presentation policy here for every
    -- compatible AddItem/RemoveItem caller, qbinventory shop purchase and
    -- (opt-in) item use.
    itemBoxes = {
        enabled = true,
        duration = 2600,
        showAdditions = true,
        showPurchases = true,
        showRemovals = true,
        -- A useable that consumes its item already draws a removal receipt
        -- through RemoveItem, so uses stay opt-in to avoid two receipts for
        -- one action. Enable this for useables that are not consumed.
        showUses = false,
    },
    persistence = {
        -- Secondary inventories only. Player items are qbcore-owned and are never
        -- read from or written to this storage layer.
        enabled = true,
        persistDrops = false,
        persistTemporary = false,
        flushInterval = 5000,
        migrationBatchSize = 100,
        legacyTables = { 'inventories', 'stashitems', 'trunkitems', 'gloveboxitems' },
    },
    -- Server-only vehicle storage policy. Clients may suggest a network id,
    -- never a plate, capacity, coordinate or arbitrary inventory key.
    vehicles = {
        distance = 3.0,
        requireSameBucket = true,
        plateMaxLength = 8,
        -- Optional trusted server callbacks. Return false (or false, reason)
        -- to deny access to the server-resolved vehicle descriptor.
        ownerCheck = nil,
        accessCheck = nil,
        -- `false` disables that storage type for the GTA vehicle class.
        classes = {
            default = { trunk = { slots = 50, maxWeight = 60000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [0] = { trunk = { slots = 30, maxWeight = 30000 }, glovebox = { slots = 6, maxWeight = 7500 } },
            [1] = { trunk = { slots = 40, maxWeight = 40000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [2] = { trunk = { slots = 50, maxWeight = 60000 }, glovebox = { slots = 10, maxWeight = 12500 } },
            [3] = { trunk = { slots = 45, maxWeight = 50000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [4] = { trunk = { slots = 35, maxWeight = 35000 }, glovebox = { slots = 6, maxWeight = 7500 } },
            [5] = { trunk = { slots = 30, maxWeight = 30000 }, glovebox = { slots = 6, maxWeight = 7500 } },
            [6] = { trunk = { slots = 30, maxWeight = 30000 }, glovebox = { slots = 6, maxWeight = 7500 } },
            [7] = { trunk = { slots = 25, maxWeight = 25000 }, glovebox = { slots = 4, maxWeight = 5000 } },
            [8] = { trunk = false, glovebox = false }, -- motorcycles
            [9] = { trunk = { slots = 55, maxWeight = 70000 }, glovebox = { slots = 10, maxWeight = 12500 } },
            [10] = { trunk = { slots = 80, maxWeight = 120000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [11] = { trunk = { slots = 75, maxWeight = 100000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [12] = { trunk = { slots = 100, maxWeight = 150000 }, glovebox = { slots = 10, maxWeight = 12500 } },
            [13] = { trunk = false, glovebox = false }, -- cycles
            [14] = { trunk = { slots = 100, maxWeight = 150000 }, glovebox = false }, -- boats
            [15] = { trunk = { slots = 100, maxWeight = 150000 }, glovebox = false }, -- helicopters
            [16] = { trunk = { slots = 100, maxWeight = 150000 }, glovebox = false }, -- planes
            [17] = { trunk = { slots = 40, maxWeight = 40000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [18] = { trunk = { slots = 40, maxWeight = 40000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [19] = { trunk = { slots = 40, maxWeight = 40000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [20] = { trunk = { slots = 100, maxWeight = 150000 }, glovebox = { slots = 8, maxWeight = 10000 } },
            [21] = { trunk = { slots = 100, maxWeight = 150000 }, glovebox = false }, -- trains
        },
    },
    -- Item-bound containers and evidence are server-only domains. There is no
    -- client event that accepts a container/evidence identifier, owner, item
    -- record, or target item slot. The functions in server/containers.lua are
    -- intended for trusted server resources only.
    containers = {
        defaultSlots = 12,
        defaultMaxWeight = 30000,
        maxIdentifierLength = 96,
        -- Portable containers are opened by using the corresponding item in a
        -- player's own inventory. The first use binds a generated containerId
        -- to that exact unique item; subsequent opens prove present possession
        -- server-side. Keep `allowNested` false unless a resource has a clear
        -- policy for recursive-capacity and self-containment edge cases.
        items = {
            backpack = {
                label = 'Backpack',
                slots = 20,
                maxWeight = 60000,
                allowNested = false,
            },
        },
        evidence = {
            slots = 100,
            maxWeight = 150000,
            distance = 3.0,
            requireSameBucket = true,
            -- Default deny. This callback is trusted server code and receives
            -- (source, action, context). Return true to grant; false, reason
            -- to deny. It must enforce job/ACE/restraint/consent policy.
            --
            -- Supplied by qbpolice (resources/[test]/qbpolice) per its own
            -- design doc: "qbpolice only supplies the access-policy callback
            -- and the UI wiring" for the evidence/confiscation system already
            -- built here. Config is a resource-local Lua global with no
            -- cross-resource setter for this one field (verified: there is no
            -- exports() registration for it, unlike e.g. RegisterInspectionAccess),
            -- so this is edited directly rather than injected at runtime.
            -- On-duty is required, not just job membership, so an officer who
            -- clocks off loses evidence access immediately.
            access = function(source, action, context)
                local job = exports.qbcore:getJob(source)
                if not job or job.name ~= 'police' or not job.onduty then
                    return false, 'not an on-duty police officer'
                end
                return true
            end,
        },
    },
    -- Recipes are registered only by server resources. qbinventory has no
    -- craft net event: callers must validate their station/role server-side
    -- and invoke the headless CraftItem export with trusted context.
    crafting = {
        maxBatchAmount = 100,
    },
    weapons = {
        defaultDurability = 100,
        maxAmmo = 10000,
        serialPrefix = 'QB',
        -- Ammunition is not merely an integer.  Every loaded round is a
        -- discrete record on its weapon (`info.loadedBullets`), so loading a
        -- 12-round magazine creates exactly 12 traceable rounds.  The
        -- server is the only code that creates, loads, or consumes them.
        ballistics = {
            enabled = true,
            maxLoadedRounds = 240,     -- hard metadata cap; keep this close to the weapons used on your server
            shotCooldown = 65,         -- server-side floor between accepted native shot reports
            casingOffset = 0.75,       -- metres behind/alongside the shooter for the recovered casing marker
        },
        -- Wear is applied by the SERVER for every accepted round fired.
        -- `perShot` is durability percentage points (0.10 means 1 point per
        -- 10 shots); per-weapon multipliers make high-wear weapons degrade
        -- faster without changing the shared baseline. Set enabled = false
        -- to keep tracking shots/ammo but disable all firing wear.
        durability = {
            enabled = true,
            perShot = 0.10,
            defaultMultiplier = 1.0,
            multipliers = {
                -- weapon_pistol = 1.0,
                -- weapon_carbinerifle = 1.25,
            },
            excluded = {
                -- weapon_stungun = true,
            },
        },
        -- Explicit allow-lists. An absent weapon (and absent `default`) has
        -- no allowed components, preventing arbitrary client metadata.
        components = {},
    },
    -- Visible weapon carry. A weapon a player owns but is not currently
    -- holding is rendered on their body for every nearby client, and drawing
    -- one takes time and plays an animation instead of snapping into hand.
    --
    -- This is presentation and pacing only. It never adds, removes, moves or
    -- reveals an inventory item, the carried list is built by the server from
    -- qbcore-owned PlayerData (never submitted by a browser or a client), and
    -- a client may only confirm the draw/holster the server itself asked it
    -- for. Disabling it leaves the inventory model completely unchanged.
    weaponCarry = {
        enabled = true,
        -- Which of a player's weapons are rendered on their body:
        --   'all'    -- every carryable weapon in the inventory.
        --   'hotbar' -- only weapons in slots 1..hotbarSlots. A weapon stowed
        --              past that range is concealed, and drawing it costs
        --              `concealedDrawTime` extra below.
        visibility = 'hotbar',
        -- Equip/holster timing in milliseconds. 0 restores the previous
        -- instant toggle and skips the animation entirely.
        drawTime = 900,
        holsterTime = 700,
        -- Added to drawTime when the weapon was NOT openly carried -- it sits
        -- outside the hotbar range while visibility = 'hotbar'. Nobody saw it
        -- coming, so it takes longer to produce. Deliberately ignored in
        -- 'all' mode and while this system is disabled: there is no
        -- concealment to price when every weapon is visible, or none are.
        concealedDrawTime = 1800,
        -- Played for the duration of the draw/holster. `false` disables the
        -- animation while keeping the timing.
        --
        -- These two are the FALLBACK, used for anything the per-tier table
        -- below has no entry for.
        drawAnim = { dict = 'reaction@intimidation@cop@unarmed', clip = 'intro', flag = 49 },
        holsterAnim = { dict = 'reaction@intimidation@cop@unarmed', clip = 'outro', flag = 49 },

        -- Per-tier animations, keyed by the SAME tier a weapon gets from
        -- `tiers` below -- so where a weapon is carried and how it is produced
        -- are one decision, not two that can disagree. A rifle coming off the
        -- back and a pistol coming off the hip are different movements, and
        -- playing the hip draw for both was the single most visible tell that
        -- the animation was decorative.
        --
        -- A tier absent here falls back to drawAnim/holsterAnim above; set an
        -- entry to `false` to skip the animation for that tier while keeping
        -- its timing.
        drawAnims = {
            -- Long guns: both hands, reaching over the shoulder.
            back = { dict = 'anim@am_hold_up@male', clip = 'shoppay_idle_a', flag = 49 },
            -- Melee, worn on a sling at the hip.
            sling = { dict = 'melee@holster', clip = 'unholster', flag = 49 },
            -- Sidearm from the hip -- the original animation, which was
            -- correct all along for exactly this tier.
            hip = { dict = 'reaction@intimidation@cop@unarmed', clip = 'intro', flag = 49 },
        },
        holsterAnims = {
            back = { dict = 'anim@am_hold_up@male', clip = 'shoppay_idle_a', flag = 49 },
            sling = { dict = 'melee@holster', clip = 'holster', flag = 49 },
            hip = { dict = 'reaction@intimidation@cop@unarmed', clip = 'outro', flag = 49 },
        },
        -- Freeze/disable policy passed to qblib's progress bar while drawing.
        -- Combat is disabled so a draw cannot be used as an instant attack.
        disable = { move = false, combat = true, car = false },
        -- qbcore shared/weapons.lua `weapontype` -> attachment tier. A type
        -- that is absent here is never carried: Throwable and Equipment are
        -- left out on purpose (a grenade on the spine looks wrong and a
        -- parachute already has its own component).
        tiers = {
            Rifle = 'back', Shotgun = 'back', SMG = 'back',
            Sniper = 'back', LMG = 'back', Heavy = 'back',
            Melee = 'sling',
            -- Keep sidearms visible with the rest of the carried weapons.
            -- This also uses the back draw/holster animation and attachment
            -- positions, so a pistol is not left at the hip.
            Pistol = 'back',
        },
        -- Attachment positions per tier, taken in order. A weapon that finds
        -- no free position in its tier is simply not rendered, rather than
        -- stacked on top of one that already is.
        --
        -- Offsets are plain {x,y,z} tables rather than vec3: config.lua is a
        -- shared script the plain-Lua smoke tests dofile() outside FiveM,
        -- where vec3 does not exist. The client converts them.
        --
        -- These numbers are the Renewed-Weaponscarry slot table (bone 24817 =
        -- SKEL_Spine3) and are a tuned starting point, not a law -- adjust per
        -- weapon through `weapons` below when a model sits wrong.
        attachments = {
            back = {
                { bone = 24817, pos = { x = 0.04, y = -0.15, z = 0.12 }, rot = { x = 0.0, y = 0.0, z = 0.0 } },
                { bone = 24817, pos = { x = 0.04, y = -0.17, z = 0.02 }, rot = { x = 0.0, y = 0.0, z = 0.0 } },
                { bone = 24817, pos = { x = 0.04, y = -0.19, z = -0.08 }, rot = { x = 0.0, y = 0.0, z = 0.0 } },
            },
            sling = {
                { bone = 24817, pos = { x = -0.13, y = -0.16, z = -0.14 }, rot = { x = 5.0, y = 62.0, z = 0.0 } },
                { bone = 24817, pos = { x = -0.13, y = -0.15, z = 0.10 }, rot = { x = 5.0, y = 124.0, z = 0.0 } },
            },
            hip = {
                { bone = 24817, pos = { x = -0.28, y = -0.14, z = 0.15 }, rot = { x = 0.0, y = 92.0, z = -13.0 } },
                { bone = 24817, pos = { x = -0.27, y = -0.14, z = 0.15 }, rot = { x = 0.0, y = 92.0, z = 13.0 } },
            },
        },
        -- Per-item overrides, keyed by item name. `tier = false` stops an
        -- item being carried at all; `bone`/`pos`/`rot` override that tier's
        -- next free position for this one item; `model` renders a plain prop
        -- instead of the weapon itself, which is also how a NON-weapon item
        -- (a wrapped brick, a duffel) can be carried -- give it an explicit
        -- `tier` and `model`, since only registry weapons are classified
        -- automatically by `tiers` above.
        weapons = {
            weapon_petrolcan = { tier = false },
            weapon_fireextinguisher = { tier = false },
        },
        -- Weapon component item name -> the GTA component this renders as, so
        -- an attached scope/suppressor shows on the carried weapon. Values are
        -- component names ('COMPONENT_AT_AR_SUPP_02') or hashes. Empty by
        -- default: qbcore's shared registry carries no component -> native
        -- mapping, and guessing one would attach the wrong part.
        components = {},
    },
}

-- Registers this resource-owned configuration with qblib without changing its public Config table.
if QB and QB.config and QB.config.adopt then Config = QB.config.adopt(Config) end
