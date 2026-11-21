# lua-hue-v2

Philips Hue **CLIP API v2** client for Lua 5.1–5.4 and LuaJIT, built on
[lua-jsonreq](https://github.com/SamOrlando/lua-jsonreq) (>= 0.1.0).

## Install

```sh
luarocks make rockspecs/lua-hue-v2-0.2.0-1.rockspec
```

## Quick start

```lua
local hue = require("hue-v2")
local b = hue.new({ host = "192.168.1.20", key = os.getenv("HUE_KEY") })

-- first time: press the bridge link button, then
if not b.key then
  local ok, code, key, clientkey = b:register()   -- key is returned, never printed
  if not ok then error("register failed: " .. tostring(code) .. " " .. tostring(key)) end
  -- store `key` (and `clientkey` for entertainment streaming) somewhere safe
end

local data, err = b:walk()          -- all resources, cached in b.data[type][id]
if not data then error(err) end
for id, light in pairs(b.data.light or {}) do print(id, light.metadata and light.metadata.name) end

b:light_on("<light id>", true)
b:light_brightness("<light id>", 40)
b:light_color("<light id>", hue.xy(255, 180, 40))
b:light_temperature("<light id>", 2700)          -- kelvin above 500; 153-500 is mirek
b:scene("<scene id>", hue.recall("active"))
```

Examples below assume `hue` and `b` from the quick start. Names such as `id`, `light_id`, and `room_id` stand for ids you already have. A raw call returns a
[lua-jsonreq](https://github.com/SamOrlando/lua-jsonreq) result: `body, code, headers, raw`, or
`nil, err`. `walk` and `hue.check` turn a Hue `errors` array or an HTTP status >= 400 into
`nil, err, code, errors`.

`GET /eventstream/clip/v2` is the bridge event stream. This client does not keep that connection open.
`b.api:get("/eventstream/clip/v2")` is a normal request, not a stream.

## Module variables

These live on the table returned by `require("hue-v2")`.

| name | what it is |
|---|---|
| `hue._VERSION` | `"lua-hue-v2 0.2.0"` |
| `hue._DESCRIPTION` | one-line description of the module |
| `hue._COPYRIGHT` | copyright string stored on the module |
| `hue.meta.hb` | metatable of every bridge from `hue.new`. `__index` is `hue.meta.hb.methods` |
| `hue.meta.hr` | metatable of every resource stored by `walk`. `__index` is `hue.meta.hr.methods` |
| `hue.collections` | name → CLIP type. Both `"lights"` and `"light"` map to `"light"`. `walk` and `get` use this table, and it is the source of the `b.data.lights` alias |
| `hue.gamut` | triangles for gamut `"A"`, `"B"`, and `"C"`. Each is `{ red, green, blue }`, and each point is `{ x, y }` from the CLIP color spec. `"other"` is not a triangle |

```lua
print(hue._VERSION)
print(hue.collections.relative_rotaries)   -- "relative_rotary"
print(hue.gamut.C[1][1], hue.gamut.C[1][2]) -- red point of gamut C
print(getmetatable(b) == hue.meta.hb)
```

`hue.collections` is the live table the module uses. Replacing a key changes `walk`, `get`, and the `b.data` alias for that name.

## Bridge fields

`hue.new` returns one bridge table.

| field | meaning |
|---|---|
| `b.api` | jsonreq client for `https://<host>/clip/v2`. Resource calls go through this |
| `b.base` | jsonreq client for `https://<host>`. `register()` posts to `/api` on this client |
| `b.key` | application key. At construction, a non-nil key is copied to `b.api.headers["hue-application-key"]` |
| `b.clientkey` | entertainment client key, stored only. Streaming does not use it |
| `b.devicetype` | `app#device` string sent by `register()`. Default is `lua-hue-v2#` plus up to 19 characters of `HOSTNAME` or `COMPUTERNAME`, or `lua` |
| `b.enabled` | the boolean passed into both clients when the bridge was built. Writing `b.enabled` later does not change those clients |
| `b.data` | cache filled by `walk`. Shape is `data[type][id] = resource`. A plural key reads the type key: `data.lights` is `data.light`. `pairs(b.data)` does not yield the plural aliases |

```lua
print(b.api.headers["hue-application-key"])
print(b.devicetype)
local same = b.data.lights == b.data.light   -- true after walk()
```

Assigning `b.key = "..."` does not update the header. Call `b:register(key)` for that.

**TLS:** the bridge uses a self-signed certificate. Requests use luasec's default
`verify = "none"`, so the certificate is not verified (no MITM protection on the LAN).

## `hue.new(opt)` or `hue.new(host)`

| field | default | meaning |
|---|---|---|
| `host` | required | bridge IP or hostname, optionally `:port` |
| `key` | none | application key |
| `clientkey` | none | stored for reference |
| `devicetype` | `lua-hue-v2#<host>` | sent by `register()`. Hue limits the two halves to 20 and 19 characters |
| `timeout` | 30 seconds | request timeout. `0` is treated as missing and becomes 30 |
| `enabled` | `true` | `false` makes every call return `nil, "disabled"` |
| `transport` | luasocket/luasec | function used by tests and proxies |

A missing or empty host raises `"lua-hue-v2: host required"`.

```lua
local b = hue.new("192.168.1.20")
local b2 = hue.new({
  host = "192.168.1.20",
  key = os.getenv("HUE_KEY"),
  timeout = 5,
  devicetype = "lua-hue-v2#kitchen",
})
```

## `hue.check(body, code)`

Normalizes one jsonreq result.

- `nil` and a numeric code → `nil, "HTTP <code>", code`
- `nil` and a string → `nil, that string`
- a body whose `errors[1]` is set → `nil, descriptions joined by "; ", code, errors`
- a numeric code >= 400 → `nil, "HTTP <code>", code`
- otherwise → `body, code`

```lua
local body, err, code, errs = hue.check(b:lights())
if not body then print(err, code) end
```

## `hue.xy(r, g, b)`

sRGB to CIE xy (D65). Each channel is `0`–`1` or `0`–`255` (`> 1` is treated as 8-bit). Returns `x, y`. Black returns `0, 0`.

```lua
local x, y = hue.xy(255, 180, 40)
```

## `hue.rgb(x, y [, Y])`

CIE xy plus relative luminance `Y` (default `1`) to sRGB channels in `0`–`1`. `y == 0` returns `0, 0, 0`. Values outside `0`–`1` are clipped.

```lua
local r, g, bch = hue.rgb(0.4, 0.4, 1)
```

## `hue.mirek(kelvin)`

`floor(1e6 / kelvin + 0.5)`, clamped to the CLIP range 153–500. 153 is about 6500 K. 500 is 2000 K.

```lua
print(hue.mirek(2700))    -- 370
print(hue.mirek(1000))    -- 500
```

## `hue.kelvin(mirek)`

`floor(1e6 / mirek + 0.5)`. This does not clamp.

```lua
print(hue.kelvin(370))    -- 2703
```

## `hue.clamp(x, y, gamut)`

Projects xy into a Hue triangle. `gamut` is `"A"`, `"B"`, `"C"`, or a three-point table of the same shape as `hue.gamut.C`. A point already inside is returned unchanged. An unknown gamut returns `nil, "unknown gamut"`.

```lua
local lamp = b:get(light_id, "light")
local gamut = lamp.color and lamp.color.gamut_type
if gamut ~= "A" and gamut ~= "B" and gamut ~= "C" then gamut = "C" end
-- A nested call keeps only its first return, so split xy and clamp.
local x0, y0 = hue.xy(255, 140, 40)
local x, y = hue.clamp(x0, y0, gamut)
b:light_color(lamp.id, x, y)
```

## `hue.state(fields)`

Builds a light or grouped-light PUT body. Omitted fields are left out, so the bridge keeps its current value. `brightness` may be `0`. `mirek` wins over `kelvin`.

| field | body |
|---|---|
| `on` | `{ on = { on = bool } }` |
| `brightness` | `{ dimming = { brightness = n } }` with `n` in 0–100 |
| `mirek` or `kelvin` | `{ color_temperature = { mirek = n } }` |
| `xy` | `{ color = { xy = { x, y } } }` |
| `effect` | `{ effects = { effect = name } }` |
| `alert` | `{ alert = { action = name } }` |
| `duration` | `{ dynamics = { duration = ms } }` |
| `gradient` | `{ gradient = { points = gradient } }` |
| `timed_effect`, `timed_duration` | `{ timed_effects = { effect, duration } }` |

Effect names include `candle`, `fire`, `prism`, `sparkle`, `opal`, `glisten`, `underwater`, `cosmos`, `sunbeam`, `enchant`, and `no_effect`. Timed effects are `sunrise`, `sunset`, and `no_effect`. `b:set` drops `effects`, `gradient`, and `timed_effects` unless the type is `"light"`.

```lua
local body = hue.state({
  on = true,
  brightness = 40,
  kelvin = 2700,
  effect = "candle",
  duration = 400,
})
b:light(id, body)   -- raw PUT; same JSON as b:set("light", id, fields)
```

## `hue.recall(action [, duration, brightness])`

Builds `{ recall = { action, duration?, dimming? } }`. The default action is `"active"`.

Scene actions: `active`, `dynamic_palette`, `static`.
Smart-scene actions: `activate`, `deactivate`.

```lua
b:scene(scene_id, hue.recall("dynamic_palette", 1000, 30))
b:smart_scene(smart_id, hue.recall("deactivate"))
```

## `b:register(key)` and `b:register()`

`register(key)` stores a string key on `b.key` and on `b.api.headers`, then returns `true, 200`. It does not call the bridge.

`register()` with no argument presses the link-button flow: `POST /api` on `b.base` with `devicetype` and `generateclientkey = true`.

- success → `true, code, username, clientkey`, and both are saved on the bridge
- the bridge returned no body → `false, err`
- the body has no `success.username` → `false, code, description` (`description` is nil when the body has no error object)

The key is returned to the caller and is not printed.

```lua
local ok, code, key, clientkey = b:register()
if not ok then error(tostring(code) .. " " .. tostring(key)) end

b:register(os.getenv("HUE_KEY"))   -- install a key you already stored
```

## `b:resources()`

`GET /clip/v2/resource`. Returns the raw jsonreq result, not a cache update. `walk()` calls this and then `hue.check`.

```lua
local body, err = hue.check(b:resources())
print(body and #body.data)
```

## `b:walk()` and `b:walk(name)`

`walk()` loads every resource. It replaces `b.data` with `data[type][id]`. Resources without `type` and `id` are skipped. Each kept resource uses `hue.meta.hr`.

`walk(name)` reloads one type. `name` is a collection (`"lights"`) or a type (`"light"`). That bucket is replaced. Other buckets stay. An unknown name returns `nil, "unknown collection: ..."`.

On failure both forms return `nil, err, code, errors`. On success `walk()` returns `b.data`. `walk(name)` returns the one bucket, keyed by id.

```lua
local data, err, code = b:walk()
if not data then error(err) end

local lights, err2 = b:walk("lights")
for id, light in pairs(lights or {}) do print(id, light:label()) end
```

## `b:get(id [, type])`

Looks up one id in `b.data`. With a type, that bucket is tried first (`"light"` or `"lights"`). If the id is not there, every bucket is scanned. `pairs` order decides which one wins when the same id exists in more than one bucket. Returns the resource, or `nil` when the cache has no match. This does not call the bridge.

```lua
local light = b:get(id)            -- any type
local light2 = b:get(id, "light")  -- prefer the light bucket
```

## `b:set(type, id, fields)`

`PUT /resource/<type>/<id>` with `hue.state(fields)`. For any type other than `"light"`, `effects`, `gradient`, and `timed_effects` are removed before the request. Returns the raw jsonreq result.

```lua
b:set("grouped_light", grouped_id, { on = true, brightness = 40, mirek = 300 })
b:set("light", light_id, { on = false, brightness = 0, duration = 200 })
```

## `b:light_on(id, on)`

`set("light", id, { on = on })`. `on` is a boolean.

```lua
b:light_on(id, true)
b:light_on(id, false)
```

## `b:light_brightness(id, level)`

`set("light", id, { brightness = level })`. `level` is 0–100. `0` is sent. The bridge raises it to the bulb's minimum.

```lua
b:light_brightness(id, 40)
```

## `b:light_effect(id, effect)`

`set("light", id, { effect = effect })`.

```lua
b:light_effect(id, "candle")
b:light_effect(id, "no_effect")
```

## `b:light_color(id, x, y)`

`set("light", id, { xy = { x = x, y = y } })`.

```lua
local x, y = hue.xy(255, 180, 40)
b:light_color(id, x, y)
```

## `b:light_temperature(id, t)`

`t <= 500` is mirek and is sent as-is. A larger `t` is kelvin and goes through `hue.mirek`. So `250` stays 250 mirek, and `2700` becomes 370.

```lua
b:light_temperature(id, 2700)   -- kelvin
b:light_temperature(id, 370)    -- mirek
```

## `b:identify(type, id)`

`PUT` `{ identify = { action = "identify" } }` to that resource. Devices and lights use this to flash.

```lua
b:identify("device", device_id)
b:identify("light", light_id)
```

## Generated resource methods

Every CLIP type in the catalog gets the same shape. Names are the type, plus `s`. A type that ends in a consonant plus `y` uses `ies` (`relative_rotary` → `relative_rotaries`).

| call | HTTP |
|---|---|
| `b:<plural>()` | `GET /resource/<type>` |
| `b:<type>(id)` | `GET /resource/<type>/<id>` |
| `b:<type>(id, body)` | `PUT` that URL, when the row says PUT |
| `b:<type>_create(body)` | `POST /resource/<type>` |
| `b:<type>_delete(id)` | `DELETE /resource/<type>/<id>` |

`bridge_home(id, body)` ignores `body` and always GETs. `groups_lights` is `grouped_light`.

```lua
local body, code = b:buttons()
local one = b:button(button_id)
b:room(room_id, { metadata = { name = "Den" } })

local created, err = hue.check(b:zone_create({
  metadata = { name = "TV Zone", archetype = "tv" },
  children = { { rid = light_id, rtype = "light" } },
}))
if created then b:zone_delete(created.data[1].rid) end

b:device_delete(device_id)
b:groups_lights(grouped_id, { on = { on = false } })
```

`scene_create` needs `metadata`, `group` (`{ rid, rtype }`), and `actions`. Each action needs `target` (`{ rid, rtype = "light" }`) and `action`. A successful create puts the new id in `body.data[1].rid`.

```lua
local body, err = hue.check(b:scene_create({
  metadata = { name = "Movie" },
  group = { rid = room_id, rtype = "room" },
  actions = {
    {
      target = { rid = light_id, rtype = "light" },
      action = { on = { on = true }, dimming = { brightness = 15 } },
    },
  },
}))
if body then b:scene_delete(body.data[1].rid) end
```

| type | collection | item | create | delete |
|---|---|---|---|---|
| `light` | `lights` | PUT | | |
| `scene` | `scenes` | PUT | `scene_create` | `scene_delete` |
| `smart_scene` | `smart_scenes` | PUT | `smart_scene_create` | `smart_scene_delete` |
| `room` | `rooms` | PUT | `room_create` | `room_delete` |
| `zone` | `zones` | PUT | `zone_create` | `zone_delete` |
| `bridge_home` | `bridge_homes` | GET only | | |
| `grouped_light` | `grouped_lights` | PUT (`groups_lights` is the same function) | | |
| `device` | `devices` | PUT | | `device_delete` |
| `bridge` | `bridges` | PUT | | |
| `device_power` | `device_powers` | PUT | | |
| `motion` | `motions` | PUT | | |
| `camera_motion` | `camera_motions` | PUT | | |
| `temperature` | `temperatures` | PUT | | |
| `light_level` | `light_levels` | PUT | | |
| `button` | `buttons` | PUT | | |
| `bell_button` | `bell_buttons` | PUT | | |
| `relative_rotary` | `relative_rotaries` | PUT | | |
| `contact` | `contacts` | PUT | | |
| `tamper` | `tampers` | PUT | | |
| `grouped_motion` | `grouped_motions` | PUT | | |
| `grouped_light_level` | `grouped_light_levels` | PUT | | |
| `convenience_area_motion` | `convenience_area_motions` | PUT | | |
| `security_area_motion` | `security_area_motions` | PUT | | |
| `motion_area_candidate` | `motion_area_candidates` | PUT | | |
| `motion_area_configuration` | `motion_area_configurations` | PUT | | |
| `zigbee_connectivity` | `zigbee_connectivities` | PUT | | |
| `zgp_connectivity` | `zgp_connectivities` | PUT | | |
| `wifi_connectivity` | `wifi_connectivities` | PUT | | |
| `zigbee_device_discovery` | `zigbee_device_discoveries` | PUT | | |
| `homekit` | `homekits` | PUT | | |
| `matter` | `matters` | PUT | | |
| `matter_fabric` | `matter_fabrics` | PUT | | |
| `entertainment` | `entertainments` | PUT | | |
| `entertainment_configuration` | `entertainment_configurations` | PUT | | |
| `speaker` | `speakers` | PUT | | |
| `behavior_script` | `behavior_scripts` | PUT | | |
| `behavior_instance` | `behavior_instances` | PUT | | |
| `geofence_client` | `geofence_clients` | PUT | | |
| `geolocation` | `geolocations` | PUT | | |
| `device_software_update` | `device_software_updates` | PUT | | |
| `service_group` | `service_groups` | PUT | | |

A room's grouped light is a service reference, not the room id.

```lua
for _, svc in ipairs(room.services or {}) do
  if svc.rtype == "grouped_light" then
    b:grouped_light(svc.rid, hue.state({ on = true, brightness = 40 }))
  end
end
```

Current sensor reports live under `motion_report` and `temperature_report`.

```lua
for id, motion in pairs(b.data.motion or {}) do
  local report = motion.motion and motion.motion.motion_report
  if report and report.motion then print(id, "motion") end
end
for id, temp in pairs(b.data.temperature or {}) do
  local report = temp.temperature and temp.temperature.temperature_report
  print(id, report and report.temperature)   -- degrees Celsius
end
```

## Cached resource methods

`walk` sets `hue.meta.hr` on each resource and remembers which bridge it came from. The link is not a field on the resource, so a later PUT of that table does not send it. Method names are not Hue fields, so `light.on` and `light.owner` stay the values from the bridge.

Calling these on a table you built yourself returns `nil` and a short reason (`"unbound resource"`, `"not a light"`, `"not a scene"`, `"not an entertainment configuration"`, or `"not deletable"`). In the snippets, `light`, `scene`, `smart`, and `area` are objects returned by `walk` or `b:get`.

### `resource:label()`

`metadata.name`, or nil.

```lua
print(light:label())
```

### `resource:ref()`

The owner currently in `b.data`, using `owner.rid` and `owner.rtype`. Returns nil when there is no owner or the owner was not walked.

```lua
local device = light:ref()
if device then print(device:label()) end
```

### `resource:update(body)`

`PUT /resource/<type>/<id>` with the table you pass. The body is not rewritten.

```lua
light:update({ metadata = { name = "Desk lamp" } })
```

### `resource:apply(fields)`

`b:set(self.type, self.id, fields)` for a `light` or `grouped_light`. Anything else returns `nil, "not a light"`.

```lua
light:apply({ brightness = 25, kelvin = 2700, duration = 800, effect = "candle" })
```

### `resource:turn(on)`

`apply({ on = on })`.

```lua
local light = b:get(light_id, "light")
local grouped = b:get(grouped_id, "grouped_light")
light:turn(true)
grouped:turn(false)
```

### `resource:activate([action, duration, brightness])`

For a `scene` or `smart_scene`, PUTs `hue.recall(...)`. A missing action becomes `"active"` on a scene and `"activate"` on a smart scene.

```lua
scene:activate("active", 1000, 30)
smart:activate("deactivate")
scene:activate()   -- action "active"
```

### `resource:stream([action])`

For an `entertainment_configuration`, PUTs `{ action = action }`. A missing action becomes `"start"`. `"stop"` stops it.

```lua
area:stream("start")
area:stream("stop")
```

### `resource:remove()`

Calls `b:<type>_delete(id)` when that method exists (`scene`, `smart_scene`, `room`, `zone`, `device`). Other types return `nil, "not deletable"`.

```lua
scene:remove()
light:remove()   -- nil, "not deletable"
```

## Tests

```sh
lua tests/test.lua
```

Uses a fake bridge transport; no hardware needed.

## License

MIT

## Related projects

- [lua-jsonreq](https://github.com/SamOrlando/lua-jsonreq) — JSON-over-HTTP request helper (dependency of this library)
