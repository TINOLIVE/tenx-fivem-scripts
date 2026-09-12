# tenx-plates-textures

Runtime licence-plate texture replacement for NAIJA 2046. One plate image per
Nigerian state, mapped onto the game's native `vehshare` plate slots.

> **This resource is one half of a pair.** It supplies the *images*.
> [`tenx-plates`](../tenx-plates) supplies the *logic* — prefixes, blocklist,
> police plate changes, DB cascade. Install both, or neither.

---

## How it works

GTA ships six plate texture slots on the shared `vehshare` texture dictionary
(`plate01`–`plate05`, `yankton_plate`). Each slot corresponds to a plate
**index**. This resource:

1. Creates a runtime TXD.
2. Opens a DUI pointed at each PNG in this folder.
3. Waits for the DUI to render, grabs its surface, and turns it into a runtime
   texture.
4. Calls `AddReplaceTexture('vehshare', slot, txd, tex)` so every vehicle using
   that plate index shows the state image.

No server side, no database, no per-frame work — it runs once on resource start
and then costs nothing.

---

## Install

1. Drop the folder into your `resources`.
2. `ensure tenx-plates-textures` in `server.cfg`.
3. Install [`tenx-plates`](../tenx-plates) as well.

---

## Keeping the two in sync

The `index` values in `client.lua` **must** match the `plateIndex` values in
`Config.States` in `tenx-plates/config.lua`. If they drift, a car gets a Lagos
prefix with a Kwara texture.

```lua
local PLATES = {
    { file = 'lagos.png', slot = 'plate01', index = 1, w = 1024, h = 512 },
    { file = 'benin.png', slot = 'plate02', index = 2, w = 1024, h = 512 },
    { file = 'abuja.png', slot = 'plate03', index = 3, w = 1024, h = 512 },
    { file = 'kwara.png', slot = 'plate04', index = 4, w = 1024, h = 512 },
    { file = 'ogun.png',  slot = 'plate05', index = 5, w = 1024, h = 512 },
}
```

---

## Adding a state

1. Drop a 1024×512 PNG in this folder.
2. Add it to `files { }` in `fxmanifest.lua` — the DUI cannot load it otherwise.
3. Add a row to `PLATES` using a free slot.
4. Add the matching state to `Config.States` in `tenx-plates` with the same
   `plateIndex`.

---

## Troubleshooting

**A state shows on the wrong car** — its `slot` and the game's index mapping
disagree. Swap the `slot` value with another entry.

**Plates are blank or black** — the DUI hadn't finished rendering when the
surface was grabbed. Increase the `Wait(1500)` in `client.lua`.

**Nothing changes at all** — confirm the folder name matches the `nui://` path.
The resource derives it with `GetCurrentResourceName()`, so renaming the folder
is safe, but a stale cached texture is not; restart the client fully.
