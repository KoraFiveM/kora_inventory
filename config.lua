Config = Config or {}

-- Whether shop counters show a floating world icon. nil (default) follows
-- kora_target's Config.target.sprites.enabled; true forces the icon on and
-- false forces it off for kora_inventory's shop zones. Needs kora_target's
-- sprites.allowPerZoneOverride (default true) for `true` to take effect.
-- Read when the zones are registered (resource or kora_target start).
Config.showTargetHints = nil

-- Prefix of newly generated weapon serials (`KORA-WEAPONPISTOL50-<time>-<n>`).
-- Upper-cased and reduced to A-Z0-9, max 12 characters; empty falls back to
-- KORA. Existing items keep the serial they already have.
Config.SerialPrefix = 'KORA'

-- Item inspector number formatting. Decimals shown for fractional metadata
-- values such as Durability/Quality (0-3); trailing zeros are dropped, so 1
-- shows 92.7 and 100.
Config.Inspector = {
    decimals = 1,
}

-- On-screen hotbar (the overlay shown by the show-hotbar key). Distance in CSS
-- pixels from the bottom edge of the screen to the bottom of the hotbar. The
-- defaults sit above kora_hud's status circles and the minimap strip; on foot
-- and seated are separate because the vehicle HUD takes more room. Raise the
-- numbers to move the hotbar up, lower them to move it down. Colours follow
-- kora_theme.
Config.Hotbar = {
    bottomOffset = 90, -- on foot
    vehicleBottomOffset = 130, -- in a vehicle
}

-- Draws a small marker (and optional "[ALT] Shop" text) at every fixed shop
-- interaction point (convenience, liquor, Ammu-Nation, ...). Colour follows
-- kora_theme's primary colour. Set `hint = false` on a shop's config to opt that
-- shop out. Vending machines are model targets without fixed points and get no
-- marker. Plain {x,y,z} tables rather than vec3, like the other offsets here.
Config.ShopHints = {
    enabled = true,
    drawDistance = 10.0, -- metres; nothing is drawn or checked per frame beyond this
    alpha = 160, -- 0-255 marker opacity
    marker = {
        type = 20, -- chevron; 2 is an inverted cone, 1 a cylinder
        scale = { x = 0.3, y = 0.3, z = 0.3 },
        zOffset = 0.0, -- added to the point's z
        bob = true,
        rotate = true,
    },
    showText = true, -- locale key shop_hints.text, drawn above the marker
}

