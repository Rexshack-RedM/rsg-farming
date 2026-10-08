-- shared client helpers for rsg-farming (loaded first)
lib.locale()

Utils = {
    busy     = false, -- one global busy flag so planting / pumps / tending can't overlap
    ownProps = {},    -- [entity] = true for props this resource spawned (never cleaned up as scenario props)
}

function Utils.notify(desc, ntype)
    if not desc then return end
    lib.notify({ title = locale('farming'), description = desc, type = ntype or 'inform', duration = 4000 })
end

function Utils.canAct()
    local ped = PlayerPedId()
    return not Utils.busy and not IsEntityDead(ped) and not IsPedInAnyVehicle(ped, false) and not IsPedOnMount(ped)
end

function Utils.face(x, y)
    TaskTurnPedToFaceCoord(PlayerPedId(), x, y, 0.0, 800)
    Wait(800)
end

local function snapshotObjects()
    local set = {}
    for _, obj in ipairs(GetGamePool('CObject')) do set[obj] = true end
    return set
end

-- removes props a scenario spawned (bucket, feed bag, tools) whether still held or dropped
local function cleanupScenarioProps(ped, before)
    local myId = PlayerId()
    local pedPos = GetEntityCoords(ped)
    for _, obj in ipairs(GetGamePool('CObject')) do
        if not before[obj] and not Utils.ownProps[obj] and DoesEntityExist(obj) then
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

-- plays a scenario with a progress bar, returns true if completed
function Utils.playScenario(scenario, duration, label)
    local ped = PlayerPedId()
    local before = snapshotObjects()
    TaskStartScenarioInPlaceHash(ped, joaat(scenario), -1, true, false, false, false)
    local ok = lib.progressBar({
        duration = duration, label = label, useWhileDead = false, canCancel = true,
        disable = { move = true, combat = true, car = true, mount = true },
    })
    ClearPedTasks(ped, true, true)
    Wait(1500) -- let the exit anim finish / drop the prop
    ClearPedTasksImmediately(ped)
    cleanupScenarioProps(ped, before)
    Wait(500)  -- second pass for props dropped late
    cleanupScenarioProps(ped, before)
    return ok
end

-- spawns a frozen, non-networked prop and registers it as ours
function Utils.spawnProp(model, x, y, z, heading)
    local hash = Placement.LoadModel(model)
    if not hash then return nil end
    local obj = CreateObject(hash, x, y, z, false, false, false)
    SetEntityHeading(obj, heading or 0.0)
    FreezeEntityPosition(obj, true)
    SetModelAsNoLongerNeeded(hash)
    Utils.ownProps[obj] = true
    return obj
end

function Utils.deleteProp(obj)
    if not obj then return end
    Utils.ownProps[obj] = nil
    if DoesEntityExist(obj) then DeleteObject(obj) end
end
