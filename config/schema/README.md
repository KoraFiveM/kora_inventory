# /config editor schema

Each feature registers its `Kora.config` descriptors (labels, descriptions,
bounds, `live`) for the in-game `/config` editor in its own file here, so
features never edit the same lines. Every file must be guarded:

```lua
if not (Kora and Kora.config and Kora.config.adopt) then return end
local cfg = Config.kora_inventory
cfg.someFeature.enabled = Kora.config.boolean(cfg.someFeature.enabled, {
    label = 'Enable some feature',
    description = 'What it does for players, and when a change applies.',
    live = true, -- only when the code reads the value at call time
})
```

The single `Kora.config.adopt(Config)` call lives in `config/adopt.lua`, which
the manifest loads after this folder.