Config.qbinventory = {
    playerSlots = 41,
    playerMaxWeight = 120000,
    -- Slots 1..hotbarSlots double as the hotbar. client/hotbar.lua binds the
    -- number keys to exactly this range, and weaponCarry's 'hotbar'
    -- visibility mode treats exactly this range as "openly carried", so the
    -- two can never drift apart into two different meanings of "hotbar".
    --
    -- This is on by default: keys 1..hotbarSlots are bound as the rebindable
    -- keybinds `qbinventory:hotbar1`..`qbinventory:hotbarN` (Settings > Key
    -- Bindings > FiveM). There is no always-on bar on the HUD while the
    -- inventory is closed; the only visual is the accent outline on those
    -- slots inside the open panel (ui.showHotbar). 0 disables the key binds.
    hotbarSlots = 5,
    -- Built-in use handlers owned by kora_inventory for items that otherwise
    -- have no handler anywhere. Set an entry to false to leave that item to
    -- another resource (it then falls back to the legacy UseItem event).
    builtinUsables = {
        -- Using the `parachute` item gives the player GADGET_PARACHUTE and
        -- consumes one item. Refused (item kept) while a parachute is already
        -- equipped.
        parachute = true,
        -- Milliseconds of the kora_lib progress bar (cancellable, with a
        -- pack-up animation) before the parachute is given. 0 skips the bar.
        parachuteTime = 2500,
        -- Optional SetPedParachuteTintIndex value (0-7). nil leaves the default.
        parachuteTint = nil,
        -- Shows the parachute pack on the ped's back while it is worn, by setting
        -- the bag component (5). Freemode peds only; other models are skipped.
        -- The previous bag is restored once the parachute is deployed or gone
        -- (unless the player changed their bag in between). Set enabled = false
        -- to leave clothing alone. Drawables are the stock freemode parachute
        -- pack; adjust per server clothing pack.
        parachuteBag = {
            enabled = true,
            male = { drawable = 8, texture = 0 },
            female = { drawable = 8, texture = 0 },
        },
    },
    -- Downed / last stand / dead players (kora_ambulance sets the
    -- `isdead` / `inlaststand` player metadata, replicated by kora_core) cannot
    -- open the inventory, use hotbar keys or use items. Enforced on the
    -- server as well as the client. Set false to restore the old behaviour.
    blockWhenDowned = true,
    -- Item names that may still be used while downed (e.g. { "bandage" }).
    -- Only affects item use; opening the inventory stays blocked. Default none.
    downedAllowedItems = {},
    -- Minimum milliseconds between "you cannot do that while downed" notifies.
    downedNotifyCooldown = 3000,
    -- Anti-exploit: while an item is being used (a useable handler is running,
    -- e.g. kora_consumables waiting on its progress bar) or any kora_lib
    -- progress bar is active, the inventory cannot be opened (and is closed if
    -- open) and hotbar use is refused. The server also refuses to drop, give
    -- or move the slot being used, so the item cannot be dropped mid-use and
    -- kept together with its effect. Set false to restore the old behaviour.
    blockWhileBusy = true,
    -- Safety timeout (ms): a slot stays locked at most this long if a useable
    -- handler never returns. It is cleared as soon as the handler finishes,
    -- errors, or the player disconnects.
    busyTimeout = 30000,
    defaultSlots = 50,
    defaultMaxWeight = 100000,
    interactionDistance = 3.0,
    -- Opening another player's inventory is denied by default. Supply a
    -- trusted server callback here (or register one at runtime) to opt into
    -- police/admin/consent rules; proximity alone is never authority.
    playerInspection = { access = nil },
    -- Milliseconds an open inventory may sit unused before the server closes it
    -- (the lease). With sessionSliding on, every request the player makes renews
    -- it, so it is an idle timeout. Off, it is a hard limit counted from the
    -- moment the inventory was opened: a player who keeps dragging or buying is
    -- force-closed when it runs out. Vending machine approvals follow the same
    -- rule. Changes apply to the next request.
    sessionTtl = 120000,
    sessionSliding = true,
    -- Log a "slow ... request" line to the server console when answering one
    -- inventory request (move, buy, drop, use) takes the server this many
    -- milliseconds or more. A move normally takes a few; 0 turns the line off.
    -- Use it to tell a slow server from a slow network when drags feel late.
    slowRequestMs = 250,
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
        -- Metres added to the bag's height after it has been placed on the
        -- ground. Positive lifts it, negative sinks it; use it if a custom
        -- `model` still floats or clips. Ignored when placeOnGround is false.
        groundOffset = 0.0,
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
        -- folklore. Purely a border: the slots behave identically either way,
        -- and the number keys keep working with this off (see hotbarSlots).
        showHotbar = true,

        -- Seconds the on-screen hotbar stays visible after the player presses
        -- the `qbinventory:hotbarshow` key (rebindable in Settings > Key
        -- Bindings, default U). It lists the first `hotbarSlots` items and
        -- fades away on its own; 0 disables the key. Read on every press.
        hotbarSeconds = 5,

        -- Size multiplier for the inventory's text, slots and counts, for
        -- players who find the default too small. 1.0 is the original size.
        -- Applied the next time the inventory opens.
        scale = 1.0,

        -- Right-clicking a stack of 2 or more in your own or a stash inventory
        -- opens an in-page "split" dialog (amount, Split, Cancel; Escape or a
        -- click outside cancels). Set to false to make right-click do nothing.
        -- Applied the next time the inventory opens.
        rightClickSplit = true,

        -- Paint a drag-and-drop move or a shop purchase in the browser straight
        -- away instead of waiting for the server's reply, then reconcile with
        -- the server's own inventory. The painted item is dimmed (and dashed)
        -- until the server confirms it, and never jumps back to the source slot
        -- while it waits; a move the server refuses, fails or does not answer
        -- in time is undone with a notice saying why. The server still
        -- validates and decides every move and charges every purchase -- this
        -- only changes when the result is drawn. Set to false to show moves
        -- only once the server has confirmed them. Applied the next time the
        -- inventory opens.
        optimisticMoves = true,

        -- While a move is waiting for the server, further drags are queued and
        -- sent in order instead of being refused behind a busy cursor. The
        -- inventory stays draggable at all times; a refused or unanswered move
        -- rolls back on its own, the server is asked to re-send the real state,
        -- and the drags queued behind it still go out. Needs optimisticMoves. Set to false
        -- to lock the inventory (without a wait cursor) until the server
        -- answers. Applied the next time the inventory opens.
        queueMoves = true,

        -- Send the bundled UI's requests to the server as one direct net event
        -- (and get the verdict back as one) instead of through kora_lib's
        -- callback layer, and acknowledge the browser's fetch at once so it never
        -- sits pending behind a busy cursor. The server runs the very same
        -- handlers and checks either way; this only changes the carrier. Set to
        -- false to fall back to kora_lib callbacks (the blocking reply, with the
        -- short 1500 ms deadline below as its default). Third-party renderers
        -- calling the callbacks are unaffected. Applied the next time the
        -- inventory opens.
        directTransport = true,

        -- Milliseconds the UI waits for the server to answer a move before
        -- rolling it back as unanswered and re-syncing (500-60000). With
        -- directTransport nothing blocks while it waits, so the default is
        -- generous: a lag spike should not be shown as a failure. With
        -- directTransport off the browser shows a busy cursor while a request
        -- is outstanding, so keep it near 1500. The same deadline bounds how
        -- long a confirmed move waits for its confirming patch. Applied the
        -- next time the inventory opens.
        moveTimeoutMs = 6000,

        -- Legacy form of moveTimeoutMs, in seconds (0.5-60). Not set by
        -- default; only read when moveTimeoutMs is absent from your config.
        -- moveTimeout = 10,

        -- Item artwork resolution. `localPath` is tried before any remote
        -- `imageUrl` when `preferLocal` is set, and always as the fallback when
        -- a remote image 404s.
        --
        -- Extensions are tried in order for `<localPath>/<item name>.<ext>`, so
        -- put the format you actually ship first. Animated WebP and GIF need no
        -- special handling -- CEF animates both in a plain <img> -- so they are
        -- listed purely to allow the extension.
        images = {
            localPath = 'nui://kora_inventory/images',
            extensions = { 'webp', 'png', 'gif', 'jpg' },
            -- The canonical qb-inventory artwork is bundled in images/, so it
            -- is the primary source. kora_core's remote catalogue remains a
            -- fallback for server-specific items not present in that set.
            preferLocal = true,
            -- Set false to never make an outbound image request at all. Items
            -- with no local file fall back to the first-letter placeholder.
            allowRemote = true,
        },
    },
    auditLimit = 1000,
    -- Trusted server domains only; client intent must be validated by the caller.
    exchangeCallers = { kora_drugs = true },
    requireSameBucket = true,
    -- Physical cash is opt-in. When enabled, the configured kora_core account is
    -- represented exclusively by this stackable item: it can be given, moved,
    -- stashed and dropped like any other inventory item. kora_core remains the
    -- only money API; kora_inventory's AddItem/RemoveItem cash compatibility
    -- calls are routed back through it so no second balance can be minted.
    -- Enabling/disabling this on an established server is a data migration:
    -- kora_inventory converts ledger cash when it activates and deliberately
    -- fails closed if its provider is stopped. Do not flip it mid-session.
    cash = {
        asItem = false,
        item = 'cash',
        account = 'cash',
    },
    -- Item receipts are owned by kora_inventory, never by the resource which
    -- grants an item.  Leave this disabled for a completely silent/headless
    -- inventory, or tune the single presentation policy here for every
    -- compatible AddItem/RemoveItem caller, kora_inventory shop purchase and
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
        -- Inventory-key access to vehicle storage (client/vehicles.lua). While
        -- seated the key opens the glovebox; on foot at a vehicle's boot it opens
        -- the trunk. Set `enabled = false` to leave vehicle storage to other
        -- resources (exports.kora_inventory:openInventory('trunk', netId) keeps
        -- working either way).
        enabled = true,
        gloveboxEnabled = true,
        trunkEnabled = true,
        -- How close (metres) a player must stand to the boot position to open
        -- the trunk. The boot position is derived from the model dimensions.
        bootReach = 1.8,
        -- Server-side limit (metres) from the player to the vehicle origin when
        -- opening a trunk. Larger than `distance` because the boot sits at the
        -- far end of the vehicle, well away from its centre.
        trunkDistance = 7.0,
        -- Visible trunk animation for the inventory-key trunk path: the player
        -- turns to the boot, the boot (or bonnet for frontBootModels) door opens
        -- and an anim loops while the trunk panel is open. Everything is undone
        -- when the inventory closes (Escape, out of range, item use, death) or
        -- the resource stops; a door that was already open is left open.
        -- dict/clip pick the animation, flag is the TaskPlayAnim flag
        -- (49 = loop + upper body + keep moving), openDoor = false skips the
        -- door. Set enabled = false to turn the whole feature off.
        trunkAnimation = {
            enabled = true,
            dict = 'mini@repair',
            clip = 'fixing_a_ped',
            flag = 49,
            openDoor = true,
        },
        -- Trunk and hood toggles (client/vehicle_doors.lua). With kora_target
        -- running, aiming ALT at the trunk or hood of a vehicle lists Open/Close
        -- for that lid (hidden when the vehicle has no such lid), and the trunk
        -- also lists Trunk storage. The driver can use /trunk and /hood from the
        -- seat. Doors are opened with network control, so everyone sees them.
        -- The trunk is the rear lid, or the front lid for frontBootModels.
        --   enabled          master switch for everything below
        --   targetOptions    Open/Close trunk and hood in the ALT menu
        --   inventoryOption  Trunk storage in the ALT menu when aiming at the trunk
        --   commands         /trunk and /hood in the driver seat
        --   commandNames     rename the commands (false or '' for one disables it);
        --                    read once when the resource starts
        --   respectLocks     a locked vehicle cannot be opened from outside
        --                    (closing, and anything from inside, is always allowed)
        --   targetDistance   metres from the player to the aimed point
        --   partDepth        metres from the end of the vehicle that count as the
        --                    trunk or hood when aiming
        -- Text comes from locales/*.json (vehicle_doors.*).
        doors = {
            enabled = true,
            targetOptions = true,
            inventoryOption = true,
            commands = true,
            commandNames = { trunk = 'trunk', hood = 'hood' },
            respectLocks = true,
            targetDistance = 3.0,
            partDepth = 1.3,
        },
        -- Refuse trunk access while the vehicle is locked (kora_vehiclekeys
        -- state bag or the native door lock status).
        respectLocks = true,
        -- When kora_lib cannot tell the vehicle class (unknown/addon model or
        -- lookup unavailable) use the `default` row of `classes` below. Set to
        -- false to refuse vehicle storage for such vehicles instead.
        unknownClassFallback = true,
        -- Models whose boot is at the FRONT (rear/mid-engine cars). Everything
        -- else uses the rear boot. Spawn names, case-insensitive.
        frontBootModels = {
            'adder', 'autarch', 'cyclone', 'deveste', 'emerus', 'entity2', 'entityxf',
            'furia', 'gp1', 'ignus', 'italigtb', 'italigtb2', 'krieger', 'le7b',
            'nero', 'nero2', 'osiris', 'penetrator', 'pfister811', 'prototipo', 'reaper',
            's80', 'sc1', 'sheava', 'taipan', 'tempesta', 'tezeract', 'thrax', 'tigon',
            'turismor', 'tyrant', 'vacca', 'vagner', 'visione', 'voltic', 'xa21', 'zentorno',
        },
        -- GTA vehicle classes that have no boot to stand at (8 motorcycles,
        -- 13 cycles, 21 trains). The inventory key ignores them on foot.
        bootSkipClasses = { 8, 13, 21 },
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
            -- Supplied by kora_police (resources/[test]/qbpolice) per its own
            -- design doc: "qbpolice only supplies the access-policy callback
            -- and the UI wiring" for the evidence/confiscation system already
            -- built here. Config is a resource-local Lua global with no
            -- cross-resource setter for this one field (verified: there is no
            -- exports() registration for it, unlike e.g. RegisterInspectionAccess),
            -- so this is edited directly rather than injected at runtime.
            -- On-duty is required, not just job membership, so an officer who
            -- clocks off loses evidence access immediately.
            access = function(source, action, context)
                local job = exports.kora_core:getJob(source)
                if not job or job.name ~= 'police' or not job.onduty then
                    return false, 'not an on-duty police officer'
                end
                return true
            end,
        },
    },
    -- Recipes are registered only by server resources. kora_inventory has no
    -- craft net event: callers must validate their station/role server-side
    -- and invoke the headless CraftItem export with trusted context.
    crafting = {
        maxBatchAmount = 100,
    },
    weapons = {
        defaultDurability = 100,
        maxAmmo = 10000,
        -- Deprecated alias of Config.SerialPrefix; only read when that is left at
        -- its default and this is set to something other than 'QB'.
        -- Ammunition is not merely an integer.  Every loaded round is a
        -- discrete record on its weapon (`info.loadedBullets`), so loading a
        -- 12-round magazine creates exactly 12 traceable rounds.  The
        -- server is the only code that creates, loads, or consumes them.
        ballistics = {
            enabled = true,
            maxLoadedRounds = 240, -- hard metadata cap; keep this close to the weapons used on your server
            shotCooldown = 65, -- client/server floor between native shot reports
            casingOffset = 0.75, -- metres behind/alongside the shooter for the recovered casing marker
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
        -- Freeze/disable policy passed to kora_lib's progress bar while drawing.
        -- Combat is disabled so a draw cannot be used as an instant attack.
        disable = { move = false, combat = true, car = false },
        -- kora_core shared/weapons.lua `weapontype` -> attachment tier. A type
        -- that is absent here is never carried: Throwable and Equipment are
        -- left out on purpose (a grenade on the spine looks wrong and a
        -- parachute already has its own component).
        tiers = {
            Rifle = 'back',
            Shotgun = 'back',
            SMG = 'back',
            Sniper = 'back',
            LMG = 'back',
            Heavy = 'back',
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
        -- default: kora_core's shared registry carries no component -> native
        -- mapping, and guessing one would attach the wrong part.
        components = {},
    },
}

-- Registers this resource-owned configuration with kora_lib without changing its public Config table.
if Kora and Kora.config and Kora.config.adopt then
    Config.qbinventory.vehicles.classes = Kora.config.map(Config.qbinventory.vehicles.classes, nil, {
        keyType = 'mixed',
        requiredKeys = { 'default' },
        scope = 'server',
        label = 'Vehicle storage by GTA class',
        description = 'Defines trusted trunk and glovebox capacities for each GTA vehicle class. Numeric keys are GTA class IDs and “default” is the required fallback. Set trunk or glovebox to false to disable that storage type; slot counts and maximum weights are enforced by the server after qbinventory restarts.',
    })
    Config.qbinventory.weapons.components = Kora.config.map(Config.qbinventory.weapons.components,
        Kora.config.list({}, Kora.config.string('', { minLength = 1 })), {
            scope = 'server',
            label = 'Allowed weapon components',
            description = 'Maps each exact weapon item name to the component item names that may be stored in that weapon’s server-owned metadata. A weapon absent from this map, and with no “default” row, accepts no components. Changes apply after qbinventory restarts.',
        })
    Config.qbinventory.weaponCarry.components = Kora.config.map(Config.qbinventory.weaponCarry.components,
        Kora.config.string('', { minLength = 1 }), {
            label = 'Visible carried-weapon components',
            description = 'Maps an inventory component item name to the exact GTA component model name rendered on a holstered weapon. Only entries in this allow-list are sent to clients, preventing item metadata from requesting arbitrary native components.',
        })
    Config.qbinventory.slowRequestMs = Kora.config.number(Config.qbinventory.slowRequestMs, {
        label = 'Log slow inventory requests (milliseconds)',
        description = 'Prints a line to the server console when answering one inventory request (move, purchase, drop, use) takes at least this long. A move normally takes a few milliseconds. 0 turns the line off. Applies from the next request.',
        min = 0,
        max = 10000,
        step = 50,
        scope = 'server',
        live = true,
    })
    Config.qbinventory.sessionSliding = Kora.config.boolean(Config.qbinventory.sessionSliding, {
        label = 'Renew an open inventory while it is used',
        description = 'When on, every move, purchase or drop a player makes keeps their open inventory (and a vending machine approval) alive, so it only closes after sitting idle for the session time. Turn it off to close every inventory a fixed time after it was opened, even in the middle of use. Applies from the next request.',
        scope = 'server',
        live = true,
    })
    Config.qbinventory.vehicles.enabled = Kora.config.boolean(Config.qbinventory.vehicles.enabled, {
        label = 'Open vehicle storage with the inventory key',
        description = 'When on, pressing the inventory key while seated in a vehicle opens its glovebox, and pressing it at the boot of a vehicle opens its trunk. Turn it off if another resource handles vehicle storage; exports can still open it. Applies on the next key press.',
        live = true,
    })
    Config.qbinventory.vehicles.gloveboxEnabled = Kora.config.boolean(Config.qbinventory.vehicles.gloveboxEnabled, {
        label = 'Glovebox from the inventory key',
        description = 'Allows the inventory key to open the glovebox while seated. Which vehicle classes have a glovebox and how big it is comes from the storage-by-class table. Applies on the next key press.',
        live = true,
    })
    Config.qbinventory.vehicles.trunkEnabled = Kora.config.boolean(Config.qbinventory.vehicles.trunkEnabled, {
        label = 'Trunk from the inventory key',
        description = 'Allows the inventory key to open the trunk when standing at the boot of a vehicle. Which vehicle classes have a trunk and how big it is comes from the storage-by-class table. Applies on the next key press.',
        live = true,
    })
    Config.qbinventory.vehicles.bootReach = Kora.config.number(Config.qbinventory.vehicles.bootReach, {
        label = 'Boot reach (metres)',
        description = 'How close a player must stand to the boot (rear, or front for rear-engine cars) to open the trunk with the inventory key. Raise it if players struggle to find the spot; very large values let them open trunks from the side of the car. Applies on the next key press.',
        min = 0.5,
        max = 5.0,
        step = 0.1,
        live = true,
    })
    Config.qbinventory.vehicles.trunkDistance = Kora.config.number(Config.qbinventory.vehicles.trunkDistance, {
        label = 'Trunk server distance (metres)',
        description = 'The furthest a player may be from the vehicle origin when the server accepts a trunk open. The boot is at the end of the vehicle, so this must exceed half the vehicle length plus the boot reach; long vans and trucks need a larger value. Applies on the next trunk open.',
        scope = 'server',
        min = 2.0,
        max = 20.0,
        step = 0.5,
        live = true,
    })
    Config.qbinventory.vehicles.unknownClassFallback = Kora.config.boolean(Config.qbinventory.vehicles.unknownClassFallback, {
        label = 'Default storage for unknown vehicle classes',
        description = 'When the vehicle class cannot be resolved, use the default row of the storage-by-class table. Disable to refuse trunk and glovebox access for such vehicles.',
        live = true,
    })
    local doorConfig = Config.qbinventory.vehicles.doors or {}
    Config.qbinventory.vehicles.doors = doorConfig
    doorConfig.enabled = Kora.config.boolean(doorConfig.enabled, {
        label = 'Trunk and hood toggles',
        description = 'Master switch for the ALT-menu Open/Close trunk and hood entries and the /trunk and /hood commands. Applies on the next use.',
        live = true,
    })
    doorConfig.targetOptions = Kora.config.boolean(doorConfig.targetOptions, {
        label = 'Trunk and hood in the ALT menu',
        description = 'Shows Open/Close trunk or hood in the target menu while aiming at that end of a vehicle that has that lid. Applies on the next aim.',
        live = true,
    })
    doorConfig.inventoryOption = Kora.config.boolean(doorConfig.inventoryOption, {
        label = 'Trunk storage in the ALT menu',
        description = 'Shows Trunk storage in the target menu while aiming at the trunk of a vehicle. It follows the trunk switches and lock rule of the inventory key. Applies on the next aim.',
        live = true,
    })
    doorConfig.commands = Kora.config.boolean(doorConfig.commands, {
        label = 'Trunk and hood commands',
        description = 'Lets the driver toggle the trunk and hood with /trunk and /hood. Command names come from the commandNames entries in config.lua and are read when the resource starts. Applies on the next use.',
        live = true,
    })
    doorConfig.respectLocks = Kora.config.boolean(doorConfig.respectLocks, {
        label = 'Locked vehicles keep trunk and hood shut',
        description = 'When on, the trunk and hood of a locked vehicle cannot be opened from outside. Closing them, and opening them from inside the vehicle, is always allowed. Applies on the next use.',
        live = true,
    })
    doorConfig.targetDistance = Kora.config.number(doorConfig.targetDistance, {
        label = 'Trunk and hood reach (metres)',
        description = 'How close the aimed point on the vehicle must be to the player for the ALT-menu trunk and hood entries to appear. Applies on the next aim.',
        min = 1.0,
        max = 10.0,
        step = 0.5,
        live = true,
    })
    doorConfig.partDepth = Kora.config.number(doorConfig.partDepth, {
        label = 'Trunk and hood zone depth (metres)',
        description = 'How far in from the front or rear end of a vehicle the aim point still counts as the hood or trunk. Raise it if players struggle to get the entry to appear. Applies on the next aim.',
        min = 0.5,
        max = 3.0,
        step = 0.1,
        live = true,
    })
    Config.qbinventory.vehicles.respectLocks = Kora.config.boolean(Config.qbinventory.vehicles.respectLocks, {
        label = 'Locked vehicles block the trunk',
        description = 'When on, the server refuses to open the trunk of a locked vehicle (kora_vehiclekeys lock state or the native door lock) and the player is told the vehicle is locked. Turn it off to let anyone open any trunk. The glovebox of the vehicle you are sitting in is never blocked. Applies on the next trunk open.',
        scope = 'server',
        live = true,
    })
    Config.qbinventory.vehicles.frontBootModels = Kora.config.list(Config.qbinventory.vehicles.frontBootModels,
        Kora.config.string('', { minLength = 1 }), {
            label = 'Front-boot vehicle models',
            description = 'Spawn names of rear- or mid-engine cars whose trunk is at the front (for example adder or zentorno). All other cars use the rear boot. Add streamed addon cars here. Applies on the next key press.',
            live = true,
        })
    Config.qbinventory.vehicles.bootSkipClasses = Kora.config.list(Config.qbinventory.vehicles.bootSkipClasses,
        Kora.config.integer(0, { min = 0, max = 30 }), {
            label = 'Vehicle classes without a boot',
            description = 'GTA vehicle class numbers that the inventory key ignores when standing next to them (default: motorcycles 8, cycles 13, trains 21). Applies on the next key press.',
            live = true,
        })
    Config.qbinventory.ui.hotbarSeconds = Kora.config.number(Config.qbinventory.ui.hotbarSeconds, {
        label = 'Hotbar display time (seconds)',
        description = 'How long the on-screen hotbar stays visible after a player presses the show-hotbar key before it disappears again. Set to 0 to disable the key.',
        min = 0,
        max = 30,
        step = 1,
        live = true,
    })
    Config.qbinventory.ui.rightClickSplit = Kora.config.boolean(Config.qbinventory.ui.rightClickSplit, {
        label = 'Right-click splits stacks',
        description = 'When on, right-clicking a stack of two or more items opens a dialog to choose how many to move into an empty slot. Turn it off to make right-click do nothing. Changes apply the next time a player opens their inventory.',
        live = true,
    })
    Config.qbinventory.ui.optimisticMoves = Kora.config.boolean(Config.qbinventory.ui.optimisticMoves, {
        label = 'Show inventory moves instantly',
        description = 'When on, moving, stacking, swapping or splitting items appears immediately and is undone if the server refuses the move or does not answer. Turn it off to show a move only after the server has confirmed it, which avoids a brief flash of a move that is then refused. The server checks every move either way. Changes apply the next time a player opens their inventory.',
        live = true,
    })
    Config.qbinventory.ui.queueMoves = Kora.config.boolean(Config.qbinventory.ui.queueMoves, {
        label = 'Queue inventory drags while a move is pending',
        description = 'When on (and instant moves are on), you can keep dragging items while an earlier move is still waiting for the server; the extra moves are sent one after another. Turn it off to block dragging until the server has answered. Changes apply the next time a player opens their inventory.',
        live = true,
    })
    Config.qbinventory.ui.directTransport = Kora.config.boolean(Config.qbinventory.ui.directTransport, {
        label = 'Send inventory requests directly to the server',
        description = 'When on, the inventory talks to the server over one direct network event instead of kora_lib callbacks, and the browser is never left waiting behind a busy cursor. The server checks every request the same way either way. Turn it off only to fall back to kora_lib callbacks. Changes apply the next time a player opens their inventory.',
        live = true,
    })
    Config.qbinventory.ui.moveTimeoutMs = Kora.config.number(Config.qbinventory.ui.moveTimeoutMs, {
        label = 'Inventory move timeout (milliseconds)',
        description = 'How long the inventory waits for the server to answer a move before undoing it, re-syncing and reporting that the server did not respond. Direct requests do not block while they wait, so a few seconds is safe; with direct requests turned off the cursor shows as busy during the wait, so keep it near 1500. Changes apply the next time a player opens their inventory.',
        min = 500,
        max = 60000,
        step = 100,
        live = true,
    })
    Config.qbinventory.ui.scale = Kora.config.number(Config.qbinventory.ui.scale, {
        label = 'Inventory UI scale',
        description = 'Scales the inventory text, slot sizes, item counts and weight labels. Leave at 1.0 for the original size; increase it if the inventory is too small on your screen. Changes apply the next time a player opens their inventory.',
        min = 0.5,
        max = 2.0,
        step = 0.05,
        live = true,
    })

    Config.qbinventory.drops.groundOffset = Kora.config.number(Config.qbinventory.drops.groundOffset, {
        label = 'Dropped bag height offset (metres)',
        description = 'Adds this many metres to the height of a dropped bag after it has been placed on the ground. Use a positive value if the bag sinks into the floor and a negative value if it floats. Only used while placing dropped bags on the ground is enabled.',
        min = -1.0,
        max = 1.0,
        step = 0.01,
        live = true,
    })

    Config.showTargetHints = Kora.config.optional(Config.showTargetHints, Kora.config.boolean(false), {
        label = 'Show shop counter icons',
        description = 'Controls the floating world icon over shop counters. Leave it unset to follow the target system’s global icon setting, or choose on or off to force it for kora_inventory shops. Applies the next time the shop targets are registered.',
        live = true,
    })

    Config = Kora.config.adopt(Config)
end
