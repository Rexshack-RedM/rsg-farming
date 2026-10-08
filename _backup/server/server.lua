local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

local Plants = {}      -- [id] = plant
local Dirty  = {}      -- [id] = true when needs saving
local Loaded = false

---------------------------------
-- helpers
---------------------------------
local function clamp(v, mn, mx) return math.max(mn, math.min(mx, v)) end

local function serialize(p)
    return {
        id = p.id, crop = p.crop, owner = p.citizenid,
        x = p.x, y = p.y, z = p.z, h = p.h,
        growth = p.growth, water = p.water, fertilizer = p.fertilizer,
        health = p.health, dead = p.dead,
    }
end

local function buildSync()
    local out = {}
    for _, p in pairs(Plants) do out[#out + 1] = serialize(p) end
    return out
end

local function syncAll()
    TriggerClientEvent('rsg-farming:client:sync', -1, buildSync())
end

local function countPlants(citizenid)
    local n = 0
    for _, p in pairs(Plants) do
        if p.citizenid == citizenid then n = n + 1 end
    end
    return n
end

local function notify(src, desc, ntype)
    TriggerClientEvent('ox_lib:notify', src, { title = locale('farming'), description = desc, type = ntype or 'inform', duration = 4000 })
end

-- validates player + plant + distance, returns Player, plant or nil, err
local function validate(src, plantId, maxDist)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return nil, nil, locale('no_player') end
    local plant = Plants[tonumber(plantId)]
    if not plant then return nil, nil, locale('plant_missing') end
    local ped = GetPlayerPed(src)
    local pc = GetEntityCoords(ped)
    if #(pc - vector3(plant.x, plant.y, plant.z)) > (maxDist or 4.0) then
        return nil, nil, locale('too_far')
    end
    return Player, plant
end

local function removeItem(src, Player, item, amount)
    if Player.Functions.RemoveItem(item, amount or 1) then
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[item], 'remove', amount or 1)
        return true
    end
    return false
end

local function addItem(src, Player, item, amount)
    if amount <= 0 or not RSGCore.Shared.Items[item] then return false end
    local ok, canAdd = pcall(function() return exports['rsg-inventory']:CanAddItem(src, item, amount) end)
    if ok and canAdd == false then return false end
    if Player.Functions.AddItem(item, amount) then
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[item], 'add', amount)
        return true
    end
    return false
end

local function deletePlant(id)
    Plants[id] = nil
    Dirty[id] = nil
    MySQL.query('DELETE FROM rsg_farming_plants WHERE id = ?', { id })
end

