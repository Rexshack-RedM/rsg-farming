local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

local Pumps  = {}   -- [id] = { id, citizenid, x, y, z, h }
local Loaded = false
local WP = Config.WellPump

local function syncAll(target)
    local out = {}
    for _, p in pairs(Pumps) do out[#out + 1] = p end
    TriggerClientEvent('rsg-farming:client:syncPumps', target or -1, out)
end

local function countPumps(cid)
    local n = 0
    for _, p in pairs(Pumps) do if p.citizenid == cid then n = n + 1 end end
    return n
end

local function itemBox(src, item, mode)
    TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[item], mode, 1)
end

local function canAdd(src, item)
    local ok, res = pcall(function() return exports['rsg-inventory']:CanAddItem(src, item, 1) end)
    return not (ok and res == false)
end

-- player + pump + distance check
local function validate(src, pumpId)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return nil end
    local pump = Pumps[tonumber(pumpId)]
    if not pump then return nil, nil, locale('pump_missing') end
    local pc = GetEntityCoords(GetPlayerPed(src))
    if #(pc - vector3(pump.x, pump.y, pump.z)) > WP.interactDist + 2.0 then
        return nil, nil, locale('too_far')
    end
    return Player, pump
end

---------------------------------
-- database (persistent across restarts)
---------------------------------
CreateThread(function()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `rsg_farming_wellpumps` (
            `id` INT(11) NOT NULL AUTO_INCREMENT,
            `citizenid` VARCHAR(50) NOT NULL,
            `x` FLOAT NOT NULL, `y` FLOAT NOT NULL, `z` FLOAT NOT NULL, `h` FLOAT NOT NULL DEFAULT 0,
            `placed_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `citizenid` (`citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
    local rows = MySQL.query.await('SELECT * FROM rsg_farming_wellpumps') or {}
    for _, r in ipairs(rows) do
        Pumps[r.id] = { id = r.id, citizenid = r.citizenid, x = r.x, y = r.y, z = r.z, h = r.h }
    end
    Loaded = true
    print(('[rsg-farming] loaded %d well pumps'):format(#rows))
    syncAll()
end)

lib.callback.register('rsg-farming:server:getPumps', function()
    while not Loaded do Wait(100) end
    local out = {}
    for _, p in pairs(Pumps) do out[#out + 1] = p end
    return out
end)

---------------------------------
-- usable item
---------------------------------
RSGCore.Functions.CreateUseableItem(WP.item, function(source)
    local Player = RSGCore.Functions.GetPlayer(source)
    if not Player then return end
    if countPumps(Player.PlayerData.citizenid) >= WP.maxPerPlayer then
        return TriggerClientEvent('ox_lib:notify', source, { title = locale('farming'), description = locale('pump_max'):format(WP.maxPerPlayer), type = 'error' })
    end
    TriggerClientEvent('rsg-farming:client:placePump', source)
end)

---------------------------------
-- place
---------------------------------
lib.callback.register('rsg-farming:server:placePump', function(source, coords, heading)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or type(coords) ~= 'vector3' and type(coords) ~= 'table' then return false, locale('pump_place_invalid') end
    coords = vector3(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0)

    if #(GetEntityCoords(GetPlayerPed(src)) - coords) > Config.PlaceMaxDistance + 2.0 then
        return false, locale('place_too_far')
    end
    local cid = Player.PlayerData.citizenid
    if countPumps(cid) >= WP.maxPerPlayer then return false, locale('pump_max'):format(WP.maxPerPlayer) end
    for _, p in pairs(Pumps) do
        if #(vector3(p.x, p.y, p.z) - coords) < WP.minDistance then return false, locale('pump_too_close') end
    end
    if not Player.Functions.RemoveItem(WP.item, 1) then return false, locale('pump_no_item') end
    itemBox(src, WP.item, 'remove')

    local h = tonumber(heading) or 0.0
    local id = MySQL.insert.await('INSERT INTO rsg_farming_wellpumps (citizenid, x, y, z, h) VALUES (?, ?, ?, ?, ?)',
        { cid, coords.x, coords.y, coords.z, h })
    if not id then
        Player.Functions.AddItem(WP.item, 1)
        itemBox(src, WP.item, 'add')
        return false, locale('pump_place_invalid')
    end
    Pumps[id] = { id = id, citizenid = cid, x = coords.x, y = coords.y, z = coords.z, h = h }
    syncAll()
    return true, locale('pump_placed')
end)

---------------------------------
-- fill bucket
---------------------------------
-- pre-check before the animation plays
lib.callback.register('rsg-farming:server:pumpPrecheck', function(source, pumpId)
    local Player, _, err = validate(source, pumpId)
    if not Player then return false, err end
    local item = Player.Functions.GetItemByName(WP.emptyItem)
    if not item or (item.amount or 0) < 1 then return false, locale('pump_no_bucket') end
    return true
end)

lib.callback.register('rsg-farming:server:fillBucket', function(source, pumpId)
    local src = source
    local Player, _, err = validate(src, pumpId)
    if not Player then return false, err end
    if not Player.Functions.RemoveItem(WP.emptyItem, 1) then return false, locale('pump_no_bucket') end
    itemBox(src, WP.emptyItem, 'remove')
    local uses = WP.bucketUses or 5
    Player.Functions.AddItem(WP.fullItem, 1, nil, { uses = uses, description = ('Uses left: %d/%d'):format(uses, uses) })
    itemBox(src, WP.fullItem, 'add')
    return true, locale('pump_filled')
end)

---------------------------------
-- pack up
---------------------------------
lib.callback.register('rsg-farming:server:packPump', function(source, pumpId)
    local src = source
    local Player, pump, err = validate(src, pumpId)
    if not Player then return false, err end
    if WP.ownerOnlyPackup and pump.citizenid ~= Player.PlayerData.citizenid then
        return false, locale('pump_not_owner')
    end
    if not canAdd(src, WP.item) then return false, locale('inv_full') end

    Pumps[pump.id] = nil
    MySQL.query('DELETE FROM rsg_farming_wellpumps WHERE id = ?', { pump.id })
    Player.Functions.AddItem(WP.item, 1)
    itemBox(src, WP.item, 'add')
    syncAll()
    return true, locale('pump_packed')
end)
