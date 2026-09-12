# Blocking dispatch for arena, lobby and Red Zone players

You run three things that can page police or EMS:

| | |
|---|---|
| **ps-dispatch** | police alerts — shooting, vehicle theft, death |
| **codem-dispatch** | the same, from a second source |
| **op-ambulance-mdt** | EMS calls |

Each needs **one line**. The line is the same every time:

```lua
if exports['tenx-arena']:IsPlayerInArena(source) then return end
```

That one call now covers a match, the lobby, the Red Zone, and any mode added
later — it works off the claim a mode takes on a player, not off a list of
resource names. You do not need a different guard per mode.

Routing buckets already stop anyone *witnessing* a fight. These three get past
buckets because they fire server-side, which is why they need patching by
hand.

---

## Step 1 — find the event, do not trust a file path

Every one of these ships with a different folder layout depending on version,
so search rather than guess. From your resources folder:

```bash
grep -rn "RegisterNetEvent" ps-dispatch/server/
grep -rn "RegisterNetEvent" codem-dispatch/server/
grep -rn "SendDispatchAlert" op-ambulance-mdt/
```

You are looking for the **one server event every alert funnels through**. Guard
that and every alert type stops at once, including custom ones you add later.

---

## Step 2 — ps-dispatch

Find the notify event. Newer Project-Sloth builds:

```bash
grep -rn "server:notify" ps-dispatch/
```

Open the file it names — usually `ps-dispatch/server/main.lua` — and find:

```lua
RegisterNetEvent('ps-dispatch:server:notify', function(data)
```

Add one line as the **first thing inside**:

```lua
RegisterNetEvent('ps-dispatch:server:notify', function(data)
    if exports['tenx-arena']:IsPlayerInArena(source) then return end
    -- ... the rest of their function, untouched
```

Older forks use `dispatch:server:notify` in `server/main.lua` or
`sv_dispatch.lua`. Same line, same position.

### Optional second layer

Stops the alert being *generated* rather than dropped on arrival. The server
guard above is enough on its own; this just saves the round trip.

In `ps-dispatch/client/alerts.lua` (older: `client/main.lua`), find the
shooting loop:

```lua
if IsPedShooting(ped) and not IsPedCurrentWeaponSilenced(ped) then
```

Make it:

```lua
if IsPedShooting(ped) and not IsPedCurrentWeaponSilenced(ped)
   and not LocalPlayer.state.arenaMatch then
```

**Know what this does and does not cover.** `arenaMatch` is true only in a
MATCH. It is not the same question as `IsPlayerInArena` and it will **not**
suppress a Red Zone or lobby alert. That is fine — it is a cheap extra layer,
and the server guard is the real one. Do not rely on it alone.

---

## Step 3 — codem-dispatch

Same shape, different names. Find its entry point:

```bash
grep -rn "RegisterNetEvent.*[Aa]lert\|RegisterNetEvent.*[Dd]ispatch" codem-dispatch/server/
```

codem builds usually expose either a server event or an export:

```lua
-- if it is an event
RegisterNetEvent('codem-dispatch:server:sendAlert', function(data)
    if exports['tenx-arena']:IsPlayerInArena(source) then return end
    -- ... rest untouched

-- if it is an export, guard inside the function it points at
exports('CustomDispatch', function(data)
    local src = data and data.source or source
    if exports['tenx-arena']:IsPlayerInArena(src) then return end
    -- ... rest untouched
end)
```

**Watch `source` here.** In an export it is not always the player who caused
the alert — some builds pass the player inside `data`. Print it once before
you trust it:

```lua
print('codem alert from', source, data and data.source)
```

Fire a shot in a Red Zone, read the console, then guard whichever one is the
real player id. A guard reading the wrong id silences either nothing or
everything, and both look like it working until someone tests properly.

---

## Step 4 — op-ambulance-mdt

Their own integration docs show alerts arriving on a **server event**:

```lua
TriggerServerEvent('op-ambulancemdt:SendDispatchAlert',
    'ambulance', 'Alert 911', 'description', 'red', 'fa-solid fa-truck-medical', coords)
```

Note the resource name has **no hyphen** between ambulance and mdt.

Find where they register it:

```bash
grep -rn "SendDispatchAlert" op-ambulance-mdt/
```

Guard it the same way:

```lua
RegisterNetEvent('op-ambulancemdt:SendDispatchAlert', function(...)
    if exports['tenx-arena']:IsPlayerInArena(source) then return end
    -- ... rest untouched
```

### The ambulance script matters more here

`op-ambulance-mdt` is a *tablet* — it displays calls. Something else raises
them. On your server that is `ak47_qb_ambulancejob` firing on death regardless
of bucket.

If EMS calls still come through after guarding the MDT, the alert is being
raised somewhere upstream. Look for whatever handles
`ak47_qb_ambulancejob:onPlayerDeath` or `:onPlayerDown` and put the same line
there.

`ak47_qb_ambulancejob` is escrowed and cannot be patched — but the thing that
*listens* to it and raises the alert usually can.

---

## Step 5 — check it worked

Do all five. Step 5 is the one people skip and it is the one that matters.

1. Someone on police **and** someone on EMS duty, both **outside** the arena
2. Start a match. Fire a full magazine. **Nothing on their dispatch**
3. Die in the match. **No EMS call**
4. Go to a **Red Zone**. Fire, and get killed. **Nothing on either**
5. Leave. Fire a shot in the city. **The alert appears**

Step 4 is the new one — it is what was broken until now. Step 5 proves the
guard is not matching too broadly. A guard that silences dispatch for
everybody is worse than no guard, because nobody notices until a real robbery
goes unanswered.

---

## Why it cannot be done from inside the arena

FiveM has no way to unregister or cancel another resource's event handler.
Anything claiming to relies on handler execution order, which is not
guaranteed and breaks silently on an update.

One line in their file is honest about what it is, takes ten seconds to
re-apply, and you can see at a glance that it is still there.

**Write down that you did this.** All three will overwrite it on update.

---

## The export

```lua
exports['tenx-arena']:IsPlayerInArena(src)   --> boolean
exports['tenx-arena']:GetArenaPlayers()      --> { [src] = true }
```

`IsPlayerInArena` returns true for:

| | |
|---|---|
| a match | occupant list, or the `arenaMatch` statebag for the moment before it catches up |
| the lobby | nothing should fire there, but a downed-player alert would |
| the Red Zone | or any other mode running on top of the arena |

`GetArenaPlayers` answers from the same rule, so if you would rather filter a
recipient list than drop the alert, the two cannot disagree.
