local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

local WP      = Config.WellPump
local Pumps   = {}   -- [id] = data
local Spawned = {}   -- [id] = entity
local Busy    = false

local function notify(desc, ntype)
    lib.notify({ title = locale('farming'), description = desc, type = ntype or 'inform', duration = 4000 })
end

local function getCid()
    local pd = RSGCore.Functions.GetPlayerData()
    return pd and pd.citizenid
end

local function playScenario(scenario, duration, label)
    local ped = PlayerPedId()
    TaskStartScenarioInPlaceHash(ped, joaat(scenario), -1, true, false, false, false)
    local ok = lib.progressBar({
        duration = duration, label = label, useWhileDead = false, canCancel = true,
        disable = { move = true, combat = true, car = true },
    })
    ClearPedTasks(ped, true, true)
    Wait(1200)
    ClearPedTasksImmediately(ped)
    -- remove any bucket prop the scenario left attached to the ped
    for _, obj in ipairs(GetGamePool('CObject')) do
        if IsEntityAttachedToEntity(obj, ped) then
            SetEntityAsMissionEntity(obj, true, true)
            DeleteObject(obj)
        end
    end
    return ok
end

local function face(x, y)
    TaskTurnPedToFaceCoord(PlayerPedId(), x, y, 0.0, 800)
    Wait(800)
end

---------------------------------
-- actions
---------------------------------
local function fillBucket(id)
    local p = Pumps[id]
    if not p or Busy then return end
    Busy = true
    local can, reason = lib.callback.await('rsg-farming:server:pumpPrecheck', false, id)
    if not can then notify(reason, 'error') Busy = false return end
    face(p.x, p.y)
    if playScenario(WP.fillScenario, WP.fillTime, locale('pump_filling')) then
        local ok, msg = lib.callback.await('rsg-farming:server:fillBucket', false, id)
        notify(msg, ok and 'success' or 'error')
    else
        notify(locale('cancelled'), 'error')
    end
    Busy = false
end

local function packPump(id)
    local p = Pumps[id]
    if not p or Busy then return end
    Busy = true
    face(p.x, p.y)
    if playScenario(WP.packScenario, WP.packTime, locale('pump_packing')) then
        local ok, msg = lib.callback.await('rsg-farming:server:packPump', false, id)
        notify(msg, ok and 'success' or 'error')
    else
        notify(locale('cancelled'), 'error')
    end
    Busy = false
end

---------------------------------
-- spawning
---------------------------------
local function despawn(id)
    local ent = Spawned[id]
    if ent then
        exports.ox_target:removeLocalEntity(ent)
        if DoesEntityExist(ent) then DeleteObject(ent) end
    end
    Spawned[id] = nil
end

local function spawn(p)
    local hash = Placement.LoadModel(WP.prop)
    if not hash then return end
    local ent = CreateObject(hash, p.x, p.y, p.z, false, false, false)
    SetEntityHeading(ent, p.h + 0.0)
    FreezeEntityPosition(ent, true)
    SetEntityAsMissionEntity(ent, true, true)
    SetModelAsNoLongerNeeded(hash)
    Spawned[p.id] = ent

    exports.ox_target:addLocalEntity(ent, {
        {
            name = ('rsg_wellpump_fill_%s'):format(p.id),
            label = locale('pump_fill_target'),
            icon = 'fa-solid fa-bucket',
            distance = WP.interactDist,
            canInteract = function() return not Busy end,
            onSelect = function() fillBucket(p.id) end,
        },
        {
            name = ('rsg_wellpump_pack_%s'):format(p.id),
            label = locale('pump_pack_target'),
            icon = 'fa-solid fa-box',
            distance = WP.interactDist,
            canInteract = function()
                return not Busy and (not WP.ownerOnlyPackup or Pumps[p.id] and Pumps[p.id].citizenid == getCid())
            end,
            onSelect = function() packPump(p.id) end,
        },
    })
end

local function applySync(list)
    local fresh = {}
    for _, p in ipairs(list or {}) do fresh[p.id] = p end
    for id in pairs(Spawned) do
        if not fresh[id] then despawn(id) end
    end
    Pumps = fresh
end

RegisterNetEvent('rsg-farming:client:syncPumps', applySync)

RegisterNetEvent('RSGCore:Client:OnPlayerLoaded', function()
    applySync(lib.callback.await('rsg-farming:server:getPumps', false))
end)

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    Wait(1500)
    applySync(lib.callback.await('rsg-farming:server:getPumps', false))
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(Spawned) do despawn(id) end
end)

-- distance streaming
CreateThread(function()
    while true do
        local pc = GetEntityCoords(PlayerPedId())
        for id, p in pairs(Pumps) do
            local near = #(pc - vector3(p.x, p.y, p.z)) < Config.RenderDistance
            if near and not Spawned[id] then spawn(p)
            elseif not near and Spawned[id] then despawn(id) end
        end
        Wait(1000)
    end
end)

---------------------------------
-- placement (same gizmo as crops)
---------------------------------
RegisterNetEvent('rsg-farming:client:placePump', function()
    if Busy then return end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) or IsPedOnMount(ped) then return end
    Busy = true
    local coords, heading = Placement.Start(WP.prop, function(pos)
        for _, p in pairs(Pumps) do
            if #(vector3(p.x, p.y, p.z) - pos) < WP.minDistance then
                return false, locale('pump_too_close')
            end
        end
        return true
    end, locale('pump_place_invalid'))
    if coords then
        face(coords.x, coords.y)
        if playScenario(WP.packScenario, WP.packTime, locale('pump_placing')) then
            local ok, msg = lib.callback.await('rsg-farming:server:placePump', false, coords, heading)
            notify(msg, ok and 'success' or 'error')
        else
            notify(locale('cancelled'), 'error')
        end
    end
    Busy = false
end)
