--- Annotation model and 3-way merge for the Google Drive sync file (format v2).
---
--- This module is pure Lua: it has no KOReader dependencies, so the exact same
--- rules can be unit-tested on a PC and are mirrored by the web reader.
--- See SYNC_FORMAT.md for the file format.

local gjson = require("gdriveplus_gjson")

local M = {}

M.FORMAT_VERSION = 2

local function round(x)
    return math.floor(x + 0.5)
end

local function is_num(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--- Deep copy keeping only JSON-representable values. `ext` (multi-page PDF
--- highlights) is keyed by page number in KOReader but by string in JSON, so
--- its keys are converted back to numbers here.
local function sanitize(v, key, depth)
    depth = depth or 0
    local tv = type(v)
    if tv == "string" or tv == "boolean" then
        return v
    elseif tv == "number" then
        if is_num(v) then return v end
        return nil
    elseif tv == "table" and depth < 32 then
        local out = {}
        for k, item in pairs(v) do
            local tk = type(k)
            if tk == "string" or tk == "number" then
                local nk = k
                if key == "ext" and tk == "string" and tonumber(k) then
                    nk = tonumber(k)
                end
                out[nk] = sanitize(item, k, depth + 1)
            end
        end
        return out
    end
    return nil
end
M.sanitize = sanitize

--- Stable identity of an annotation.
---   PDF highlight:   "p<page>|x0,y0|x1,y1"  (page coordinates, rounded)
---   EPUB highlight:  "<pos0 xpointer>|<pos1 xpointer>"
---   page bookmark:   "BOOKMARK|<page>"
--- Returns nil for entries that cannot be identified.
function M.key(a)
    if type(a) ~= "table" then return nil end
    local p0, p1 = a.pos0, a.pos1
    if p0 ~= nil and p1 ~= nil then
        if type(p0) == "table" and type(p1) == "table" then
            local page = tonumber(a.page) or tonumber(p0.page)
            if is_num(page) and is_num(p0.x) and is_num(p0.y) and is_num(p1.x) and is_num(p1.y) then
                return string.format("p%d|%d,%d|%d,%d", round(page),
                    round(p0.x), round(p0.y), round(p1.x), round(p1.y))
            end
            return nil
        elseif type(p0) == "string" and type(p1) == "string" then
            return p0 .. "|" .. p1
        end
        return nil
    end
    if is_num(a.page) then
        return "BOOKMARK|" .. string.format("%d", round(a.page))
    elseif type(a.page) == "string" and a.page ~= "" then
        return "BOOKMARK|" .. a.page
    end
    return nil
end

--- Modification time used for conflict resolution ("YYYY-MM-DD HH:MM:SS").
function M.time(a)
    local t = a.datetime_updated or a.datetime
    if type(t) == "string" then return t end
    return ""
end

--- Canonical string form, used to tell whether two entries are identical.
function M.canon(a)
    return gjson.encode(a)
end

--- Turn KOReader's annotation list (or any list/map of entries) into a keyed map.
--- Entries without a computable key are kept under their original string key
--- when one exists (so nothing is silently lost), otherwise dropped.
function M.to_map(entries)
    local map = {}
    if type(entries) ~= "table" then return map end
    for k, entry in pairs(entries) do
        if type(entry) == "table" then
            local copy = sanitize(entry)
            local key = M.key(copy)
            if key then
                -- On a key clash keep the most recently modified entry.
                local existing = map[key]
                if not existing or M.time(copy) >= M.time(existing) then
                    map[key] = copy
                end
            elseif type(k) == "string" and k ~= "__progress__" then
                map["?" .. (k:gsub("^%?+", ""))] = copy
            end
        end
    end
    return map
end

--- A deleted annotation: the whole entry, marked deleted and stamped. Keeping
--- everything (colour, note, boxes) lets another client restore it as it was.
local function tombstone(entry, now)
    local t = sanitize(entry) or {}
    t.deleted = true
    t.datetime_updated = now
    return t
end
M.tombstone = tombstone

--- 3-way merge.
--- @param local_map   current annotations on this device (keyed, live entries only)
--- @param base_map    snapshot written after the last successful sync (may be empty)
--- @param remote_map  what is on Google Drive now (may be empty)
--- @param now         "YYYY-MM-DD HH:MM:SS", stamped on new deletions
--- @return merged map (live entries and tombstones)
function M.merge(local_map, base_map, remote_map, now)
    local mine = {}
    for k, v in pairs(local_map) do mine[k] = v end

    -- Anything that was live at the last sync and is gone now was deleted here.
    for k, base in pairs(base_map) do
        if mine[k] == nil then
            if base.deleted then
                mine[k] = base
            else
                mine[k] = tombstone(base, now)
            end
        end
    end

    local merged = {}
    for k, v in pairs(remote_map) do merged[k] = v end

    for k, l in pairs(mine) do
        local r = merged[k]
        if r == nil then
            merged[k] = l
        else
            local lc, rc = M.canon(l), M.canon(r)
            if lc ~= rc then
                local b = base_map[k]
                local bc = b and M.canon(b)
                if bc and lc == bc then
                    -- unchanged here since last sync: the other side wins
                elseif bc and rc == bc then
                    merged[k] = l
                elseif M.time(l) >= M.time(r) then
                    merged[k] = l
                end
            end
        end
    end
    return merged
end

local function valid_box(b)
    return type(b) == "table" and is_num(b.x) and is_num(b.y) and is_num(b.w) and is_num(b.h)
end

local function valid_pos(p)
    return type(p) == "table" and is_num(p.x) and is_num(p.y)
end

--- Check an entry and fill in the fields KOReader relies on, so that data
--- written by another client can never crash the reader.
--- @param a        a sanitised entry (modified in place)
--- @param paging   true for PDF/DjVu/CBZ…, false for EPUB and other reflowable books
--- @param now      fallback timestamp
--- @param check_xpointer  optional function(xpointer) -> boolean
--- @return true, or false + reason
function M.normalize(a, paging, now, check_xpointer)
    local highlight = a.pos0 ~= nil or a.pos1 ~= nil
    if paging then
        if not is_num(a.page) then return false, "page is not a number" end
        if highlight then
            if not valid_pos(a.pos0) or not valid_pos(a.pos1) then
                return false, "pos0/pos1 are not page positions"
            end
            if type(a.pboxes) ~= "table" or #a.pboxes == 0 then
                return false, "no pboxes"
            end
            for _, b in ipairs(a.pboxes) do
                if not valid_box(b) then return false, "bad pbox" end
            end
            for _, p in ipairs({ a.pos0, a.pos1 }) do
                if not is_num(p.zoom) or p.zoom == 0 then p.zoom = 1 end
                if not is_num(p.rotation) then p.rotation = 0 end
                if not is_num(p.page) then p.page = a.page end
            end
            if a.ext ~= nil then
                if type(a.ext) ~= "table" then return false, "bad ext" end
                for page, part in pairs(a.ext) do
                    if not is_num(page) or type(part) ~= "table"
                        or not valid_pos(part.pos0) or not valid_pos(part.pos1)
                        or type(part.pboxes) ~= "table" then
                        return false, "bad ext entry"
                    end
                end
            end
        end
    else
        if type(a.page) ~= "string" or a.page == "" then return false, "page is not an xpointer" end
        if highlight then
            if type(a.pos0) ~= "string" or type(a.pos1) ~= "string" then
                return false, "pos0/pos1 are not xpointers"
            end
        end
        if check_xpointer then
            if not check_xpointer(a.page) then return false, "page xpointer not in document" end
            if highlight and not (check_xpointer(a.pos0) and check_xpointer(a.pos1)) then
                return false, "xpointer not in document"
            end
        end
    end
    if highlight and type(a.drawer) ~= "string" then a.drawer = "lighten" end
    if type(a.datetime) ~= "string" then a.datetime = now end
    if a.datetime_updated ~= nil and type(a.datetime_updated) ~= "string" then a.datetime_updated = nil end
    for _, field in ipairs({ "text", "note", "chapter", "color", "pageref" }) do
        local v = a[field]
        if v ~= nil and type(v) ~= "string" then a[field] = tostring(v) end
    end
    if a.pageno ~= nil and not is_num(a.pageno) then a.pageno = nil end
    return true
end

--- Build the list handed to KOReader: live, valid entries only.
--- @return list, skipped (array of {key=, reason=})
function M.to_reader_list(merged, paging, now, check_xpointer)
    local list, skipped = {}, {}
    for k, entry in pairs(merged) do
        if not entry.deleted then
            local copy = sanitize(entry)
            local ok, reason = false, "no key"
            if k:sub(1, 1) ~= "?" then
                ok, reason = M.normalize(copy, paging, now, check_xpointer)
            end
            if ok then
                list[#list + 1] = copy
            else
                skipped[#skipped + 1] = { key = k, reason = reason }
            end
        end
    end
    return list, skipped
end

--- Geometric fallback ordering (page, then top-to-bottom, then left-to-right).
--- Used only when KOReader's own sort is unavailable or fails.
function M.fallback_sort(list, paging)
    if not paging then return end
    local function top(a)
        if type(a.pos0) ~= "table" then return -1, -1 end
        return math.min(a.pos0.y, a.pos1.y), math.min(a.pos0.x, a.pos1.x)
    end
    table.sort(list, function(a, b)
        if a.page ~= b.page then return a.page < b.page end
        local ay, ax = top(a)
        local by, bx = top(b)
        if ay ~= by then return ay < by end
        if ax ~= bx then return ax < bx end
        return M.time(a) < M.time(b)
    end)
end

--- True when the two keyed maps hold the same live entries.
function M.same_live(a, b)
    local function live_count(m)
        local n = 0
        for _, v in pairs(m) do if not v.deleted then n = n + 1 end end
        return n
    end
    if live_count(a) ~= live_count(b) then return false end
    for k, v in pairs(a) do
        if not v.deleted then
            local other = b[k]
            if not other or other.deleted or M.canon(v) ~= M.canon(other) then
                return false
            end
        end
    end
    return true
end

--- True when two maps are identical including tombstones.
function M.same(a, b)
    for k, v in pairs(a) do
        if b[k] == nil or M.canon(v) ~= M.canon(b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

--- Build the sync document that is uploaded.
function M.build_doc(book, merged)
    return {
        version = M.FORMAT_VERSION,
        book = book,
        annotations = merged,
    }
end

--- Extract the annotation map from a decoded sync file.
--- Accepts format v2 and the legacy v1 file (a bare map keyed "pos0|pos1").
--- @return keyed map, version (1 or 2), book table or nil
function M.parse_doc(doc)
    if type(doc) ~= "table" then return {}, 0, nil end
    if type(doc.version) == "number" and type(doc.annotations) == "table" then
        return M.to_map(doc.annotations), doc.version, type(doc.book) == "table" and doc.book or nil
    end
    return M.to_map(doc), 1, nil
end

return M
