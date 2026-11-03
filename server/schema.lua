local NULL = Kora.sql.NULL
local NOW = { raw = 'CURRENT_TIMESTAMP' }
local COLLATE = 'utf8mb4_unicode_ci'

local function created()
    return { name = 'created_at', type = 'timestamp', default = NOW }
end

local function updated()
    return { name = 'updated_at', type = 'timestamp', default = NOW, on_update = 'CURRENT_TIMESTAMP' }
end

QBInventorySchema = {
    {
        name = 'qbinventory_inventories',
        collate = COLLATE,
        columns = {
            { name = 'inventory_type', type = 'varchar(32)' },
            { name = 'inventory_id', type = 'varchar(128)' },
            { name = 'label', type = 'varchar(128)' },
            { name = 'slots', type = 'smallint', unsigned = true, default = 50 },
            { name = 'max_weight', type = 'int', unsigned = true, default = 100000 },
            { name = 'revision', type = 'bigint', unsigned = true, default = 0 },
            { name = 'items', type = 'longtext' },
            { name = 'properties', type = 'longtext' },
            created(),
            updated(),
        },
        primary = { 'inventory_type', 'inventory_id' },
        indexes = { { name = 'idx_qbinventory_updated', columns = { 'updated_at' } } },
    },
    {
        name = 'qbinventory_shop_stock',
        collate = COLLATE,
        columns = {
            { name = 'shop_id', type = 'varchar(128)' },
            { name = 'slot', type = 'smallint', unsigned = true },
            { name = 'item', type = 'longtext' },
            { name = 'revision', type = 'bigint', unsigned = true, default = 0 },
            updated(),
        },
        primary = { 'shop_id', 'slot' },
    },
    {
        name = 'qbinventory_audit',
        collate = COLLATE,
        columns = {
            { name = 'id', type = 'bigint', unsigned = true, auto_increment = true },
            created(),
            { name = 'actor', type = 'varchar(96)', null = true, default = NULL },
            { name = 'action', type = 'varchar(64)' },
            { name = 'inventory_type', type = 'varchar(32)', null = true, default = NULL },
            { name = 'inventory_id', type = 'varchar(128)', null = true, default = NULL },
            { name = 'details', type = 'longtext' },
        },
        primary = { 'id' },
        indexes = {
            { name = 'idx_qbinventory_audit_inventory', columns = { 'inventory_type', 'inventory_id', 'created_at' } },
            { name = 'idx_qbinventory_audit_action', columns = { 'action', 'created_at' } },
        },
    },
    {
        name = 'qbinventory_migration_state',
        collate = COLLATE,
        columns = {
            { name = 'source_name', type = 'varchar(64)' },
            { name = 'status', type = 'varchar(24)' },
            { name = 'last_started_at', type = 'timestamp', null = true, default = NULL },
            { name = 'last_finished_at', type = 'timestamp', null = true, default = NULL },
            { name = 'imported_count', type = 'int', unsigned = true, default = 0 },
            { name = 'skipped_count', type = 'int', unsigned = true, default = 0 },
            { name = 'quarantined_count', type = 'int', unsigned = true, default = 0 },
            { name = 'last_error', type = 'text', null = true, default = NULL },
        },
        primary = { 'source_name' },
    },
    {
        name = 'qbinventory_migration_rows',
        collate = COLLATE,
        columns = {
            { name = 'source_name', type = 'varchar(64)' },
            { name = 'source_key', type = 'varchar(191)' },
            { name = 'source_checksum', type = 'char(64)' },
            { name = 'inventory_type', type = 'varchar(32)', null = true, default = NULL },
            { name = 'inventory_id', type = 'varchar(128)', null = true, default = NULL },
            { name = 'status', type = 'varchar(24)' },
            { name = 'error', type = 'text', null = true, default = NULL },
            { name = 'imported_at', type = 'timestamp', default = NOW },
        },
        primary = { 'source_name', 'source_key' },
        indexes = { { name = 'idx_qbinventory_migration_status', columns = { 'status', 'imported_at' } } },
    },
    {
        name = 'qbinventory_quarantine',
        collate = COLLATE,
        columns = {
            { name = 'id', type = 'bigint', unsigned = true, auto_increment = true },
            { name = 'source_name', type = 'varchar(64)' },
            { name = 'source_key', type = 'varchar(191)' },
            { name = 'reason', type = 'varchar(255)' },
            { name = 'raw_payload', type = 'longtext' },
            created(),
        },
        primary = { 'id' },
        indexes = { { name = 'idx_qbinventory_quarantine_source', columns = { 'source_name', 'source_key' } } },
    },
    {
        name = 'qbinventory_recovery_operations',
        columns = {
            { name = 'provider', type = 'varchar(64)' },
            { name = 'operation_key', type = 'varchar(128)' },
            { name = 'stash_id', type = 'varchar(128)' },
            { name = 'citizenid', type = 'varchar(50)' },
            { name = 'status', type = 'varchar(16)', default = 'pending' },
            { name = 'destination_items', type = 'longtext', null = true },
            { name = 'source_revision', type = 'bigint', unsigned = true, null = true },
            { name = 'receipt', type = 'longtext', null = true },
            created(),
        },
        primary = { 'provider', 'operation_key' },
    },
    {
        name = 'qbinventory_player_exchanges',
        columns = {
            { name = 'provider', type = 'varchar(64)' },
            { name = 'operation_key', type = 'varchar(128)' },
            { name = 'citizenid', type = 'varchar(50)' },
            { name = 'request', type = 'longtext' },
            { name = 'player_values', type = 'longtext' },
            { name = 'receipt', type = 'longtext' },
            created(),
        },
        primary = { 'provider', 'operation_key' },
    },
}
