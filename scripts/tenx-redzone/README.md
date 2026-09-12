# NAIJA 2046 — Red Zone

Always-on free-for-all. Pick a zone, get dropped just outside it with
everything you own, walk in.

This is its own resource. It talks to `tenx-arena` rather than duplicating
it, in both directions.

---

## Install

1. **Update `tenx-arena` first.** This resource needs the exports that
   ship with it — an older arena has none of them, and the Red Zone refuses to
   start rather than half-working.
2. Run `tenx-redzone.sql`
3. `ensure tenx-redzone` **after** the arena
4. Mark spawns: `/rzspawn list`, then `/rzspawn add <zone id>` standing where
   you want players to appear
5. Players use `/rz`

If the arena is out of date you'll get one clear block in the console listing
exactly which exports are missing, rather than a broken feature at a time.

---

## How the two resources fit together

**Neither owns the other.** Each asks, and each copes when the answer doesn't
come — a stopped resource means a feature quietly does nothing rather than an
error every frame.

### What the Red Zone asks the arena for

| | |
|---|---|
| `getKey` | the player's licence, by the arena's rules |
| `getArenas` | the marked shapes — no marking anything twice |
| `getInventory` `addItem` `removeItem` `countItem` | what they carry |
| `getCoins` `giveCoins` `takeCoins` | coins, spent in the arena's shop |
| `syncToPlayer` `syncFromPlayer` | arm them going in, save on the way out |
| `isBusy` | don't drag someone out of a match |
| `returnToCity` | leave the way the arena expects |
| `isStaff` | one set of permission rules, not two |
| `registerBoard` | put this leaderboard on the arena's walls |

### What the arena asks the Red Zone for

| | |
|---|---|
| `getLeaderboard` | rows for the wall board |
| `getZones` `playersInZone` | the control panel's live view |

Plus `getStats`, `isInZone`, `removePlayer` and `getSpawns` for anything else
you build.

---

## Who owns what

**The arena owns everything a player has.** Inventories, coins, item
definitions, the arena shapes. A rifle bought in the shop is the same rifle in
here, and a coin earned in here spends in the same shop — because there's one
copy of each, not two that drift apart.

**This resource owns the mode.** Who's in which zone, kills, streaks, drops,
its own leaderboard, and its own spawn points.

Spawn points are deliberately here rather than in the arena: the arena owns the
*shape*, but where somebody stands when they walk into it is this mode's
business. Asking the arena to store settings for a mode it knows nothing about
is how two resources end up tangled.

---

## The wall board

On startup this registers **the name of an export**, not a function — a
function passed between resources doesn't arrive as something the other side
can call:

```lua
exports['tenx-arena']:registerBoard('redzone', {
    resource = GetCurrentResourceName(),
    export   = 'getBoardRows',
    label    = 'NAIJA 2046 RED ZONE',
})
```

`/rzboard redzone <name>` then shows this leaderboard on a wall the arena
draws. The arena calls `getBoardRows` when it needs the data.

The arena has no idea this mode exists — it asks whoever registered that name.
Stop this resource and the registration goes with it, so the board shows
nothing rather than erroring.

The same mechanism works for anything else you write.

---

## When it won't let you in

```
/rzcheck
```

Prints everything that decides whether you can enter — whether the arena is
running, whether your licence reads, which exports are present, what state the
arena thinks you're in, and every zone with its spawn count and whether it's
usable.

Every refusal names its actual cause rather than a generic message. Five
different failures sharing one vague line is how "nothing works" happens.

---

## Commands

```
/rz                     pick a zone
/exitred                back to the lobby

/rzspawn list           zones and their spawn counts
/rzspawn add <id>       mark where you're standing
/rzspawn clear <id>     remove a zone's spawns

/rzcheck                why won't it let me in
```

A zone with **no spawns is not offered at all** — better than computing a point
that knows nothing about what's actually there and dropping somebody on a roof.

---

## Config

`Config.RZ` — buckets, respawn timing, spawn protection, ammo, the starter
weapon, weapon durability.

`Config.RZ.killReward` — coins per kill, points, and the weighted drop table.
`nothing` is a real entry and the likeliest one: a drop that always happens is
a payment, not a drop.

`Config.RZ.streaks` — extra at 3, 5 and 10 in a row.

`Config.RZ.board` — what the wall board is called.
