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

## `hue.new(opt)` (or `hue.new(host)`)

| field | default | meaning |
|---|---|---|
| `host` | required | bridge IP/hostname (optionally `:port`) |
| `key` | – | application key (`hue-application-key`) |
| `clientkey` | – | stored for reference |
| `devicetype` | `lua-hue-v2#<HOSTNAME>` | sent by `register()`; Hue limits `app#device` to 20#19 chars |
| `timeout` | 30 s | request timeout for every call |
| `enabled` | `true` | `false` makes every call return `nil, "disabled"` |
| `transport` | luasocket/luasec | custom request function (tests, proxies) |

**TLS:** the bridge uses a self-signed certificate. Requests use luasec's default
`verify = "none"`, so the certificate is not verified (no MITM protection on the LAN).

## Methods

* `register(key)` → `true, 200` (set key) — `register()` → `true, code, key, clientkey` or `false, code, description`
* `walk()` → `data` (`data[type][id]`) — `walk(name)` → `data[type]`, `name` is a collection getter
  (`"lights"`) or a type (`"light"`). Failures return `nil, err, code, errors`.
  `b.data.lights` still works as an alias of `b.data.light`.
* `get(id [, type])` → cached resource
* `hue.state(fields)` builds a light or grouped_light PUT body from `on`, `brightness` (0–100),
  `mirek` or `kelvin`, `xy` (`{x, y}`), `effect`, `alert`, `duration` (ms), `gradient`, `timed_effect`.
  `b:set(type, id, fields)` sends it. Effects, gradient, and timed effects are sent only for `light`.
* `hue.recall(action [, duration, brightness])` builds a scene or smart-scene recall body.
  Scene actions are `active`, `dynamic_palette`, `static`. Smart-scene actions are `activate`, `deactivate`.
* `hue.xy(r, g, b)` / `hue.rgb(x, y [, Y])` convert sRGB and CIE xy. Channels are 0–1 or 0–255.
  `hue.mirek(kelvin)` / `hue.kelvin(mirek)` clamp to the CLIP range 153–500.
  `hue.clamp(x, y, gamut)` projects xy into gamut `"A"`, `"B"`, or `"C"`.
* `b:light_on(id, bool)`, `b:light_brightness(id, 0-100)`, `b:light_effect(id, name)`,
  `b:light_color(id, x, y)`, `b:light_temperature(id, t)` (`t <= 500` is mirek, otherwise kelvin),
  `b:identify(type, id)`.
* After `walk`, a cached resource has `label()`, `ref()` (owner in the cache), `update(body)`,
  `remove()`, and, by type, `turn(bool)` / `apply(fields)`, `activate(...)`, `stream(action)`.
  Method names stay off Hue fields such as `on` and `owner`, so those values remain readable.
* Raw calls return jsonreq results (`body, code, headers, raw` or `nil, err`).
  Plural getters (`lights`, `smart_scenes`, `relative_rotaries`, …) and `type(id)` / `type(id, body)`
  cover the OpenHue CLIP v2 catalog. `scene`, `smart_scene`, `room`, and `zone` also have `_create`
  and `_delete`. `device` has `_delete`. `bridge_home` is read only. `grouped_light` is also `groups_lights`.
* `hue.check(body, code)` → `body, code` or `nil, err, code, errors` (turns a Hue `errors` array or HTTP >= 400 into an error)

`GET /eventstream/clip/v2` is the bridge event stream. This client does not keep that connection open.

## Tests

```sh
lua tests/test.lua
```

Uses a fake bridge transport; no hardware needed.

## License

MIT

## Related projects

- [lua-jsonreq](https://github.com/SamOrlando/lua-jsonreq) — JSON-over-HTTP request helper (dependency of this library)
