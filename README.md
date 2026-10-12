# lua-hue-v2

Philips Hue **CLIP API v2** client for Lua 5.1–5.4 and LuaJIT, built on
[lua-jsonreq](https://github.com/SamOrlando/lua-jsonreq) (>= 0.1.0).

## Install

```sh
luarocks make rockspecs/lua-hue-v2-0.1.0-1.rockspec
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
```

## `hue.new(opt)` (or `hue.new(host)`)

| field | default | meaning |
|---|---|---|
| `host` | required | bridge IP/hostname (optionally `:port`) |
| `key` | – | application key (`hue-application-key`) |
| `clientkey` | – | stored for reference |
| `devicetype` | `lua-hue-v2#<HOSTNAME>` | sent by `register()`; Hue limits `app#device` to 20#19 chars |
| `timeout` | 30 s (`jsonreq.TIMEOUT`) | request timeout for every call |
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
* Raw API calls return jsonreq results (`body, code, headers, raw` or `nil, err`):
  `resources()`, and for each resource type a collection getter plus `x(id)` (GET) / `x(id, tbl)` (PUT):

| collection | single | extras |
|---|---|---|
| `lights` | `light` | `light_on(id, bool)`, `light_brightness(id, 0-100)`, `light_effect(id, name)` |
| `scenes` | `scene` | `scene_create(tbl)`, `scene_delete(id)` |
| `rooms` | `room` | `room_create`, `room_delete` |
| `zones` | `zone` | `zone_create`, `zone_delete` |
| `grouped_lights` | `grouped_light` (alias `groups_lights`) | |
| `devices` | `device` | `device_delete` |
| `bridge_homes` | `bridge_home(id)` (read only) | |
| `bridges`, `device_powers`, `motions`, `camera_motions`, `temperatures`, `light_levels`, `buttons` | singular forms | |

* `hue.check(body, code)` → `body, code` or `nil, err, code, errors` (turns a Hue `errors` array or HTTP >= 400 into an error)

## Tests

```sh
lua tests/test.lua
```

Uses a fake bridge transport; no hardware needed.

## License

MIT

## Related projects

- [lua-jsonreq](https://github.com/SamOrlando/lua-jsonreq) — JSON-over-HTTP request helper (dependency of this library)
