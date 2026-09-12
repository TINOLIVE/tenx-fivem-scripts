-- =====================================================================
--  tenx-plates | client: whole-city Nigerian plates on AI traffic
--  Cosmetic + local only. Never touches the database.
--  Only AMBIENT (randomly spawned) NPC vehicles are touched — never
--  owned, script-spawned, mission, or player-occupied vehicles.
-- =====================================================================
if not Config.Traffic.enabled then return end

local handled = {}
local ownedFlag = Config.Traffic.ownedStateFlag

-- GTA population types that mean "ambient NPC traffic" (safe to re-plate).
-- Owned/script cars are PERMANENT(6) or MISSION(7) and never appear here,
-- so they're excluded automatically even after a garage releases them.
local AMBIENT_POP = {
    [2] = true,  -- RANDOM_PARKED
    [3] = true,  -- RANDOM_PATROL
    [4] = true,  -- RANDOM_SCENARIO
    [5] = true,  -- RANDOM_AMBIENT
}

-- Any player in ANY seat (covers a player who jacked an NPC car).
local function hasPlayerOccupant(veh)
    for seat = -1, GetVehicleMaxNumberOfPassengers(veh) - 1 do
        local ped = GetPedInVehicleSeat(veh, seat)
        if ped ~= 0 and IsPedAPlayer(ped) then return true end
    end
    return false
end

-- Owned = statebag flag (if your garage sets one) OR a script/mission entity.
local function isOwned(veh)
    if ownedFlag then
        local st = Entity(veh).state
        if st and st[ownedFlag] == true then return true end
    end
    if IsEntityAMissionEntity(veh) then return true end
    return false
end

CreateThread(function()
    while true do
        for _, veh in ipairs(GetGamePool('CVehicle')) do
            if not handled[veh] and DoesEntityExist(veh) then

                local ambient = AMBIENT_POP[GetEntityPopulationType(veh)] == true

                -- Only ambient traffic, no player aboard, not owned/script-spawned.
                if ambient and not hasPlayerOccupant(veh) and not isOwned(veh) then
                    local orig = GetVehicleNumberPlateText(veh) or tostring(veh)
                    SetVehicleNumberPlateText(veh, Plates.GenerateNigerian(orig))
                end
                handled[veh] = true
            end
        end

        -- Trim dead entries so the table doesn't grow forever.
        for veh in pairs(handled) do
            if not DoesEntityExist(veh) then handled[veh] = nil end
        end

        Wait(Config.Traffic.scanInterval)
    end
end)