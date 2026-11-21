-- Hands the finished Config (core descriptors from config.lua plus every
-- config/schema/*.lua feature file) to kora_lib's /config editor in one call.
-- Runs once, after all schema files; without kora_lib's config module it is a
-- no-op and Config stays a plain table.
if Kora and Kora.config and Kora.config.adopt then
    Config = Kora.config.adopt(Config)
end
