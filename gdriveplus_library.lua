--- Library sync: every book in the home folder gets the annotations and the
--- reading position that are on Google Drive, and Drive gets what changed
--- here, without the books being opened.
---
--- A closed book's state is its KOReader metadata file (<book>.sdr/metadata.<ext>.lua),
--- read and written through DocSettings as KOReader's own file browser does.
--- Annotations written this way are sorted and renumbered by KOReader the next
--- time the book is opened (`annotations_externally_modified`).
---
--- Pure Lua: everything that touches KOReader, the disk or the network comes in
--- through `deps` (see M.process), so the rules are tested on a PC.

local gjson = require("gdriveplus_gjson")
local progress = require("gdriveplus_progress")
local sync = require("gdriveplus_sync")
local utils = require("gdriveplus_utils")

local M = {}

M.INDEX_VERSION = 1

-- ---------------------------------------------------------------------------
-- What is there
-- ---------------------------------------------------------------------------

--- Book files under `root`; hidden folders and metadata folders are skipped.
--- @param fs {dir = function(path) -> iterator of entry names,
---            mode = function(path) -> "file" | "directory" | nil,
---            is_book = function(path) -> boolean}
--- @return array of {path, name}, sorted by path
function M.scan(root, fs, max_depth)
    max_depth = max_depth or 12
    local books = {}
    local function walk(dir, depth)
        local ok, iter, state, init = pcall(fs.dir, dir)
        if not ok or type(iter) ~= "function" then return end
        local prefix = dir == "/" and "" or dir
        for name in iter, state, init do
            if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
                local path = prefix .. "/" .. name
                local mode = fs.mode(path)
                if mode == "directory" then
                    if depth < max_depth and not name:match("%.sdr$") then walk(path, depth + 1) end
                elseif mode == "file" and fs.is_book(path) then
                    books[#books + 1] = { path = path, name = name }
                end
            end
        end
    end
    if type(root) == "string" and root ~= "" then
        walk(root == "/" and root or (root:gsub("/+$", "")), 0)
    end
    table.sort(books, function(a, b) return a.path < b.path end)
    return books
end

--- Drive files of a sync folder by book file name ("<book>.json" → "<book>").
--- When a name occurs twice, the most recently modified file wins (as findFile).
function M.by_book(files)
    local map = {}
    for _, f in ipairs(files or {}) do
        local book = type(f.name) == "string" and f.name:match("^(.+)%.json$")
        if book then
            local cur = map[book]
            if not cur or tostring(f.modifiedTime or "") > tostring(cur.modifiedTime or "") then
                map[book] = f
            end
        end
    end
    return map
end

--- What identifies one version of a Drive file.
local function version_of(f)
    return f and (f.md5Checksum or f.modifiedTime) or nil
end

-- ---------------------------------------------------------------------------
-- What changed since the last library sync
-- ---------------------------------------------------------------------------

--- The index remembers, per book path, the Drive files and the metadata file
--- as they were after the last library sync: {ann=, prog=, sdr=}.
function M.load_index(path)
    local data = utils.read_json(path)
    if type(data) ~= "table" or data.version ~= M.INDEX_VERSION or type(data.books) ~= "table" then
        return { version = M.INDEX_VERSION, books = {} }
    end
    return data
end

function M.save_index(path, index)
    return utils.write_file(path, gjson.encode(index))
end

--- Forget books that are no longer in the library.
function M.prune(index, books)
    local present = {}
    for _, b in ipairs(books) do present[b.path] = true end
    for path in pairs(index.books) do
        if not present[path] then index.books[path] = nil end
    end
end

--- The books that need work: the ones whose Drive files or metadata changed
--- since the last library sync, or that were never looked at. Books with
--- nothing on Drive and no metadata here are left alone.
--- @param remote {ann = M.by_book(...), prog = M.by_book(...)}
--- @param sidecar_mtime function(path) -> modification time of the metadata file, or nil
--- @param skip   a path not to touch (the open book), or nil
--- @return queue of {path, name, ann_file, prog_file, sdr_mtime, ann_changed, prog_changed, sdr_changed},
---         the books changed on Drive most recently first
function M.plan(remote, books, index, sidecar_mtime, skip)
    local queue = {}
    for _, b in ipairs(books) do
        if b.path ~= skip then
            local ann, prog = remote.ann[b.name], remote.prog[b.name]
            local mtime = sidecar_mtime(b.path)
            if ann or prog or mtime then
                local seen = index.books[b.path]
                local item = {
                    path = b.path, name = b.name, ann_file = ann, prog_file = prog, sdr_mtime = mtime,
                    ann_changed = true, prog_changed = true, sdr_changed = true,
                }
                if type(seen) == "table" then
                    item.ann_changed = seen.ann ~= version_of(ann)
                    item.prog_changed = seen.prog ~= version_of(prog)
                    item.sdr_changed = seen.sdr ~= mtime
                end
                if item.ann_changed or item.prog_changed or item.sdr_changed then
                    local t1 = ann and ann.modifiedTime or ""
                    local t2 = prog and prog.modifiedTime or ""
                    item.order = t1 > t2 and t1 or t2
                    queue[#queue + 1] = item
                end
            end
        end
    end
    table.sort(queue, function(a, b)
        if a.order ~= b.order then return a.order > b.order end
        return a.path < b.path
    end)
    return queue
end

-- ---------------------------------------------------------------------------
-- One book
-- ---------------------------------------------------------------------------

local function str(v)
    return type(v) == "string" and v ~= "" and v or nil
end

--- The position kept in a closed book's metadata, or nil.
local function local_position(ds, paging)
    local pct = tonumber(ds:readSetting("percent_finished"))
    local pos
    if paging then
        pos = tonumber(ds:readSetting("last_page"))
    else
        pos = str(ds:readSetting("last_xpointer"))
    end
    if pos == nil and pct == nil then return nil end
    return { progress = pos, percentage = pct, pages = paging and tonumber(ds:readSetting("doc_pages")) or nil }
end

--- Sync one closed book with Drive.
--- @param item  from M.plan
--- @param deps {
---   network, token, folders = {annotations = id, progress = id},
---   device, device_id, only_ahead, settings_key,
---   md5 = function(string) -> hex (optional),
---   parse_time = function(RFC 3339) -> Unix time,
---   docs = {
---     open(path) -> DocSettings, had_metadata;  flush(ds);
---     sidecar_dir(path);  sidecar_mtime(path);
---     paging(path) -> true | false | nil (not a book);  partial_md5(path);
---     dom_versions() -> latest, oldest with normalized xpointers (or nil);
---     history_time(path);  add_history(path, ts);  changed(path) } }
--- @return {status = "changed" | "unchanged" | "skipped" | "failed", reason?, notes,
---          pulled_annotations, pulled_position, pushed, index = {ann, prog, sdr}}
function M.process(item, deps)
    local docs = deps.docs
    local path, name = item.path, item.name
    local res = { name = name, path = path, notes = {}, pushed = false }
    local function fail(reason)
        res.status, res.reason = "failed", reason
        return res
    end

    local paging = docs.paging(path)
    if paging == nil then
        res.status, res.reason = "skipped", "no reader for this file type"
        return res
    end
    local ds, had_metadata = docs.open(path)
    local cache = ds:readSetting(deps.settings_key)
    if type(cache) ~= "table" then cache = {} end
    local cache_before = gjson.encode(cache)
    local hash = str(ds:readSetting("partial_md5_checksum")) or docs.partial_md5(path)
    if not hash then return fail("cannot read the book file") end

    local dirty = false -- something new for the metadata
    local index = { ann = version_of(item.ann_file), prog = version_of(item.prog_file) }
    local base_json, history_ts

    -- Annotations ------------------------------------------------------------
    local list = ds:readSetting("annotations")
    local old_format = list == nil
        and (ds:readSetting("highlight") ~= nil or ds:readSetting("bookmarks") ~= nil)
    if type(list) ~= "table" then list = {} end
    if (item.ann_changed or item.sdr_changed) and (item.ann_file or #list > 0) then
        if old_format then
            -- KOReader converts these when it opens the book; writing the new
            -- list now would hide them from that conversion
            table.insert(res.notes, "annotations in KOReader's old format: open the book once")
        else
            local props = ds:readSetting("doc_props")
            if type(props) ~= "table" then props = {} end
            local ctx = {
                ui = { annotation = { annotations = list }, doc_settings = ds },
                offline = true, paging = paging, cache = cache,
                folder_id = deps.folders.annotations, remote_name = name .. ".json",
                sdr_dir = docs.sidecar_dir(path),
                book = {
                    file = name, title = str(props.display_title) or str(props.title),
                    authors = str(props.authors), partial_md5 = hash, paging = paging,
                },
            }
            if item.ann_file and not cache.ann_id then
                cache.ann_id, cache.ann_name = item.ann_file.id, item.ann_file.name
            end
            local ok, stats = sync.run(deps.network, deps.token, ctx)
            if not ok then return fail("annotations: " .. tostring(stats)) end
            if stats.pulled then
                dirty = true
                res.pulled_annotations = true
            end
            if stats.pushed then
                res.pushed = true
                index.ann = deps.md5 and deps.md5(stats.uploaded_json) or nil
            end
            base_json = stats.base_json
        end
    end

    -- Reading position -------------------------------------------------------
    if item.prog_changed or item.sdr_changed then
        local here = local_position(ds, paging)
        -- when the book was last read here: the newest of what this plugin and
        -- KOReader's history remember; the metadata file's time only as a last
        -- resort (other tools touch it too)
        local here_ts = math.max(tonumber(cache.progress_ts) or 0, tonumber(docs.history_time(path)) or 0)
        if here_ts == 0 and had_metadata then here_ts = tonumber(item.sdr_mtime) or 0 end

        local remote
        if item.prog_file then
            local err
            remote, err = progress.fetch(deps.network, deps.token, item.prog_file.id)
            if not remote then return fail("position: " .. tostring(err)) end
            if not cache.prog_id then cache.prog_id = item.prog_file.id end
        end

        local action = progress.decide(here, here_ts, remote,
            { device_id = deps.device_id, only_ahead = deps.only_ahead })
        if action == "push" then
            local ok, body = progress.push_position(deps.network, deps.token, {
                book = { file = name, partial_md5 = hash }, remote_name = name .. ".json",
                folder_id = deps.folders.progress, cache = cache,
                device = deps.device, device_id = deps.device_id,
            }, here, here_ts)
            if not ok then return fail("position: " .. tostring(body)) end
            res.pushed = true
            index.prog = deps.md5 and deps.md5(body) or nil
        elseif action == "apply" then
            local pos = progress.usable_progress(remote, paging)
            if pos and not paging then
                -- An xpointer is only valid in the DOM version it was made in.
                -- Metadata with a position but no DOM version is taken by
                -- KOReader for a book opened by a very old version.
                local latest, normalized = docs.dom_versions()
                local here_dom = tonumber(ds:readSetting("cre_dom_version"))
                if here_dom == nil and latest then
                    ds:saveSetting("cre_dom_version", latest)
                elseif here_dom == nil or (normalized and here_dom < normalized) then
                    pos = nil -- the jump is offered on opening, checked against the book
                end
            end
            local pct = tonumber(remote.percentage)
            if pos or pct then
                if pos then
                    ds:saveSetting(paging and "last_page" or "last_xpointer", pos)
                    cache.progress_ts = tonumber(remote.timestamp)
                elseif here_ts > 0 then
                    -- remembered so that the old position here is not taken for a newer one
                    cache.progress_ts = here_ts
                end
                if pct then ds:saveSetting("percent_finished", pct) end
                dirty = true
                res.pulled_position = true
                history_ts = tonumber(remote.timestamp)
            end
        end
    end

    -- A book read elsewhere shows up in the history (where annotation viewers
    -- look for books, too), at the time it was read there.
    if res.pulled_annotations and not history_ts and not docs.history_time(path) and item.ann_file then
        history_ts = deps.parse_time and deps.parse_time(item.ann_file.modifiedTime) or nil
    end

    -- Write ------------------------------------------------------------------
    local write = dirty or (had_metadata and gjson.encode(cache) ~= cache_before)
    if write then
        if not had_metadata then
            ds:saveSetting("partial_md5_checksum", hash)
            if not paging and ds:readSetting("cre_dom_version") == nil then
                local latest = docs.dom_versions()
                if latest then ds:saveSetting("cre_dom_version", latest) end
            end
        end
        ds:saveSetting(deps.settings_key, cache)
        docs.flush(ds)
    end
    if base_json and (had_metadata or write) then
        if not sync.write_base(docs.sidecar_dir(path), base_json) then
            table.insert(res.notes, "cannot write the sync snapshot")
        end
    end
    if history_ts and history_ts > 0 and history_ts > (tonumber(docs.history_time(path)) or 0) then
        docs.add_history(path, history_ts)
    end
    if write then docs.changed(path) end

    index.sdr = docs.sidecar_mtime(path)
    res.index = index
    res.status = (dirty or res.pushed) and "changed" or "unchanged"
    return res
end

return M
