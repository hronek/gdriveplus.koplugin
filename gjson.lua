--- Minimal, dependency-free JSON encoder/decoder.
---
--- KOReader's bundled JSON library can emit output that browsers reject
--- (bare NaN/Infinity, "\v", "[]" for an empty map) and turns sparse tables into
--- surprising shapes. The sync files are shared with a web app, so we control
--- both directions ourselves:
---   * output is always valid JSON, keys sorted (stable, diff-friendly, and
---     usable as a canonical form for equality checks);
---   * tables are arrays only when they are a clean 1..n sequence;
---   * values that JSON cannot represent (functions, userdata, NaN, inf) are dropped.

local M = {}

--- Keys whose value is always an object, even when it looks like a sequence.
M.object_keys = { annotations = true, ext = true, book = true }
--- Keys whose value is always an array, even when empty.
M.array_keys = { pboxes = true }

local escapes = {
    ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encode_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function encode_number(n)
    if n ~= n or n == math.huge or n == -math.huge then
        return nil
    end
    if n == math.floor(n) and math.abs(n) < 1e15 then
        return string.format("%d", n)
    end
    return string.format("%.14g", n)
end

local function is_array(t)
    local n = #t
    if n == 0 then return false end
    local count = 0
    for _ in pairs(t) do
        count = count + 1
        if count > n then return false end
    end
    return count == n
end

local encode_value

local function encode_table(t, key, depth)
    if depth > 64 then return nil end
    local as_array
    if M.object_keys[key] then
        as_array = false
    elseif M.array_keys[key] then
        as_array = next(t) == nil or is_array(t)
    else
        as_array = is_array(t)
    end

    local out = {}
    if as_array then
        for i = 1, #t do
            out[i] = encode_value(t[i], nil, depth + 1) or "null"
        end
        return "[" .. table.concat(out, ",") .. "]"
    end

    local keys = {}
    for k in pairs(t) do
        local tk = type(k)
        if tk == "string" then
            keys[#keys + 1] = k
        elseif tk == "number" then
            local ks = encode_number(k)
            if ks then keys[#keys + 1] = k end
        end
    end
    table.sort(keys, function(a, b)
        local sa, sb = tostring(a), tostring(b)
        if type(a) == "number" then sa = encode_number(a) end
        if type(b) == "number" then sb = encode_number(b) end
        return sa < sb
    end)
    for _, k in ipairs(keys) do
        local ks = type(k) == "number" and encode_number(k) or k
        local vs = encode_value(t[k], ks, depth + 1)
        if vs then
            out[#out + 1] = encode_string(ks) .. ":" .. vs
        end
    end
    return "{" .. table.concat(out, ",") .. "}"
end

encode_value = function(v, key, depth)
    local tv = type(v)
    if tv == "string" then
        return encode_string(v)
    elseif tv == "number" then
        return encode_number(v)
    elseif tv == "boolean" then
        return v and "true" or "false"
    elseif tv == "table" then
        return encode_table(v, key, depth)
    end
    return nil
end

--- Encode a Lua value. Returns a JSON string (never raises for odd values).
function M.encode(v)
    return encode_value(v, nil, 0) or "null"
end

-- ---------------------------------------------------------------------------
-- Decoder
-- ---------------------------------------------------------------------------

local function utf8_char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000),
        0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local unescapes = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
    n = "\n", r = "\r", t = "\t", v = "\v",
}

local function decode_error(s, pos, msg)
    error(string.format("JSON error at byte %d: %s", pos, msg), 0)
end

local function skip_ws(s, pos)
    local _, e = s:find("^[ \t\r\n]*", pos)
    return e + 1
end

local function decode_string(s, pos)
    -- pos points at the opening quote
    local parts = {}
    local i = pos + 1
    while true do
        local j = s:find('["\\]', i)
        if not j then decode_error(s, pos, "unterminated string") end
        if j > i then parts[#parts + 1] = s:sub(i, j - 1) end
        local c = s:sub(j, j)
        if c == '"' then
            return table.concat(parts), j + 1
        end
        local e = s:sub(j + 1, j + 1)
        if e == "u" then
            local hex = s:match("^%x%x%x%x", j + 2)
            if not hex then decode_error(s, j, "bad \\u escape") end
            local cp = tonumber(hex, 16)
            i = j + 6
            if cp >= 0xD800 and cp <= 0xDBFF then
                local lo = s:match("^\\u(%x%x%x%x)", i)
                local lo_cp = lo and tonumber(lo, 16)
                if lo_cp and lo_cp >= 0xDC00 and lo_cp <= 0xDFFF then
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo_cp - 0xDC00)
                    i = i + 6
                else
                    cp = 0xFFFD
                end
            elseif cp >= 0xDC00 and cp <= 0xDFFF then
                cp = 0xFFFD
            end
            parts[#parts + 1] = utf8_char(cp)
        else
            -- Unknown escapes are taken literally (old sync files may contain them).
            parts[#parts + 1] = unescapes[e] or e
            i = j + 2
        end
    end
end

local decode_value

local function decode_array(s, pos)
    local arr = {}
    local n = 0
    pos = skip_ws(s, pos + 1)
    if s:sub(pos, pos) == "]" then return arr, pos + 1 end
    while true do
        local v
        v, pos = decode_value(s, pos)
        n = n + 1
        arr[n] = v -- a null leaves a hole; callers only use sanitised data
        pos = skip_ws(s, pos)
        local c = s:sub(pos, pos)
        if c == "]" then return arr, pos + 1 end
        if c ~= "," then decode_error(s, pos, "expected ',' or ']'") end
        pos = skip_ws(s, pos + 1)
    end
end

local function decode_object(s, pos)
    local obj = {}
    pos = skip_ws(s, pos + 1)
    if s:sub(pos, pos) == "}" then return obj, pos + 1 end
    while true do
        if s:sub(pos, pos) ~= '"' then decode_error(s, pos, "expected string key") end
        local k, v
        k, pos = decode_string(s, pos)
        pos = skip_ws(s, pos)
        if s:sub(pos, pos) ~= ":" then decode_error(s, pos, "expected ':'") end
        pos = skip_ws(s, pos + 1)
        v, pos = decode_value(s, pos)
        obj[k] = v
        pos = skip_ws(s, pos)
        local c = s:sub(pos, pos)
        if c == "}" then return obj, pos + 1 end
        if c ~= "," then decode_error(s, pos, "expected ',' or '}'") end
        pos = skip_ws(s, pos + 1)
    end
end

decode_value = function(s, pos)
    local c = s:sub(pos, pos)
    if c == "{" then
        return decode_object(s, pos)
    elseif c == "[" then
        return decode_array(s, pos)
    elseif c == '"' then
        return decode_string(s, pos)
    end
    -- Literals. NaN/Infinity are not JSON but old sync files may contain them.
    for _, lit in ipairs({ "true", "false", "null", "NaN", "Infinity", "-Infinity" }) do
        if s:sub(pos, pos + #lit - 1) == lit then
            local v = nil
            if lit == "true" then v = true elseif lit == "false" then v = false end
            return v, pos + #lit
        end
    end
    local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if num and num ~= "" then
        local n = tonumber(num)
        if n then return n, pos + #num end
    end
    decode_error(s, pos, "unexpected character '" .. c .. "'")
end

--- Decode a JSON string. Returns value, or nil + error message.
function M.decode(s)
    if type(s) ~= "string" then return nil, "not a string" end
    -- strip UTF-8 BOM
    if s:sub(1, 3) == "\239\187\191" then s = s:sub(4) end
    local ok, res, pos = pcall(function()
        local start = skip_ws(s, 1)
        local v, p = decode_value(s, start)
        return v, skip_ws(s, p)
    end)
    if not ok then return nil, res end
    if pos <= #s then return nil, "trailing data at byte " .. pos end
    return res
end

return M
