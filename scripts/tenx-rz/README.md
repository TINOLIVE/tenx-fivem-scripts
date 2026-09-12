# tenx-rz

NAIJA 2046 Red Zone. Admin-run arena rounds for QBCore + ox_inventory,
driven entirely from an in-game panel.

Sweeps every inventory inside a live zone, hands out one weapon, and returns
everything on end — including to players who died, disconnected, wandered off,
or were online through a server crash.

---

## Install

1. Drop the `tenx-rz` folder into your resources.
2. Run **`tenx-rz.sql`** against your database. This is not optional — the DB is
   what makes the restore survive a crash.
3. Add `ensure tenx-rz` to your `server.cfg`, **after** `ox_inventory` and `qb-core`.
4. Start the server, join, and run **`/ffawhoami`**. It prints your license
   identifier. Paste it into `Config.Staff` in `config.lua` and restart the resource.
5. Confirm `Config.Item` is the weapon you actually want handed out.

---

## Commands

| Command | What it does |
|---|---|
| `/ffastart [radius]` | Starts the event centred on where you're standing. Defaults to 150m. Shows a head count and asks you to confirm first. |
| `/ffaend` | Ends it. Revives everyone, returns every inventory. |
| `/ffastatus` | Shows whether an event is live and how many inventories are currently held. |
| `/ffarestore <id>` | Failsafe. Restores one specific player immediately, event running or not. |
| `/ffarecover [id]` | Opens the recovery stash, in the unlikely event something wouldn't fit on restore. |
| `/ffatestshrink [radius] [speed]` | **Dry run.** Draws the ring and closes it at compressed timings so you can watch it work. Nobody is swept, no loot, no damage, no eliminations. Speed defaults to 5x. |
| `/ffateststop` | Cancels a preview. |
| `/ffawhoami` | Prints your license identifier for the config. |

---


## Signing up

Players walk to the sign-up ped, press E, and carry on with whatever they were
doing. They can be anywhere in the city. When you start a round, everyone in
the queue is swept and dropped into the arena from wherever they stand.

`Config.Queue.warning` gives them a few seconds of notice first, because being
yanked out of a scene with no warning is jarring. Set it to 0 to pull them
instantly.

The queue empties itself when a round starts, so nobody is pulled twice and
they can sign up again for the next one. Anyone still owed an inventory from a
previous round is refused entry — that's the same guard that prevents double
confiscation.

The old lobby-radius method still works and is off by default. Turn
`Config.Lobby.enabled` back on to use both.

---

## Nobody lands in the sea

**Water is checked automatically.** Before any player, supply pile or airdrop
is placed, a client probes that exact spot for both ground height and water
level. If the ground sits under the waterline, the point is thrown away and
another is tried. Every coastline and lake on the map is covered without you
marking a thing.

**No-spawn areas** handle everything water detection can't — a runway, a cliff
face, an interior. Open Setup, stand where you want the area centred, set a
radius, and press "Mark where I'm standing". No typing coordinates.

The search tries `Config.NoSpawn.attempts` times for a point that is inside the
ring, on dry land, outside your marked areas, and spaced away from other
players. Spacing is the first thing dropped when the arena gets crowded; dry
land is the last. If it genuinely can't find anything clean it uses the best it
saw and says so in the console, rather than stalling the round.

The same "Mark where I'm standing" button fills in the lobby and holding-area
coordinates, so those never need typing either.

---

## Loadout and ground loot

**Loadout** is what everyone gets on being swept in — `Config.Loadout`. Currently
the rifle, 5 cookies and a firstaid. Add or remove lines freely; just keep
`Config.PrimaryWeapon` pointing at whichever weapon should get infinite ammo.

**Ground loot** scatters piles around the arena floor. Each line in
`Config.Loot.items` reads as "*this many piles, each holding this many*":

```lua
{ name = 'WEAPON_COMBATPISTOL', count = 1,   piles = 5  },  -- 5 pistols
{ name = 'ammo-9',              count = 200, piles = 10 },  -- 10 piles of 200
```

**Piles are script state, not ox_inventory drops.** Nothing physical is created
in the world. Each pile draws a **flat circle on the ground sized exactly to
`Config.Loot.collectDistance`** — what you see is the pickup area — plus a cone
above it so it's findable from a distance. Stand in the circle, press E, and the
server hands the items straight to your inventory.

That's what makes the cleanup airtight. Ending a round is just clearing a
table — there is no drop entity that could survive the event, get missed by a
cleanup pass, and leak free pistols into your economy.

**Everyone can see the piles, including staff who were never swept in.** Only
*collecting* is restricted. Press E while not in the round and you're told why,
rather than nothing happening.

**Taken piles vanish immediately** — circle, cone, prompt and blip all go, for
everyone, the moment the server hands the items over.

