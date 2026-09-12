Config = {}

-- account charged for everything
Config.Account = 'bank'

-- medic prices
Config.ReviveCost = 500
Config.HealCost   = 200

-- ambulance job events fired AFTER the server takes payment
Config.ReviveEvent = 'ak47_qb_ambulancejob:revive'
Config.HealEvent   = 'ak47_qb_ambulancejob:skellyfix'

-- peds (model + vector4 location)
Config.MedicPed  = { model = 's_m_m_doctor_01',   coords = vector4(1775.47, 2551.93, 45.56, 91.76) }
Config.WeaponPed = { model = 'u_m_y_prisoner_01', coords = vector4(1752.88, 2566.77, 45.56, 225.8) }

-- weapon shop stock
Config.Weapons = {
    weapon_knife = { label = 'Knife', price = 5000 },
    -- weapon_pistol = { label = 'Pistol', price = 25000 },
}
