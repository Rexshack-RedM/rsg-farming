local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

local Plants   = {}   -- [id] = plant data from server
local Spawned  = {}   -- [id] = { entity = handle, stage = idx }
local Busy     = false
local UIPlant  = nil  -- id of plant open in UI
local MyCid    = nil

---------------------------------
-- helpers
---------------------------------
local function notify(desc, ntype)
    lib.notify({ title = locale('farming'), description = desc, type = ntype or 'inform', duration = 4000 })
end

local function getCid()
    if not MyCid then
        local pd = RSGCore.Functions.GetPlayerData()
        MyCid = pd and pd.citizenid
    end
    return MyCid
end

local function getStage(crop, growth)
    local idx = 1
    for i, st in ipairs(crop.stages) do
        if growth >= st.from then idx = i end
    end
    return idx
end

local openUI -- forward declaration (defined in interaction section)

local function despawn(id)
    local s = Spawned[id]
    if s then
        if DoesEntityExist(s.entity) then DeleteObject(s.entity) end
        if s.zone then exports.ox_target:removeZone(s.zone) end
    end
    Spawned[id] = nil
end

local function addTarget(plant)
    if not Config.UseTarget then return nil end
    local label = Config.Crops[plant.crop].label
    return exports.ox_target:addSphereZone({
        coords = vector3(plant.x, plant.y, plant.z + 0.5),
        radius = Config.TargetRadius,
        debug = Config.Debug,
        options = {
            {
                name = ('rsg_farming_plant_%s'):format(plant.id),
                label = locale('tend_target'):format(label),
                icon = Config.TargetIcon,
                distance = Config.InteractDistance + 0.5,
                canInteract = function()
                    return not Busy and Plants[plant.id] ~= nil
                end,
                onSelect = function()
                    openUI(plant.id)
                end,
            },
        },
    })
end

local function spawn(plant, stageIdx)
    local crop = Config.Crops[plant.crop]
    local st = crop.stages[stageIdx]
    local hash = Placement.LoadModel(st.prop)
    if not hash then return end
    local obj = CreateObject(hash, plant.x, plant.y, plant.z + (st.zOffset or 0.0), false, false, false)
    SetEntityHeading(obj, plant.h or 0.0)
    FreezeEntityPosition(obj, true)
    SetEntityCollision(obj, false, false)
    SetModelAsNoLongerNeeded(hash)
    if plant.dead then SetEntityAlpha(obj, 140, false) end
    Spawned[plant.id] = { entity = obj, stage = stageIdx, dead = plant.dead, zone = addTarget(plant) }
end

local function remainingMinutes(p)
    local crop = Config.Crops[p.crop]
    if p.growth >= 100 then return 0 end
    local rate = 100 / crop.growTime
    if p.fertilizer > 0 then rate = rate * Config.FertilizerBoost end
    return math.ceil((100 - p.growth) / rate)
end

