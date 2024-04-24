local _M = {
	_VERSION	 = 'lua-hue-v2 0.0.1',
	_DESCRIPTION = 'woot with a woot and maybe a heep',
	_COPYRIGHT   = 'Copyright (C) Sam Orlando 2024 - MIT Cheese Please',	
}

local rawget, rawset, setmetatable, getmetatable = rawget, rawset, setmetatable, getmetatable
local type, pair, ipair = type, pair, ipair
local concat, insert = table.concat, table.insert
local jro = require ('jsonreq').new

-- removed meta because of potential methods using global rawget, etc before localization
_M.meta = {
	hb = { -- hue bridge metatable
		methods = {},
		__index = function(self, key) return rawget(getmetatable(self), "methods")[key] or rawget(self, key) end,
	},
	hr = { -- hue resource metatable
		methods = {},
		__call = function(self, ...) end,
		__index = function(self, key) return rawget(getmetatable(self), "methods")[key] or rawget(self, key) end,
	}
}

function _M.new(opt)  -- new bridge contains all data
	opt = opt or {}
	if type(opt) == "string" then opt = {host=opt} end
	
	local tbl = {
		api = jro('https://' .. opt.host .. '/clip/v2'),
		base = jro('https://' .. opt.host),
		key = opt.key,
		enabled = opt.enabled and opt.enabled or true,
		data = {}, -- cache table of all our walks of the api
	}
	
	if tbl.key then tbl.api.headers['hue-application-key'] = tbl.key end
	
	return setmetatable(tbl, _M.meta.hb)
end

local hb = _M.meta.hb.methods
function hb:register(key)
	if key and type(key) == "string" then
		self.key = key
		self.api.headers['hue-application-key'] = self.key
		return true, 200
	end

	local res, code = self.base:post('/api', {devicetype='app_name#instance_name', generateclientkey=true})
	if not res then return false, code end
	if res[1] and res[1].success then
		self.key = res[1].success.username
		print("NEW KEY: " .. self.key)
		self.api.headers['hue-application-key'] = self.key
		return true, code
	end
	return false, code
end

local hrm = _M.meta.hr -- speed local var for hue resource metatable
function hb:walk(name) -- walk one resource group in
	if name then
		local tbl, func = {}, self[name]
		if not func then return end
		for _,r in pairs(func(self).data) do
			tbl[r.id] = setmetatable(r, hrm)
		end
		self.data[name] = tbl
		return tbl
	else
		local tbl, rtype, rid = {}
		for _,r in pairs(self:resources().data) do
			rtype, rid = r.type, r.id
			tbl[rtype] = tbl[rtype] or {}
			tbl[rtype][rid] = setmetatable(r, hrm)
		end
		self.data = tbl
		return tbl
	end
end

function hb:get(id, device_type) -- new object / fix
	if self.data[device_type] and self.data[device_type][id] then
		return self.data[device_type][id]
	else
		for _,g in pairs(self.data) do
			for rid,r in pairs(g) do
				if rid == id then return r end
			end
		end
	end
end

-- local hr = _M.meta.hr.methods
-- function hr:name()
	-- table.cprint(self)
	-- --return self.metadata and self.metadata.name or self.owner and self.owner.bridge:get(data.owner.rid, data.owner.rtype)
-- end
-- function hr:owner() return self.data.owner and self.bridge:get(self.data.owner.rid) end


-- The following is for direct calls and results bypassing any usage of convience objects 
function hb:resources() return self.api:get('/resource') end

local fs = '/' -- field sep
local rl = '/resource/light' -- resource light
function hb:lights() return self.api:get(rl) end -- pluralization of light
function hb:light(id, tbl)
	if tbl then return self.api:put(concat({rl,fs,id}), tbl)
	else return self.api:get(concat({rl,fs,id})) end
end
-- extend custom element functions
function hb:light_on(id, state) return self.api:put(concat({rl,fs,id}), {on={on=state}}) end
function hb:light_brightness(id, level) return self.api:put(concat({rl,fs,id}), {dimming={brightness=level}}) end
function hb:light_effect(id, effect) return self.api:put(concat({rl,fs,id}), {effects={effect=effect}}) end

local rs = '/resource/scene'
function hb:scenes() return self.api:get(rs) end
function hb:scene_create(tbl) return self.api:post(rs, tbl) end
function hb:scene(id, tbl)
	if tbl then return self.api:put(concat({rs,fs,id}), tbl)
	else return self.api:get(concat({rs,fs,id})) end
end
function hb:scene_delete(id) return self.api:delete(concat({rs,fs,id})) end

