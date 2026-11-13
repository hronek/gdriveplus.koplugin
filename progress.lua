--- Reading progress push/pull.
---
--- Remote layout: KOReader_Sync/progress/<book file name>.json
---   { version, book={file, partial_md5}, progress, percentage, pages,
---     timestamp, device, device_id }
--- `progress` is a page number (PDF…) or an xpointer (EPUB…). Another client
--- that cannot produce an xpointer may omit it; `percentage` is then used.

local Event = require("ui/event")
local gjson = require("gjson")
local logger = require("logger")

local M = {}

function M.get_current(ui)
    if not ui or not ui.document then return nil end
    local progress_val, percent_val
    if ui.paging then
        progress_val = ui.paging:getLastProgress()
        percent_val = ui.paging:getLastPercent()
    elseif ui.rolling then
        progress_val = ui.rolling:getLastProgress()
        percent_val = ui.rolling:getLastPercent()
    end
    if progress_val == nil then return nil end
    local pages
    local ok, n = pcall(ui.document.getPageCount, ui.document)
    if ok and type(n) == "number" then pages = n end
    return { progress = progress_val, percentage = percent_val or 0, pages = pages }
end

local function go_to(ui, remote)
    local pct = type(remote.percentage) == "number" and remote.percentage or nil
    if ui.paging then
        local page = tonumber(remote.progress)
        if page then
            ui:handleEvent(Event:new("GotoPage", page))
            return true
        end
    elseif type(remote.progress) == "string" and remote.progress ~= "" then
        local doc = ui.document
        local valid = true
        if type(doc.isXPointerInDocument) == "function" then
            local ok, res = pcall(doc.isXPointerInDocument, doc, remote.progress)
            valid = ok and res
        end
        if valid then
            ui:handleEvent(Event:new("GotoXPointer", remote.progress))
            return true
        end
    end
    if pct then
        ui:handleEvent(Event:new("GotoPercent", pct * 100))
        return true
    end
    return false
end

local function locate(network, token, ctx)
    if ctx.cache.prog_id then return { id = ctx.cache.prog_id } end
    local file, err = network.findFile(token, ctx.remote_name, { parent_id = ctx.folder_id })
    if err then return nil, err end
    if file then return file end
    file, err = network.findByProperty(token, "partial_md5", ctx.book.partial_md5, ctx.folder_id)
    if err then return nil, err end
    return file
end

--- @param ctx {ui, book, remote_name, folder_id, cache, device, device_id}
--- @return true — or false, error
function M.push(network, token, ctx)
    local cur = M.get_current(ctx.ui)
    if not cur then return false, "no reading position" end
    local now = os.time()
    local body = gjson.encode({
        version = 2,
        book = { file = ctx.book.file, partial_md5 = ctx.book.partial_md5 },
        progress = cur.progress,
        percentage = cur.percentage,
        pages = cur.pages,
        timestamp = now,
        device = ctx.device,
        device_id = ctx.device_id,
    })

    local function put(id)
        return network.upload(token, {
            id = id,
            name = ctx.remote_name,
            parent_id = ctx.folder_id,
            app_properties = { partial_md5 = ctx.book.partial_md5 },
            content = body,
            mime = "application/json",
        })
    end

    local id, err
    if ctx.cache.prog_id then
        id, err = put(ctx.cache.prog_id)
        if not id then ctx.cache.prog_id = nil end -- stale id: fall through to a lookup
    end
    if not id then
        local file, lerr = locate(network, token, ctx)
        if lerr then return false, lerr end
        id, err = put(file and file.id or nil)
    end
    if not id then return false, "upload: " .. tostring(err) end
    ctx.cache.prog_id = id
    ctx.cache.progress_ts = now
    logger.dbg("GDriveSync: pushed progress", cur.percentage)
    return true
end

--- @param force  jump even when the remote position is older / from this device
--- @return status ("moved" | "same" | "older" | "none") — or nil, error
function M.pull(network, token, ctx, force)
    local file, err = locate(network, token, ctx)
    if err then return nil, err end
    if not file then return "none" end

    local content, derr, code = network.download(token, file.id)
    if not content and code == 404 and ctx.cache.prog_id then
        ctx.cache.prog_id = nil
        return M.pull(network, token, ctx, force)
    end
    if not content then return nil, "download: " .. tostring(derr) end
    ctx.cache.prog_id = file.id

    local remote = gjson.decode(content)
    if type(remote) ~= "table" then return nil, "remote progress is not valid JSON" end

    local cur = M.get_current(ctx.ui)
    if cur and remote.progress ~= nil and remote.progress == cur.progress then return "same" end

    if not force then
        if remote.device_id ~= nil and remote.device_id == ctx.device_id then return "same" end
        local remote_ts = tonumber(remote.timestamp) or 0
        if remote_ts <= (tonumber(ctx.cache.progress_ts) or 0) then return "older" end
    end

    if go_to(ctx.ui, remote) then
        ctx.cache.progress_ts = os.time()
        return "moved", remote
    end
    return nil, "remote position cannot be used"
end

return M
