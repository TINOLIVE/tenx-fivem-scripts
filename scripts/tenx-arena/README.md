# tenx-arena

NAIJA 2046 Arena. Bounded PvP arenas with team spawns, isolated routing
buckets, and an in-game zone builder.

**Stages 1 and 2 are in.** Arenas, boundaries, buckets, spawns and the builder
panel; plus the meeting zone, player panel, parties, queue, matchmaking, ready
check, map voting and the match hotbar. Live scoring, respawns and the shop are
what's left.

---

## Install

1. Drop the folder into your resources.
2. Run **`tenx-arena.sql`** against your database.
3. Add `ensure tenx-arena` to `server.cfg`.
4. Join, run **`/arenawhoami`**, paste your licence into `Config.Staff`, restart
   the resource.
5. Run **`/arena`**.

Separate from `tenx-rz` on purpose — different event namespace, different
tables, different buckets. Nothing they share can collide, and merging them
later is a merge rather than a rewrite.

## If something doesn't work

**Check the console at boot.** The resource prints two lines that answer most
problems immediately:

```
[arena] Database schema is up to date
[arena] Loaded 3 arena(s), 3 switched on
```

If the first says tables are missing, run `tenx-arena.sql`. There are
five tables now: zones, stats, matches, boards and props. The schema has
grown across updates and it's easy to miss one — a missing table shows up as a
command that silently does nothing rather than an error.

`/rz` reports its own failures now: if the menu can't be built the player is
told and the reason goes to the console, instead of the command appearing to do
nothing at all.

---

## Commands

| Command | What it does |
|---|---|
| `/arena` | Opens the builder. |
| `/arenaout` | Gets you out of an arena and back to bucket 0. Your way out if something goes wrong. |
| `/arenawhoami` | Prints your licence for the config. |
| `/rzunstick` | Releases the mouse cursor and closes every panel. Your way out if the interface ever traps you. |
| `/exitrz` | Unconditional exit. Clears every trace of arena state and puts you in the city, whether or not the server thinks you're in one. |
| `/rzbillboard` | What the leaderboard board tried to bind to. |

---

## Building an arena

> Arenas are created **switched on** and stay that way across restarts. If you
> ever see them come back off, check the console line on boot — it prints how
> many loaded and how many are on, which makes a mismatch obvious immediately.



1. **New** in the left rail.
2. **Mark the zone.** The panel steps out of the way and you walk the shape,
   pressing **E** at each point. Three or more, any shape you like — follow the
   walls of the place you're actually fighting in rather than boxing it.
3. **Enter** saves it, **Backspace** cancels. The shape draws as you walk,
   closed back to the first point, so you see what you'll get.
4. Height comes from the points you marked. The floor extends a few metres
   below so a dip in the ground doesn't put someone "outside".

Zones are polygons now, not rectangles. Anything marked as a rectangle before
is converted to a four-point polygon when it loads, so old arenas keep working
and there's one shape and one code path afterwards.
5. Stand where players should appear and **Add here** under Team A, then again
   under Team B. More than one per team stops everyone landing on the same spot.
6. **Go in as Team A** to test it. You'll be in the arena's own bucket, exactly
   as a player would be.

A spawn point outside the boundary is refused rather than silently accepted —
it would drop someone straight into the wall.

---

## Dispatch

**See DISPATCH.md for the exact patch lines.** Buckets do most of the work but
not all of it, and the gap is worth understanding.

**Routing buckets, not patches.**

Every dispatch script works the same way: a client witnesses a gunshot in the
live world and reports it. Blocking that per-script means patching each one and
redoing it every time any of them updates.

Players inside an arena are moved into their own routing bucket, where they
stop existing to everyone outside it. No client in the main world can witness
anything, so no dispatch script ever has anything to report. Nothing to patch,
nothing that breaks on someone else's update, works with ps-dispatch, cd, qs,
origen or anything else.

Three things come free with it:

- RP players never see a firefight in the middle of the city.
- Outsiders can't shoot into an arena, and arena players can't shoot out.
- **One arena hosts several matches at once.**

### One arena, several matches

