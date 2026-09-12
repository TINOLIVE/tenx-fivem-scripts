# tenx-zones

The zone authority for NAIJA 2046. It owns every boundary shape, the
shell you see, and the rule about whether players can walk through it.
`tenx-arena` and `tenx-redzone` stop owning zones and ask
this instead.

---

## Install

1. Drop `tenx-zones` in your resources folder.
2. `ensure tenx-zones` in server.cfg, **before** arena and redzone.
3. Nothing. Your license and Duel's are already in `Config.Admins`.

To add anyone else, they run `/zonesid` in game and you paste the
`license:` line it prints. Use `license:` — it is stable, and unlike
`steam:` it does not depend on the player being on Steam or on a
Discord resource running. `ip:` identifiers are ignored even if pasted
in, because an address is not an identity.

ACE still works as a fallback if you prefer it, and both can be on at
once:

```
add_ace group.admin tenx.zones allow
```

Set `Config.UseAce = false` to make the identifier list the only way in.

The table builds itself on first start. `sql/tenx_zones.sql` is only
there if you want to import it by hand.

Requires `oxmysql`. Nothing else.

---

## Using the creator

`/zones` opens the panel. Not allowed without the ACE — and the check
runs on the server, so a leaked NUI gets nowhere.

Pick **Dome** or **Walls**. You stay **on foot** — drawing no longer
forces noclip on you.

| Key | Does |
|---|---|
| W A S D | move |
| Space / Ctrl | up and down |
| Shift | boost |
| 1 | cycle speed |
| Scroll | size the dome |
| E | drop the dome centre / mark a corner |
| R | undo last corner |
| F2 | toggle noclip |
| Enter | done, name it |
| Esc | cancel |

A new dome **follows you** until you press E. Walk to the middle, press
E to drop it, then scroll to size it. Press E again to pick it back up.

For a dome that is not centred at ground level — a rooftop, or one over
a multi-storey building — **Space and Ctrl move the centre height as a
number**, not your ped. Hold Shift to move it faster. The readout shows
the offset. Because your ped never leaves the ground, there is no
landing afterwards and nothing to fall through.

F2 still gives you noclip if a large zone needs it. It is opt-in now.
Drawing used to enable it for you, and every fall through the map was
the exit transition out of a state you had not asked to be in.

Walls need at least 3 corners. Floor and ceiling are set from the
ground under the corners you marked — floor a few metres below the
lowest one so nobody clips out under a slope, ceiling well above the
highest. Both are editable in the panel afterwards.

If the cursor ever locks: `/zonesunstick`.

---

## Wiring arena and redzone in

A zone is a shape. It does nothing until you bind it to somebody.
That is deliberate — an unbound zone can't wall in a random player
standing on those coords in the city.

**Starting a match:**

```lua
exports['tenx-zones']:BindZoneToBucket(zoneId, bucket)
```

**Ending it:**

```lua
exports['tenx-zones']:ReleaseZone(zoneId)
```

**Moving someone between buckets** — call this straight after, so the
boundary applies immediately instead of on the next sweep:

```lua
exports['tenx-zones']:RefreshPlayer(src)
```

### Full server export list

| Export | Returns |
|---|---|
| `GetZone(id)` | a copy of the zone, or nil |
| `GetZones()` | all zones keyed by id |
| `ZoneExists(id)` | bool |
| `IsPointInZone(id, coords)` | bool |
| `IsPlayerInZone(src, id)` | bool |
| `GetZoneDepth(id, coords)` | metres; positive inside, negative outside |
| `ValidateSpawn(id, coords, clearance)` | ok, reason |
| `ClampToZone(id, coords, margin)` | vector3 nudged inside |
| `BindZoneToBucket(id, bucket)` | bool |
| `UnbindZoneFromBucket(id, bucket)` | bool |
| `BindZoneToPlayers(id, {src,...})` | bool |
| `UnbindZoneFromPlayers(id, {src,...})` | bool |
| `ReleaseZone(id)` | drops every binding |
| `RefreshPlayer(src)` | re-resolve after a bucket move |
| `GetPlayersInZone(id)` | array of sources actually inside |
| `SetZoneSolid(id, bool)` | flip pass-through at runtime |
| `SetZoneVisible(id, bool)` | show/hide shell without changing blocking |
| `CreateZone(zone)` | id, error |

