--- End-to-end test of sync.lua against an in-memory fake of Google Drive and a
--- minimal fake of KOReader's reader UI.
---     lua tests/test_sync.lua

package.path = "./?.lua;" .. package.path

-- KOReader stubs -------------------------------------------------------------
local log = {}
package.preload["logger"] = function()
    local function rec(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        log[#log + 1] = table.concat(parts, " ")
    end
    return { warn = rec, dbg = function() end, info = rec, err = rec }
end
package.preload["ui/uimanager"] = function()
    return { setDirty = function() end }
end

local gjson = require("gjson")
local annotations = require("annotations")
local utils = require("utils")
local sync = require("sync")

local passed, failed = 0, 0
local function check(cond, name)
    if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name) end
end
local function eq(a, b, name)
    check(a == b, name .. "  (got " .. tostring(a) .. ", expected " .. tostring(b) .. ")")
end

-- Fake Drive -----------------------------------------------------------------
local function new_drive()
    local drive = { files = {}, next_id = 1, requests = 0, fail_upload = false }
    local net = {}
    function net.findFile(_, name, opts)
        drive.requests = drive.requests + 1
        for id, f in pairs(drive.files) do
            if f.name == name and f.parent == opts.parent_id then return { id = id, name = f.name } end
        end
        return nil
    end
    function net.findByProperty(_, key, value, parent)
        drive.requests = drive.requests + 1
        for id, f in pairs(drive.files) do
            if f.parent == parent and f.props and f.props[key] == value then return { id = id, name = f.name } end
        end
        return nil
    end
    function net.download(_, id)
        drive.requests = drive.requests + 1
        local f = drive.files[id]
        if not f then return nil, "HTTP 404: File not found", 404 end
        return f.content, 200
    end
    function net.upload(_, args)
        drive.requests = drive.requests + 1
        if drive.fail_upload then return nil, "HTTP 500: backend error" end
        local id = args.id
        if id then
            if not drive.files[id] then return nil, "HTTP 404: File not found" end
        else
            id = "id" .. drive.next_id
            drive.next_id = drive.next_id + 1
            drive.files[id] = { parent = args.parent_id }
        end
        local f = drive.files[id]
        f.name, f.content, f.props = args.name, args.content, args.app_properties
        return id
    end
    drive.net = net
    function drive.put(name, content, props)
        local id = "id" .. drive.next_id
        drive.next_id = drive.next_id + 1
        drive.files[id] = { name = name, content = content, parent = "ANN", props = props }
        return id
    end
    function drive.by_name(name)
        for id, f in pairs(drive.files) do if f.name == name then return f, id end end
    end
    return drive
end

-- Fake device ----------------------------------------------------------------
local tmp_root = os.getenv("TEMP") or os.getenv("TMPDIR") or "."
local sdr_counter = 0
local function new_device(file_name, paging, list)
    sdr_counter = sdr_counter + 1
    local sdr = tmp_root .. "/gdriveplus_test_" .. os.time() .. "_" .. sdr_counter
    -- no mkdir in plain Lua: use the directory itself as a file-name prefix
    local dev = { saved = 0, sort_calls = 0 }
    dev.ui = {
        annotation = {
            annotations = list or {},
            onSaveSettings = function() dev.saved = dev.saved + 1 end,
            sortItems = function(_, items)
                dev.sort_calls = dev.sort_calls + 1
                if dev.sort_fails then error("comparePositions blew up") end
                annotations.fallback_sort(items, paging)
            end,
        },
        document = {
            isXPointerInDocument = function(_, xp) return not xp:find("BAD", 1, true) end,
        },
        doc_settings = { flush = function() end },
        view = { dialog = {}, resetHighlightBoxesCache = function() dev.cache_resets = (dev.cache_resets or 0) + 1 end },
    }
    dev.ctx = function(name)
        return {
            ui = dev.ui, paging = paging, sdr_dir = sdr, folder_id = "ANN",
            remote_name = (name or file_name) .. ".json", cache = dev.cache,
            book = { file = name or file_name, title = "Title", partial_md5 = "abc123", paging = paging },
        }
    end
    dev.cache = {}
    dev.sdr = sdr
    return dev
end

-- sync.lua writes "<sdr_dir>/gdriveplus.json"; make that a flat temp file name.
sync.BASE_NAME = "base.json"
local real_write, real_read = utils.write_file, utils.read_json
local store = {}
utils.write_file = function(path, content) store[path] = content; return true end
utils.read_json = function(path)
    local c = store[path]
    if not c then return nil end
    local d = gjson.decode(c)
    return type(d) == "table" and d or nil
end

local function pdf(page, x, y, text, extra)
    local a = {
        page = page,
        pos0 = { x = x, y = y, page = page, zoom = 1.3, rotation = 0 },
        pos1 = { x = x + 150, y = y + 12, page = page, zoom = 1.3, rotation = 0 },
        pboxes = { { x = x, y = y - 2, w = 150, h = 16 } },
        text = text, drawer = "lighten", datetime = "2026-11-01 10:00:00",
    }
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
end
local function texts(list)
    local t = {}
    for _, a in ipairs(list) do t[#t + 1] = a.text end
    table.sort(t)
    return table.concat(t, ",")
end

-- 1. First sync of a PDF with several highlights (the case that used to fail) --
local drive = new_drive()
local kobo = new_device("Moje kniha.pdf", true, {
    pdf(3, 100, 200, "a"), pdf(7, 100, 200, "b"), pdf(3, 100, 400, "c"),
})
local ok, res = sync.run(drive.net, "tok", kobo.ctx())
check(ok, "first PDF sync succeeds: " .. tostring(res))
eq(res.total, 3, "three annotations synced")
local f = drive.by_name("Moje kniha.pdf.json")
check(f ~= nil, "remote file is named after the book")
eq(f.props.partial_md5, "abc123", "hash stored in appProperties")
local remote_doc = gjson.decode(f.content)
eq(remote_doc.version, 2, "format version")
eq(remote_doc.book.file, "Moje kniha.pdf", "book name inside the file")
eq(remote_doc.book.partial_md5, "abc123", "hash inside the file")
eq(kobo.saved, 0, "reader is not touched when nothing came from remote")
check(kobo.cache.ann_id ~= nil, "remote id is cached")

-- 2. Nothing changed: on close no request is made at all ----------------------
local before = drive.requests
local ctx = kobo.ctx(); ctx.only_if_changed = true
ok, res = sync.run(drive.net, "tok", ctx)
check(ok and res.skipped_unchanged, "unchanged book is skipped on close")
eq(drive.requests, before, "no network requests when unchanged")

-- 3. Second device with no annotations pulls everything -----------------------
local kindle = new_device("Moje kniha.pdf", true, {})
ok, res = sync.run(drive.net, "tok", kindle.ctx())
check(ok and res.pulled, "second device pulls")
eq(texts(kindle.ui.annotation.annotations), "a,b,c", "all three highlights arrive, incl. same-x on another page")
eq(kindle.saved, 1, "reader settings saved once")
eq(kindle.cache_resets, 1, "KOReader's drawn-highlight cache is cleared")
eq(kindle.ui.annotation.annotations[1].text, "a", "list is sorted by position")

-- 4. KOReader's own sort crashing must not fail the sync ----------------------
local third = new_device("Moje kniha.pdf", true, {})
third.sort_fails = true
third.ui.document.configurable = { text_wrap = 1 }
local real_sort = third.ui.annotation.sortItems
third.ui.annotation.sortItems = function(self, items)
    third.ui.document.configurable.text_wrap = 0 -- as KOReader does before comparing
    return real_sort(self, items)
end
ok, res = sync.run(drive.net, "tok", third.ctx())
check(ok and res.pulled, "sync survives a failing KOReader sort")
eq(#third.ui.annotation.annotations, 3, "fallback sort keeps all entries")
eq(third.ui.document.configurable.text_wrap, 1, "PDF reflow setting is restored after a failed sort")

-- 5. Delete on one device, add on the other -----------------------------------
table.remove(kindle.ui.annotation.annotations, 1) -- delete "a"
ok = sync.run(drive.net, "tok", kindle.ctx())
check(ok, "kindle pushes a deletion")
table.insert(kobo.ui.annotation.annotations, pdf(9, 50, 50, "d"))
ok, res = sync.run(drive.net, "tok", kobo.ctx())
check(ok and res.pulled, "kobo merges")
eq(texts(kobo.ui.annotation.annotations), "b,c,d", "deletion applied and local addition kept")
ok = sync.run(drive.net, "tok", kindle.ctx())
eq(texts(kindle.ui.annotation.annotations), "b,c,d", "both devices converge")

-- 6. An entry written by the web reader (no zoom/rotation/drawer) -------------
local _, id = drive.by_name("Moje kniha.pdf.json")
local doc = gjson.decode(drive.files[id].content)
doc.annotations["p2|10,20|160,32"] = {
    page = 2, pos0 = { x = 10, y = 20, page = 2 }, pos1 = { x = 160, y = 32, page = 2 },
    pboxes = { { x = 10, y = 18, w = 150, h = 16 } }, text = "web", color = "green",
    datetime = "2026-11-09 09:00:00",
}
-- …and a broken one that must be skipped, not crash the sync
doc.annotations["p2|1,1|2,2"] = { page = 2, pos0 = { x = 1, y = 1 }, pos1 = { x = 2, y = 2 }, text = "broken", datetime = "2026-11-09 09:00:00" }
drive.files[id].content = gjson.encode(doc)
ok, res = sync.run(drive.net, "tok", kobo.ctx())
check(ok, "sync with web-written entries succeeds")
eq(res.invalid, 1, "the broken entry is reported")
eq(texts(kobo.ui.annotation.annotations), "b,c,d,web", "the web highlight is added")
local web = kobo.ui.annotation.annotations[1]
eq(web.pos0.zoom, 1, "zoom filled in for KOReader")
eq(web.drawer, "lighten", "drawer filled in for KOReader")
doc = gjson.decode(drive.files[id].content)
check(doc.annotations["p2|1,1|2,2"] ~= nil, "the broken entry is preserved on Drive, not destroyed")

-- 7. Failed upload: reported, and the next sync recovers ----------------------
table.insert(kobo.ui.annotation.annotations, pdf(11, 60, 60, "e"))
drive.fail_upload = true
ok, res = sync.run(drive.net, "tok", kobo.ctx())
check(not ok and tostring(res):find("HTTP 500", 1, true), "upload failure is reported with its reason")
drive.fail_upload = false
ok = sync.run(drive.net, "tok", kobo.ctx())
check(ok, "next sync succeeds")
ok = sync.run(drive.net, "tok", kindle.ctx())
eq(texts(kindle.ui.annotation.annotations), "b,c,d,e,web", "the change arrives after recovery")

-- 8. Unreadable remote file is never overwritten ------------------------------
local bad_drive = new_drive()
bad_drive.put("Moje kniha.pdf.json", "{ this is not json")
local dev = new_device("Moje kniha.pdf", true, { pdf(1, 1, 1, "x") })
ok, res = sync.run(bad_drive.net, "tok", dev.ctx())
check(not ok and tostring(res):find("not valid JSON", 1, true), "invalid remote JSON aborts the sync")
eq(bad_drive.by_name("Moje kniha.pdf.json").content, "{ this is not json", "remote file left untouched")

-- 9. Book renamed locally: the remote file follows -----------------------------
kobo.cache = {} -- e.g. metadata was not moved along
ok = sync.run(drive.net, "tok", kobo.ctx("Nový název.pdf"))
check(ok, "sync after rename succeeds")
check(drive.by_name("Nový název.pdf.json") ~= nil, "remote file renamed to the new book name")
check(drive.by_name("Moje kniha.pdf.json") == nil, "no duplicate under the old name")

-- 10. Migration from the original plugin's <hash>.json ------------------------
local old_drive = new_drive()
local legacy = {}
legacy["76.9|192.3"] = pdf(3, 100, 200, "old-a")
legacy["76.9|192.3 "] = pdf(7, 100, 200, "old-b")
old_drive.put("abc123.json", gjson.encode(legacy))
local fresh = new_device("Moje kniha.pdf", true, { pdf(5, 30, 30, "local") })
ok, res = sync.run(old_drive.net, "tok", fresh.ctx())
check(ok, "migration sync succeeds: " .. tostring(res))
eq(texts(fresh.ui.annotation.annotations), "local,old-a,old-b", "legacy annotations are imported")
check(old_drive.by_name("Moje kniha.pdf.json") ~= nil, "new file created under the book name")
check(old_drive.by_name("abc123.json") ~= nil, "legacy file is left in place")

-- 11. EPUB: remote xpointer that is not in the document is skipped --------------
local epub_drive = new_drive()
local function epub(xp0, xp1, text)
    return { page = xp0, pos0 = xp0, pos1 = xp1, text = text, drawer = "lighten", datetime = "2026-11-01 10:00:00" }
end
local e_doc = annotations.build_doc({ file = "Kniha.epub" }, annotations.to_map({
    epub("/body/DocFragment[2]/body/p[1]/text().0", "/body/DocFragment[2]/body/p[1]/text().9", "good"),
    epub("/body/DocFragment[2]/body/BAD[1]/text().0", "/body/DocFragment[2]/body/BAD[1]/text().9", "bad"),
}))
epub_drive.put("Kniha.epub.json", gjson.encode(e_doc))
local ereader = new_device("Kniha.epub", false, {})
ok, res = sync.run(epub_drive.net, "tok", ereader.ctx())
check(ok, "EPUB sync succeeds")
eq(texts(ereader.ui.annotation.annotations), "good", "only the resolvable xpointer is applied")
eq(res.invalid, 1, "the unresolvable one is reported")

-- 12. A crash inside the merge is caught and logged ----------------------------
local crash_dev = new_device("Moje kniha.pdf", true, { pdf(1, 1, 1, "x") })
crash_dev.ui.annotation.onSaveSettings = nil
local crash_net = {}
for k, v in pairs(drive.net) do crash_net[k] = v end
crash_net.findFile = function() error("boom") end
ok, res = sync.run(crash_net, "tok", crash_dev.ctx())
check(not ok and tostring(res):find("boom", 1, true), "internal errors are returned as text")
local logged = false
for _, line in ipairs(log) do if line:find("boom", 1, true) then logged = true end end
check(logged, "internal errors are written to the log")

utils.write_file, utils.read_json = real_write, real_read
print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
