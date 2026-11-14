--- Small file and string helpers (no KOReader dependencies).

local gjson = require("gdriveplus_gjson")

local M = {}

function M.read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

--- Write via a temporary file so a crash never leaves a half-written file.
function M.write_file(path, content)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(content)
    f:close()
    os.remove(path)
    local ok = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return false
    end
    return true
end

--- @return decoded table, or nil when the file is missing/empty/invalid
function M.read_json(path)
    local content = M.read_file(path)
    if not content or content == "" then return nil end
    local data = gjson.decode(content)
    if type(data) == "table" then return data end
    return nil
end

function M.urlencode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

--- Escape a value for use inside single quotes in a Drive `q` expression.
function M.q_escape(s)
    return (tostring(s):gsub("\\", "\\\\"):gsub("'", "\\'"))
end

function M.basename(path)
    return path:match("([^/\\]+)$") or path
end

function M.now()
    return os.date("%Y-%m-%d %H:%M:%S")
end

return M
