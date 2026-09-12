# tenx-cookie

Consumable "cookie" that grants a temporary stamina, sprint, swim and armour
boost. Standalone — no framework required beyond `ox_lib`.

> **Early work.** One of the first resources I shipped. Kept here as-is.

---

## Requirements

- `ox_lib`

---

## Install

1. Drop the folder into your `resources`.
2. `ensure tenx-cookie` in `server.cfg`.
3. Register the item in your inventory and point its use handler at the
   `cookie:client:use` event.

---

## Behaviour

On use, the ped plays a pill-taking animation, then the boost applies:

- Sprint and swim multipliers raised
- Armour set
- Stamina restored, then drained on a timer

Using a second cookie while one is active refuels it rather than stacking, so
the effect cannot be compounded.

Multipliers are reset on effect end and on resource stop, so a restart mid-boost
does not leave a player permanently fast.