Every arena has `Config.Buckets.instancesPerArena` instances, each its own
bucket. Two matches at identical coordinates in different buckets cannot see
or shoot each other, so a single good arena serves six simultaneous 1v1s
rather than five groups waiting for the space.

An arena is only "busy" when *every* instance is taken. The builder shows
`2 of 6 running` so you can see capacity at a glance.

Arena N instance I uses bucket `base + (N × instancesPerArena) + I`. With the
defaults, arena 1 occupies 4207–4212 and arena 2 occupies 4213–4218. Check that
range is clear of anything else on your server.

### What buckets don't cover

Two routes get past them, and both need one line in the resource that owns
them — see **DISPATCH.md**:

- **Self-reported alerts.** ps-dispatch checks `IsPedShooting` on the
  *shooter's own client* and reports itself. The shooter is in the bucket and
  so is the code reporting them, so the bucket is irrelevant.
- **Server-side death hooks.** Your ambulance script fires on death regardless
  of bucket, so EMS still gets paged.

Neither can be fixed from inside this resource — FiveM has no way to
unregister another resource's handler. These exports make the guard over there
a single readable line:

```lua
exports['tenx-arena']:IsPlayerInArena(src)   --> boolean
exports['tenx-arena']:GetArenaPlayers()      --> { [src] = true }
```

Kills are scoped to the instance, not the arena — otherwise two matches at the
same coordinates would score off each other.

Traffic and pedestrians are stripped from arena buckets, so a match starts
clean.

---

## Finding out where the time goes

```
/rzperf     start measuring
/rzperf     again to stop and print the table
```

Prints total milliseconds, call count and worst single call per thread, in F8.
Off by default and costs one boolean check when off.

resmon tells you the resource costs 5ms; it doesn't tell you which of forty
threads is spending it. Guessing from a list of likely suspects is how you
spend an evening optimising something that was already cheap.

---

## The boundary

**A soft wall, not a physical collider.** Your position is clamped back inside
the box every frame. Colliders snag vehicles, break whenever the map updates,
and leak entities on a resource restart — clamping does none of that and reads
identically from inside: you simply cannot get through. Outward momentum is
zeroed too, or a fast car just bounces against it repeatedly.

**It's drawn only where you're near it.** A big arena has a lot of perimeter and
none of it matters until you're close enough to run into it, so only edges
within `drawWithin` metres get drawn. The wall brightens while it's actually
holding you back. Corner posts mark the shape.

Per-arena **Hide boundary** turns the visuals off while leaving the wall itself
in force — for when you want it clean rather than obvious.

**The server double-checks.** The clamp runs client-side because it has to run
every frame. A slow server sweep catches anyone who has ended up well outside
their arena anyway — a teleport from another script, a conflict, or a client
that stopped cooperating — and puts them back.

---

## Getting out of a panel

**Escape closes whatever is open.** They close in stacking order, so the split
dialog goes before the inventory behind it, and the inventory before the panel
behind that — one press does the thing you meant rather than dismissing
everything at once.

The match-found card and the map vote are the exception: they're part of a
flow, close themselves in seconds, and dismissing them would only hide
something you need to see.

**If the interface stops responding**, which is exactly when Escape won't help,
there's a keybind the game itself owns: **Backspace**, rebindable in FiveM's
key settings. `/rzclose` does the same without a key at all.

FiveM doesn't give a resource the escape key — the pause menu owns it — which
is why the backstop is a different one.

---

## The cursor

Several things can want the mouse: the builder, the player panel, the ready
check, the map vote. Each holds a **named claim**, and the cursor is released
when the last claim drops.

The obvious approach — each overlay calling `SetNuiFocus` itself — breaks in
both directions: whichever finishes last either steals the cursor while another
still needs it, or takes it and never gives it back.

**Claims come in two kinds, and the difference is the whole design.**

**Deliberate** — the builder and the player panel. You opened them, so nothing
releases them except you. No timeout, no watchdog, no cleverness. An admin
editing an arena while a match runs elsewhere is completely normal, and must
never have the cursor pulled away mid-click.

**Transient** — the ready check and map vote. These appear on their own and are
expected to be gone within a known window. If one is still held long past that,
the flow broke and it gets dropped.

**Only transient claims can expire.** That's the safety mechanism, and it's
deliberately narrow: a watchdog that can close things you opened on purpose is
worse than no watchdog at all.