Collection is server authoritative. The client only ever says *which* pile it
wants; the server checks the pile still exists, that you're actually next to
it, and that you're in the round. The pile is claimed before the items are
handed over, so two players pressing E on the same pile at the same moment
can't both get it — the second one finds nothing. If your inventory is full,
the pile is put back rather than deleted.

If `Config.Loot.respawn` is on, a smaller batch drops every
`respawnInterval` seconds — always inside the **current** ring, so late-round
loot never lands somewhere lethal.

---

## Airdrop

150 seconds into the round — roughly halfway — a crate lands at a random spot
inside the **current** ring, so it never drops somewhere the zone has already
made lethal.

It's marked with a **big red box** standing on the ground, visible from 400m
across the arena, plus a flashing red blip that shows on the map from anywhere.
Everyone in the round gets a centre-screen `AIRDROP INCOMING` and a notification
telling them how far away it is. The whole lobby converges on one point.

Contents are in `Config.Airdrop.items` — currently the DuelX, 20 cookies and
10 firstaid. Pickup radius is wider than a normal pile since it's a crate.

For multiple drops per round, make `spawnAfter` a table:

```lua
spawnAfter = { 90, 210 },  -- two crates
```

> **Check the weapon name.** `WEAPON_DUELX` has to match the item name in your
> ox_inventory `weapons.lua` exactly, case included. It's a custom weapon so I
> can't verify it from here — if the airdrop lands and gives you cookies and
> firstaid but no gun, that's the name being wrong.

Loot piles and airdrops are the same underlying thing: a position and a list of
items. The crate just holds more and draws differently. If your inventory is
full when you open it, whatever fits goes in and the rest **stays in the crate**
rather than being deleted.

---


## What players see

Everything on screen during a round is a real interface element rendered by
the NUI layer, not text drawn onto the game. It never takes focus, so it can't
block input or eat a keypress.

**The banner drops down from the top centre.** Zone closing, final close, round
starting, eliminated, airdrop incoming, round over — each one has its own accent
colour and a countdown bar for anything timed. It slides in, holds, and retracts.

**The alive counter and kill feed** sit under it, centred. The counter turns red
at three players left. Kill lines fade in, fade out, and show a kill count next
to anyone on a streak.

**The winner card** appears when a round ends, naming who took it and with how
many kills.

---

## The zone

Built the way Call of Duty actually does it, which is not what a plain
shrinking circle does.

**The circle moves.** Each new safe zone is a smaller circle at a *new*
position inside the current one, not concentric with it. This is the whole
game: a circle that always shrinks toward the same point means nobody ever has
to leave the middle. Rotating is the decision players are making.

**You can see it coming.** Each phase has two parts, same as Warzone. First a
**wait**: the next circle is announced, drawn on your map as a white ring, and
nothing moves — that's your window to decide when to rotate. Then the **close**:
the ring travels to its new centre and shrinks at the same time.

`Config.Shrink.drift` controls how far it's allowed to wander. `1.0` means
anywhere it still fits inside the current circle; `0.0` gives you the old
concentric behaviour.

**One number still drives the timing.** `totalDuration` is the whole close.
Everything else is derived, and it's editable in the panel under
**Setup → The zone timer** with a phase editor that shows what your numbers
actually produce.

### Damage

Warzone's gas is a flat 8.5 a second for the entire match — about **12 seconds**
to die — and it makes no difference how deep into it you are. Ours escalates
instead, as you asked, but calibrated around that number so the mid-game feels
like the real thing:

| Phase | Shrinks to | Damage/sec | Kills in |
|---|---|---|---|
| 1 | 72% | 2 | 50s |
| 2 | 52% | 4 | 25s |
| 3 | 36% | 6 | 17s |
| 4 | 22% | 8.5 | 12s ← Warzone |
| 5 | 11% | 12 | 8s |
| 6 | 4% | 18 | 5.5s |
| 7 | 0% | 25 | 4s |

Whatever phase the ring is **currently** in is what everyone outside takes,
wherever they're standing. Retreating to where a gentler ring used to be buys
nothing.

**It closes to nothing.** The last phase is `radius = 0.00` — the ring shuts
completely and every square metre goes lethal, which forces an ending without a
timer deciding it.

> Two bugs fixed here. Fractional damage was being thrown away every tick, so a
> phase set to 0.5 subtracted literally nothing — and the readout used `%.0f`,
> which printed 0.5 as **"0 health a second"**. Damage now accumulates across
> ticks and the readout shows one decimal.

---

## Death and elimination

Die in the arena and you're **out for the round**. Rather than leaving you face
down on the floor for ten minutes, the script revives you, clears your skelly
damage, heals you, and moves you to `Config.Respawn.coords` — a holding area
well away from the fighting — so you've got somewhere to wait.

Where you died doesn't matter: inside the ring, outside it, killed by the ring,
killed by another player. Same path every time.

