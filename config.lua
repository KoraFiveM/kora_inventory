Config = Config or {}

Config.qbinventory = {
    playerSlots = 41,
    playerMaxWeight = 120000,
    defaultSlots = 50,
    defaultMaxWeight = 100000,
    interactionDistance = 3.0,
    -- Opening another player's inventory is denied by default. Supply a
    -- trusted server callback here (or register one at runtime) to opt into
    -- police/admin/consent rules; proximity alone is never authority.
    playerInspection = { access = nil },
    sessionTtl = 120000,
    dropDistance = 2.0,
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
    -- compatible AddItem caller and qbinventory shop purchase.
    itemBoxes = {
        enabled = true,
        duration = 2600,
        showAdditions = true,
        showPurchases = true,
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
    crafting = {},
    weapons = {
        defaultDurability = 100,
        maxAmmo = 10000,
        serialPrefix = 'QB',
        -- Explicit allow-lists. An absent weapon (and absent `default`) has
        -- no allowed components, preventing arbitrary client metadata.
        components = {},
    },
}