`/rzunstick` releases everything by hand if anything ever slips past.

---

## The leaderboard boards

Names shown are the **character's in-city name**, not the FiveM account name —
a leaderboard full of Steam handles reads like a different game to the one
people are playing.

Live boards ranking players by **war points** — 100 for a win, 25 for a loss,
10 a kill. They refresh the moment a match finishes.

**You usually don't need a prop.** Boards are drawn across four points you
mark, so any flat wall in the city works. The prop is only for when there's
nothing flat where you want the board.

**Looking for a big flat prop?** Guessing model names off a list and finding
out they have legs is a waste of an evening:

```
/rzprops            step through the candidates
/rzprops next       the next one
/rzprops prev       back
/rzprops <name>     check any model name you've found elsewhere
/rzprops use        send the current one to the placer
/rzprops stop       done
```

Each spawns in front of you and reports its **real dimensions** — width,
height and thickness — and says so when something is properly flat. The
shortlist is `Config.FlatProps`; add anything good you find.

**Need a surface first?** If the wall isn't flat, spawn a billboard prop and
angle it yourself:

```
/rzprop                    place prop_billboard_05
/rzprop <model>            place any prop
/rzprop list               what's placed, with ids
/rzprop delete <id>        remove one
```

**WASD** moves it relative to your camera, **Q/E** turns, **PgUp/PgDn** height,
**Z** pitch and **X** roll — those last two are the point, so you can angle the
prop to a surface that isn't square. **Shift** for coarse movement, **Enter**
to place, **Backspace** to cancel. Position and rotation are on screen as you
work.

Placed props are saved to the database and respawn on restart — and survive
re-uploading the script, which a file in the resource folder would not. Then mark the board
on the prop with `/rzboard`.

---

**You mark them yourself, and you can have as many as you like.**

```
/rzboard pvp <name>       the match leaderboard
/rzboard ranked <name>    the ranked ladder on its own
/rzboard list <name>      live queues and open rooms

/rzboard boards           what's marked, with ids and kinds
/rzboard delete <id>      remove one
/rzboard kinds            what kinds exist
/rzboard cancel           stop marking
```

The name is just a label for you — it shows in `/rzboard boards` so you can
tell which is which. Leave it off and it's numbered.

**Note `boards`, not `list`** — `list` is a board kind now, so the listing
moved rather than have a subcommand a kind could never reach.

**The boards are defined in `Config.Boards`**, not in the page. Title, footer,
accent colour, which numbers appear, their headings, their order and their
widths all come from there — so renaming a board, recolouring one, or adding a
column is a config edit rather than an edit to the HTML.

Add a new kind to that table and `/rzboard` accepts it immediately; nothing
else needs changing.

Then aim at a wall and press **right mouse** four times: top left, top right,
bottom right, bottom left. **Enter** works too.

Not E — too many servers have that on noclip or a door. `Config.Billboard.markKey`
if you want a different one; the list of codes is in the config next to it.

**If a key turns out to be claimed by something else**, `/rzmark` places a
point with no key at all. Whichever key gets picked, some server somewhere has
it bound to something that eats the press, and a command can't be stolen.

**Buildings aren't flat.** Aiming at a wall puts the point *on* the surface,
and a board flush against a ridged face disappears into the ridges. New boards
are lifted 12cm off automatically.

**To adjust one, edit it in place rather than typing metres:**

```
/rzedit              the board you're standing nearest
/rzedit <id>         a specific one
```

| | |
|---|---|
| **W A S D** | move it |
| **PgUp / PgDn** | up and down |
| **Q / E** | off the wall and back |
| **Z / X** | straighten a crooked one |
| **Mouse wheel** | size |
| **Shift** | faster |
| **Enter** | save |
| **Backspace** | throw the changes away |

You see it move as you go, with its size on screen. The edit is local until you
press Enter, so Backspace really does leave it as it was.

The one-shot commands still exist if you'd rather: `/rzboard push <id> 0.3`,
`bigger <id> 1.5`, `raise <id> 2`. `/rzboard boards` for the ids.

