-- /config editor schema for the admin tools: the item-creation audit log
-- (/invaudit) and the admin omnipack (/omnipack). All values are server-only;
-- the server reads each one at call time unless a description says otherwise.
if not (Kora and Kora.config and Kora.config.adopt) then return end

local cfg = Config.kora_inventory
local audit = cfg.audit
local anomaly = audit.anomaly
local omnipack = cfg.omnipack

audit.enabled = Kora.config.boolean(audit.enabled, {
    label = 'Record item creation in the audit log',
    description = 'When on, every item added to an inventory by a script, shop, craft, exchange or the omnipack is logged with the script that did it, so admins can find duplication and broken scripts with /invaudit. Turning it off stops new entries; existing ones stay until they expire. Applies immediately.',
    scope = 'server',
    live = true,
})
audit.persist = Kora.config.boolean(audit.persist, {
    label = 'Keep the audit log in the database',
    description = 'When on, audit entries are written to the kora_inventory_audit table in batches so they survive restarts. When off, only the most recent entries are kept in memory and are lost on restart. Item adds never wait for the database either way. Applies immediately.',
    scope = 'server',
    live = true,
})
audit.flushSeconds = Kora.config.number(audit.flushSeconds, {
    label = 'Audit write interval (seconds)',
    description = 'How often queued audit entries are written to the database. Entries are also written as soon as 200 are waiting. Longer intervals mean fewer queries but more entries lost if the server crashes. Applies immediately.',
    min = 1,
    max = 300,
    step = 1,
    advanced = true,
    scope = 'server',
    live = true,
})
audit.retentionDays = Kora.config.number(audit.retentionDays, {
    label = 'Audit log retention (days)',
    description = 'Audit entries older than this are deleted automatically (checked hourly). Raise it if you need to look further back; the table grows with how many items your server creates. Applies at the next hourly clean-up.',
    min = 1,
    max = 365,
    step = 1,
    scope = 'server',
    live = true,
})
audit.trackRemovals = Kora.config.boolean(audit.trackRemovals, {
    label = 'Also log item removals',
    description = 'When on, items removed by scripts through RemoveItem are logged too. This makes the log much larger and is only useful when chasing a script that deletes items. Applies immediately.',
    advanced = true,
    scope = 'server',
    live = true,
})
audit.ace = Kora.config.string(audit.ace, {
    label = 'Audit viewer permission (ACE)',
    description = 'The ACE permission an admin needs to open /invaudit. Grant it in server.cfg, for example: add_ace group.admin kora_inventory.audit allow. The server checks it on every request. Applies immediately.',
    minLength = 1,
    advanced = true,
    scope = 'server',
    live = true,
})
audit.command = Kora.config.string(audit.command, {
    label = 'Audit viewer command name',
    description = 'The chat command that opens the audit viewer (without the slash). Applies the next time the resource starts.',
    minLength = 1,
    advanced = true,
    scope = 'server',
})

anomaly.enabled = Kora.config.boolean(anomaly.enabled, {
    label = 'Warn about unusual item creation',
    description = 'When on, the server counts how many items each script and each player is given inside the time window and logs a warning (and fires kora_inventory:server:auditAnomaly for Discord log scripts) when a limit is crossed. One alert per script or player per window. Applies immediately.',
    scope = 'server',
    live = true,
})
anomaly.windowSeconds = Kora.config.number(anomaly.windowSeconds, {
    label = 'Unusual-creation window (seconds)',
    description = 'The rolling period over which item amounts are counted for the limits below, and the minimum gap between repeat alerts for the same script or player. Applies immediately.',
    min = 10,
    max = 3600,
    step = 10,
    advanced = true,
    scope = 'server',
    live = true,
})
anomaly.perResourceThreshold = Kora.config.number(anomaly.perResourceThreshold, {
    label = 'Items per script before an alert',
    description = 'Total item amount one script (other than kora_inventory itself) may add inside the window before an alert is raised. Lower it to be warned sooner; raise it if a busy script triggers false alarms. Applies immediately.',
    min = 1,
    max = 1000000,
    step = 10,
    advanced = true,
    scope = 'server',
    live = true,
})
anomaly.perPlayerThreshold = Kora.config.number(anomaly.perPlayerThreshold, {
    label = 'Items per player before an alert',
    description = 'Total item amount one player may receive from any source inside the window before an alert is raised. Applies immediately.',
    min = 1,
    max = 1000000,
    step = 10,
    advanced = true,
    scope = 'server',
    live = true,
})

omnipack.enabled = Kora.config.boolean(omnipack.enabled, {
    label = 'Enable the admin omnipack',
    description = 'When on, admins with the omnipack permission can open /omnipack, a free shop of every registered item and weapon. Taken items are logged in the audit log. Turning it off refuses opening and taking immediately.',
    scope = 'server',
    live = true,
})
omnipack.ace = Kora.config.string(omnipack.ace, {
    label = 'Omnipack permission (ACE)',
    description = 'The ACE permission an admin needs to open the omnipack and to take items from it. Grant it in server.cfg, for example: add_ace group.admin kora_inventory.omnipack allow. The server checks it on open and on every take. Applies immediately.',
    minLength = 1,
    advanced = true,
    scope = 'server',
    live = true,
})
omnipack.command = Kora.config.string(omnipack.command, {
    label = 'Omnipack command name',
    description = 'The chat command that opens the omnipack (without the slash). Applies the next time the resource starts.',
    minLength = 1,
    advanced = true,
    scope = 'server',
})
omnipack.maxAmount = Kora.config.number(omnipack.maxAmount, {
    label = 'Largest omnipack take',
    description = 'The most of one item an admin can take from the omnipack in a single action. Applies immediately.',
    min = 1,
    max = 10000,
    step = 1,
    advanced = true,
    scope = 'server',
    live = true,
})