local function uiPayload(p)
    local crop = Config.Crops[p.crop]
    local stageIdx = getStage(crop, p.growth)
    local ped = PlayerPedId()
    return {
        id = p.id,
        label = crop.label,
        growth = p.growth, water = p.water, fertilizer = p.fertilizer, health = p.health,
        dead = p.dead,
        stage = stageIdx, stages = #crop.stages,
        ready = p.growth >= 100 and not p.dead,
        isOwner = p.owner == getCid(),
        ownerOnly = Config.OwnerOnlyHarvest,
        remaining = remainingMinutes(p),
        thirsty = p.water <= Config.MinWaterToGrow,
        distance = math.floor(#(GetEntityCoords(ped) - vector3(p.x, p.y, p.z))),
    }
end

local function myPlantsPayload()
    local list = {}
    local cid = getCid()
    for _, p in pairs(Plants) do
        if p.owner == cid then list[#list + 1] = uiPayload(p) end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

---------------------------------
-- sync
---------------------------------
local function applySync(list)
    local new = {}
    for _, p in ipairs(list or {}) do new[p.id] = p end
    for id in pairs(Spawned) do
        if not new[id] then despawn(id) end
    end
    Plants = new
    if UIPlant then
        if Plants[UIPlant] then
            SendNUIMessage({ action = 'update', plant = uiPayload(Plants[UIPlant]) })
        else
            UIPlant = nil
            SetNuiFocus(false, false)
            SendNUIMessage({ action = 'close' })
        end
    end
end

RegisterNetEvent('rsg-farming:client:sync', function(list) applySync(list) end)

RegisterNetEvent('RSGCore:Client:OnPlayerLoaded', function()
    MyCid = nil
    applySync(lib.callback.await('rsg-farming:server:getPlants', false))
end)

CreateThread(function()
    Wait(1000)
    applySync(lib.callback.await('rsg-farming:server:getPlants', false))
end)

---------------------------------
-- streaming props
---------------------------------
CreateThread(function()
    while true do
        local pos = GetEntityCoords(PlayerPedId())
        for id, p in pairs(Plants) do
            local crop = Config.Crops[p.crop]
            if crop then
                local dist = #(pos - vector3(p.x, p.y, p.z))
                local s = Spawned[id]
                if dist <= Config.RenderDistance then
                    local stage = getStage(crop, p.growth)
                    if not s or s.stage ~= stage or s.dead ~= p.dead or not DoesEntityExist(s.entity) then
                        despawn(id)
                        spawn(p, stage)
                    end
                elseif s then
                    despawn(id)
                end
            end
        end
        Wait(1000)
    end
end)

---------------------------------
-- interaction
---------------------------------
function openUI(id)
    local p = Plants[id]
    if not p then return end
    UIPlant = id
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', plant = uiPayload(p) })
end

CreateThread(function()
    if Config.UseTarget then return end -- ox_target handles interaction
    local shown = false
    while true do
        local sleep = 750
        local ped = PlayerPedId()
        local pos = GetEntityCoords(ped)
        local nearest, nearestDist = nil, Config.InteractDistance

        if not Busy and not UIPlant and not IsPedInAnyVehicle(ped, false) and not IsPedOnMount(ped) then
            for id, p in pairs(Plants) do
                local d = #(pos - vector3(p.x, p.y, p.z))
                if d < 10.0 then sleep = 0 end
                if d < nearestDist then nearest, nearestDist = id, d end
            end
        end

        if nearest then
            if shown ~= nearest then
                lib.showTextUI(locale('tend_plant'):format(Config.Crops[Plants[nearest].crop].label))
                shown = nearest
            end
            if IsControlJustReleased(0, Config.InteractKey) then
                lib.hideTextUI(); shown = false
                openUI(nearest)
            end
        elseif shown then
            lib.hideTextUI(); shown = false
        end
        Wait(sleep)
    end
end)

---------------------------------
-- actions
---------------------------------
-- snapshot of objects that exist before a scenario starts
local function snapshotObjects()
    local set = {}
    for _, obj in ipairs(GetGamePool('CObject')) do set[obj] = true end
    return set
end

local function isPlantProp(obj)
    for _, s in pairs(Spawned) do
        if s.entity == obj then return true end
    end
    return false
end

-- removes props the scenario spawned (bucket, tools) whether still held or dropped
local function cleanupScenarioProps(ped, before)
    local myId = PlayerId()
    local pedPos = GetEntityCoords(ped)
    for _, obj in ipairs(GetGamePool('CObject')) do
        if not before[obj] and DoesEntityExist(obj) and not isPlantProp(obj) then
            local attached = IsEntityAttachedToEntity(obj, ped)
            local nearMine = #(GetEntityCoords(obj) - pedPos) < 3.0
                and (not NetworkGetEntityIsNetworked(obj) or NetworkGetEntityOwner(obj) == myId)
            if attached or nearMine then
                if attached then DetachEntity(obj, true, true) end
                SetEntityAsMissionEntity(obj, true, true)
                DeleteObject(obj)
                if DoesEntityExist(obj) then DeleteEntity(obj) end
            end
        end
    end
end

local function doAction(scenario, duration, label)
    local ped = PlayerPedId()
    local before = snapshotObjects()
    TaskStartScenarioInPlaceHash(ped, joaat(scenario), -1, true, false, false, false)
    local ok = lib.progressBar({
        duration = duration, label = label, useWhileDead = false, canCancel = true,
        disable = { move = true, combat = true, car = true },
    })
    ClearPedTasks(ped, true, true)
    Wait(1500) -- let the exit anim finish / drop the prop
    ClearPedTasksImmediately(ped)
    cleanupScenarioProps(ped, before)
    Wait(500) -- second pass for props dropped late (e.g. feed bag)
    cleanupScenarioProps(ped, before)
    return ok
end

local function faceCoords(x, y)
    local ped = PlayerPedId()
    TaskTurnPedToFaceCoord(ped, x, y, 0.0, 800)
    Wait(800)
end

local ACTIONS = {
    water     = { cb = 'rsg-farming:server:water',     scenario = 'water',     time = 'WaterTime',     label = 'watering' },
    fertilize = { cb = 'rsg-farming:server:fertilize', scenario = 'fertilize', time = 'FertilizeTime', label = 'fertilizing' },
    harvest   = { cb = 'rsg-farming:server:harvest',   scenario = 'harvest',   time = 'HarvestTime',   label = 'harvesting' },
    destroy   = { cb = 'rsg-farming:server:destroy' },
}

local function runAction(name, id)
    local act = ACTIONS[name]
    local p = Plants[id]
    if not act or not p or Busy then return end
    Busy = true
    UIPlant = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })

    if act.scenario then
        local canDo, reason = lib.callback.await('rsg-farming:server:precheck', false, name, id)
        if not canDo then
            notify(reason, 'error')
            Busy = false
            return
        end
    end

    local proceed = true
    if act.scenario then
        faceCoords(p.x, p.y)
        proceed = doAction(Config.Scenarios[act.scenario], Config[act.time], locale(act.label))
    end
    if proceed then
        local ok, msg = lib.callback.await(act.cb, false, id)
        notify(msg, ok and 'success' or 'error')
    else
        notify(locale('cancelled'), 'error')
    end
    Busy = false
