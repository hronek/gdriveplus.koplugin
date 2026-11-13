--- Annotation sync: download, 3-way merge, apply to KOReader, upload.
---
--- Remote layout:  KOReader_Sync/annotations/<book file name>.json
--- Local snapshot: <book>.sdr/gdriveplus.json  (state after the last successful sync)

local annotations = require("annotations")
local gjson = require("gjson")
local logger = require("logger")
local utils = require("utils")

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

    local map, version = {}, 0
    if content:match("%S") then
        local doc, jerr = gjson.decode(content)
        if type(doc) ~= "table" then
            -- Never overwrite a file we could not read.
            return nil, "remote file is not valid JSON (" .. tostring(jerr) .. ")"
        end
        map, version = annotations.parse_doc(doc)
        if version > annotations.FORMAT_VERSION then
            return nil, "remote file has a newer format (v" .. version .. "); update the plugin"
        end
    end
    return { file = file, legacy = legacy, map = map, version = version }
end

local function read_base(ctx)
    local doc = utils.read_json(ctx.sdr_dir .. "/" .. M.BASE_NAME)
    if doc then return (annotations.parse_doc(doc)) end
    -- snapshot left by the original gdrive.koplugin
    doc = utils.read_json(ctx.sdr_dir .. "/" .. ctx.book.partial_md5 .. ".json.sync")
    if doc then return (annotations.parse_doc(doc)) end
    return {}
end

local function apply_to_reader(ctx, list)
    local ui = ctx.ui
    local ann = ui.annotation
    local sorted = false
    if type(ann.sortItems) == "function" then
        local ok, err = pcall(ann.sortItems, ann, list)
        sorted = ok
        if not ok then logger.warn("GDrivePlus: KOReader sort failed, using fallback:", err) end
    end
    if not sorted then annotations.fallback_sort(list, ctx.paging) end

    ann.annotations = list
    pcall(ann.onSaveSettings, ann)
    if ui.doc_settings and type(ui.doc_settings.flush) == "function" then
        pcall(ui.doc_settings.flush, ui.doc_settings)
    end
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    local dialog = ui.view and ui.view.dialog or ui.dialog
    if ok_ui and dialog then UIManager:setDirty(dialog, "partial") end
end

--- Only xpointers that did not originate on this device need checking.
local function make_xpointer_check(ctx, local_list)
    local doc = ctx.ui.document
    if ctx.paging or type(doc.isXPointerInDocument) ~= "function" then return nil end
    local known = {}
    for _, a in ipairs(local_list) do
        for _, f in ipairs({ "page", "pos0", "pos1" }) do
            if type(a[f]) == "string" then known[a[f]] = true end
        end
    end
    return function(xp)
        if known[xp] then return true end
        local ok, res = pcall(doc.isXPointerInDocument, doc, xp)
        return ok and res and true or false
    end
end

local function do_sync(network, token, ctx)
    local ann = ctx.ui.annotation
    local local_list = ann and ann.annotations or {}
    local local_map = annotations.to_map(local_list)
    local base_map = read_base(ctx)

    if ctx.only_if_changed and annotations.same(local_map, base_map) then
        -- nothing new on this device; remote changes are picked up on next open
        return true, { skipped_unchanged = true }
    end

    local remote, err = fetch(network, token, ctx)
    if not remote then return false, err end

    local now = utils.now()
    local merged = annotations.merge(local_map, base_map, remote.map, now)

    local stats = { total = 0, pulled = false, pushed = false, invalid = 0 }
    for _, v in pairs(merged) do
        if not v.deleted then stats.total = stats.total + 1 end
    end

    -- Apply to KOReader when the live set differs from what the reader has.
    if ann and not annotations.same_live(merged, local_map) then
        local list, skipped = annotations.to_reader_list(merged, ctx.paging, now,
            make_xpointer_check(ctx, local_list))
        stats.invalid = #skipped
        for _, s in ipairs(skipped) do
            logger.warn("GDrivePlus: skipping remote annotation", s.key, "-", s.reason)
        end
        -- Skipped entries stay in the sync file; only apply if the valid part differs.
        if not annotations.same_live(annotations.to_map(list), local_map) then
            apply_to_reader(ctx, list)
            stats.pulled = true
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
    else
        ctx.cache.ann_id, ctx.cache.ann_name = remote.file.id, remote.file.name
    end

    if not utils.write_file(ctx.sdr_dir .. "/" .. M.BASE_NAME, doc_json) then
        logger.warn("GDrivePlus: cannot write snapshot in", ctx.sdr_dir)
    end
    return true, stats
end

--- Run one annotation sync.
--- @param ctx {ui, paging, book={file,title,authors,partial_md5,paging}, remote_name,
---             folder_id, sdr_dir, cache (table persisted per book), only_if_changed}
--- @return true, stats — or false, error message
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