### Client exports and events

```lua
exports['tenx-zones']:IsInZone(id)      -- bool
exports['tenx-zones']:GetMyZones()      -- array of ids
exports['tenx-zones']:GetZoneDepth(id)  -- metres

AddEventHandler('tenx-zones:entered', function(id, zone) end)
AddEventHandler('tenx-zones:left',    function(id, zone) end)
```

---

## Spawn validation

This is the thing arena gains that it did not have. Before saving a
spawn point, check it:

```lua
local ok, why = exports['tenx-zones']:ValidateSpawn(zoneId, coords, 5.0)
if not ok then
    print('bad spawn: ' .. why)   -- "spawn is 12.4m outside the zone"
end
```

Without this you can save a spawn just outside the boundary, and the
player gets dropped in and instantly shoved back. Looks like a bug,
isn't one.

If you would rather auto-fix than reject:

```lua
coords = exports['tenx-zones']:ClampToZone(zoneId, coords, 5.0)
```

---

## Importing your existing arena polygons

Your saved arena zones are already polygons, so they come straight
across. Run once, server side:

```lua
for _, old in pairs(yourExistingArenaZones) do
    local id = exports['tenx-zones']:CreateZone({
        name   = old.name,
        kind   = 'poly',
        points = old.points,        -- { {x=,y=}, ... }
        minZ   = old.minZ or 0.0,
        maxZ   = old.maxZ or 100.0,
        solid  = true,
    })
    print(old.name, id)
end
```

Then delete arena's own clamp. **Do not leave both running** — two
scripts clamping the same player fight each other and the player
jitters at the edge.

---

## The numbers you might want to change

All in `config.lua`.

- `Config.Tick.nearDistance` / `nearDistanceVeh` — how close to the
  edge before the fast tick starts. Vehicles get a wider band because
  they cover ground faster.
- `Config.Render.fadeStart` / `fadeEnd` — where the shell fades out as
  you move away from the wall. Raise `fadeStart` to see the dome from
  deeper inside, at a frame cost.
- `Config.Boundary.margin` — how far back inside the edge a blocked
  player is placed.
- `Config.Security.sweepTolerance` — how far outside a solid zone the
  server tolerates before calling it a violation. Must stay well above
  `Config.Boundary.margin` or normal clamping trips it.
- `Config.Security.onViolation` — hook your anticheat here.

---

## Known limits, stated plainly

- **There is no real collision.** FiveM cannot make an invisible wall
  out of an arbitrary shape. This clamps position. On foot it is
  seamless. In a car at speed you hit the edge and stop dead, because
  the alternative is the engine grinding into the wall and vibrating.
- **A true sphere shrinks on hills.** You chose 3D, so a player high on
  a slope near the edge is closer to the top of the dome than the
  middle and will be blocked earlier than the ground outline suggests.
  This is correct behaviour, not a bug — the shell you see is the shell
  that is enforced.
- **Bindings do not survive a restart.** On purpose. A stale binding
  would wall players into a match that no longer exists.


---

## v2 — integration notes for arena and redzone

### Wrapping a client-side teleport

`SuspendLocal` runs on the client, where the clamp runs, so it takes
effect on the same frame. It also reports the claim to the server, which
is what stops the backstop sweep force-correcting a player mid-teleport
during a long collision load.

```lua
local function safeTeleport(x, y, z, heading)
    exports['tenx-zones']:SuspendLocal('arena:teleport')
    -- ...your existing body, unchanged...
    exports['tenx-zones']:ResumeLocal('arena:teleport')
end
```

Claims are named and nest. Two overlapping teleports do not release each
other; enforcement returns when the last one drops.

