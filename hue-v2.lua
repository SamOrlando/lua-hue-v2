local _M = {
	_VERSION     = 'lua-hue-v2 0.2.1',
	_DESCRIPTION = 'Philips Hue CLIP API v2 client (over lua-jsonreq)',
	_COPYRIGHT   = 'Copyright (C) Sam Orlando 2024-2026 - MIT',
}

local type, pairs, ipairs, tostring, setmetatable, rawget, getenv =
	type, pairs, ipairs, tostring, setmetatable, rawget, os.getenv
local concat = table.concat
local floor = math.floor
local jsonreq = require('jsonreq')
local jro = jsonreq.new

_M.meta = {
	hb = { methods = {} }, -- hue bridge metatable
	hr = { methods = {} }, -- hue resource metatable
}
_M.meta.hb.__index = _M.meta.hb.methods
_M.meta.hr.__index = _M.meta.hr.methods
local hb = _M.meta.hb.methods
local hrm = _M.meta.hr.methods
local collections = {} -- collection name or type -> resource type
_M.collections = collections
-- resource -> bridge, without a field the next PUT would send back
local link = setmetatable({}, { __mode = "k" })

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

function _M.new(opt)
	opt = opt or {}
	if type(opt) == "string" then opt = { host = opt } end
	if type(opt.host) ~= "string" or opt.host == "" then
		error("lua-hue-v2: host required", 2)
	end
	local enabled = opt.enabled ~= false
	local function client(url)
		return jro({ url = url, enabled = enabled, timeout = opt.timeout or 30, transport = opt.transport })
	end

	local tbl = {
		api = client('https://' .. opt.host .. '/clip/v2'),
		base = client('https://' .. opt.host),
		key = opt.key,
		clientkey = opt.clientkey,
		devicetype = opt.devicetype or default_devicetype(),
		enabled = enabled,
		data = setmetatable({}, data_mt),
	}
	if tbl.key then tbl.api.headers['hue-application-key'] = tbl.key end
	return setmetatable(tbl, _M.meta.hb)
end

-- body, code  |  nil, err, code, errors
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

-- Hue gamut triangles (red, green, blue) from the CLIP color spec.
_M.gamut = {
	A = { { 0.704, 0.296 }, { 0.2151, 0.7106 }, { 0.138, 0.08 } },
	B = { { 0.675, 0.322 }, { 0.409, 0.518 }, { 0.167, 0.04 } },
	C = { { 0.6915, 0.3083 }, { 0.17, 0.7 }, { 0.1532, 0.0475 } },
}

local function srgb_lin(c)
	if c > 1 then c = c / 255 end
	if c <= 0.04045 then return c / 12.92 end
	return ((c + 0.055) / 1.055) ^ 2.4
end

local function srgb_enc(c)
	if c < 0 then c = 0 elseif c > 1 then c = 1 end
	if c <= 0.0031308 then return 12.92 * c end
	return 1.055 * (c ^ (1 / 2.4)) - 0.055
end

-- IEC 61966-2-1 sRGB, D65. Channels are 0-1 or 0-255.
function _M.xy(r, g, b)
	r, g, b = srgb_lin(r), srgb_lin(g), srgb_lin(b)
	local X = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
	local Y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
	local Z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
	local s = X + Y + Z
	if s == 0 then return 0, 0 end
	return X / s, Y / s
end

-- Y is relative luminance, default 1. Returns channels in 0-1.
function _M.rgb(x, y, Y)
	Y = Y or 1
	if y == 0 then return 0, 0, 0 end
	local X = Y / y * x
	local Z = Y / y * (1 - x - y)
	local r =  3.2404542 * X + -1.5371385 * Y + -0.4985314 * Z
	local g = -0.9692660 * X +  1.8760108 * Y +  0.0415560 * Z
	local b =  0.0556434 * X + -0.2040259 * Y +  1.0572252 * Z
	return srgb_enc(r), srgb_enc(g), srgb_enc(b)
end

function _M.mirek(kelvin)
	local m = floor(1000000 / kelvin + 0.5)
	if m < 153 then return 153 elseif m > 500 then return 500 end
	return m
end

function _M.kelvin(mirek)
	return floor(1000000 / mirek + 0.5)
end