**Each board shows two panes at once** rather than alternating — a wall you
have to stand and wait at is a wall people walk past. `rzranked` is the
exception: one ladder, so it takes the whole board and shows ten places
instead of seven.

Colour tells you which is which from across the room: **gold** for PVP, **red**
**violet** for ranked.

You can see all three without launching the game — open
`html/billboard.html?preview=rzpvp` in a browser, and swap `rzpvp` for
`rzranked` or `info`.

**The `info` board replaced the floating text over the ped.** Text drawn in the
world scales with distance, overlaps itself and covers whatever's behind it — a
board sits flat on a wall and stays readable. It shows the queue per mode, how
many are queued, and the headline numbers: people in the lobby,
queued, live matches, open rooms.

Each board renders its own kind, so a wall showing ranked and a wall
showing what's happening now are different pages. Boards of the same kind share
one render rather than paying for two.

Aim at a wall and press **E** four times: top left, top right, bottom right,
bottom left. The corners and edges are drawn as you place them, so you can see
the shape before committing. `/rzboard cancel` backs out.

The board stretches to fit whatever four points you gave it — any size, any
angle, flat on a wall or floating. It's drawn from both sides, so it isn't
invisible from behind.

**Why not a prop.** A prop meant hunting texture names that aren't documented,
guessing a scale, and fighting the model's own orientation — and a wrong guess
gave a blank object with nothing to debug. Four points has none of that.

**Boards and placed props live in the database**, not in a file beside the
script. A file in the resource folder survives a restart perfectly well — but
it does not survive re-uploading the resource, and that folder gets replaced
every time you push an update. You'd mark boards, upload the next version, and
lose them.

Anything already in `boards.json` or `props.json` is migrated across
automatically the first time this version starts.

Only staff can mark or delete.

The page is only created while a board is in range and dropped when you walk
away — no point paying for a render nobody can see.

You can design it without launching FiveM: open `html/billboard.html?preview`
in a browser and it fills itself with sample data.

---

## Restarting the script

Routing buckets outlive the resource. Restart while someone is in the lobby and
the server forgets they're there — but the player is still sitting in bucket
2046, so asking to leave gets "you are not in the arena" while they're
visibly standing in it.

**That's handled on start.** Anyone found in one of our buckets is adopted back
into the lobby; anyone in an arena bucket for a match that no longer exists is
moved to the lobby, which is where a finished match leaves you anyway. The
console says what it did:

```
[arena] after restart: 2 recovered in the lobby, 1 moved out of dead arenas
```

**`/exitrz` is the escape hatch.** It never refuses and never checks whether we
think you're in the arena — that's the point, it works when our own state is
wrong. Clears the bucket, the statebags, any room membership, and puts you in
the city.

---

## Getting in

**One ped, three options**, and only the relevant ones ever show:

| Where you are | What it offers |
|---|---|
| The city | Enter PVP |
| The lobby | Open the PVP menu · Go to free roam |

There is only one ped because it's created client-side, which means it exists
in *every* bucket. A second ped inside the lobby was always in the wrong world
from somewhere — standing in the city you'd see it, standing in the lobby the
entry ped would offer to let you into a place you were already in.

**Entering does not open the menu.** Coming in and picking a mode are two
decisions — people want to look around, read the board, or wait for a friend
first.

**The lobby is the same physical spot, in its own routing bucket.** A crowd of
arena players waiting for a match is therefore invisible to everyone doing RP
in that street, and they can't shoot each other while they wait, because to
the city they aren't there.

Inside, a second ped opens the match panel, or `/rz` from anywhere in the
lobby. `/rzleave` steps back out to the city.

**After a match you return to the lobby, not the city.** You came to fight, so
you land where the next match starts. `returnToLobbyAfterMatch = false` to go
back to the street instead.

Both locations and the bucket are in `Config.Meeting`. The lobby bucket is
4100, well clear of the arena range that starts at 4207.

---

## Where every reward is set

One place per mode, all in `config.lua`.

