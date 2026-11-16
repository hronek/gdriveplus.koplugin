--- Google Drive v3 REST client.
---
--- Uses KOReader's standard network stack (socket.http + socketutil timeouts),
--- the same one KOReader's own cloud storage and KOSync use. Every function
--- returns nil/false plus an error string on failure; nothing raises.

local gjson = require("gdriveplus_gjson")
local ltn12 = require("ltn12")
local utils = require("gdriveplus_utils")

local M = {}

local TOKEN_URL = "https://oauth2.googleapis.com/token"
local API = "https://www.googleapis.com/drive/v3/files"
local UPLOAD = "https://www.googleapis.com/upload/drive/v3/files"
M.FOLDER_MIME = "application/vnd.google-apps.folder"
M.SHORTCUT_MIME = "application/vnd.google-apps.shortcut"
--- Pseudo folder id for the "Shared with me" view.
M.SHARED_WITH_ME = "sharedWithMe"
-- Needed on every call so that files on shared drives are reachable.
local ALL_DRIVES = "supportsAllDrives=true"
--- Set while syncing in the background during reading (see main.lua `quietly`):
--- small requests then use these timeouts (seconds) instead of the usual 10/30.
M.short_timeouts = false
M.SHORT_BLOCK_TIMEOUT = 5
M.SHORT_TOTAL_TIMEOUT = 10

local function api_error(body, code, status)
    local msg
    local data = body and gjson.decode(body)
    if type(data) == "table" then
        if type(data.error) == "table" then
            msg = data.error.message
        elseif type(data.error) == "string" then
            msg = data.error_description or data.error
        end
    end
    return string.format("HTTP %s%s", tostring(code or status or "?"), msg and (": " .. msg) or "")
end

--- @param params {url, method, headers, body, sink}
--- @return body (or true when a sink was given), code — or nil, error
function M.request(params)
    local http = require("socket.http")
    local socket = require("socket")
    local ok_su, socketutil = pcall(require, "socketutil")

    local chunks = {}
    local req = {
        url = params.url,
        method = params.method or "GET",
        headers = params.headers or {},
        sink = params.sink or ltn12.sink.table(chunks),
    }
    req.headers["User-Agent"] = "KOReader/GDrivePlus"
    if not req.headers["Accept"] then req.headers["Accept"] = "application/json" end
    if params.body then
        req.source = ltn12.source.string(params.body)
        req.headers["Content-Length"] = tostring(#params.body)
    elseif req.method ~= "GET" then
        req.headers["Content-Length"] = "0"
    end

    if ok_su then
        -- Whole files get the longer "file" timeouts; a stalled connection still gives up.
        if params.file_transfer then
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        elseif M.short_timeouts then
            -- Background work while the user reads: give up quickly rather than freeze.
            socketutil:set_timeout(M.SHORT_BLOCK_TIMEOUT, M.SHORT_TOTAL_TIMEOUT)
        else
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        end
    end
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, http.request(req))
    end)
    if ok_su then socketutil:reset_timeout() end

    if not ok then return nil, "request failed: " .. tostring(code) end
    if type(code) ~= "number" then
        -- luasocket returns nil, "error message" on connection problems
        return nil, "connection error: " .. tostring(code or status)
    end
    local body = params.sink and "" or table.concat(chunks)
    if code < 200 or code >= 300 then
        return nil, api_error(body, code, status), code
    end
    return params.sink and true or body, code
end

local function auth(token, extra)
    local h = { ["Authorization"] = "Bearer " .. token }
    if extra then for k, v in pairs(extra) do h[k] = v end end
    return h
end

local function json_request(params)
    local body, err, code = M.request(params)
    if not body then return nil, err, code end
    local data, derr = gjson.decode(body)
    if type(data) ~= "table" then return nil, "bad JSON response: " .. tostring(derr) end
    return data
end

function M.refreshToken(client_id, client_secret, refresh_token)
    local body = string.format(
        "client_id=%s&client_secret=%s&refresh_token=%s&grant_type=refresh_token",
        utils.urlencode(client_id), utils.urlencode(client_secret), utils.urlencode(refresh_token))
    local data, err = json_request({
        url = TOKEN_URL,
        method = "POST",
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        body = body,
    })
    if not data then return nil, err end
    if not data.access_token then return nil, "no access_token in response" end
    return data
end

