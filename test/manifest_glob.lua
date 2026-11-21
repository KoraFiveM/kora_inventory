-- Test helper: expands fxmanifest.lua script entries that contain a `*` glob
-- (for example 'config/schema/*.lua') into the matching files, sorted by name.
-- Entries without a wildcard are returned unchanged. Run from the repo root.
--   local expand = dofile('test/manifest_glob.lua')
--   for _, path in ipairs(expand(paths)) do dofile(path) end
local function shellQuote(text) return "'" .. text:gsub("'", "'\\''") .. "'" end
return function(paths)
    local out = {}
    for _, path in ipairs(paths) do
        if path:find('*', 1, true) and path:sub(1, 1) ~= '@' then
            local dir, pattern = path:match('^(.*)/([^/]*)$')
            assert(dir and not dir:find('*', 1, true) and not dir:find('%.%.'), 'unsupported manifest glob: ' .. path)
            local matches = {}
            local p = io.popen('ls -1 ' .. shellQuote(dir) .. ' 2>/dev/null | LC_ALL=C sort')
            local luaPattern = '^' .. pattern:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'):gsub('%*', '.*') .. '$'
            for name in p:lines() do
                if name:match(luaPattern) then matches[#matches + 1] = dir .. '/' .. name end
            end
            p:close()
            assert(#matches > 0, 'manifest glob matched no files: ' .. path)
            for _, match in ipairs(matches) do out[#out + 1] = match end
        else
            out[#out + 1] = path
        end
    end
    return out
end