| What | Where | Now |
|---|---|---|
| Casual match coins | `Config.Match.coins` | 8 a kill, 60 win, 20 loss |
| Casual war points | `Config.Match.points` | 10 a kill, 100 win, 25 loss |
| Ranked coins *(on top of casual)* | `Config.Ranked.coins` | +120 win, +40 loss |
| How far a rating moves | `Config.Ranked.kFactor` | 40 |
| Wager amounts | `Config.Wager.amounts` | 0 / 50 / 100 / 250 / 500 / 1000 |
| Coins → bank | `Config.Coins.convert` | 5:1, min 50, 5% fee |
| Shop prices | `Config.Shop.categories` | per item |

**Ranked adds to casual rather than replacing it**, so a ranked win pays
60 + 120 = 180 plus kills. Change the casual numbers and ranked moves with
them.

**Coins are spent, points are a record.** They're deliberately separate: one
is currency, the other is the leaderboard.

---

## Finding out where the time goes

```
/rzperf     start measuring
/rzperf     again to stop and print the table
```

Prints total milliseconds, call count and worst single call per thread, in F8.
Off by default and costs one boolean check when off.

resmon tells you the resource costs 5ms; it doesn't tell you which of forty
threads is spending it. Guessing from a list of likely suspects is how you
spend an evening optimising something that was already cheap.

---

## The boundary

**The wall isn't drawn.** You're clamped back inside when you reach the edge,
and a line of text tells you why — which teaches the same thing as a glowing
wall, for nothing.

Drawing it cost a few hundred `DrawPoly` calls a frame for as long as anyone
stood near an edge, on every client, to tell people something they find out
the moment they walk into it.

`Config.Boundary.wall.enabled = true` brings it back if you disagree — all the
tuning below it still works.

---

## The shop

A ped in the lobby, or `/rzshop`. Categories and prices are in `Config.Shop`.
Weapons show how many lives they have, because a cheap gun that lasts is often
better value than an expensive one that doesn't.

### Spawns

Mark them per arena in the builder — stand **outside** the zone and add a point.
Marked spawns keep their heading, so you choose which way players face.

---

---

## Playing a match

Players walk to the meeting zone ped and press **E**, or type **`/rz`** from
anywhere. Mark a meeting zone by standing where you want it and using the
admin panel.

**Modes** run 1v1 through squad 5v5. Pick the mode, the weapons and the score
limit, then queue.

### Rooms

A **room** is a lobby you control. Create one, set it up, press start. No
matchmaking to wait on — which matters on a server your size, and is also why
the dummies were unusable before: there was nothing to press.

The host picks the **mode**, the **weapons**, the **items and how many charges
of each**, **kills to win a round**, and **rounds to win the match**. Public or
private with one toggle. Public rooms show in a browser everyone can see;
private ones need the code.

**Teams are yours to arrange.** Click your own name to swap sides; the host can
move anyone. New joiners land on whichever side is lighter.

**Rounds work properly.** Best of 3 means first to 3 round wins; each round is
won by reaching the kill limit, then scores reset, everyone respawns, and the
next round starts after a short break.

**Test mode fills the room.** Add one dummy or fill every slot, then press
start — that's the whole flow testable alone.

**Parties.** Two ways in, because both happen:

- **Someone standing near you** appears in a list. One click invites them.
  This is how most invites actually happen and a code is a silly way to do it.
- **A four-character code** for anyone not next to you. Read it out on Discord.

**Invites are answered with keys, not buttons.** An invite lands while you're
walking around, so the toast can't take the cursor — buttons on it would sit
there unclickable. **Y** accepts, **N** declines, and the bar draining across
the top is the countdown. Both keys are in `Config.Party` if you'd rather use
others.

> `N` is also push-to-talk in most voice resources, so declining may key your
> mic for an instant. Harmless, but `177` (Backspace) is a clean alternative if
> it bothers you.

Party members are **never split across teams** — that's the whole reason
someone made a party. Matchmaking places the biggest groups first and fills in
around them with solos.

**The ready check** is the thing most queue systems skip. When a match forms,
everyone gets 20 seconds to accept. Nobody is teleported out of what they were
doing without agreeing to it, and if someone doesn't answer the match is called
off and the person who declined is told it was them.

**Map voting** follows. Everyone picks from the free arenas, most votes wins,
ties broken at random. An arena already hosting a match is never offered. One
free arena means no vote — there's nothing to decide.

---

## No confiscation

Arena matches **do not touch anyone's inventory**.

