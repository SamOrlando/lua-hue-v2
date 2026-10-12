local _M = {
	_VERSION     = 'lua-hue-v2 0.1.0',
	_DESCRIPTION = 'Philips Hue CLIP API v2 client (over lua-jsonreq)',
	_COPYRIGHT   = 'Copyright (C) Sam Orlando 2024 - MIT Cheese Please',
}

local type, pairs, ipairs, tostring, setmetatable, rawget, getenv =
	type, pairs, ipairs, tostring, setmetatable, rawget, os.getenv
local concat = table.concat
local jsonreq = require('jsonreq')
local jro = jsonreq.new

_M.meta = {
	hb = { methods = {} }, -- hue bridge metatable
	hr = { methods = {} }, -- hue resource metatable
}
_M.meta.hb.__index = _M.meta.hb.methods
_M.meta.hr.__index = _M.meta.hr.methods
local hb = _M.meta.hb.methods
local hrm = _M.meta.hr
local collections = {} -- collection name or type -> resource type
_M.collections = collections

-- data cache: keyed by type; legacy plural keys (data.lights) resolve to data.light
local data_mt = { __index = function(t, k)
	local rt = collections[k]
	if rt and rt ~= k then return rawget(t, rt) end
end }

local function default_devicetype()
	-- Hue limits: application name <= 20 chars, device/instance name <= 19 chars
	local inst = getenv("HOSTNAME") or getenv("COMPUTERNAME") or "lua"
	return "lua-hue-v2#" .. inst:sub(1, 19)
end

function _M.new(opt)  -- new bridge contains all data
	opt = opt or {}
	if type(opt) == "string" then opt = { host = opt } end
	if type(opt.host) ~= "string" or opt.host == "" then
		error("lua-hue-v2: host required", 2)
	end
	local enabled = opt.enabled ~= false
	local function client(url)
		return jro({ url = url, enabled = enabled, timeout = opt.timeout, transport = opt.transport })
	end

	local tbl = {
		api = client('https://' .. opt.host .. '/clip/v2'),
		base = client('https://' .. opt.host),
		key = opt.key,
		clientkey = opt.clientkey,
		devicetype = opt.devicetype or default_devicetype(),
		enabled = enabled,
		data = setmetatable({}, data_mt), -- cache of walks, keyed by resource type ("light", "scene", ...)
	}
	if tbl.key then tbl.api.headers['hue-application-key'] = tbl.key end
	return setmetatable(tbl, _M.meta.hb)
end

-- Turn a jsonreq result into data or nil, err.
-- Returns: body, code  |  nil, err_string, code, errors_table
local function check(res, code, ...)
	if res == nil then
		if type(code) == "number" then return nil, "HTTP " .. code, code end
		return nil, tostring(code or "request failed")
	end
	local errs = type(res) == "table" and res.errors
	if type(errs) == "table" and errs[1] then
		local d = {}
		for i, e in ipairs(errs) do d[i] = type(e) == "table" and tostring(e.description) or tostring(e) end
		return nil, concat(d, "; "), code, errs
	end
	if type(code) == "number" and code >= 400 then return nil, "HTTP " .. code, code end
	return res, code
end
_M.check = check

-- register(key)  -> true, 200
-- register()     -> true, code, username, clientkey  |  false, code_or_err, description
function hb:register(key)
	if key and type(key) == "string" then
		self.key = key
		self.api.headers['hue-application-key'] = key
		return true, 200
	end

	local res, code = self.base:post('/api', { devicetype = self.devicetype, generateclientkey = true })
	if not res then return false, code end
	local r = type(res) == "table" and res[1]
	if type(r) == "table" and type(r.success) == "table" and r.success.username then
		self.key = r.success.username
		self.clientkey = r.success.clientkey
		self.api.headers['hue-application-key'] = self.key
		return true, code, self.key, self.clientkey
	end
	return false, code, type(r) == "table" and type(r.error) == "table" and r.error.description or nil
