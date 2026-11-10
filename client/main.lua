-- client side: holster, melee flag, controls, blips, notifications
-- the server decides exceptions and blocks the actual damage, this only stops
-- local input. until the server sends perms, everything in the zone is blocked.
--
-- one thread, no per-frame work unless the player holds a weapon they can't
-- use, sits in an armed vehicle, or a boundary is being drawn

local T = Config.Locales[Config.Locale] or Config.Locales.en
local CC = Config.Client
local PID = PlayerId()

local zones, grid, cell, near = NXZ.load(Config, CC.nearDistance)
local version = 0          -- zone list version from the server (0 = config only)
local pending              -- perms that arrived before their zone list

local caps = {}
local myBucket = 0

local active, nActive = {}, 0
local insideIdx = {}
local visible, nVisible = {}, 0
local carry                -- ids we were in before a zone reload, to avoid repeat notices

local P = { weapons = true, aim = true, shoot = true, melee = true }
local holster = false
local vehInvincible = false

local hot = false
local hotAim, hotFire, hotMelee, hotMeleeWeapon, hotVehicle = false, false, false, false, false

-- staff tools
local showAll = false
local highlightId, highlightUntil = nil, 0
local SHOW_RANGE2 = 250.0 * 250.0

-- natives don't agree on signed/unsigned hashes
local function u32(h) return (h or 0) & 0xFFFFFFFF end
local UNARMED = `WEAPON_UNARMED`
local U_UNARMED = u32(UNARMED)
local GROUP_MELEE = u32(`GROUP_MELEE`)
local FLAG_DISABLE_MELEE = 122

local blips = {}
local touchedVehicle = 0
local meleePed = 0
local lastHolster, lastWeaponNotice = -1e9, -1e9
local nextPoll = 0

local function debug(msg, ...)
    if Config.Debug then print(('[NX_safezones] ' .. msg):format(...)) end
end

local function notify(text, kind)
    local mode = Config.Notify
    if not mode then return end
    if mode == 'ox_lib' or (mode == 'auto' and GetResourceState('ox_lib') == 'started') then
        TriggerEvent('ox_lib:notify', { title = T.title, description = text, type = kind or 'inform' })
        return
    end
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandThefeedPostTicker(false, false)
end

local function recomputeEffective()
    P.weapons = NXZ.allowed(active, nActive, caps, 'weapons')
    P.aim = NXZ.allowed(active, nActive, caps, 'aim')
    P.shoot = NXZ.allowed(active, nActive, caps, 'shoot')
    P.melee = NXZ.allowed(active, nActive, caps, 'melee')

    holster = false
    vehInvincible = false
    for i = 1, nActive do
        local z = active[i]
        if not P.weapons and z.block.weapons and z.weaponMode == 'holster'
            and not (caps[z.idx] and caps[z.idx].weapons) then
            holster = true
        end
        if z.invincibleVehicle then vehInvincible = true end
    end
end

local function restoreVehicle()
    if touchedVehicle ~= 0 then
        if DoesEntityExist(touchedVehicle) then SetEntityCanBeDamaged(touchedVehicle, true) end
        touchedVehicle = 0
    end
end

local function restoreMelee()
    if meleePed ~= 0 then
        if DoesEntityExist(meleePed) then SetPedConfigFlag(meleePed, FLAG_DISABLE_MELEE, false) end
        meleePed = 0
    end
end

-- set the ped flag once instead of disabling melee controls every frame.
-- if something else already set it we leave it alone.
local function blockMelee(ped, block)
    if not block then return restoreMelee() end
    if meleePed == ped then return end
    restoreMelee()
    if not GetPedConfigFlag(ped, FLAG_DISABLE_MELEE, true) then
        SetPedConfigFlag(ped, FLAG_DISABLE_MELEE, true)
        meleePed = ped
    end
end

