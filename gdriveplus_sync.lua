--- Annotation sync: download, 3-way merge, apply to KOReader, upload.
---
--- Remote layout:  KOReader_Sync/annotations/<book file name>.json
--- Local snapshot: <book>.sdr/gdriveplus.json  (state after the last successful sync)
---
--- Two modes:
---   open book  ctx.ui is KOReader's reader; merged annotations go straight into it.
---   offline    ctx.offline: a closed book (library sync). ctx.ui.annotation.annotations
---              holds the list from its metadata file and ctx.ui.doc_settings the
---              DocSettings to write it to; the caller flushes them and writes
---              the snapshot (stats.base_json). Without the document, EPUB
---              xpointers cannot be checked: entries taken over this way are
---              listed in ctx.cache.unverified and checked when the book is next
---              opened.
---
--- ctx.cache (kept in the book's metadata) also holds `unloadable`: keys of
--- remote entries this device cannot show (bad xpointer, broken entry). They are
--- in the snapshot but not in the reader, and must not be taken for deletions.

local annotations = require("gdriveplus_annotations")
local gjson = require("gdriveplus_gjson")
local logger = require("logger")
local utils = require("gdriveplus_utils")

local M = {}

M.BASE_NAME = "gdriveplus.json"

--- Locate the remote file for this book.
--- Order: cached id → by name → by content hash (book was renamed) → legacy <hash>.json.
--- @return file {id, name} or nil, is_legacy, error
local function locate(network, token, ctx)
    local cached = ctx.cache.ann_id
    if cached then
        return { id = cached, name = ctx.cache.ann_name }, false
    end
    local file, err = network.findFile(token, ctx.remote_name, { parent_id = ctx.folder_id })
    if err then return nil, false, err end
    if file then return file, false end

    file, err = network.findByProperty(token, "partial_md5", ctx.book.partial_md5, ctx.folder_id)
    if err then return nil, false, err end
    if file then return file, false end

    file, err = network.findFile(token, ctx.book.partial_md5 .. ".json", { parent_id = ctx.folder_id })
    if err then return nil, false, err end
    if file then return file, true end
    return nil, false
end

local function fetch(network, token, ctx)
    local file, legacy, err = locate(network, token, ctx)
    if err then return nil, err end
    if not file then return { map = {}, version = 0 } end

    local content, derr, code = network.download(token, file.id)
    if not content and code == 404 and ctx.cache.ann_id then
        -- cached id is stale (file deleted on Drive): look it up again
        ctx.cache.ann_id, ctx.cache.ann_name = nil, nil
        return fetch(network, token, ctx)
    end
    if not content then return nil, "download: " .. tostring(derr) end

    local map, version, book = {}, 0, nil
    if content:match("%S") then
        local doc, jerr = gjson.decode(content)
        if type(doc) ~= "table" then
            -- Never overwrite a file we could not read.
            return nil, "remote file is not valid JSON (" .. tostring(jerr) .. ")"
        end
        map, version, book = annotations.parse_doc(doc)
        if version > annotations.FORMAT_VERSION then
            return nil, "remote file has a newer format (v" .. version .. "); update the plugin"
        end
    end
    return { file = file, legacy = legacy, map = map, version = version, book = book }
end

local function read_base(ctx)
    local doc = utils.read_json(ctx.sdr_dir .. "/" .. M.BASE_NAME)
    if doc then return (annotations.parse_doc(doc)) end
    -- snapshot left by the original gdrive.koplugin
    doc = utils.read_json(ctx.sdr_dir .. "/" .. ctx.book.partial_md5 .. ".json.sync")
    if doc then return (annotations.parse_doc(doc)) end
    return {}
end

--- Closed book: store the list in its metadata. KOReader sorts the annotations
--- and recomputes their page numbers when it next opens a book whose metadata
--- carries `annotations_externally_modified` (meant for tools like KOHighlights).
local function apply_offline(ctx, list)
    if ctx.paging then annotations.fallback_sort(list, true) end
    ctx.ui.annotation.annotations = list
    local ds = ctx.ui.doc_settings
    ds:saveSetting("annotations", list)
    ds:saveSetting("annotations_externally_modified", true)
end

local function apply_to_reader(ctx, list)
    if ctx.offline then return apply_offline(ctx, list) end
    local ui = ctx.ui
    local ann = ui.annotation
    local sorted = false
    if type(ann.sortItems) == "function" then
        -- KOReader's comparator switches PDF reflow off while it runs; if it
        -- fails part-way the setting must be put back.
        local conf = ui.document and ui.document.configurable
        local text_wrap = conf and conf.text_wrap
        local ok, err = pcall(ann.sortItems, ann, list)
        sorted = ok
        if not ok then
            if conf then conf.text_wrap = text_wrap end
            logger.warn("GDrivePlus: KOReader sort failed, using fallback:", err)
        end
    end
    if not sorted then annotations.fallback_sort(list, ctx.paging) end

    ann.annotations = list
    -- KOReader caches the boxes it has drawn per page; without this, highlights
    -- that just arrived would not appear until the book is reopened.
    if ui.view and type(ui.view.resetHighlightBoxesCache) == "function" then
        pcall(ui.view.resetHighlightBoxesCache, ui.view)
    end
    pcall(ann.onSaveSettings, ann)
    if ui.doc_settings and type(ui.doc_settings.flush) == "function" then
        pcall(ui.doc_settings.flush, ui.doc_settings)
    end
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    local dialog = ui.view and ui.view.dialog or ui.dialog
    if ok_ui and dialog then UIManager:setDirty(dialog, "partial") end
end

local function key_set(t)
    return type(t) == "table" and next(t) ~= nil and t or nil
end

--- Only xpointers that did not originate on this device need checking: those
--- of the open book's own annotations are known to be good, except the ones a
--- library sync put there without the document (ctx.cache.unverified).
--- @return function(xpointer) -> boolean, or nil when nothing can be checked
local function make_xpointer_check(ctx, local_list)
    local doc = ctx.ui and ctx.ui.document
    if ctx.paging or ctx.offline or not doc or type(doc.isXPointerInDocument) ~= "function" then
        return nil
    end
    local unverified = key_set(ctx.cache.unverified) or {}
    local known = {}
    for _, a in ipairs(local_list) do
        local k = annotations.key(a)
        if not (k and unverified[k]) then
            for _, f in ipairs({ "page", "pos0", "pos1" }) do
                if type(a[f]) == "string" then known[a[f]] = true end
            end
        end
    end
    return function(xp)
        if known[xp] then return true end
        local ok, res = pcall(doc.isXPointerInDocument, doc, xp)
        return ok and res and true or false
    end
end

--- Can this device show the entry at all? Keys starting with "?" never can.
local function loadable(k, entry, paging, now, check)
    if k:sub(1, 1) == "?" then return false end
    return (annotations.normalize(annotations.sanitize(entry) or {}, paging, now, check))
end

--- The reader's list from the merged map, without what this device cannot show.
--- @return list, skipped (array of {key=, reason=})
local function reader_list(ctx, merged, now, check, unloadable)
    local list, skipped = annotations.to_reader_list(merged, ctx.paging, now, check)
    if check or ctx.paging or not next(unloadable) then return list, skipped end
    -- EPUB without the document: leave out what the open book found unusable
    local kept = {}
    for _, a in ipairs(list) do
        local k = annotations.key(a)
        if k and unloadable[k] then
            skipped[#skipped + 1] = { key = k, reason = "xpointer not in document (checked when the book was open)" }
        else
            kept[#kept + 1] = a
        end
    end
    return kept, skipped
end

local function do_sync(network, token, ctx)
    local ann = ctx.ui.annotation
    local local_list = ann and ann.annotations or {}
    local local_map = annotations.to_map(local_list)
    local base_map = read_base(ctx)
    local now = utils.now()
    local check = make_xpointer_check(ctx, local_list)
    local unverified = key_set(ctx.cache.unverified)
    local unloadable = key_set(ctx.cache.unloadable) or {}
    local verify_now = check ~= nil and unverified ~= nil

    -- An entry in the snapshot that this device could never show is missing
    -- from the reader without having been deleted here.
    local merge_local = local_map
    for k, b in pairs(base_map) do
        if local_map[k] == nil and not b.deleted
            and (unloadable[k] or not loadable(k, b, ctx.paging, now, check)) then
            if merge_local == local_map then
                merge_local = {}
                for lk, lv in pairs(local_map) do merge_local[lk] = lv end
            end
            merge_local[k] = b
        end
    end

    -- (live entries only: the snapshot's tombstones are never in the reader)
    if ctx.only_if_changed and not verify_now and annotations.same_live(merge_local, base_map) then
        -- nothing new on this device; remote changes are picked up on next open
        return true, { skipped_unchanged = true }
    end

    local remote, err = fetch(network, token, ctx)
    if not remote then return false, err end

    local merged = annotations.merge(merge_local, base_map, remote.map, now)

    local stats = { total = 0, pulled = false, pushed = false, invalid = 0 }
    for _, v in pairs(merged) do
        if not v.deleted then stats.total = stats.total + 1 end
    end

    -- Apply to KOReader when the live set differs from what the reader has, or
    -- when entries taken over without the document can now be checked.
    if ann and (verify_now or not annotations.same_live(merged, local_map)) then
        local list, skipped = reader_list(ctx, merged, now, check, unloadable)
        stats.invalid = #skipped
        local not_shown = {}
        for _, s in ipairs(skipped) do
            not_shown[s.key] = true
            logger.warn("GDrivePlus: skipping remote annotation", s.key, "-", s.reason)
        end
        ctx.cache.unloadable = key_set(not_shown)
        if check or ctx.paging then
            ctx.cache.unverified = nil -- everything in the list has been checked
        elseif ctx.offline then
            -- taken over without the document: checked when the book is opened
            local uv, before = {}, unverified or {}
            for _, a in ipairs(list) do
                local k = annotations.key(a)
                if k and (before[k] or not local_map[k]) then uv[k] = true end
            end
            ctx.cache.unverified = key_set(uv)
        end
        -- Skipped entries stay in the sync file; only apply if the valid part differs.
        if not annotations.same_live(annotations.to_map(list), local_map) then
            apply_to_reader(ctx, list)
            stats.pulled = true
        end
    end

    -- A device that has not opened the book knows its title only from the file.
    if remote.book then
        for _, f in ipairs({ "title", "authors" }) do
            if (ctx.book[f] == nil or ctx.book[f] == "") and type(remote.book[f]) == "string" then
                ctx.book[f] = remote.book[f]
            end
        end
    end

    local doc_json = gjson.encode(annotations.build_doc(ctx.book, merged))

    local need_upload = remote.file == nil or remote.legacy or remote.version ~= annotations.FORMAT_VERSION
        or remote.file.name ~= ctx.remote_name
        or not annotations.same(merged, remote.map)
    if need_upload then
        local id, uerr = network.upload(token, {
            id = (remote.file and not remote.legacy) and remote.file.id or nil,
            name = ctx.remote_name,
            parent_id = ctx.folder_id,
            app_properties = { partial_md5 = ctx.book.partial_md5 },
            content = doc_json,
            mime = "application/json",
        })
        if not id then return false, "upload: " .. tostring(uerr) end
        ctx.cache.ann_id, ctx.cache.ann_name = id, ctx.remote_name
        stats.pushed = true
        stats.uploaded_json = doc_json
    else
        ctx.cache.ann_id, ctx.cache.ann_name = remote.file.id, remote.file.name
    end

    if ctx.offline then
        -- the book's metadata folder may not exist yet: the caller writes it
        stats.base_json = doc_json
    elseif not M.write_base(ctx.sdr_dir, doc_json) then
        logger.warn("GDrivePlus: cannot write snapshot in", ctx.sdr_dir)
    end
    return true, stats
end

--- Write the snapshot of the last successful sync into a book's metadata folder.
function M.write_base(sdr_dir, doc_json)
    return utils.write_file(sdr_dir .. "/" .. M.BASE_NAME, doc_json)
end

--- Run one annotation sync.
--- @param ctx {ui, paging, book={file,title,authors,partial_md5,paging}, remote_name,
---             folder_id, sdr_dir, cache (table persisted per book), only_if_changed,
---             offline}
--- @return true, stats {total, pulled, pushed, invalid, uploaded_json?, base_json?}
---         (or {skipped_unchanged=true}) — or false, error message
function M.run(network, token, ctx)
    local ok, res, detail = xpcall(function()
        return do_sync(network, token, ctx)
    end, function(e)
        return tostring(e) .. "\n" .. debug.traceback()
    end)
    if not ok then
        logger.warn("GDrivePlus: annotation sync crashed:", res)
        return false, "internal error: " .. tostring(res):match("^[^\n]*")
    end
    if not res then
        logger.warn("GDrivePlus: annotation sync failed:", detail)
    end
    return res, detail
end

return M
