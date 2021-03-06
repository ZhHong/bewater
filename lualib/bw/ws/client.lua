f-- Copyright (C) Yichun Zhang (agentzh)


-- FIXME: this library is very rough and is currently just for testing
--        the websocket server.
local wbproto = require "bw.ws.proto"
local url = require "bw.ws.url"
local crypt = require "skynet.crypt"
local _recv_frame = wbproto.recv_frame
local _send_frame = wbproto.send_frame
local new_tab = wbproto.new_tab
local concat = table.concat
local char = string.char
local str_find = string.find
local rand = math.random
local setmetatable = setmetatable
local type = type
local debug = true --ngx.config.debug
local ngx_log = print --ngx.log
local ngx_DEBUG = print --ngx.DEBUG
local socket_base = require "bw.ws.socket_help"

local _M = new_tab(0, 13)
_M._VERSION = '0.03'


local mt = { __index = _M }


function _M.new(self, opts)
   local max_payload_len, send_unmasked, timeout
   if opts then
      max_payload_len = opts.max_payload_len
      send_unmasked = opts.send_unmasked
        timeout = opts.timeout
   end
   return setmetatable({
			  sock = sock,
			  max_payload_len = max_payload_len or 65535,
			  send_unmasked = send_unmasked,
		       }, mt)
end


function _M.connect(self, uri, opts)
    local parsed = url.parse(uri)
    local host = parsed.host
    local port = parsed.port
    local path = parsed.path
    if not port then
        port = 80
    end
    if type(port) == "string" then
       port = tonumber(port)
    end
    if path == "" then
        path = "/"
    end
    local proto_header, sock_opts
    if opts then
       local protos = opts.protocols
        if protos then
	   if type(protos) == "table" then
	      proto_header = "Sec-WebSocket-Protocol: "
		 .. concat(protos, ",") .. "\r\n"

            else
	       proto_header = "Sec-WebSocket-Protocol: " .. protos .. "\r\n"
	   end
        end

        local pool = opts.pool
        if pool then
            sock_opts = { pool = pool }
        end
    end

    if not proto_header then
       proto_header = ""
    end

    local ok, err
    local id
    if sock_opts then
       id = socket_base.open(host, port, sock_opts)
    else
       id = socket_base.open(host, port)
    end
    if not id then
        return nil, "failed to connect: " .. err
    end

    self.socket = socket_base.new_sock(id)
    -- do the websocket handshake:

    local bytes = char(rand(256) - 1, rand(256) - 1, rand(256) - 1,
                       rand(256) - 1, rand(256) - 1, rand(256) - 1,
                       rand(256) - 1, rand(256) - 1, rand(256) - 1,
                       rand(256) - 1, rand(256) - 1, rand(256) - 1,
                       rand(256) - 1, rand(256) - 1, rand(256) - 1,
                       rand(256) - 1)

    local key = crypt.base64encode(bytes)
    local req = "GET " .. path .. " HTTP/1.1\r\nUpgrade: websocket\r\nHost: "
                .. host .. ":" .. port
                .. "\r\nSec-WebSocket-Key: " .. key
                .. proto_header
                .. "\r\nSec-WebSocket-Version: 13"
                .. "\r\nConnection: Upgrade\r\n\r\n"
    self.socket:write(req)
    --if not bytes then
       -- return nil, "failed to send the handshake request: " .. err
   -- end

    local header_reader = self.socket:readline("\r\n\r\n")
    -- FIXME: check for too big response headers

    --    print (header_reader)
   -- local header, err, partial = header_reader()
   -- if not header then
   --     return nil, "failed to receive response header: " .. err
   -- end

    -- FIXME: verify the response headers
    return 1
end


function _M.set_timeout(self, time)
    local sock = self.socket
    if not sock then
        return nil, nil, "not initialized yet"
    end
    return sock:settimeout(time)
end


function _M.recv_frame(self)
    if self.fatal then
        return nil, nil, "fatal error already happened"
    end

    local socket = self.socket
    if not socket then
        return nil, nil, "not initialized yet"
    end

    local data, typ, err =  _recv_frame(socket, self.max_payload_len, false)
    if not data and not str_find(err, ": timeout", 1, true) then
        self.fatal = true
    end
    return data, typ, err
end

local function send_frame(self, fin, opcode, payload, max_payload_len)
    if self.fatal then
        return nil, "fatal error already happened"
    end

    if self.closed then
        return nil, "already closed"
    end

    local socket = self.socket
    if not socket then
        return nil, "not initialized yet"
    end

    local bytes, err = _send_frame(socket, fin, opcode, payload,
                                   self.max_payload_len,
                                   not self.send_unmasked)
    if not bytes then
     --   self.fatal = true
    end
    --return bytes, err
end
_M.send_frame = send_frame


function _M.send_text(self, data)
    return send_frame(self, true, 0x1, data)
end


function _M.send_binary(self, data)
    return send_frame(self, true, 0x2, data)
end


local function send_close(self, code, msg)
    local payload
    if code then
        if type(code) ~= "number" or code > 0x7fff then
            return nil, "bad status code"
        end
        payload = char(((code>>8) & 0xff), (code & 0xff))
                        .. (msg or "")
    end

    if debug then
        ngx_log(ngx_DEBUG, "sending the close frame")
    end

    local bytes, err = send_frame(self, true, 0x8, payload)

    if not bytes then
        self.fatal = true
    end

    self.closed = true

    return bytes, err
end
_M.send_close = send_close


function _M.send_ping(self, data)
    return send_frame(self, true, 0x9, data)
end


function _M.send_pong(self, data)
    return send_frame(self, true, 0xa, data)
end


function _M.close(self)
    if self.fatal then
        return nil, "fatal error already happened"
    end

    local socket = self.socket
    if not sock then
        return nil, "not initialized"
    end

    if not self.closed then
        local bytes, err = send_close(self)
        if not bytes then
            return nil, "failed to send close frame: " .. err
        end
    end

    return socket:close()
end


function _M.set_keepalive(self, ...)
    local sock = self.socket
    if not sock then
        return nil, "not initialized"
    end

    return socket:setkeepalive(...)
end


return _M