local rr = '/resource/room'
function hb:rooms() return self.api:get(rr) end
function hb:room_create(tbl) return self.api:post(rr, tbl) end
function hb:room(id, tbl)
	if tbl then return self.api:put(concat({rr,fs,id}), tbl)
	else return self.api:get(concat({rr,fs,id})) end
end
function hb:room_delete(id) return self.api:delete(concat({rr,fs,id})) end

local rz = '/resource/zone'
function hb:zones() return self.api:get(rz) end
function hb:zone_create(tbl) return self.api:post(rz, tbl) end
function hb:zone(id, tbl)
	if tbl then return self.api:put(concat({rz,fs,id}), tbl)
	else return self.api:get(concat({rz,fs,id})) end
end
function hb:zone_delete(id) return self.api:delete(concat({rz,fs,id})) end

local rbh = '/resource/bridge_home'
function hb:bridge_homes() return self.api:get(rbh) end
function hb:bridge_home(id) return self.api:get(concat({rbh,fs,id})) end

local rgl = '/resource/grouped_light'
function hb:grouped_lights() return self.api:get(rgl) end
function hb:groups_lights(id, tbl)
	if tbl then return self.api:put(concat({rgl,fs,id}), tbl)
	else return self.api:get(concat({rgl,fs,id})) end
end

local rd = '/resource/device'
function hb:devices() return self.api:get(rd) end
function hb:device(id, tbl)
	if tbl then return self.api:put(concat({rd,fs,id}), tbl)
	else return self.api:get(concat({rd,fs,id})) end
end
function hb:device_delete(id) return self.api:delete(concat({rd,fs,id})) end

local rb = '/resource/bridge'
function hb:bridges() return self.api:get(rb) end
function hb:bridge(id, tbl)
	if tbl then return self.api:put(concat({rb,fs,id}), tbl)
	else return self.api:get(concat({rb,fs,id})) end
end

local rpd = '/resource/device_power'
function hb:device_powers() return self.api:get(rpd) end
function hb:device_power(id, tbl)
	if tbl then return self.api:put(concat({rpd,fs,id}), tbl)
	else return self.api:get(concat({rpd,fs,id})) end
end

local rm = '/resource/motion'
function hb:motions() return self.api:get(rm) end
function hb:motion(id, tbl)
	if tbl then return self.api:put(concat({rm,fs,id}), tbl)
	else return self.api:get(concat({rm,fs,id})) end
end

local rcm = '/resource/camera_motion'
function hb:camera_motions() return self.api:get(rcm) end
function hb:camera_motion(id, tbl)
	if tbl then return self.api:put(concat({rcm,fs,id}), tbl)
	else return self.api:get(concat({rcm,fs,id})) end
end

local rt = '/resource/temperature'
function hb:temperatures() return self.api:get(rt) end
function hb:temperature(id, tbl)
	if tbl then return self.api:put(concat({rt,fs,id}), tbl)
	else return self.api:get(concat({rt,fs,id})) end
end

local rll = '/resource/light_level'
function hb:light_levels() return self.api:get(rll) end
function hb:light_level(id, tbl)
	if tbl then return self.api:put(concat({rll,fs,id}), tbl)
	else return self.api:get(concat({rll,fs,id})) end
end

local rbu = '/resource/button'
function hb:buttons() return self.api:get(rbu) end
function hb:button(id, tbl)
	if tbl then return self.api:put(concat({rbu,fs,id}), tbl)
	else return self.api:get(concat({rbu,fs,id})) end
end

-- function mm:() return self.api:get('/resource/relative_rotary') end
-- function mm:() return self.api:get('/resource/behavior_script') end
-- function mm:() return self.api:get('/resource/behavior_instance') end
-- function mm:() return self.api:get('/resource/geofence_client') end
-- function mm:() return self.api:get('/resource/geolocation') end
-- function mm:() return self.api:get('/resource/entertainment_configuration') end
-- function mm:() return self.api:get('/resource/entertainment') end
-- function mm:() return self.api:get('/resource/homekit') end
-- function mm:() return self.api:get('/resource/matter') end
-- function mm:() return self.api:get('/resource/matter_fabric') end
-- function mm:() return self.api:get('/resource/smart_scene') end
-- function mm:() return self.api:get('/resource/contact') end
-- function mm:() return self.api:get('/resource/tamper') end
-- function mm:() return self.api:get('/resource/zigbee_connectivity') end
-- function mm:() return self.api:get('/resource/zgp_connectivity') end
-- function mm:() return self.api:get('/resource/zigbee_device_discovery') end

return _M