--- Run a files.list query, following nextPageToken.
--- @return array of files, or nil + error
function M.query(token, q, fields, order_by, max_items)
    local files = {}
    local page_token
    repeat
        local url = API .. "?pageSize=200&spaces=drive&includeItemsFromAllDrives=true&" .. ALL_DRIVES
            .. "&fields=" .. utils.urlencode("nextPageToken,files(" .. (fields or "id,name,mimeType,modifiedTime,size") .. ")")
            .. "&q=" .. utils.urlencode(q)
        if order_by then url = url .. "&orderBy=" .. utils.urlencode(order_by) end
        if page_token then url = url .. "&pageToken=" .. utils.urlencode(page_token) end
        local data, err = json_request({ url = url, headers = auth(token) })
        if not data then return nil, err end
        for _, f in ipairs(data.files or {}) do files[#files + 1] = f end
        page_token = data.nextPageToken
    until not page_token or (max_items and #files >= max_items)
    return files
end

--- Find one file by exact name.
--- @param opts {parent_id=, folder=true|nil}
--- @return file table, or nil (not found), or nil + error
function M.findFile(token, name, opts)
    opts = opts or {}
    local q = string.format("name = '%s' and trashed = false", utils.q_escape(name))
    if opts.parent_id then q = q .. string.format(" and '%s' in parents", utils.q_escape(opts.parent_id)) end
    if opts.folder then q = q .. string.format(" and mimeType = '%s'", M.FOLDER_MIME) end
    local files, err = M.query(token, q, nil, "modifiedTime desc", 1)
    if not files then return nil, err end
    return files[1]
end

--- Find one file by an appProperties value (visible to this OAuth client only).
function M.findByProperty(token, key, value, parent_id)
    local q = string.format("appProperties has { key='%s' and value='%s' } and trashed = false",
        utils.q_escape(key), utils.q_escape(value))
    if parent_id then q = q .. string.format(" and '%s' in parents", utils.q_escape(parent_id)) end
    local files, err = M.query(token, q, nil, "modifiedTime desc", 1)
    if not files then return nil, err end
    return files[1]
end

--- List a folder. Shortcuts are resolved to the file or folder they point to,
--- so folders shared by other people (which appear in My Drive only as
--- shortcuts) can be opened like any other folder.
--- @param folder_id  nil/"root" for My Drive, M.SHARED_WITH_ME for shared items
function M.listFiles(token, folder_id)
    local q
    if folder_id == M.SHARED_WITH_ME then
        q = "sharedWithMe = true and trashed = false"
    else
        q = string.format("'%s' in parents and trashed = false", utils.q_escape(folder_id or "root"))
    end
    local files, err = M.query(token, q,
        "id,name,mimeType,size,shortcutDetails(targetId,targetMimeType)", "folder,name")
    if not files then return nil, err end
    for _, f in ipairs(files) do
        local target = f.mimeType == M.SHORTCUT_MIME and f.shortcutDetails
        if type(target) == "table" and target.targetId then
            f.id, f.mimeType = target.targetId, target.targetMimeType
        end
    end
    return files
end

function M.createFolder(token, name, parent_id)
    local data, err = json_request({
        url = API .. "?fields=id&" .. ALL_DRIVES,
        method = "POST",
        headers = auth(token, { ["Content-Type"] = "application/json; charset=UTF-8" }),
        body = gjson.encode({
            name = name,
            mimeType = M.FOLDER_MIME,
            parents = parent_id and { parent_id } or nil,
        }),
    })
    if not data then return nil, err end
    return data.id
end

--- Find a folder by name under a parent, creating it when missing.
function M.ensureFolder(token, name, parent_id)
    local folder, err = M.findFile(token, name, { parent_id = parent_id, folder = true })
    if folder then return folder.id end
    if err then return nil, err end
    return M.createFolder(token, name, parent_id)
end

--- Download a file's content into memory.
function M.download(token, file_id)
    return M.request({
        url = string.format("%s/%s?alt=media&%s", API, utils.urlencode(file_id), ALL_DRIVES),
        headers = auth(token, { ["Accept"] = "*/*" }),
    })
end

--- Download straight to disk (books can be far larger than available RAM).
function M.downloadToFile(token, file_id, dest_path)
    local tmp = dest_path .. ".part"
    local f = io.open(tmp, "wb")
    if not f then return false, "cannot write " .. dest_path end
    local ok, err = M.request({
        url = string.format("%s/%s?alt=media&%s", API, utils.urlencode(file_id), ALL_DRIVES),
        headers = auth(token, { ["Accept"] = "*/*" }),
        sink = ltn12.sink.file(f),
        file_transfer = true,
    })
    if not ok then
        os.remove(tmp)
        return false, err
    end
    os.remove(dest_path)
    if not os.rename(tmp, dest_path) then
        os.remove(tmp)
        return false, "cannot rename download"
    end
    return true
end

--- Create or replace a file (metadata and content in one multipart request).
--- @param args {id=, name=, parent_id=, app_properties=, content=, mime=}
--- @return file id, or nil + error
function M.upload(token, args)
    local metadata = { name = args.name, appProperties = args.app_properties }
    local url, method
    if args.id then
        url = string.format("%s/%s?uploadType=multipart&fields=id&%s", UPLOAD, utils.urlencode(args.id), ALL_DRIVES)
        method = "PATCH"
    else
        url = UPLOAD .. "?uploadType=multipart&fields=id&" .. ALL_DRIVES
        method = "POST"
        metadata.parents = args.parent_id and { args.parent_id } or nil
    end
    local boundary = "gdriveplus_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
    local body = "--" .. boundary .. "\r\n"
        .. "Content-Type: application/json; charset=UTF-8\r\n\r\n"
        .. gjson.encode(metadata) .. "\r\n"
        .. "--" .. boundary .. "\r\n"
        .. "Content-Type: " .. (args.mime or "application/octet-stream") .. "\r\n\r\n"
        .. args.content .. "\r\n"
        .. "--" .. boundary .. "--"
    local data, err = json_request({
        url = url,
        method = method,
        headers = auth(token, { ["Content-Type"] = "multipart/related; boundary=" .. boundary }),
        body = body,
        file_transfer = #args.content > 256 * 1024,
    })
    if not data then return nil, err end
    if not data.id then return nil, "upload returned no id" end
    return data.id
end

return M
