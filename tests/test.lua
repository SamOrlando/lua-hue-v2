-- Plain-Lua tests for lua-hue-v2: lua tests/test.lua (from repo root). No bridge needed.
package.path = "./?.lua;" .. package.path
local hue = require("hue-v2")
local json = require("jsonreq").json
local pass, fail = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, m) if a ~= b then error((m or "") .. " expected " .. tostring(b) .. " got " .. tostring(a), 2) end end

-- fake Hue bridge transport
local function bridge(routes)
	local log = {}
	local t = function(r)
		local body = {}
		if r.source then while true do local c = r.source(); if not c then break end; body[#body + 1] = c end end
		local e = { m = r.method, url = r.url, h = r.headers, b = table.concat(body), timeout = r.timeout }
		log[#log + 1] = e
		local path = r.url:gsub("^https://[^/]+", "")
		local h = routes[r.method .. " " .. path] or routes[path]
		if not h then return 1, 404, {} end
		local code, resp = h(e)
		if code == nil then return nil, resp end
		r.sink(type(resp) == "string" and resp or json.encode(resp)); r.sink(nil)
		return 1, code, {}
	end
	return t, log
end
local RES = { data = { { id = "L1", type = "light" }, { id = "S1", type = "scene" }, { id = "R1", type = "room" } }, errors = {} }
local function ok200(v) return function() return 200, v end end
local default_routes = {
	["POST /api"] = ok200({ { success = { username = "NEWKEY", clientkey = "CK" } } }),
	["/clip/v2/resource"] = ok200(RES),
	["/clip/v2/resource/light"] = ok200({ data = { { id = "L1", type = "light" } }, errors = {} }),
	["/clip/v2/resource/scene"] = ok200({ data = { { rid = "S2", rtype = "scene" } }, errors = {} }),
}
setmetatable(default_routes, { __index = function(_, k)
	if k:find("^%u+ /clip/v2/resource/%w+/") then return ok200({ data = { { rid = "X" } }, errors = {} }) end
end })
local function mk(opt)
	local t, log = bridge(opt.routes or default_routes)
	opt.transport = t; opt.host = opt.host or "bridge.local"
	return hue.new(opt), log
end
local function hdr(e, k) for hk, v in pairs(e.h or {}) do if hk:lower() == k then return v end end end

test("new: urls, headers, enabled, devicetype", function()
	local b = mk({})
	eq(b.api.url, "https://bridge.local/clip/v2"); eq(b.base.url, "https://bridge.local")
	eq(type(b.api.headers), "table"); eq(b.enabled, true)
	assert(b.devicetype:find("^lua%-hue%-v2#")); assert(#b.devicetype <= 31)
	eq(mk({ enabled = false }).enabled, false)
	eq(hue.new("h").api.url, "https://h/clip/v2")
	assert(not pcall(hue.new, {}))
end)

test("disabled bridge sends nothing", function()
	local b, log = mk({ enabled = false })
	local r, e = b:lights(); eq(r, nil); eq(e, "disabled"); eq(#log, 0)
	r, e = b:walk(); eq(r, nil); eq(e, "disabled")
end)

test("key via opt and register(key)", function()
	local b, log = mk({ key = "K0" })
	b:lights(); eq(hdr(log[#log], "hue-application-key"), "K0")
	local ok, code = b:register("K1"); eq(ok, true); eq(code, 200)
	b:lights(); eq(hdr(log[#log], "hue-application-key"), "K1")
end)

test("register() post path returns key + clientkey, no print", function()
	local b, log = mk({ devicetype = "app#dev" })
	local oldprint = print; local printed = false; print = function() printed = true end
	local ok, code, key, ck = b:register()
	print = oldprint
	eq(ok, true); eq(code, 200); eq(key, "NEWKEY"); eq(ck, "CK"); eq(b.clientkey, "CK"); eq(printed, false)
	local sent = json.decode(log[#log].b); eq(sent.devicetype, "app#dev"); eq(sent.generateclientkey, true)
	eq(hdr(log[#log], "hue-application-key"), nil)
	b:lights(); eq(hdr(log[#log], "hue-application-key"), "NEWKEY")
end)

test("register() link button not pressed", function()
	local b = mk({ routes = { ["POST /api"] = ok200({ { error = { type = 101, description = "link button not pressed" } } }) } })
	local ok, code, desc = b:register(); eq(ok, false); eq(code, 200); eq(desc, "link button not pressed"); eq(b.key, nil)
end)

test("walk() caches by type with legacy plural alias", function()
	local b = mk({ key = "K" })
	local all = assert(b:walk())
	assert(all.light.L1 and all.scene.S1 and all.room.R1)
	eq(b.data.lights, b.data.light)
	eq(getmetatable(all.light.L1), hue.meta.hr)
	local n = 0; for _ in pairs(b.data) do n = n + 1 end; eq(n, 3)
end)

test("walk(name) consistent keys, restricted names", function()
	local b = mk({ key = "K" })
	local l = assert(b:walk("lights")); assert(l.L1); eq(b.data.light, l); eq(b.data.lights, l)
	assert(b:walk("light").L1)
	local r, e = b:walk("scene_delete"); eq(r, nil); assert(e:find("unknown"))
	r, e = b:walk("nope"); eq(r, nil)
end)

test("walk errors returned, not thrown", function()
	local b = mk({ routes = {
		["/clip/v2/resource"] = function() return 403, { data = {}, errors = { { description = "unauthorized user" } } } end,
		["/clip/v2/resource/light"] = function() return nil, "connection refused" end,
		["/clip/v2/resource/scene"] = function() return 503, "" end,
	} })
	local r, e, code, errs = b:walk(); eq(r, nil); eq(e, "unauthorized user"); eq(code, 403); eq(errs[1].description, "unauthorized user")
	r, e = b:walk("lights"); eq(r, nil); eq(e, "connection refused")
	r, e, code = b:walk("scenes"); eq(r, nil); eq(e, "HTTP 503"); eq(code, 503)
end)

test("get() by type, legacy plural type, or scan", function()
	local b = mk({ key = "K" }); b:walk()
	eq(b:get("L1", "light"), b.data.light.L1); eq(b:get("L1", "lights"), b.data.light.L1)
	eq(b:get("S1"), b.data.scene.S1); eq(b:get("zz"), nil)
end)

test("resource methods: verbs and paths", function()
	local b, log = mk({ key = "K" })
	local function last() return log[#log] end
	local r = b:lights(); eq(r.data[1].id, "L1")
	b:light_on("L1", true); eq(last().m, "PUT"); assert(last().url:find("/resource/light/L1$")); eq(json.decode(last().b).on.on, true)
	b:light_brightness("L1", 50); eq(json.decode(last().b).dimming.brightness, 50)
	b:light_effect("L1", "candle"); eq(json.decode(last().b).effects.effect, "candle")
	b:scene_create({ type = "scene" }); eq(last().m, "POST"); assert(last().url:find("/resource/scene$"))
	b:scene_delete("S1"); eq(last().m, "DELETE"); assert(last().url:find("/resource/scene/S1$"))
	b:light("L1"); eq(last().m, "GET")
	b:light("L1", { on = { on = false } }); eq(last().m, "PUT")
	b:grouped_light("G1", { on = { on = true } }); eq(last().m, "PUT"); assert(last().url:find("/resource/grouped_light/G1$"))
	eq(b.groups_lights, b.grouped_light)
	b:bridge_home("BH"); eq(last().m, "GET")
	for _, m in ipairs({ "resources", "lights", "scenes", "rooms", "zones", "bridge_homes", "grouped_lights", "devices",
		"bridges", "device_powers", "motions", "camera_motions", "temperatures", "light_levels", "buttons",
		"light", "scene", "room", "zone", "bridge_home", "groups_lights", "device", "bridge", "device_power", "motion",
		"camera_motion", "temperature", "light_level", "button", "scene_create", "scene_delete", "room_create",
		"room_delete", "zone_create", "zone_delete", "device_delete", "light_on", "light_brightness", "light_effect" }) do
		eq(type(b[m]), "function", m)
	end
end)

test("timeout passed through", function()
	local b, log = mk({ timeout = 4, key = "K" })
	b:lights(); eq(log[#log].timeout, 4)
	b:register(); eq(log[#log].timeout, 4)
	local d, dl = mk({}); d:lights(); eq(dl[#dl].timeout, 30)
end)

test("check() helper", function()
	eq(select(2, hue.check(nil, "x")), "x")
	eq(hue.check({ data = {} }, 200).data[1], nil)
end)

test("no globals leaked", function()
	for _, k in ipairs({ "hb", "hrm", "jro", "resources", "collections", "check" }) do eq(rawget(_G, k), nil, k) end
end)

print(string.format("%s (%s): %d passed, %d failed", _VERSION, jit and jit.version or "PUC", pass, fail))
os.exit(fail == 0 and 0 or 1)
