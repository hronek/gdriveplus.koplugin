--- In-memory fake of the parts of Google Drive the plugin uses (see gdriveplus_network.lua).
---     local new_drive = dofile("tests/fake_drive.lua")
---     local drive = new_drive()
--- drive.net is passed where the plugin expects the network module; drive.requests
--- counts the calls. Files live in drive.files[id] = {name, content, parent, props}.

--- A stand-in for Drive's md5Checksum: any stable hash of the content will do.
local function checksum(s)
    local h1, h2 = 5381, 0
    for i = 1, #s do
        local c = s:byte(i)
        h1 = (h1 * 33 + c) % 4294967296
        h2 = (h2 * 31 + c * i) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end

local function new_drive()
    local drive = { files = {}, next_id = 1, requests = 0, fail_upload = false, clock = 0 }
    local net = {}
    local function touch(f)
        drive.clock = drive.clock + 1
        f.modifiedTime = string.format("2026-11-19T10:%02d:%02d.000Z", math.floor(drive.clock / 60) % 60, drive.clock % 60)
    end
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
    function net.listFolder(_, folder_id)
        drive.requests = drive.requests + 1
        local out = {}
        for id, f in pairs(drive.files) do
            if f.parent == folder_id then
                out[#out + 1] = { id = id, name = f.name, md5Checksum = checksum(f.content), modifiedTime = f.modifiedTime }
            end
        end
        return out
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
        touch(f)
        return id
    end
    drive.net = net
    drive.checksum = checksum
    function drive.put(name, content, props, parent)
        local id = "id" .. drive.next_id
        drive.next_id = drive.next_id + 1
        drive.files[id] = { name = name, content = content, parent = parent or "ANN", props = props }
        touch(drive.files[id])
        return id
    end
    function drive.by_name(name, parent)
        for id, f in pairs(drive.files) do
            if f.name == name and (parent == nil or f.parent == parent) then return f, id end
        end
    end
    return drive
end

return new_drive