-- returns false while throttled, the weapon is still out then
local function putAway(ped)
    local now = GetGameTimer()
    if now - lastHolster < 400 then return false end
    lastHolster = now
    -- let the inventory disarm so it doesn't get out of sync
    if GetResourceState('ox_inventory') == 'started' then
        TriggerEvent('ox_inventory:disarm', PID, true)
    end
    SetCurrentPedWeapon(ped, UNARMED, true)
    if now - lastWeaponNotice > 8000 then
        lastWeaponNotice = now
        notify(T.noWeapons, 'error')
    end
    return true
end

local function clearInside()
    restoreMelee()
    restoreVehicle()
    hot, hotAim, hotFire, hotMelee, hotMeleeWeapon, hotVehicle = false, false, false, false, false, false
end

local function topZone(list, n)
    local best
    for i = 1, n do
        local z = list[i]
        if z.notify and (not best or z.priority > best.priority) then best = z end
    end
    return best
end

local tmp, left = {}, {}

local function addVisible(z)
    for i = 1, nVisible do if visible[i] == z then return end end
    nVisible = nVisible + 1
    visible[nVisible] = z
end

-- returns how long to sleep before the next check
local function updateZones(ped)
    local c = GetEntityCoords(ped)
    local x, y, zc = c.x, c.y, c.z
    local n = NXZ.zonesAt(grid, cell, x, y, zc, myBucket, tmp)

    local changed = n ~= nActive
    if not changed then
        for i = 1, n do if not insideIdx[tmp[i].idx] then changed = true break end end
    end

    if changed then
        local nLeft = 0
        for i = 1, nActive do
            local z = active[i]
            local stays = false
            for j = 1, n do if tmp[j] == z then stays = true break end end
            if not stays then nLeft = nLeft + 1; left[nLeft] = z end
        end
        for i = nLeft + 1, #left do left[i] = nil end

        local entering = nil
        for j = 1, n do
            local z = tmp[j]
            if not insideIdx[z.idx] and not (carry and carry[z.id]) then
                if z.notify and (not entering or z.priority > entering.priority) then entering = z end
            end
        end

        for k in pairs(insideIdx) do insideIdx[k] = nil end
        for i = 1, n do active[i] = tmp[i]; insideIdx[tmp[i].idx] = true end
        for i = n + 1, #active do active[i] = nil end
        nActive = n
        recomputeEffective()

        if entering then
            notify(T.enter:format(entering.label), 'inform')
        elseif n == 0 and nLeft > 0 then
            local z = topZone(left, nLeft)
            if z then notify(T.leave:format(z.label), 'inform') end
        end
        if n == 0 then clearInside() end
        debug('active zones: %d', n)
    end
    carry = nil

    local nr = near[NXZ.key(cell, x, y)]
    nVisible = 0
    local shows = nr and nr.shows
    if shows then
        for i = 1, #shows do
            local z = shows[i]
            local dx, dy = x - z.x, y - z.y
            if z.bucket == myBucket and dx * dx + dy * dy <= z.boundary.d2 then addVisible(z) end
        end
    end

    -- staff view: every zone in range, or the one just edited
    local lit = highlightId and GetGameTimer() < highlightUntil
    if showAll or lit then
        for _, z in ipairs(zones) do
            if not z.invalid and z.bucket == myBucket and (showAll or z.id == highlightId) then
                local dx, dy = x - z.x, y - z.y
                if dx * dx + dy * dy <= SHOW_RANGE2 + z.r2 then addVisible(z) end
            end
        end
    elseif highlightId then
        highlightId = nil
    end
    for i = nVisible + 1, #visible do visible[i] = nil end

    if nActive > 0 then return CC.insideCheck end
    if nVisible > 0 then return CC.edge end
    if not nr then return CC.far end
    if nr.edge < 30.0 then return CC.edge end
    return CC.near
end

