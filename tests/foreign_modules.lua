--- Simulate another KOReader plugin (e.g. the original gdrive.koplugin) that has
--- already loaded modules with generic names. KOReader runs all plugins in one Lua
--- state, so a plain require("utils") in this plugin would get that plugin's module.
--- Every module here must be required under its gdriveplus_ name; touching one of
--- these foreign modules fails the test run.

for _, name in ipairs({ "annotations", "gjson", "network", "progress", "sync", "utils" }) do
    package.loaded[name] = setmetatable({}, {
        __index = function(_, key)
            error("foreign module '" .. name .. "' used (field '" .. tostring(key) .. "')", 2)
        end,
    })
end
