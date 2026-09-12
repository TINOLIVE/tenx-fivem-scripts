-- Cookie Boost - Standalone
-- Uses ox_inventory item hook — no QBCore inventory needed
-- ox_inventory removes the item automatically on use (consume)

exports.ox_inventory:registerHook('usingItem', function(payload)
    if payload.item.name == 'cookies' then
        TriggerClientEvent('cookie:client:use', payload.source)
    end
end, {
    itemFilter = {
        cookies = true
    }
})