-- runs at check rate while inside, decides if the per-frame loop is needed
local function updateInside(ped)
    blockMelee(ped, not P.melee)

    local weapon = GetSelectedPedWeapon(ped)
    local armed = u32(weapon) ~= U_UNARMED
    if armed and holster and putAway(ped) then armed = false end

    local isMelee = armed and u32(GetWeapontypeGroup(weapon)) == GROUP_MELEE
    local noShoot = not P.shoot or not P.weapons

    hotAim = armed and not P.aim
    hotFire = armed and not isMelee and noShoot
    hotMelee = armed and not P.melee   -- pistol whips, knives, bats
    hotMeleeWeapon = hotMelee and isMelee
    hotVehicle = false

    local veh = GetVehiclePedIsIn(ped, false)
    if veh ~= 0 then
        if noShoot and DoesVehicleHaveWeapons(veh) then hotVehicle = true end
        if vehInvincible and veh ~= touchedVehicle and GetPedInVehicleSeat(veh, -1) == ped then
            restoreVehicle()
            SetEntityCanBeDamaged(veh, false)
            touchedVehicle = veh
        end
    end
    if touchedVehicle ~= 0 and (veh ~= touchedVehicle or not vehInvincible) then restoreVehicle() end

    hot = hotAim or hotFire or hotMelee or hotVehicle
end

local function frame()
    if hot then
        if hotAim then
            DisableControlAction(0, 25, true)
            DisableControlAction(0, 68, true)
            DisableControlAction(0, 91, true)
        end
        -- attack button: guns when shooting is blocked, knives/bats when melee is.
        -- a gun with only melee blocked can still fire, it just can't pistol whip.
        if hotFire or hotMeleeWeapon then
            DisablePlayerFiring(PID, true)
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 257, true)
        end
        if hotMelee then
            DisableControlAction(0, 140, true)
            DisableControlAction(0, 141, true)
            DisableControlAction(0, 142, true)
            DisableControlAction(0, 263, true)
            DisableControlAction(0, 264, true)
        end
        if hotFire or hotVehicle then
            DisableControlAction(0, 69, true)
            DisableControlAction(0, 70, true)
            DisableControlAction(0, 92, true)
            DisableControlAction(0, 114, true)
        end
    end

    for i = 1, nVisible do
        local z = visible[i]
        local b, col = z.boundary, z.boundary.color
        DrawMarker(1, z.x, z.y, z.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            z.radius * 2.0, z.radius * 2.0, b.height, col[1], col[2], col[3], col[4],
            false, false, 2, false, nil, nil, false)
    end
end

CreateThread(function()
    while true do
        local now = GetGameTimer()
        if now >= nextPoll then
            local ped = PlayerPedId()
            local sleep = updateZones(ped)
            if nActive > 0 then updateInside(ped) end
            nextPoll = now + sleep
        end

        if hot or nVisible > 0 then
            frame()
            Wait(0)
        else
            local w = nextPoll - now
            Wait(w > 0 and w or 0)
        end
    end
end)

-- blips -----------------------------------------------------------------------

local function removeBlips()
    for _, b in ipairs(blips) do if DoesBlipExist(b) then RemoveBlip(b) end end
    blips = {}
end

