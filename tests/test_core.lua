--- Tests for the KOReader-independent parts (JSON, keys, merge, validation).
--- Run from the repository root with any Lua 5.1+ / LuaJIT:
---     lua tests/test_core.lua

package.path = "./?.lua;" .. package.path
dofile("tests/foreign_modules.lua")

local gjson = require("gdriveplus_gjson")
local annotations = require("gdriveplus_annotations")
local utils = require("gdriveplus_utils")

local passed, failed = 0, 0
local function check(cond, name)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL: " .. name)
    end
end
local function eq(a, b, name)
    check(a == b, name .. "  (got " .. tostring(a) .. ", expected " .. tostring(b) .. ")")
end

-- --- gjson -----------------------------------------------------------------
eq(gjson.encode({}), "{}", "empty table is an object")
eq(gjson.encode({ pboxes = {} }), '{"pboxes":[]}', "empty pboxes is an array")
eq(gjson.encode({ 1, 2, 3 }), "[1,2,3]", "sequence is an array")
eq(gjson.encode({ b = 1, a = "x" }), '{"a":"x","b":1}', "keys are sorted")
eq(gjson.encode({ ext = { [1] = { a = 1 }, [2] = { a = 2 } } }), '{"ext":{"1":{"a":1},"2":{"a":2}}}', "ext is always an object")
eq(gjson.encode({ ext = { [5] = { a = 1 } } }), '{"ext":{"5":{"a":1}}}', "sparse ext")
eq(gjson.encode({ a = 0 / 0, b = math.huge, c = 1 }), '{"c":1}', "NaN and inf are dropped")
eq(gjson.encode({ f = function() end, c = true }), '{"c":true}', "functions are dropped")
eq(gjson.encode("a\"b\\c\n\11\1"), '"a\\"b\\\\c\\n\\u000b\\u0001"', "string escapes (no \\v)")
eq(gjson.encode(1.5), "1.5", "float")
eq(gjson.encode(100), "100", "integer")
eq(gjson.encode(123.456789012345678), "123.45678901235", "14 significant digits")

local d = gjson.decode('{"a":[1,2,{"b":null}],"s":"\\u010d\\ud83d\\ude00\\/x","n":-1.5e2,"t":true,"f":false}')
check(type(d) == "table", "decode object")
eq(d.a[2], 2, "decode array")
eq(d.a[3].b, nil, "null becomes nil")
eq(d.s, "č😀/x", "unicode escapes incl. surrogate pair")
eq(d.n, -150, "number with exponent")
eq(d.t, true, "true")
eq(d.f, false, "false")
check(gjson.decode('{"a":NaN,"b":1}').b == 1, "tolerates NaN from old files")
check(gjson.decode("[]") ~= nil and next(gjson.decode("[]")) == nil, "empty array")
check(gjson.decode('{"a":1} x') == nil, "trailing garbage is an error")
check(gjson.decode('{"a":') == nil, "truncated input is an error")
check(gjson.decode("") == nil, "empty input is an error")

-- round trip stability (canonical form)
local sample = { page = 3, pos0 = { x = 100.123456789012345, y = 1 / 3, zoom = 1.5 }, text = "žluťoučký kůň", pboxes = { { x = 1, y = 2, w = 3, h = 4 } } }
local once = gjson.encode(sample)
eq(gjson.encode(gjson.decode(once)), once, "encode(decode(x)) is stable")

-- --- utils -----------------------------------------------------------------
eq(utils.urlencode("a b'c=&+#ž"), "a%20b%27c%3D%26%2B%23%C5%BE", "urlencode")
eq(utils.q_escape("it's a \\ test"), "it\\'s a \\\\ test", "q_escape")
eq(utils.basename("/mnt/us/books/Moje kniha.pdf"), "Moje kniha.pdf", "basename")

-- --- shared merge fixtures ---------------------------------------------------
local fixtures = utils.read_json("tests/fixtures/merge_cases.json")
check(fixtures ~= nil, "fixtures load")

local function entry(spec)
    local name = type(spec) == "table" and spec.use or spec
    local e = annotations.sanitize(fixtures.entries[name])
    if type(spec) == "table" and spec.set then
        for k, v in pairs(spec.set) do e[k] = v end
    end
    return e, name