Do not use `TeleportPlayer` from arena — it is for server-side callers
with no sequence of their own.

### Arm-on-entry

```lua
exports['tenx-zones']:BindZoneToBucket(zoneId, bucket, { armOnEntry = true })
```

Passable until that player first walks in, solid from then on. Leaving
under a claim disarms, so the Red Zone death loop works with no extra
call: down -> `SuspendZone(src, 'redzone:down')` -> teleport outside ->
`ResumeZone` -> they walk back in.

### Re-binding after a restart

```lua
AddEventHandler('tenx-zones:server:ready', function(version, zoneIds) end)
```

Not guaranteed on a cold boot — it fires before consumers exist. Also
reconcile with `GetBindings()` on your own start.

### Deciding money

Query at the moment of payout rather than tracking membership off events:

```lua
if exports['tenx-zones']:IsPlayerInZone(killerSrc, zoneId) then ... end
```

Synchronous, never nil for a live player.

### Spawn validation, both directions

```lua
exports['tenx-zones']:ValidateSpawn(id, coords, 5.0, 'inside')   -- arena
exports['tenx-zones']:ValidateSpawn(id, coords, 25.0, 'outside') -- redzone entry
```

Returns `ok, why, depth`. For `'outside'`, `why` is `inside_zone` or
`too_far`.

### Migration

```lua
exports['tenx-zones']:CreateZone({
    name = a.name, kind = 'poly',
    points = a.bounds.points, minZ = a.bounds.minZ, maxZ = a.bounds.maxZ,
    solid = true,
    importKey = 'tenx:arena:' .. id,
})
```

Idempotent on `importKey` — re-running converges instead of duplicating.
Not keyed on name, so two zones may share a display name and a rename
never merges shapes.

### Startup check

```lua
local ok, list = pcall(function() return exports['tenx-zones']:GetExports() end)
```

`ReleaseZone` is included in that list even though it was absent from the
frozen contract you sent — your integration guide calls it on every match
end, so a check that omits it would miss a real dependency.


---

## Tags — how the Red Zone picker finds its zones

`/zones` holds everything: the arena polygons and the Red Zone spheres.
Tags are how a consumer asks for only its own.

```lua
exports['tenx-zones']:CreateZone({ ..., tags = { 'redzone' } })
exports['tenx-zones']:SetZoneTags(zoneId, { 'redzone' })

exports['tenx-zones']:GetZonesByTag('redzone')  --> { 12, 17 }
exports['tenx-zones']:GetZoneTags(zoneId)       --> { 'redzone' }
exports['tenx-zones']:ZoneHasTag(zoneId, 'redzone')
```

Tags are lowercased and trimmed, commas are not allowed inside one, and
lookup is case insensitive.

Adding a new Red Zone is then: draw a sphere, mark it passable, tag it
`redzone`. It appears in the next `/rz` with no config edit and no
restart.

## Zone ids are stable and never reused

Confirmed, and it needed a change to make it true.

`id` is `AUTO_INCREMENT`, and AUTO_INCREMENT is **not** stable across a
restart on MariaDB, which is what most FiveM servers run — the counter is
recomputed as `MAX(id)+1` at startup. Deleting the highest numbered zone
and restarting would hand that id straight to the next zone created, and
anything keyed on it elsewhere (Red Zone spawn points, an arena's
`zoneId`) would silently re-point at a different shape somewhere else on
the map.

So deletes are **soft**. The row stays with `deleted = 1`, is skipped at
load, and `MAX(id)` stays monotonic — the id can never be handed out
again. Its `import_key` is released so a re-import is not blocked.

You can safely key your own tables on zone id.

To actually purge retired rows, do it deliberately and never while the
server is live:

```sql
SELECT * FROM tenx_zones WHERE deleted = 1;   -- look first
```

## Passable zones cost less

A zone that cannot block anyone never escalates the client to a
frame-rate tick, and never enters the server sweep. Binding six passable
domes to one standing bucket costs a 500ms loop and nothing else.


