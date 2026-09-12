# tenx-prison

Two prison peds: a medic who sells revives and heals, and a prisoner who sells
weapons.

> **Early work.** Kept here as-is.

---

## Requirements

- `qb-core`
- `ox_lib`
- `ox_target`
- `ox_inventory`

Revives are handed off to an ambulance job via configurable event names.

---

## Install

1. Drop the folder into your `resources`.
2. `ensure tenx-prison` in `server.cfg`.
3. Adjust prices, ped coordinates and weapon stock in `config.lua`.

---

## Configuration

```lua
Config.Account     = 'bank'   -- account charged for everything
Config.ReviveCost  = 500
Config.HealCost    = 200
```

Ped placement uses `vector4` (x, y, z, heading):

```lua
Config.MedicPed  = { model = 's_m_m_doctor_01',   coords = vector4(1775.47, 2551.93, 45.56, 91.76) }
Config.WeaponPed = { model = 'u_m_y_prisoner_01', coords = vector4(1752.88, 2566.77, 45.56, 225.8) }
```

Weapon stock is a table of `weapon_hash = { label, price }`. Anything commented
out is not purchasable.

---

## Payment ordering

The ambulance events fire **after** the server has taken payment, not before:

```lua
Config.ReviveEvent = 'ak47_qb_ambulancejob:revive'
Config.HealEvent   = 'ak47_qb_ambulancejob:skellyfix'
```

The client never triggers those events directly — it asks the server, the server
checks the balance, charges, and only then revives. A player who cannot pay does
not get healed, and a spoofed client event does not skip the charge.