A battle royale has to confiscate, because looting is the game
there. An arena match is three minutes long and everyone has identical gear, so
snapshotting a full inventory to the database and restoring it slot by slot is
a great deal of machinery, and a great deal of risk, for nothing.

Instead ox_inventory is blocked for the duration, weapons are given natively,
and everything is stripped on the way out. The player's real inventory is never
touched, so there is nothing that can be lost and nothing that needs restoring.

**The hotbar** replaces the inventory during a match. Keys 1 and 2 are your
weapons, 3 and 4 are armour and a medkit with limited charges. Charges make
each one a decision rather than a button to mash. Players are held on the slot
they picked, so a dropped weapon or another script can't quietly swap what's in
their hands.

---

## Teammate nametags

Native GTA Online gamer tags over teammates: real name, real health bar, the
correct font. The natives keep the health bar current themselves, so this costs
one scan every half second rather than work every frame.

**Teammates only.** Tagging the enemy through walls isn't a nametag, it's a
wallhack.

---

## Testing alone

`Config.TestMode` fills a lobby with dummies so you can walk the entire flow by
yourself — party, queue, matchmaking, ready check, map vote, teams, spawns.

**Add a dummy** puts one in your party. **Fill the other team** queues a full
enemy side so a match actually forms. **Clear dummies** removes them all.

Be clear about what these are: they occupy slots. **They do not fight back.**
Peds that path, take cover and shoot competently are a serious AI project, not
a config option. Set `Config.TestMode.enabled = false` and every trace of it is
gone.

---

## The live match

### Rounds, not deathmatch

**A round ends when an entire team is down.** The survivors take the point,
then **everyone** respawns on full health for the next round.

In a 1v1 that means one kill ends the round and both players come back. In a
2v2, downing one opponent doesn't end anything — they're out and waiting while
their teammate fights on. Drop the second and the round is yours, and all four
respawn.

Dying puts you **out until the round resolves**, not on a five-second timer.
That's the whole point: your death costs your team the round, so it matters.
While you're down you're shown whether your team is still in it.

`Config.Match.scoring = 'kills'` switches back to straight deathmatch — every
kill is a point and you're back in a few seconds. The room's score setting
relabels itself to match, since the number means rounds in one mode and kills
in the other.

**Kill credit** still tracks per player for the leaderboard either way, and is
scoped to the match instance — two matches at the same coordinates can't score
off each other.


Killer detection unwraps vehicles (roadkill reports the *car* as the source of
death, not a ped) and retries for up to 800ms, because the killer entity isn't
always resolved the instant death fires. Miss either and kills go uncredited.

**Team kills cost you.** Rather than handing the other side a point they
didn't earn, your own team loses one. Dying to the world — the wall, a fall,
your own grenade — counts as a death for you and scores nothing for anyone.

**Respawns** put you back at one of your team's spawn points with weapons
restored and a few seconds of invincibility, so you can't be shot while the
screen is still fading in. You're held frozen and invisible while you're out,
so nothing can happen to you in between.

### Fair fights

**What this cannot do.** GTA decides a hit on the *shooter's* machine, against
a position it received milliseconds ago. That is the netcode, and no script
changes it — "I shot first" arguments come with every online shooter ever
made. Anyone promising you zero desync is selling something.

**What it does do** is remove the causes that aren't netcode, which on a
scripted arena account for more disputed kills than lag does:

**Invincibility can't leak.** There is one owner of it. Spawn protection and
the revive window declare exactly when they start and end, and a watchdog
clears invincibility twice a second at every other moment. Previously, a
thread dying mid-protection or a player leaving while protected would leave
them bulletproof for the rest of the match — which looks *exactly* like "I
headshot him and he didn't die".

**Damage is normalised.** Every player in a match is forced to the same weapon
damage and defence multipliers. A modifier left on by another resource is
invisible and silently decides fights.

**Health is reconciled.** The server reads health off the entity — the value
every other client works from — and corrects any client that has drifted more
than `healthSyncTolerance`. This is what stops "he was nearly dead on my
screen". It doesn't run while a player is down, so it can't fight the
ambulance script mid-revive.

**Aim assist off**, so controller and mouse are on the same terms.