local function bary(x, y, t)
	local r, g, b = t[1], t[2], t[3]
	local den = (g[2] - b[2]) * (r[1] - b[1]) + (b[1] - g[1]) * (r[2] - b[2])
	local w1 = ((g[2] - b[2]) * (x - b[1]) + (b[1] - g[1]) * (y - b[2])) / den
	local w2 = ((b[2] - r[2]) * (x - b[1]) + (r[1] - b[1]) * (y - b[2])) / den
	return w1, w2, 1 - w1 - w2
end

local function nearest(px, py, ax, ay, bx, by)
	local dx, dy = bx - ax, by - ay
	local t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
	if t < 0 then t = 0 elseif t > 1 then t = 1 end
	return ax + t * dx, ay + t * dy
end

-- gamut is "A", "B", "C", or a red/green/blue triangle.
function _M.clamp(x, y, gamut)
	local t = _M.gamut[gamut] or gamut
	if type(t) ~= "table" or not t[3] then return nil, "unknown gamut" end
	local w1, w2, w3 = bary(x, y, t)
	if w1 >= -1e-8 and w2 >= -1e-8 and w3 >= -1e-8 then return x, y end
	local bx, by, bd = x, y, math.huge
	local pts = { t[1], t[2], t[3], t[1] }
	for i = 1, 3 do
		local cx, cy = nearest(x, y, pts[i][1], pts[i][2], pts[i + 1][1], pts[i + 1][2])
		local d = (cx - x) ^ 2 + (cy - y) ^ 2
		if d < bd then bx, by, bd = cx, cy, d end
	end
	return bx, by
end

-- High-level light fields -> CLIP PUT body. Brightness 0 is kept.
-- mirek wins over kelvin. effects, gradient, and timed_effects are light-only;
-- set() drops them for other types.
function _M.state(s)
	local b = {}
	if s.on ~= nil then b.on = { on = s.on } end
	if s.brightness ~= nil then b.dimming = { brightness = s.brightness } end
	if s.mirek ~= nil or s.kelvin ~= nil then
		b.color_temperature = { mirek = s.mirek or _M.mirek(s.kelvin) }
	end
	if s.xy then b.color = { xy = s.xy } end
	if s.effect then b.effects = { effect = s.effect } end
	if s.alert then b.alert = { action = s.alert } end
	if s.duration ~= nil then b.dynamics = { duration = s.duration } end
	if s.gradient then b.gradient = { points = s.gradient } end
	if s.timed_effect then
		b.timed_effects = { effect = s.timed_effect, duration = s.timed_duration }
	end
	return b
end

-- Scene recall.action: active | dynamic_palette | static.
-- Smart scene recall.action: activate | deactivate.
function _M.recall(action, duration, brightness)
	local recall = { action = action or "active" }
	if duration ~= nil then recall.duration = duration end
	if brightness ~= nil then recall.dimming = { brightness = brightness } end
	return { recall = recall }
end

-- p = item PUT, c = collection POST, d = item DELETE. Item GET is always there.
-- Verbs follow the OpenHue CLIP v2 spec (openhue/openhue-api).
local resources = {
	"light p", "scene pcd", "smart_scene pcd", "room pcd", "zone pcd",
	"bridge_home", "grouped_light p", "device pd", "bridge p", "device_power p",
	"motion p", "camera_motion p", "temperature p", "light_level p", "button p",
	"bell_button p", "relative_rotary p", "contact p", "tamper p",
	"grouped_motion p", "grouped_light_level p",
	"convenience_area_motion p", "security_area_motion p",
	"motion_area_candidate p", "motion_area_configuration p",
	"zigbee_connectivity p", "zgp_connectivity p", "wifi_connectivity p",
	"zigbee_device_discovery p", "homekit p", "matter p", "matter_fabric p",
	"entertainment p", "entertainment_configuration p", "speaker p",
	"behavior_script p", "behavior_instance p", "geofence_client p",
	"geolocation p", "device_software_update p", "service_group p",
}

local function pluralize(s)
	if s:sub(-1) == "y" and not s:sub(-2, -2):find("[aeiou]") then
		return s:sub(1, -2) .. "ies"
	end
	return s .. "s"
end