---

## Console commands

```
/zones              open the builder
/zonesid            print your own identifiers
/zoneaudit          list every zone: id, name, kind, import key, tags
/zonetag <id> <t>   add a tag        e.g. zonetag 12 redzone
/zoneuntag <id> <t> remove a tag
```

`/zoneaudit` also lists retired ids, so you can see at a glance that
none has been reissued.

## Verifying a stored zone id still points at the right shape

The arena zones were imported before deletes became soft. In that window
a delete could free an id, and a later zone could take it — leaving an
arena pointing at a different shape with no error anywhere.

To check a stored mapping:

```lua
local ok, why, actualId =
    exports['tenx-zones']:VerifyZoneMapping(storedZoneId, 'tenx:arena:' .. arenaId)

-- ok      -> the id still holds the shape you imported
-- why     -> "zone 3 is \"WeedRamps\" (tenx:arena:3), expected tenx:arena:5"
-- actualId-> the id that DOES hold that key, so the fix is a field update
```

Or look one up directly:

```lua
exports['tenx-zones']:GetZoneByImportKey('tenx:arena:5')  --> 5
```

A zone drawn by hand in `/zones` has no import key and is reported as
such rather than as a mismatch.

## Noclip in the builder

Exiting noclip used to re-enable collision and release the freeze
*before* looking for the ground, and did nothing at all when the ground
probe failed — which is why people fell through the map.

Now the exit holds you frozen and non-colliding until it has confirmed
ground: it requests collision and waits for it to stream, probes from
several heights rather than only your own, and places you before
releasing anything. If it still cannot find ground it puts you back into
noclip and says so, rather than dropping you.

"Fly here" also requests collision at the destination on arrival, so the
next exit has something to probe against.


---

## Auto tags

A tag decides which script picks a zone up, and tagging as a separate
step afterwards is a step that gets forgotten. So the shape seeds it:

```lua
Config.AutoTags = {
    sphere = { 'redzone' },
    poly   = { 'arena' },
}
```

Draw a dome and it arrives at the save form already tagged `redzone`.

It is a **default, not a rule**. The tag shows as a chip in the form
before you commit — click it to remove, or type another and press
Enter. So a sphere that is not a Red Zone is still possible, it just
is not the assumption.

Set either list to `{}` to turn it off for that shape.

**Reshaping keeps the zone's existing tags** rather than re-seeding,
so editing a zone you deliberately tagged something else does not
quietly put the default back.

**Zones created through the `CreateZone` export are not touched** —
the arena migration and anything else scripted pass their own tags and
get exactly those.

Tags coming from the panel are user input, so the server cleans them
before storage: lowercased, trimmed, commas and symbols stripped (a
comma is the storage separator), 24 characters each, 8 per zone,
deduplicated.

Each row in `/zones` also shows the zone's id as a `#9` badge, so the
number the console commands want is never a hunt.


## Fade

The shell gets lighter as you move deeper into a zone, so a big dome is
not filling every pixel while you stand in the middle of it. That
overdraw is the real frame cost of any zone script.

It used to fade to **nothing** at a flat 90 metres deep, and that was
wrong twice over. The number was absolute, so a 180m dome vanished
exactly at its own centre -- because its centre is 90m deep. And fading
to zero means the zone you are standing in becomes invisible, which is
the opposite of useful.

Now it scales to each zone and never reaches zero:

```lua
Config.Render.fadeStartFrac = 0.5     -- full strength until this deep in
Config.Render.fadeFloor     = 0.35    -- never lighter than this inside
```

Full strength out to half the zone's own size, then easing down to the
floor at its deepest point. A 40m dome and a 300m dome both behave the
same way relative to themselves.

For walls, "size" is the distance from the interior point to the
nearest edge, not the bounding radius -- otherwise a long thin arena
would think it was much deeper than it is and dim too early.

Raise `fadeFloor` to 1.0 to turn fading off entirely and always draw at
full strength, at a frame cost inside large zones.
