-- BalatroBench TCP Server
-- Uses LuaSocket (bundled with LOVE2D) for TCP communication

local socket = require("socket")

---------------------------------------------------------------------------
-- Minimal JSON encoder/decoder (avoids dependency on any specific JSON lib)
---------------------------------------------------------------------------
local JSON = {}

function JSON.encode(val)
    local t = type(val)
    if t == "nil" then return "null"
    elseif t == "boolean" then return val and "true" or "false"
    elseif t == "number" then return tostring(val)
    elseif t == "string" then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    elseif t == "table" then
        -- Check if array
        local is_array = true
        local max_i = 0
        for k, _ in pairs(val) do
            if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
                is_array = false
                break
            end
            if k > max_i then max_i = k end
        end
        if is_array and max_i == #val then
            local parts = {}
            for i = 1, #val do parts[i] = JSON.encode(val[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                parts[#parts + 1] = JSON.encode(tostring(k)) .. ":" .. JSON.encode(v)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

-- Simple JSON decoder for flat action objects from the Python client
-- Handles: {"action":"play","cards":[1,3,5],"type":"card","index":1}
function JSON.decode(s)
    if not s or s == "" then return nil end
    s = s:match("^%s*(.-)%s*$") -- trim

    if s == "null" then return nil end
    if s == "true" then return true end
    if s == "false" then return false end

    local num = tonumber(s)
    if num then return num end

    -- String
    if s:sub(1,1) == '"' and s:sub(-1) == '"' then
        return s:sub(2, -2):gsub('\\n', '\n'):gsub('\\r', '\r'):gsub('\\t', '\t'):gsub('\\"', '"'):gsub('\\\\', '\\')
    end

    -- Array
    if s:sub(1,1) == '[' and s:sub(-1) == ']' then
        local arr = {}
        local inner = s:sub(2, -2)
        if inner:match("^%s*$") then return arr end
        for item in inner:gmatch("[^,]+") do
            arr[#arr + 1] = JSON.decode(item)
        end
        return arr
    end

    -- Object
    if s:sub(1,1) == '{' and s:sub(-1) == '}' then
        local obj = {}
        local inner = s:sub(2, -2)
        if inner:match("^%s*$") then return obj end
        -- Match key:value pairs, handling arrays and nested strings
        local pos = 1
        local len = #inner
        while pos <= len do
            -- Skip whitespace and commas
            pos = inner:find('[^%s,]', pos)
            if not pos then break end
            -- Get key (must be a string)
            if inner:sub(pos, pos) ~= '"' then break end
            local key_end = inner:find('"', pos + 1)
            if not key_end then break end
            local key = inner:sub(pos + 1, key_end - 1)
            -- Skip colon
            pos = inner:find(':', key_end + 1)
            if not pos then break end
            pos = pos + 1
            -- Skip whitespace
            pos = inner:find('[^%s]', pos)
            if not pos then break end
            -- Get value
            local ch = inner:sub(pos, pos)
            local val_str
            if ch == '"' then
                -- String value
                local vend = inner:find('"', pos + 1)
                while vend and inner:sub(vend - 1, vend - 1) == '\\' do
                    vend = inner:find('"', vend + 1)
                end
                if not vend then break end
                val_str = inner:sub(pos, vend)
                pos = vend + 1
            elseif ch == '[' then
                -- Array value
                local depth = 1
                local vend = pos + 1
                while depth > 0 and vend <= len do
                    local c = inner:sub(vend, vend)
                    if c == '[' then depth = depth + 1
                    elseif c == ']' then depth = depth - 1 end
                    vend = vend + 1
                end
                val_str = inner:sub(pos, vend - 1)
                pos = vend
            elseif ch == '{' then
                -- Nested object
                local depth = 1
                local vend = pos + 1
                while depth > 0 and vend <= len do
                    local c = inner:sub(vend, vend)
                    if c == '{' then depth = depth + 1
                    elseif c == '}' then depth = depth - 1 end
                    vend = vend + 1
                end
                val_str = inner:sub(pos, vend - 1)
                pos = vend
            else
                -- Number, bool, null
                local vend = inner:find('[,}%]]', pos) or (len + 1)
                val_str = inner:sub(pos, vend - 1)
                pos = vend
            end
            obj[key] = JSON.decode(val_str)
        end
        return obj
    end

    return nil
end

---------------------------------------------------------------------------
-- Server class
---------------------------------------------------------------------------
local Server = {}
Server.__index = Server

local HOST = "127.0.0.1"
local PORT = tonumber(os.getenv("BALATROBENCH_PORT")) or 12345

function Server.new()
    local self = setmetatable({}, Server)
    self.server = nil
    self.client = nil
    self.buffer = ""
    self.connected = false
    self.running = false
    return self
end

function Server:start()
    local err
    self.server, err = socket.bind(HOST, PORT)
    if not self.server then
        print("[BalatroBench] Failed to bind " .. HOST .. ":" .. PORT .. " - " .. tostring(err))
        return false
    end
    self.server:settimeout(0) -- non-blocking
    self.running = true
    print("[BalatroBench] TCP server listening on " .. HOST .. ":" .. PORT)
    return true
end

function Server:stop()
    if self.client then self.client:close(); self.client = nil end
    if self.server then self.server:close(); self.server = nil end
    self.running = false
    self.connected = false
    print("[BalatroBench] Server stopped")
end

function Server:accept_client()
    if self.connected or not self.server then return end
    local client = self.server:accept()
    if client then
        client:settimeout(0) -- non-blocking reads
        self.client = client
        self.connected = true
        self.buffer = ""
        print("[BalatroBench] Client connected")
    end
end

function Server:send(data)
    if not self.connected or not self.client then return false end
    local ok, err = self.client:send(data .. "\n===END===\n")
    if not ok then
        print("[BalatroBench] Send error: " .. tostring(err))
        self:disconnect()
        return false
    end
    return true
end

function Server:send_json(tbl)
    if not self.connected or not self.client then return false end
    local data = JSON.encode(tbl)
    local ok, err = self.client:send(data .. "\n")
    if not ok then
        print("[BalatroBench] Send error: " .. tostring(err))
        self:disconnect()
        return false
    end
    return true
end

-- Non-blocking receive: returns parsed JSON or nil
function Server:receive()
    if not self.connected or not self.client then return nil end

    -- Use *l pattern to read a complete line (LuaSocket handles buffering)
    local line, err, partial = self.client:receive("*l")

    -- If we got partial data, buffer it for next time
    if partial and partial ~= "" then
        self.buffer = self.buffer .. partial
    end

    if not line then
        if err == "closed" then
            self:disconnect()
            return nil
        end
        -- err == "timeout" is normal for non-blocking

        -- Check if buffer has a complete line from accumulated partials
        local newline_pos = self.buffer:find("\n")
        if newline_pos then
            line = self.buffer:sub(1, newline_pos - 1)
            self.buffer = self.buffer:sub(newline_pos + 1)
        else
            return nil
        end
    else
        -- Got a complete line. Prepend any buffered partial data.
        if self.buffer ~= "" then
            line = self.buffer .. line
            self.buffer = ""
        end
    end

    -- Trim whitespace/CR
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then return nil end

    local data = JSON.decode(line)
    if data then
        return data
    else
        print("[BalatroBench] Invalid JSON: " .. line:sub(1, 200))
        return nil
    end
end

function Server:disconnect()
    if self.client then self.client:close(); self.client = nil end
    self.connected = false
    self.buffer = ""
    print("[BalatroBench] Client disconnected")
end

function Server:is_connected()
    return self.connected
end

return Server