for _, spec in ipairs(resources) do
	local rtype, flags = spec:match("^(%S+)%s*(.*)$")
	local plural = pluralize(rtype)
	local base = "/resource/" .. rtype
	local pre = base .. "/"
	collections[plural], collections[rtype] = rtype, rtype
	hb[plural] = function(self) return self.api:get(base) end
	if flags:find("p", 1, true) then
		hb[rtype] = function(self, id, body)
			if body then return self.api:put(pre .. id, body) end
			return self.api:get(pre .. id)
		end
	else
		hb[rtype] = function(self, id) return self.api:get(pre .. id) end
	end
	if flags:find("c", 1, true) then
		hb[rtype .. "_create"] = function(self, body) return self.api:post(base, body) end
	end
	if flags:find("d", 1, true) then
		hb[rtype .. "_delete"] = function(self, id) return self.api:delete(pre .. id) end
	end
end
hb.groups_lights = hb.grouped_light -- legacy misspelled name

function hb:resources() return self.api:get("/resource") end

function hb:set(rtype, id, fields)
	local body = _M.state(fields)
	if rtype ~= "light" then body.effects, body.gradient, body.timed_effects = nil end
	return self.api:put("/resource/" .. rtype .. "/" .. id, body)
end

function hb:light_on(id, on) return self:set("light", id, { on = on }) end
function hb:light_brightness(id, level) return self:set("light", id, { brightness = level }) end
function hb:light_effect(id, effect) return self:set("light", id, { effect = effect }) end
function hb:light_color(id, x, y) return self:set("light", id, { xy = { x = x, y = y } }) end
-- t <= 500 is mirek (153-500). A larger t is kelvin.
function hb:light_temperature(id, t)
	if t > 500 then return self:set("light", id, { kelvin = t }) end
	return self:set("light", id, { mirek = t })
end
function hb:identify(rtype, id)
	return self.api:put("/resource/" .. rtype .. "/" .. id, { identify = { action = "identify" } })
end

local function bind(resource, bridge)
	setmetatable(resource, _M.meta.hr)
	link[resource] = bridge
	return resource
end

function hrm:label()
	return self.metadata and self.metadata.name
end

function hrm:ref()
	local b, o = link[self], self.owner
	if not (b and type(o) == "table" and o.rid) then return nil end
	return b:get(o.rid, o.rtype)
end

function hrm:update(body)
	local b = link[self]
	if not b then return nil, "unbound resource" end
	return b.api:put("/resource/" .. self.type .. "/" .. self.id, body)
end

function hrm:apply(fields)
	if self.type ~= "light" and self.type ~= "grouped_light" then return nil, "not a light" end
	local b = link[self]
	if not b then return nil, "unbound resource" end
	return b:set(self.type, self.id, fields)
end

function hrm:turn(on) return self:apply({ on = on }) end

function hrm:activate(action, duration, brightness)
	if self.type ~= "scene" and self.type ~= "smart_scene" then return nil, "not a scene" end
	if not action then action = self.type == "smart_scene" and "activate" or "active" end
	return self:update(_M.recall(action, duration, brightness))
end

function hrm:stream(action)
	if self.type ~= "entertainment_configuration" then return nil, "not an entertainment configuration" end
	return self:update({ action = action or "start" })
end

function hrm:remove()
	local b = link[self]
	local fn = b and b[self.type .. "_delete"]
	if not fn then return nil, "not deletable" end
	return fn(b, self.id)
end

local function index_by_id(bridge, rows)
	local tbl = {}
	for _, r in pairs(rows or {}) do
		if type(r) == "table" and r.id then tbl[r.id] = bind(r, bridge) end
	end
	return tbl
end

-- walk()     : every resource, cached as self.data[type][id]
-- walk(name) : collection ("lights") or type ("light"); refreshes that bucket
-- On failure: nil, err, code, errors
function hb:walk(name)
	if name then
		local rtype = collections[name]
		if not rtype then return nil, "unknown collection: " .. tostring(name) end
		local res, err, code, errs = check(self.api:get("/resource/" .. rtype))
		if not res then return nil, err, code, errs end
		local tbl = index_by_id(self, res.data)
		self.data[rtype] = tbl
		return tbl
	end
	local res, err, code, errs = check(self:resources())
	if not res then return nil, err, code, errs end
	local tbl = setmetatable({}, data_mt)
	for _, r in pairs(res.data or {}) do
		if type(r) == "table" and r.type and r.id then
			local g = tbl[r.type]
			if not g then g = {}; tbl[r.type] = g end
			g[r.id] = bind(r, self)
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