end

for name, key in pairs(fixtures.keys) do
    eq(annotations.key(fixtures.entries[name]), key, "key of " .. name)
end

local function build(list)
    local out = {}
    for _, spec in ipairs(list) do out[#out + 1] = (entry(spec)) end
    return annotations.to_map(out)
end

for _, case in ipairs(fixtures.cases) do
    local merged = annotations.merge(build(case["local"]), build(case.base), build(case.remote), "2026-11-10 12:00:00")
    local live, deleted = {}, {}
    for k, v in pairs(merged) do
        if v.deleted then deleted[k] = true else live[k] = true end
    end
    local function same_set(set, names)
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        if n ~= #names then return false end
        for _, nm in ipairs(names) do
            if not set[fixtures.keys[nm]] then return false end
        end
        return true
    end
    check(same_set(live, case.expect.live), case.name .. " [live]")
    check(same_set(deleted, case.expect.deleted), case.name .. " [deleted]")
    for nm, fields in pairs(case.expect.fields or {}) do
        for f, v in pairs(fields) do
            eq(merged[fixtures.keys[nm]][f], v, case.name .. " [" .. f .. "]")
        end
    end
    -- merging the result again with itself as base and remote must be a no-op
    local live_map = {}
    for k, v in pairs(merged) do if not v.deleted then live_map[k] = v end end
    local again = annotations.merge(live_map, merged, merged, "2026-11-11 12:00:00")
    check(annotations.same(again, merged), case.name .. " [idempotent]")
end

-- --- validation --------------------------------------------------------------
local now = "2026-11-10 12:00:00"
local good = entry("pdfA")
check(annotations.normalize(good, true, now), "valid PDF highlight")

local nozoom = entry("pdfA")
nozoom.pos0.zoom, nozoom.pos1.zoom, nozoom.pos0.rotation = nil, nil, nil
nozoom.drawer, nozoom.datetime = nil, nil
check(annotations.normalize(nozoom, true, now), "web-style PDF highlight is accepted")
eq(nozoom.pos0.zoom, 1, "zoom is filled in")
eq(nozoom.pos0.rotation, 0, "rotation is filled in")
eq(nozoom.drawer, "lighten", "drawer is filled in")
eq(nozoom.datetime, now, "datetime is filled in")

local nobox = entry("pdfA")
nobox.pboxes = nil
check(not annotations.normalize(nobox, true, now), "PDF highlight without pboxes is rejected")
check(not annotations.normalize(entry("epubA"), true, now), "EPUB entry is rejected in a PDF")
check(not annotations.normalize(entry("pdfA"), false, now), "PDF entry is rejected in an EPUB")
check(annotations.normalize(entry("epubA"), false, now), "valid EPUB highlight")
check(not annotations.normalize(entry("epubA"), false, now, function() return false end), "EPUB xpointer outside the document is rejected")
check(annotations.normalize(entry("pdfBookmark"), true, now), "valid PDF bookmark")

-- ext keys survive a JSON round trip as numbers
local multi = entry("pdfA")
multi.ext = { [3] = { pos0 = { x = 1, y = 2 }, pos1 = { x = 3, y = 4 }, pboxes = {} }, [4] = { pos0 = { x = 1, y = 2 }, pos1 = { x = 3, y = 4 }, pboxes = {} } }
local doc = gjson.decode(gjson.encode(annotations.build_doc({ file = "a.pdf" }, annotations.to_map({ multi }))))
local map, version, book = annotations.parse_doc(doc)
eq(version, 2, "document version")
eq(book.file, "a.pdf", "book info")
local back = map[fixtures.keys.pdfA]
check(back and back.ext and back.ext[3] ~= nil and back.ext[4] ~= nil and back.ext["3"] == nil, "ext keys are numbers again")
check(annotations.normalize(back, true, now), "multi-page highlight validates after a round trip")

-- a deletion keeps the whole entry, so another client can restore it as it was
local full = entry("pdfA")
full.note, full.color, full.drawer = "n", "green", "underscore"
local tomb = annotations.tombstone(full, "2026-11-10 12:00:00")
check(tomb.deleted == true and tomb.datetime_updated == "2026-11-10 12:00:00", "tombstone is marked and stamped")
check(tomb.note == "n" and tomb.color == "green" and tomb.drawer == "underscore" and #tomb.pboxes == #full.pboxes, "tombstone keeps colour, note and boxes")
check(annotations.key(tomb) == annotations.key(full) and full.deleted == nil, "tombstone keeps the key and leaves the entry alone")
local tomb_ext = annotations.tombstone(back, "2026-11-10 12:00:00")
check(tomb_ext.ext and tomb_ext.ext[3] ~= nil, "tombstone of a multi-page highlight keeps its parts")
local after_delete = annotations.merge({}, { [fixtures.keys.pdfA] = full }, { [fixtures.keys.pdfA] = full }, "2026-11-10 12:00:00")
check(after_delete[fixtures.keys.pdfA].deleted and after_delete[fixtures.keys.pdfA].note == "n", "a deletion found by the merge keeps the note")

-- legacy v1 file: bare map with the old lossy keys is re-keyed
local legacy = { ["66.9|200.4"] = entry("pdfA"), ["66.9|200.4x"] = entry("pdfB_samex_otherpage"), ["__progress__"] = { progress = 5 } }
local lmap, lversion = annotations.parse_doc(gjson.decode(gjson.encode(legacy)))
eq(lversion, 1, "legacy file is recognised")
check(lmap[fixtures.keys.pdfA] and lmap[fixtures.keys.pdfB_samex_otherpage], "legacy entries are re-keyed")
check(lmap["__progress__"] == nil and lmap["?__progress__"] == nil, "legacy progress entry is ignored")

-- reader list: tombstones and invalid entries are left out, order is by page/position
local merged = annotations.to_map({ entry("pdfC"), entry("pdfB_samex_otherpage"), entry("pdfA"), entry("pdfBookmark") })
merged[fixtures.keys.pdfBookmark].deleted = true
merged["?junk"] = { text = "no position" }
local list, skipped = annotations.to_reader_list(merged, true, now)
eq(#list, 3, "reader list has the live valid entries")
eq(#skipped, 1, "invalid entry is reported")
annotations.fallback_sort(list, true)
eq(list[1].text, "first highlight", "sort: page 3, upper")
eq(list[2].text, "two line highlight", "sort: page 3, lower")
eq(list[3].text, "same x, other page", "sort: page 7")

-- --- main.lua against _meta.lua -------------------------------------------
-- KOReader's PluginLoader copies every _meta.lua field into the plugin object,
-- replacing a method of the same name. 1.1.0 had GDrivePlus:version(), and
-- drawing the Version item on Settings' second page crashed KOReader.
do
    local function read(path)
        local f = assert(io.open(path, "rb"))
        local s = f:read("*a")
        f:close()
        return s
    end
    local fields = {}
    for key in read("_meta.lua"):gmatch("\n%s*([%a_][%w_]*)%s*=") do fields[key] = true end
    check(fields.version and fields.fullname, "_meta.lua fields are found")
    local methods = 0
    for name in read("main.lua"):gmatch("function%s+GDrivePlus[:.]([%a_][%w_]*)") do
        methods = methods + 1
        check(not fields[name], "GDrivePlus:" .. name .. " would be replaced by the _meta.lua field " .. name)
    end
    check(methods > 20, "main.lua methods are found")
end

-- --- Drive search and folder listing (files.list stubbed) -----------------
do
    package.preload["ltn12"] = function() return { sink = {}, source = {} } end -- only request() uses it
    local network = require("gdriveplus_network")
    local real_query = network.query
    local calls = {}
    local reply = {}
    network.query = function(token, q, fields, order_by, max_items, corpora)
        calls[#calls + 1] = { token = token, q = q, fields = fields, order_by = order_by,
            max_items = max_items, corpora = corpora }
        local copy = {}
        for i, f in ipairs(reply) do
            copy[i] = {}
            for k, v in pairs(f) do copy[i][k] = v end
        end
        return copy
    end

    reply = {
        { id = "d1", name = "Hobit", mimeType = network.FOLDER_MIME, parents = { "root" } },
        { id = "f1", name = "Hobit.epub", mimeType = "application/epub+zip", parents = { "d1" } },
        { id = "s1", name = "Hobit (shortcut)", mimeType = network.SHORTCUT_MIME, parents = { "root" },
          shortcutDetails = { targetId = "f1", targetMimeType = "application/epub+zip" } },
        { id = "s2", name = "Shared Hobit", mimeType = network.SHORTCUT_MIME, parents = { "root" },
          shortcutDetails = { targetId = "d9", targetMimeType = network.FOLDER_MIME } },
        { id = "j1", name = "Hobit.epub.json", mimeType = "application/json", parents = { "sync_ann" } },
        { id = "n1", name = "No parents.pdf", mimeType = "application/pdf" },
    }
    local files, truncated = network.searchFiles("tok", "it's", { limit = 200, exclude_parents = { sync_ann = true } })
    local c = calls[#calls]
    eq(c.q, "name contains 'it\\'s' and trashed = false", "search query escapes the text")
    eq(c.corpora, "allDrives", "search includes shared drives")
    eq(c.order_by, "folder,name", "search lists folders first")
    eq(c.max_items, 200, "search passes the limit")
    check(c.fields:find("parents", 1, true) and c.fields:find("shortcutDetails", 1, true), "search asks for parents and shortcuts")
    local ids = {}
    for _, f in ipairs(files) do ids[#ids + 1] = f.id end
    eq(table.concat(ids, ","), "d1,f1,d9,n1", "search: shortcut resolved, duplicate and sync file left out")
    eq(files[3].mimeType, network.FOLDER_MIME, "shortcut to a folder opens as a folder")
    eq(truncated, false, "fewer results than the limit")

    reply = { { id = "a", name = "A" }, { id = "b", name = "B" } }
    local _, hit = network.searchFiles("tok", "x", { limit = 2 })
    eq(hit, true, "limit reached is reported")
    local plain = network.searchFiles("tok", "x")
    eq(#plain, 2, "search works without options")
    eq(calls[#calls].max_items, nil, "no limit without options")

    reply = {
        { id = "s1", name = "Shared", mimeType = network.SHORTCUT_MIME,
          shortcutDetails = { targetId = "d9", targetMimeType = network.FOLDER_MIME } },
        { id = "f1", name = "Book.pdf", mimeType = "application/pdf" },
    }
    local listed = network.listFiles("tok", "folder'1")
    eq(calls[#calls].q, "'folder\\'1' in parents and trashed = false", "listFiles query")
    eq(calls[#calls].corpora, nil, "listFiles keeps the default corpora")
    eq(listed[1].id .. " " .. listed[1].mimeType, "d9 " .. network.FOLDER_MIME, "listFiles resolves shortcuts")
    eq(listed[2].id, "f1", "listFiles keeps plain files")
    eq(network.listFiles("tok", network.SHARED_WITH_ME) and calls[#calls].q,
        "sharedWithMe = true and trashed = false", "listFiles shared with me")

    network.query = real_query

    -- query(): paging, the limit and corpora in the URL (HTTP stubbed)
    local real_request = network.request
    local urls = {}
    network.request = function(params)
        urls[#urls + 1] = params.url
        local page = {}
        for i = 1, 150 do page[i] = { id = tostring(#urls * 1000 + i) } end
        return gjson.encode({ files = page, nextPageToken = #urls < 3 and ("p" .. #urls) or nil }), 200
    end
    local got = network.query("tok", "name contains 'x'", nil, "folder,name", 200, "allDrives")
    eq(#got, 200, "query stops at the limit and trims to it")
    eq(#urls, 2, "query fetches only the pages it needs")
    check(urls[1]:find("&corpora=allDrives", 1, true), "query sends corpora")
    check(urls[2]:find("&pageToken=p1", 1, true), "query follows nextPageToken")
    urls = {}
    got = network.query("tok", "q")
    eq(#got, 450, "query without a limit reads every page")
    check(not urls[1]:find("corpora", 1, true), "no corpora unless asked")
    network.request = real_request
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