**Unlimited stamina**, so nobody loses a fight because they ran out of breath.

All of it is in `Config.Fair` and each part can be switched off.

---

### The match inventory

A real grid you open during a match: slots, weight, drag to rearrange.

**The first slots ARE the hotbar.** Drag a rifle into slot 1 and it's on key 1.
Arranging your inventory is arranging your keys — there's no separate
"assign to hotbar" step because there doesn't need to be.

**`TAB` opens it**, and it's registered through FiveM's own keybind system, so
players rebind it in *Settings → Key Bindings → FiveM* rather than us building
a settings menu for one key. `Config.MatchInventory.key` is only the default.

**Slots and weight are both configurable** — `slots`, `columns`, `hotbarSlots`
and `maxWeight` in grams. Item weights and stack sizes are in `Config.Items`;
weapons are heavy and one-per-slot, so carrying two costs you.

**The server owns it.** The client sends "move slot 3 to slot 7" or "use slot
2" and every one of those is validated before anything moves. A modified
client can drag pixels around and change nothing real — and it can't use one
medkit ten times, because the count lives on the server.

**Nothing here touches ox_inventory.** The match inventory is built fresh at
the start and thrown away at the end, so there is nothing in it that can be
lost. Your real belongings are never involved.

Double-click to use an item. Escape or `TAB` closes it. It shuts itself at the
end of a round so nobody is stood in a menu when the next one starts.

Other resources can push items in mid-match:

```lua
exports['tenx-arena']:GiveMatchItem(source, 'medkit', 1)
```

---

### Your death system

ak47_qb_ambulancejob owns dying on this server — incapacitated screen,
bleedout timer, distress signal. All correct for RP and all completely wrong
for a 1v1.

**Nothing is done to the player at the moment of death.** They lie where they
fell. Every attempt at reviving them there failed for the same reason: the
revive landed while their death screen was still animating in, did nothing,
and the screen stayed up for the rest of the match.

**Everything happens inside the black screen instead.** That is the only
moment nothing else is competing for the player's state — their screen has
long finished, no other transition is running, and they cannot see any of it.

```
round ends
  +10s          screen fades to black
  behind it     revive fires, and keeps firing until they are actually up
  +2s           skellyfix, twice, with the natives alongside
  then          teleport to spawn, health set
                fade back in
```

`Config.Match.roundBreak` is the 10 seconds. Everything after is in
`Config.Ambulance`.

**It checks rather than hopes.** The revive fires, then polls — up to 8
attempts — until the player is genuinely up. Only then does the skellyfix run,
because a skellyfix into a revive that has not landed does nothing at all,
which is why limb damage kept surviving.

**Native resurrect as a last resort**, so nobody is ever stranded on a death
screen even if their script refuses entirely.

**It runs at four points**, so there is no way out of an arena while down:

| When | Why |
|---|---|
| Match start | Someone already down in the city when it was called |
| Every respawn | Behind the black screen, between rounds |
| Match end | Whoever lost the final round is down at that moment |
| Leaving | Forfeit, admin pull, `/arenaout`, arena switched off |

The match-end one matters more than it sounds: without it the loser is sent
back into the city on the floor, in the middle of whatever RP is happening
there. It runs while the result card is up, so there is a good ten seconds of
cover for it to land in.

**Finding out what works on your server:** die in a match, then run
`rztestrevive client`, `rztestrevive server`, `rztestrevive native` or
`rztestrevive skelly`. Each prints `down = true/false` before and after, so you
can see which one actually flips it. Set `Config.Ambulance.reviveVia` to
whichever works and drop the rest.

**On screen:** a small kill feed top left, the score in the top-centre
scoreboard with each player's slot dimming as they die, a respawn countdown,
a protection pill while you're invulnerable, and a result card at the end
showing the score and everyone's K/D.

**Stats are written per player** — wins, losses, kills, deaths, matches and
points (100 for a win, 25 for a loss, 10 a kill). That's what feeds the
leaderboard.

**Matches end** on the score limit, on `Config.Match.timeLimit`, or by
forfeit if a team empties out.

---

## Still to come

**Stage 4 — shop and clothing.** War points earned from matches, weapon
unlocks, pre-made outfits.
