-- =====================================================================
--  tenx-plates-textures | runtime plate texture replacement (multi-state)
--  Replaces several native plate slots, one texture per state, so each
--  plate INDEX shows the right city image.
-- =====================================================================

-- Map each STATE texture to a native plate slot.
--   file  : your PNG in this resource
--   slot  : the vehshare texture to overwrite
--   index : the plate index this slot shows at (must match Config.States
--           plateIndex in tenx-plates, so prefix + texture stay in sync)
-- vehshare slots: plate01 plate02 plate03 plate04 plate05 yankton_plate
-- If a state's texture shows on the wrong index in-game, swap its `slot`.
local PLATES = {
    { file = 'lagos.png', slot = 'plate01', index = 1, w = 1024, h = 512 },
    { file = 'benin.png', slot = 'plate02', index = 2, w = 1024, h = 512 },
    { file = 'abuja.png', slot = 'plate03', index = 3, w = 1024, h = 512 },
    { file = 'kwara.png', slot = 'plate04', index = 4, w = 1024, h = 512 },
    { file = 'ogun.png',  slot = 'plate05', index = 5, w = 1024, h = 512 },
}

-- The part after nui:// MUST equal this resource's folder name.
local RES = GetCurrentResourceName()

CreateThread(function()
    for _, p in ipairs(PLATES) do
        local url = ('nui://%s/%s'):format(RES, p.file)
        local txdName = ('naija_txd_%s'):format(p.slot)
        local texName = ('naija_tex_%s'):format(p.slot)

        local txd = CreateRuntimeTxd(txdName)
        local dui = CreateDui(url, p.w, p.h)

        Wait(1500)  -- let the DUI render before we grab the surface
        local handle = GetDuiHandle(dui)

        CreateRuntimeTextureFromDuiHandle(txd, texName, handle)
        AddReplaceTexture('vehshare', p.slot, txdName, texName)

        print(('[tenx-plates-textures] %s -> %s (index %d)'):format(p.file, p.slot, p.index))
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= RES then return end
    for _, p in ipairs(PLATES) do
        RemoveReplaceTexture('vehshare', p.slot)
    end
end)