local function createBlips()
    for _, z in ipairs(zones) do
        if not z.invalid and z.bucket == 0 then
            if z.map.radius then
                local b = AddBlipForRadius(z.x, z.y, z.z, z.radius)
                SetBlipColour(b, z.map.color)
                SetBlipAlpha(b, 90)
                SetBlipDisplay(b, 4)
                blips[#blips + 1] = b
            end
            if z.map.blip then
                local b = AddBlipForCoord(z.x, z.y, z.z)
                SetBlipSprite(b, z.map.sprite)
                SetBlipColour(b, z.map.color)
                SetBlipScale(b, 0.7)
                SetBlipDisplay(b, 4)
                SetBlipAsShortRange(b, true)
                BeginTextCommandSetBlipName('STRING')
                AddTextComponentSubstringPlayerName(z.label)
                EndTextCommandSetBlipName(b)
                blips[#blips + 1] = b
            end
        end
    end
end

-- server events ---------------------------------------------------------------

local function applyPerms(packet, bucket)
    for k in pairs(caps) do caps[k] = nil end
    if type(packet) == 'table' then
        for _, pair in ipairs(packet) do
            local idx, list = tonumber(pair[1]), pair[2]
            if idx and zones[idx] and type(list) == 'table' then
                local set = {}
                for _, a in ipairs(list) do if NXZ.IS_ACTION[a] then set[a] = true end end
                caps[idx] = set
            end
        end
    end
    myBucket = tonumber(bucket) or 0
    recomputeEffective()
    if nActive > 0 then updateInside(PlayerPedId()) end
    nextPoll = 0
    debug('perms received, bucket %d', myBucket)
end

RegisterNetEvent('NX_safezones:zones', function(ver, list)
    ver = tonumber(ver) or 0
    if ver == version then return end

    -- remember where we were so a reload doesn't spam enter notices
    carry = {}
    for i = 1, nActive do carry[active[i].id] = true end

    zones, grid, cell, near = NXZ.load(Config, CC.nearDistance, type(list) == 'table' and list or {})
    version = ver

    -- old zone objects are gone: caps by index are meaningless until the new perms arrive
    for k in pairs(caps) do caps[k] = nil end
    for i = 1, #active do active[i] = nil end
    for k in pairs(insideIdx) do insideIdx[k] = nil end
    nActive, nVisible = 0, 0
    clearInside()
    recomputeEffective()

    removeBlips()
    createBlips()

    if pending and pending.ver == ver then applyPerms(pending.packet, pending.bucket) end
    pending = nil
    nextPoll = 0
    debug('zone list v%d, %d zone(s)', ver, #zones)
end)

RegisterNetEvent('NX_safezones:permissions', function(packet, bucket, ver)
    ver = tonumber(ver) or 0
    if ver ~= version then
        pending = { packet = packet, bucket = bucket, ver = ver }
        return
    end
    applyPerms(packet, bucket)
end)

RegisterNetEvent('NX_safezones:notify', function(text, kind)
    if type(text) == 'string' then notify(text, kind) end
end)

RegisterNetEvent('NX_safezones:print', function(lines)
    if type(lines) ~= 'table' then return end
    for _, l in ipairs(lines) do if type(l) == 'string' then print(l) end end
end)

RegisterNetEvent('NX_safezones:show', function()
    showAll = not showAll
    nextPoll = 0
    notify(showAll and T.showOn or T.showOff)
end)

RegisterNetEvent('NX_safezones:highlight', function(id)
    if type(id) ~= 'string' then return end
    highlightId, highlightUntil = id, GetGameTimer() + 15000
    nextPoll = 0
end)

RegisterNetEvent('NX_safezones:info', function()
    print(('[NX_safezones] bucket %d, %d active zone(s), zone list v%d'):format(myBucket, nActive, version))
    for i = 1, nActive do
        local z = active[i]
        local l = {}
        for _, a in ipairs(NXZ.ACTIONS) do if caps[z.idx] and caps[z.idx][a] then l[#l + 1] = a end end
        print(('  %s: exceptions = %s'):format(z.id, #l > 0 and table.concat(l, ', ') or 'none'))
    end
    print(('  effective: weapons=%s aim=%s shoot=%s melee=%s holster=%s per-frame=%s'):format(
        tostring(P.weapons), tostring(P.aim), tostring(P.shoot), tostring(P.melee), tostring(holster),
        tostring(hot or nVisible > 0)))
    notify(nActive > 0 and T.inside:format(nActive) or T.none)
end)

CreateThread(function()
    createBlips()
    TriggerServerEvent('NX_safezones:request')
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    removeBlips()
    clearInside()
end)
