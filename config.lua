Config = Config or {}

Config.qbinventory = {
    playerSlots = 41,
    playerMaxWeight = 120000,
    defaultSlots = 50,
    defaultMaxWeight = 100000,
    interactionDistance = 3.0,
    sessionTtl = 120000,
    dropDistance = 2.0,
    auditLimit = 1000,
    requireSameBucket = true,
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
}
