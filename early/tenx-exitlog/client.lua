-- report our coords to the server on a light interval so the server knows where
-- everyone is when someone disconnects (you can't read a dropped player's ped)
CreateThread(function()
    while true do
        Wait((Config.PosInterval or 5) * 1000)
        local c = GetEntityCoords(PlayerPedId())
        TriggerServerEvent('tenx-exitlog:pos', c.x, c.y, c.z)
    end
end)