end

---------------------------------
-- planting
---------------------------------
RegisterNetEvent('rsg-farming:client:startPlacing', function(cropKey)
    local crop = Config.Crops[cropKey]
    if not crop or Busy then return end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) or IsPedOnMount(ped) then return end
    Busy = true

    local finalStage = crop.stages[#crop.stages]
    local coords, heading = Placement.Start(finalStage.prop, function(pos)
        for _, p in pairs(Plants) do
            if #(vector3(p.x, p.y, p.z) - pos) < Config.MinPlantDistance then
                return false, locale('place_too_close')
            end
        end
        return true
    end)

    if coords then
        faceCoords(coords.x, coords.y)
        if doAction(Config.Scenarios.plant, Config.PlantTime, locale('planting')) then
            local ok, msg = lib.callback.await('rsg-farming:server:plant', false, cropKey, coords, heading)
            notify(msg, ok and 'success' or 'error')
        else
            notify(locale('cancelled'), 'error')
        end
    end
    Busy = false
end)

---------------------------------
-- NUI callbacks
---------------------------------
RegisterNUICallback('close', function(_, cb)
    UIPlant = nil
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNUICallback('action', function(data, cb)
    cb('ok')
    CreateThread(function() runAction(data.action, tonumber(data.id)) end)
end)

RegisterNUICallback('openPlant', function(data, cb)
    cb('ok')
    local id = tonumber(data.id)
    local p = Plants[id]
    if not p then return end
    if #(GetEntityCoords(PlayerPedId()) - vector3(p.x, p.y, p.z)) <= Config.InteractDistance + 1.0 then
        openUI(id)
    else
        -- too far: mark it on the map instead
        ClearGpsMultiRoute()
        StartGpsMultiRoute(joaat('COLOR_YELLOW'), true, true)
        AddPointToGpsMultiRoute(p.x, p.y, p.z)
        SetGpsMultiRouteRender(true)
        notify(locale('too_far'), 'inform')
    end
end)

---------------------------------
-- my plants overview
---------------------------------
RegisterCommand('myplants', function()
    if Busy then return end
    UIPlant = nil
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'list', plants = myPlantsPayload() })
end, false)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(Spawned) do despawn(id) end
    SetNuiFocus(false, false)
    lib.hideTextUI()
    ClearGpsMultiRoute()
end)

RegisterNUICallback('showList', function(_, cb)
    cb('ok')
    UIPlant = nil
    SendNUIMessage({ action = 'list', plants = myPlantsPayload() })
end)
