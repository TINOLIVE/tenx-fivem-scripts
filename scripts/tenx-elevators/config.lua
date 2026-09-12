Config = {}

Config.Brand = 'NAIJA ELEVATORS'

-- Admin panel command
Config.AdminCommand = 'elevadmin'

-- Who can open the creator.
Config.AdminIdentifiers = {
    'license:PUT_YOUR_LICENSE_IDENTIFIER_HERE',
}
Config.AdminGroups = { 'admin', 'god' }

-- Interaction
Config.InteractKey  = 38    -- E
Config.DrawDistance = 8.0   -- how far the floating [E] text shows
Config.InteractDist = 2.0   -- how close to actually use it

-- Travel
Config.TravelTime    = 2500
Config.ScreenEffect  = true
Config.SkipAnimation = false
Config.DingSound     = true
Config.GbamSound     = true   -- mechanical thud when the cab lands
Config.ElevatorMusic = true   -- soft hum during travel

-- Vehicles: elevators with "allowVehicles" move the car you're driving too
Config.VehicleTravel = true
