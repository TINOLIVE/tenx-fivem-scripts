# Naija Elevator Creator (v2)

An in-game elevator builder. Create elevators live from a NUI dashboard — name floors,
capture their positions by standing there, set access, allow vehicles — all saved to SQL.

## Install
1. Import `tenx-elevators.sql` in HeidiSQL (creates `tenx_elevators`).
2. Drop `aec` in resources, `ensure aec` after ox_lib / oxmysql / ox_inventory / qb-core.
3. Your license is already in `Config.AdminIdentifiers`. `/myid` prints identifiers if needed.

## Build an elevator
- `/elevadmin` opens the dashboard (admins only).
- Create Elevator → **Basic** (name, allow-vehicles) → **Floors** (name each floor, stand where the
  doors go and hit **Set position**) → **Access** → **Review** → **Save**.
- Elevators appear instantly for everyone (no restart). Edit/Delete/Go from the Elevators tab.

## Using an elevator (players)
- Walk to a floor → floating **[E] <Elevator> - <Floor>** text → press **E** → pick a floor.
- **Vehicles:** if the elevator allows vehicles and you're driving, your car rides with you.

## Access (per elevator)
- Public, or Restricted by: jobs (any), **card items (holding ANY ONE)**, or a passcode.
- Passcode is only asked if the player has no matching job/card.

## Feel
- Travel screen with a moving light strip + progress shine.
- Arrival plays a synthesized **gbam** (mechanical thud) + ding. No sound files needed.

Notes: Map View & Maintenance tabs from the inspiration aren't included in this build — the core
(create/list/edit/access/vehicles/travel) is. Those can be layered on later.