end

-- Resource table: { collection getter, single getter/setter, path, extra }
-- extra: "c" = <singular>_create, "d" = <singular>_delete, "r" = read-only single
local resources = {
	{ "lights",          "light",          "light" },
	{ "scenes",          "scene",          "scene",          "cd" },
	{ "rooms",           "room",           "room",           "cd" },
	{ "zones",           "zone",           "zone",           "cd" },
	{ "bridge_homes",    "bridge_home",    "bridge_home",    "r" },
	{ "grouped_lights",  "grouped_light",  "grouped_light" },
	{ "devices",         "device",         "device",         "d" },
	{ "bridges",         "bridge",         "bridge" },
	{ "device_powers",   "device_power",   "device_power" },
	{ "motions",         "motion",         "motion" },
	{ "camera_motions",  "camera_motion",  "camera_motion" },
	{ "temperatures",    "temperature",    "temperature" },
	{ "light_levels",    "light_level",    "light_level" },
	{ "buttons",         "button",         "button" },
}
for _, d in ipairs(resources) do
	local plural, single, rtype, extra = d[1], d[2], d[3], d[4] or ""
	local base = '/resource/' .. rtype
	local pre = base .. '/'
	collections[plural], collections[rtype] = rtype, rtype
	hb[plural] = function(self) return self.api:get(base) end
	if extra:find("r", 1, true) then
		hb[single] = function(self, id) return self.api:get(pre .. id) end
	else
		hb[single] = function(self, id, tbl)
			if tbl then return self.api:put(pre .. id, tbl) end
			return self.api:get(pre .. id)
		end
	end
	if extra:find("c", 1, true) then hb[single .. "_create"] = function(self, tbl) return self.api:post(base, tbl) end end
	if extra:find("d", 1, true) then hb[single .. "_delete"] = function(self, id) return self.api:delete(pre .. id) end end
end
hb.groups_lights = hb.grouped_light -- legacy misspelled name

function hb:resources() return self.api:get('/resource') end

local rlp = '/resource/light/'
function hb:light_on(id, state) return self.api:put(rlp .. id, { on = { on = state } }) end
function hb:light_brightness(id, level) return self.api:put(rlp .. id, { dimming = { brightness = level } }) end
function hb:light_effect(id, effect) return self.api:put(rlp .. id, { effects = { effect = effect } }) end

-- walk()      : fetch all resources, cache as self.data[type][id]; returns self.data
-- walk(name)  : name is a collection getter ("lights") or type ("light");
--               refreshes self.data[type] and returns it.
-- On failure: nil, err, code, errors
function hb:walk(name)
	if name then
		local rtype = collections[name]
		if not rtype then return nil, "unknown collection: " .. tostring(name) end
		local res, err, code, errs = check(self.api:get('/resource/' .. rtype))
		if not res then return nil, err, code, errs end
		local tbl = {}
		for _, r in pairs(res.data or {}) do
			if r.id then tbl[r.id] = setmetatable(r, hrm) end
		end
		self.data[rtype] = tbl
		return tbl
	end
	local res, err, code, errs = check(self:resources())
	if not res then return nil, err, code, errs end
	local tbl = setmetatable({}, data_mt)
	for _, r in pairs(res.data or {}) do
		local rtype, rid = r.type, r.id
		if rtype and rid then
			local g = tbl[rtype]
			if not g then g = {}; tbl[rtype] = g end
			g[rid] = setmetatable(r, hrm)
		end
	end
	self.data = tbl
	return tbl
end

-- get(id [, type]) from cache; type may be "light" or legacy "lights"
function hb:get(id, device_type)
	local g = device_type and self.data[collections[device_type] or device_type]
	if g and g[id] then return g[id] end
	for _, grp in pairs(self.data) do
		local r = grp[id]
		if r then return r end
	end
end

return _M