---------------------------------
-- database
---------------------------------
CreateThread(function()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `rsg_farming_plants` (
            `id` INT(11) NOT NULL AUTO_INCREMENT,
            `citizenid` VARCHAR(50) NOT NULL,
            `crop` VARCHAR(50) NOT NULL,
            `x` FLOAT NOT NULL, `y` FLOAT NOT NULL, `z` FLOAT NOT NULL, `h` FLOAT NOT NULL DEFAULT 0,
            `growth` FLOAT NOT NULL DEFAULT 0,
            `water` FLOAT NOT NULL DEFAULT 0,
            `fertilizer` FLOAT NOT NULL DEFAULT 0,
            `health` FLOAT NOT NULL DEFAULT 100,
            `dead` TINYINT(1) NOT NULL DEFAULT 0,
            `dead_time` INT(11) NOT NULL DEFAULT 0,
            `planted_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            KEY `citizenid` (`citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    local rows = MySQL.query.await('SELECT * FROM rsg_farming_plants') or {}
    for _, r in ipairs(rows) do
        if Config.Crops[r.crop] then
            Plants[r.id] = {
                id = r.id, citizenid = r.citizenid, crop = r.crop,
                x = r.x, y = r.y, z = r.z, h = r.h,
                growth = r.growth, water = r.water, fertilizer = r.fertilizer,
                health = r.health, dead = r.dead == 1 or r.dead == true, deadTime = r.dead_time or 0,
            }
        end
    end
    Loaded = true
    print(('[rsg-farming] loaded %d plants'):format(#rows))
    syncAll()
end)

local function saveDirty()
    local queries = {}
    for id in pairs(Dirty) do
        local p = Plants[id]
        if p then
            queries[#queries + 1] = {
                query = 'UPDATE rsg_farming_plants SET growth = ?, water = ?, fertilizer = ?, health = ?, dead = ?, dead_time = ? WHERE id = ?',
                values = { p.growth, p.water, p.fertilizer, p.health, p.dead and 1 or 0, p.deadTime or 0, id },
            }
        end
    end
    Dirty = {}
    if #queries > 0 then MySQL.transaction(queries) end
end

---------------------------------
-- growth tick
---------------------------------
CreateThread(function()
    while not Loaded do Wait(500) end
    local lastSave = os.time()
    while true do
        Wait(Config.TickInterval * 1000)
        local mins = Config.TickInterval / 60
        local now = os.time()

        for id, p in pairs(Plants) do
            local crop = Config.Crops[p.crop]
            if p.dead then
                if Config.DeadPlantRemoveTime > 0 and now - (p.deadTime or now) >= Config.DeadPlantRemoveTime * 60 then
                    deletePlant(id)
                end
            elseif crop then
                p.water      = clamp(p.water - Config.WaterDecay * mins, 0, 100)
                p.fertilizer = clamp(p.fertilizer - Config.FertilizerDecay * mins, 0, 100)

                if p.water > Config.MinWaterToGrow then
                    p.health = clamp(p.health + Config.HealthRegen * mins, 0, 100)
                    if p.growth < 100 then
                        local rate = 100 / crop.growTime -- % per minute
                        if p.fertilizer > 0 then rate = rate * Config.FertilizerBoost end
                        p.growth = clamp(p.growth + rate * mins, 0, 100)
                    end
                else
                    p.health = clamp(p.health - Config.DryDamage * mins, 0, 100)
                    if p.health <= 0 then
                        p.dead = true
                        p.deadTime = now
                    end
                end
                Dirty[id] = true
            end
        end

        syncAll()

        if now - lastSave >= Config.SaveInterval then
            saveDirty()
            lastSave = now
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then saveDirty() end
end)

AddEventHandler('txAdmin:events:serverShuttingDown', saveDirty)

---------------------------------
-- usable seeds
---------------------------------
for cropKey, crop in pairs(Config.Crops) do
    RSGCore.Functions.CreateUseableItem(crop.seed, function(source)
        local Player = RSGCore.Functions.GetPlayer(source)
        if not Player then return end
        if countPlants(Player.PlayerData.citizenid) >= Config.MaxPlantsPerPlayer then
            return notify(source, locale('max_plants'):format(Config.MaxPlantsPerPlayer), 'error')
        end
        TriggerClientEvent('rsg-farming:client:startPlacing', source, cropKey)
    end)
end

---------------------------------
-- callbacks
---------------------------------
lib.callback.register('rsg-farming:server:getPlants', function()
    return buildSync()
end)

lib.callback.register('rsg-farming:server:plant', function(source, cropKey, coords, heading)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    local crop = Config.Crops[cropKey]
    if not Player or not crop or type(coords) ~= 'vector3' and type(coords) ~= 'table' then
        return false, locale('place_invalid')
    end
    coords = vector3(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0)

    local pc = GetEntityCoords(GetPlayerPed(src))
    if #(pc - coords) > Config.PlaceMaxDistance + 2.0 then return false, locale('place_too_far') end

    local cid = Player.PlayerData.citizenid
    if countPlants(cid) >= Config.MaxPlantsPerPlayer then
        return false, locale('max_plants'):format(Config.MaxPlantsPerPlayer)
    end
    for _, p in pairs(Plants) do
        if #(vector3(p.x, p.y, p.z) - coords) < Config.MinPlantDistance then
            return false, locale('place_too_close')
        end
    end
    if not removeItem(src, Player, crop.seed, 1) then return false, locale('no_seed') end

    local h = tonumber(heading) or 0.0
    local id = MySQL.insert.await(
        'INSERT INTO rsg_farming_plants (citizenid, crop, x, y, z, h, growth, water, fertilizer, health) VALUES (?, ?, ?, ?, ?, ?, 0, 0, 0, 100)',
        { cid, cropKey, coords.x, coords.y, coords.z, h })
    if not id then
        addItem(src, Player, crop.seed, 1)
        return false, locale('place_invalid')
    end

    Plants[id] = {
        id = id, citizenid = cid, crop = cropKey,
        x = coords.x, y = coords.y, z = coords.z, h = h,
        growth = 0, water = 0, fertilizer = 0, health = 100, dead = false, deadTime = 0,
    }
    syncAll()
    return true, locale('planted')
end)

lib.callback.register('rsg-farming:server:water', function(source, plantId)
    local Player, plant, err = validate(source, plantId)
    if not Player then return false, err end
    if plant.dead then return false, locale('plant_dead') end
    if plant.water >= 95 then return false, locale('already_full') end
    -- full bucket has limited uses (stored in item metadata)
    local bucket = Player.Functions.GetItemByName(Config.WaterItem)
    if not bucket or (bucket.amount or 0) < 1 then return false, locale('no_water') end
    local maxUses = (Config.WellPump and Config.WellPump.bucketUses) or 5
    local info = bucket.info or {}
    local uses = tonumber(info.uses) or maxUses
    if uses <= 1 then
        -- last use: bucket is empty now
        if not Player.Functions.RemoveItem(Config.WaterItem, 1, bucket.slot) then return false, locale('no_water') end
        TriggerClientEvent('rsg-inventory:client:ItemBox', source, RSGCore.Shared.Items[Config.WaterItem], 'remove', 1)
        if Config.WaterReturnItem then addItem(source, Player, Config.WaterReturnItem, 1) end
    else
        local newInfo = {}
        for k, v in pairs(info) do newInfo[k] = v end
        newInfo.uses = uses - 1
        newInfo.description = ('Uses left: %d/%d'):format(newInfo.uses, maxUses)
        if not Player.Functions.RemoveItem(Config.WaterItem, 1, bucket.slot) then return false, locale('no_water') end
        Player.Functions.AddItem(Config.WaterItem, 1, bucket.slot, newInfo)
    end

    plant.water = clamp(plant.water + Config.WaterAmount, 0, 100)
    Dirty[plant.id] = true
    syncAll()
    return true, locale('watered')
end)

lib.callback.register('rsg-farming:server:fertilize', function(source, plantId)
    local Player, plant, err = validate(source, plantId)
    if not Player then return false, err end
    if plant.dead then return false, locale('plant_dead') end
    if plant.fertilizer >= 95 then return false, locale('already_full') end
    if not removeItem(source, Player, Config.FertilizerItem, 1) then return false, locale('no_fertilizer') end

    plant.fertilizer = clamp(plant.fertilizer + Config.FertilizerAmount, 0, 100)
    Dirty[plant.id] = true
    syncAll()
    return true, locale('fertilized')
end)

lib.callback.register('rsg-farming:server:harvest', function(source, plantId)
    local Player, plant, err = validate(source, plantId)
    if not Player then return false, err end
    if Config.OwnerOnlyHarvest and plant.citizenid ~= Player.PlayerData.citizenid then
        return false, locale('not_owner')
    end
    if plant.dead then return false, locale('plant_dead') end
    if plant.growth < 100 then return false, locale('not_ready') end

    local crop = Config.Crops[plant.crop]
    deletePlant(plant.id) -- remove first to stop double-harvest
    syncAll()

    local gaveAll = true
    for _, reward in ipairs(crop.harvest) do
        local amount = math.random(reward.min, reward.max)
        if amount > 0 and not addItem(source, Player, reward.item, amount) then gaveAll = false end
    end
    if not gaveAll then notify(source, locale('inv_full'), 'error') end
    return true, locale('harvested')
end)

lib.callback.register('rsg-farming:server:destroy', function(source, plantId)
    local Player, plant, err = validate(source, plantId)
    if not Player then return false, err end
    if plant.citizenid ~= Player.PlayerData.citizenid and not plant.dead then
        return false, locale('not_owner')
    end
    deletePlant(plant.id)
    syncAll()
    return true, locale('destroyed')
end)

---------------------------------
-- pre-check (runs before the client plays the animation)
---------------------------------
local function hasItem(Player, item)
    local it = Player.Functions.GetItemByName(item)
    return it ~= nil and (it.amount or 0) > 0
end

lib.callback.register('rsg-farming:server:precheck', function(source, action, plantId)
    local Player, plant, err = validate(source, plantId)
    if not Player then return false, err end

    if action == 'water' then
        if plant.dead then return false, locale('plant_dead') end
        if plant.water >= 95 then return false, locale('already_full') end
        if not hasItem(Player, Config.WaterItem) then return false, locale('no_water') end
    elseif action == 'fertilize' then
        if plant.dead then return false, locale('plant_dead') end
        if plant.fertilizer >= 95 then return false, locale('already_full') end
        if not hasItem(Player, Config.FertilizerItem) then return false, locale('no_fertilizer') end
    elseif action == 'harvest' then
        if Config.OwnerOnlyHarvest and plant.citizenid ~= Player.PlayerData.citizenid then return false, locale('not_owner') end
        if plant.dead then return false, locale('plant_dead') end
        if plant.growth < 100 then return false, locale('not_ready') end
    end
    return true
end)