Three things protect the holding area:

- **The ring ignores eliminated players.** The holding area is outside the ring
  by design, so without this exemption everyone waiting there would be chipped
  to death and teleported back on a loop until the event ended.
- **They're disarmed on elimination** (`Config.Respawn.disarm`), so the holding
  area doesn't become its own deathmatch.
- **They're invincible while waiting** (`Config.Respawn.godmode`), for the same
  reason. Both drop the instant the event ends.

Being revived by a medic does not put you back in the round.

**Auto-end is on by default now.** Since death is a real elimination, the
last-man-standing check works, and it's the thing that stops everyone in the
holding area waiting on you to remember to type `/ffaend`. It fires
`Config.AutoEndDelay` seconds after the second-to-last player goes down.

---

## ak47_qb_ambulancejob integration

No patching required. Everything hooks through their documented triggers and
exports, so nothing in their resource is touched.

**What tenx-rz uses:**

| Their trigger / export | What it's for |
|---|---|
| `ak47_qb_ambulancejob:revive` (client) | Reviving everyone on `/ffaend` |
| `ak47_qb_ambulancejob:skellyfix` (client) | Clearing limb damage after the round |
| `ak47_qb_ambulancejob:onPlayerDeath` (server) | Tracking who's out |
| `ak47_qb_ambulancejob:onPlayerDown` (server) | Tracking who's out |
| `ak47_qb_ambulancejob:onPlayerRevive` (server) | Clearing the "out" flag |
| `IsPlayerDead(id)` export | Cross-check for last-man-standing |

The skellyfix call matters more than it sounds. ak47 tracks per-limb damage
that survives a plain revive — without it, everyone who got shot up in the
arena walks away with damaged legs and driving penalties they'd have to pay a
doctor to fix. If you'd rather keep the injuries, set
`Config.FixSkellyOnRevive = false`.

If you ever swap ambulance scripts, change `Config.AmbulanceResource` and the
trigger names rebuild themselves.

### One thing I can't do

**Players cannot be forced to stay down.** ak47_qb_ambulancejob is escrowed, so
its respawn selector can't be blocked from outside the resource. A dead player
can still choose to respawn mid-round.

In practice this matters less than it sounds, because the restore doesn't care
where anyone is:

- Die, respawn at a hospital, wander off — you're out of the fight either way,
  and you still have no inventory until the event ends.
- `/ffaend` restores you wherever you are.

If you want hard "you stay on the floor until I say so", the options are a
respawn-timer setting in ak47's own `config.lua` (worth a look — they have a
multi-stage death system, there may be something usable), or asking MenanAk47
for an export to suppress respawn. Neither is something I can bolt on from here.

---

## How the restore is guaranteed

This is the part that matters, so here's exactly what happens:

**Taking:**
1. Read the player's full slot table out of ox_inventory (names, counts, slots, metadata).
2. Write it to `tenx_rz_snapshots` as JSON and **wait for the insert to confirm**.
3. Only if that write succeeded, clear the inventory and give the weapon.

If step 2 fails for any reason, the player keeps everything and simply doesn't
join the round. Nothing is ever removed before it's safely recorded.

**Giving back:**
- `/ffaend` works off the **roster in the database**, not off who's standing in
  the zone. If the script took your stuff, the script gives it back — dead,
  alive, across the map, or logged off.
- Items go back to their **original slot with original metadata**, so weapon
  serials, attachments, ammo counts, durability and registration all survive.
- Offline players get flagged `pending` and are paid out automatically on their
  next login.
- If the resource restarts or the server crashes mid-event, every outstanding
  snapshot is found on boot and restored.
- `tenx_rz_log` keeps a permanent record of every take and return. Nothing is
  ever deleted from it, so any "I lost my stuff" claim is checkable.

**Double-confiscation is impossible.** `identifier` is the primary key on the
snapshots table, so a second sweep of the same player is rejected by the
database itself rather than overwriting their real inventory with an arena-only
one.

---

## Config quick reference

| Setting | Default | Note |
|---|---|---|
| `Config.Item` | `WEAPON_ASSAULTRIFLE` | **Placeholder — confirm this.** Must exist in `ox_inventory/data/weapons.lua`. |
| `Config.AmbulanceResource` | `ak47_qb_ambulancejob` | Used to build revive/skellyfix trigger names. |
| `Config.FixSkellyOnRevive` | `true` | Clears limb damage on revive. |
| `Config.AmmoMode` | `'infinite'` | Or `'fixed'` / `'items'`. |
| `Config.AutoEndLastManStanding` | `false` | Flip to `true` if you want it to end itself. |
| `Config.StaffImmune` | `true` | Staff can stand in the zone and spectate untouched. |
| `Config.DefaultRadius` | `150.0` | |
| `Config.MaxRadius` | `1000.0` | Typo guard. |
