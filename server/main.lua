-- server side, this is where the actual decisions are made
-- positions are read here (onesync), the client never tells us where it is or
-- what job it has. the only client event is a sync request on start.

local CS = Config.Server
local ED = Config.Editor or {}
local RES = GetCurrentResourceName()
local T = Config.Locales[Config.Locale] or Config.Locales.en

local dynamic = {}    -- zones made in game, saved to ED.file
local version = 0     -- bumps every time the zone list changes
local zones, grid, cell, near
local byJob, aceZones = {}, {}

local perms    = {}   -- [src] = { caps = { [idx] = { action = true } }, auth = { [idx] = true }, sig }
local online   = {}
local due      = {}   -- next position check per player
local marks    = {}   -- [src][idx] = check number the player was last seen inside
local checks   = {}
local buckets  = {}
local lastCalc = {}
local requests = {}
local deferred = {}

local tmpA, tmpB = {}, {}

local function log(msg, ...)
    print(('^5[NX_safezones]^7 ' .. msg):format(...))
end

local function debug(msg, ...)
    if Config.Debug then log(msg, ...) end
end

local function connected(src)
    src = tonumber(src)
    return src ~= nil and src > 0 and GetPlayerName(src) ~= nil
end

-- zone list -----------------------------------------------------------------

local function wipe(t) for k in pairs(t) do t[k] = nil end end

local function rebuild()
    zones, grid, cell, near = NXZ.load(Config, CS.farDistance, dynamic)

    -- index zones by job / ace so a refresh only touches the ones that matter
    byJob, aceZones = {}, {}
    for idx, z in ipairs(zones) do
        if not z.invalid and z.permissions.any then
            for job in pairs(z.permissions.jobs) do
                byJob[job] = byJob[job] or {}
                byJob[job][#byJob[job] + 1] = idx
            end
            if #z.permissions.ace > 0 then aceZones[#aceZones + 1] = idx end
        end
    end

    -- indices may have moved, start position tracking over
    wipe(marks); wipe(checks); wipe(due)
    version = version + 1
end

local function sanitize(z)
    if type(z) ~= 'table' or type(z.id) ~= 'string' or type(z.center) ~= 'table' then return nil end
    local x, y, zc = tonumber(z.center.x), tonumber(z.center.y), tonumber(z.center.z)
    local r = tonumber(z.radius)
    if not (x and y and zc and r) then return nil end
    return {
        id = z.id,
        label = type(z.label) == 'string' and z.label or z.id,
        center = { x = x + 0.0, y = y + 0.0, z = zc + 0.0 },
        radius = r + 0.0,
        height = tonumber(z.height),
        bucket = math.floor(tonumber(z.bucket) or 0),
        preset = type(z.preset) == 'string' and z.preset or ED.defaultPreset,
        dynamic = true,
    }
end

local function loadDynamic()
    dynamic = {}
    if not ED.enabled then return end
    local raw = LoadResourceFile(RES, ED.file)
    if not raw or raw == '' then return end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then
        log('^1%s is not valid json, in-game zones not loaded^7', ED.file)
        return
    end
    for _, z in ipairs(data) do
        local clean = sanitize(z)
        if clean then dynamic[#dynamic + 1] = clean end
    end
end

local function saveDynamic()
    local list = {}
    for i, z in ipairs(dynamic) do
        list[i] = { id = z.id, label = z.label, center = z.center, radius = z.radius,
            height = z.height, bucket = z.bucket, preset = z.preset }
    end
    return SaveResourceFile(RES, ED.file, json.encode(list, { indent = true }), -1) == true
end

-- permissions ---------------------------------------------------------------

local function signature(caps, b)
    local idxs = {}
    for idx in pairs(caps) do idxs[#idxs + 1] = idx end
    table.sort(idxs)
    local parts = { version, tostring(b) }
    for _, idx in ipairs(idxs) do
        local c = caps[idx]
        local acts = {}
        for _, a in ipairs(NXZ.ACTIONS) do if c[a] then acts[#acts + 1] = a end end
        parts[#parts + 1] = idx .. '=' .. table.concat(acts, ',')
    end
    return table.concat(parts, ';')
end

local function recalc(src, force)
    if not connected(src) then return end
    local now = GetGameTimer()
    local wait = (CS.recalcMs or 1500) - (now - (lastCalc[src] or -1e9))
    if not force and wait > 0 then
        -- too soon, run it once when the wait is over instead of dropping it
        if not deferred[src] then
            deferred[src] = true
            SetTimeout(wait, function()
                deferred[src] = nil
                recalc(src, true)
            end)
        end
        return
    end
    lastCalc[src] = now

    local data = FW.data(src)
    local aceSeen = {}
    local function hasAce(ace)
        local v = aceSeen[ace]
        if v == nil then v = IsPlayerAceAllowed(src, ace) == true; aceSeen[ace] = v end
        return v
    end

    local caps, auth = {}, {}
    local function check(idx)
        if caps[idx] or auth[idx] then return end
        local c, authorized = NXZ.resolve(zones[idx], data, hasAce)
        if next(c) then caps[idx] = c end
        if authorized then auth[idx] = true end
    end
    local list = data and type(data.job) == 'string' and byJob[data.job]
    if list then for i = 1, #list do check(list[i]) end end
    for i = 1, #aceZones do check(aceZones[i]) end

    local b = buckets[src] or GetPlayerRoutingBucket(src)
    buckets[src] = b
    local sig = signature(caps, b)
    local previous = perms[src]
    perms[src] = { caps = caps, auth = auth, sig = sig }

    if not previous or previous.sig ~= sig then
        local packet = {}
        for idx, c in pairs(caps) do
            local l = {}
            for a in pairs(c) do l[#l + 1] = a end
            packet[#packet + 1] = { idx, l }
        end
        TriggerClientEvent('NX_safezones:permissions', src, packet, b, version)
        debug('perms for %s: %s (job %s, grade %s)', src, sig,
            data and data.job or '-', data and tostring(data.grade) or '-')
    end
end

local function recalcAll()
    for src in pairs(online) do
        if perms[src] then perms[src].sig = nil end
        recalc(src, true)
    end
end

FW.onChange(function(src, force) recalc(src, force) end)

FW.onReady = function()
    for _, id in ipairs(GetPlayers()) do recalc(tonumber(id), true) end
end

-- tell everyone about a new zone list, then resend perms (indices changed)
local function broadcast()
    TriggerClientEvent('NX_safezones:zones', -1, version, dynamic)
    recalcAll()
end

RegisterNetEvent('NX_safezones:request', function()
    local src = tonumber(source)
    if not connected(src) then return end
    local now = GetGameTimer()
    if requests[src] and now - requests[src] < 3000 then return end
    requests[src] = now
    online[src] = true
    TriggerClientEvent('NX_safezones:zones', src, version, dynamic)
    -- chat hint with arguments, only for people who can actually use it
    if IsPlayerAceAllowed(src, 'command.safezone') then
        TriggerClientEvent('chat:addSuggestion', src, '/safezone', 'Safe zone tools', {
            { name = 'action', help = 'add, move, radius, label, remove, list, presets, show, coords' },
            { name = 'name', help = 'zone name' },
            { name = 'radius', help = 'metres' },
        })
    end
    if perms[src] then perms[src].sig = nil end
    recalc(src, true)
end)

-- position checks -----------------------------------------------------------

local function checkPlayer(src, now)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then due[src] = now + CS.interval; return end
    local c = GetEntityCoords(ped)
    local x, y, z = c.x, c.y, c.z
    local b = GetPlayerRoutingBucket(src)
    local n = NXZ.zonesAt(grid, cell, x, y, z, b, tmpA)

    local k = (checks[src] or 0) + 1
    checks[src] = k
    local m = marks[src]
    if not m then m = {}; marks[src] = m end
    local entered = false
    for i = 1, n do
        local idx = tmpA[i].idx
        if m[idx] ~= k - 1 then entered = true end
        m[idx] = k
    end

    -- the further away, the longer until the next check
    local wait = CS.interval
    if n == 0 then
        local nr = near[NXZ.key(cell, x, y)]
        if not nr then
            wait = CS.farInterval
        else
            wait = nr.edge / CS.maxSpeed * 1000
            if wait < CS.interval then wait = CS.interval elseif wait > CS.farInterval then wait = CS.farInterval end
        end
    end
    due[src] = now + wait

    if buckets[src] ~= b then
        buckets[src] = b
        if perms[src] then perms[src].sig = nil end
        recalc(src, true)
    elseif entered then
        recalc(src, false)   -- refresh job/ace on the way in
    end
end

local function sweep(now)
    for src in pairs(online) do
        local d = due[src]
        if not d or d <= now then checkPlayer(src, now) end
    end
end

-- in case a join event got missed
local function resync()
    wipe(online)
    for _, id in ipairs(GetPlayers()) do online[tonumber(id)] = true end
end

AddEventHandler('playerJoining', function()
    local src = tonumber(source)
    if src then online[src] = true end
end)

AddEventHandler('playerDropped', function()
    local src = source
    online[src], due[src], marks[src], checks[src] = nil, nil, nil, nil
    perms[src], buckets[src], lastCalc[src], requests[src], deferred[src] = nil, nil, nil, nil, nil
end)

-- damage --------------------------------------------------------------------

local function capsOf(src, idx)
    local p = perms[src]
    return p and p.caps[idx]
end

local function isAuthorized(src, idx)
    local p = perms[src]
    return p and p.auth[idx] == true
end

local function can(src, list, n, action)
    local p = perms[src]
    return NXZ.allowed(list, n, p and p.caps, action)
end

-- both sides count, so you can't shoot into a zone from outside or out of it from inside
local function playerDamageAllowed(attacker, victim, zA, nA, zV, nV)
    if attacker == victim then return true end
    for pass = 1, 2 do
        local list, n = zA, nA
        if pass == 2 then list, n = zV, nV end
        for i = 1, n do
            local z = list[i]
            if z.block.playerDamage then
                local c = capsOf(attacker, z.idx)
                if not (c and c.playerDamage) then return false end
                if z.permissions.target ~= 'anyone' and not isAuthorized(victim, z.idx) then return false end
            end
        end
    end
    return true
end

local function zonesOfPlayer(src, out)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return 0 end
    local c = GetEntityCoords(ped)
    return NXZ.zonesAt(grid, cell, c.x, c.y, c.z, GetPlayerRoutingBucket(src), out)
end

local function zonesOfEntity(ent, out)
    local c = GetEntityCoords(ent)
    return NXZ.zonesAt(grid, cell, c.x, c.y, c.z, GetEntityRoutingBucket(ent), out)
end

local function targets(data)
    if type(data.hitGlobalIds) == 'table' and #data.hitGlobalIds > 0 then return data.hitGlobalIds end
    if data.hitGlobalId and data.hitGlobalId ~= 0 then return { data.hitGlobalId } end
    return nil
end

-- CancelEvent here only cancels this one event, nothing outside zones is touched
local function onWeaponDamage(sender, data)
    sender = tonumber(sender)
    if not sender or type(data) ~= 'table' then return end
    local list = targets(data)
    if not list then return end

    local nA = zonesOfPlayer(sender, tmpA)

    for i = 1, math.min(#list, 8) do
        local ent = NetworkGetEntityFromNetworkId(list[i])
        if ent and ent ~= 0 and DoesEntityExist(ent) then
            local kind = GetEntityType(ent)
            if kind == 1 and IsPedAPlayer(ent) then
                local victim = NetworkGetEntityOwner(ent)
                local nV = zonesOfEntity(ent, tmpB)
                if (nA > 0 or nV > 0) and not playerDamageAllowed(sender, victim, tmpA, nA, tmpB, nV) then
                    debug('blocked damage %s -> %s', sender, victim)
                    CancelEvent()
                    return
                end
            elseif kind == 2 then
                local nV = zonesOfEntity(ent, tmpB)
                if nV > 0 and not can(sender, tmpB, nV, 'vehicleDamage') then
                    debug('blocked vehicle damage from %s', sender)
                    CancelEvent()
                    return
                end
            end
        end
    end
end
AddEventHandler('weaponDamageEvent', onWeaponDamage)

AddEventHandler('explosionEvent', function(sender, ev)
    sender = tonumber(sender)
    if not sender or type(ev) ~= 'table' then return end
    local x, y, z = tonumber(ev.posX), tonumber(ev.posY), tonumber(ev.posZ)
    if not (x and y and z) then return end
    local n = NXZ.zonesAt(grid, cell, x, y, z, GetPlayerRoutingBucket(sender), tmpB)
    if n > 0 and not can(sender, tmpB, n, 'explosions') then
        debug('blocked explosion from %s', sender)
        CancelEvent()
    end
end)

AddEventHandler('startProjectileEvent', function(sender)
    sender = tonumber(sender)
    if not sender then return end
    local n = zonesOfPlayer(sender, tmpA)
    if n > 0 and not (can(sender, tmpA, n, 'shoot') and can(sender, tmpA, n, 'weapons')) then
        debug('blocked projectile from %s', sender)
        CancelEvent()
    end
end)

-- in-game editor --------------------------------------------------------------
-- registered as a restricted command: players need the command.safezone ace,
-- everyone else neither sees it in chat suggestions nor can run it

local function reply(src, text, kind)
    if src == 0 then print('[NX_safezones] ' .. text) return end
    TriggerClientEvent('NX_safezones:notify', src, text, kind)
end

local function printTo(src, lines)
    if src == 0 then for _, l in ipairs(lines) do print(l) end return end
    TriggerClientEvent('NX_safezones:print', src, lines)
end

local function findDynamic(id)
    for i, z in ipairs(dynamic) do if z.id == id then return i, z end end
end

local function idTaken(id)
    for _, z in ipairs(Config.Zones or {}) do if type(z) == 'table' and tostring(z.id) == id then return true end end
    return findDynamic(id) ~= nil
end

local function isConfigZone(id)
    for _, z in ipairs(Config.Zones or {}) do if type(z) == 'table' and tostring(z.id) == id then return true end end
    return false
end

local function position(src)
    if src == 0 then return nil end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    return { x = c.x + 0.0, y = c.y + 0.0, z = c.z + 0.0 }, GetPlayerRoutingBucket(src)
end

local function validId(id)
    return type(id) == 'string' and #id >= 1 and #id <= 32 and id:match('^[%w_%-]+$') ~= nil
end

local function validRadius(r)
    r = tonumber(r)
    if not r or r ~= r or r < (ED.minRadius or 2.0) or r > (ED.maxRadius or 500.0) then return nil end
    return r + 0.0
end

-- apply a change: save, rebuild, push to everyone. rolls back if saving fails.
local function commit(src, undo)
    if not saveDynamic() then
        undo()
        reply(src, T.saveFailed, 'error')
        log('^1could not write %s^7', ED.file)
        return false
    end
    rebuild()
    broadcast()
    return true
end

local function actor(src)
    return src == 0 and 'console' or ('%s (%d)'):format(GetPlayerName(src) or '?', src)
end

local sub = {}

sub.add = function(src, args)
    local id, radius, preset = args[2], args[3], args[4] or ED.defaultPreset
    if not validId(id) then return reply(src, T.badId, 'error') end
    if idTaken(id) then return reply(src, T.idTaken:format(id), 'error') end
    local r = validRadius(radius)
    if not r then return reply(src, T.badRadius:format(ED.minRadius or 2, ED.maxRadius or 500), 'error') end
    if not (Config.Presets and Config.Presets[preset]) then return reply(src, T.badPreset:format(tostring(preset)), 'error') end
    if #dynamic >= (ED.maxZones or 100) then return reply(src, T.tooMany:format(ED.maxZones or 100), 'error') end
    local pos, bucket = position(src)
    if not pos then return reply(src, T.noPosition, 'error') end

    local label = #args > 4 and table.concat(args, ' ', 5):sub(1, 64) or id
    dynamic[#dynamic + 1] = { id = id, label = label, center = pos, radius = r, bucket = bucket, preset = preset, dynamic = true }
    if commit(src, function() dynamic[#dynamic] = nil end) then
        reply(src, T.added:format(id, r, preset), 'success')
        TriggerClientEvent('NX_safezones:highlight', src, id)
        log('%s added zone %s (%.1f m, %s) at %.1f, %.1f, %.1f', actor(src), id, r, preset, pos.x, pos.y, pos.z)
    end
end

local function needDynamic(src, id)
    local i, z = findDynamic(id or '')
    if i then return i, z end
    if id and isConfigZone(id) then reply(src, T.configZone:format(id), 'error')
    else reply(src, T.notFound:format(tostring(id)), 'error') end
end

sub.move = function(src, args)
    local i, z = needDynamic(src, args[2])
    if not i then return end
    local pos, bucket = position(src)
    if not pos then return reply(src, T.noPosition, 'error') end
    local oldPos, oldBucket = z.center, z.bucket
    z.center, z.bucket = pos, bucket
    if commit(src, function() z.center, z.bucket = oldPos, oldBucket end) then
        reply(src, T.moved:format(z.id), 'success')
        TriggerClientEvent('NX_safezones:highlight', src, z.id)
        log('%s moved zone %s', actor(src), z.id)
    end
end

sub.radius = function(src, args)
    local i, z = needDynamic(src, args[2])
    if not i then return end
    local r = validRadius(args[3])
    if not r then return reply(src, T.badRadius:format(ED.minRadius or 2, ED.maxRadius or 500), 'error') end
    local old = z.radius
    z.radius = r
    if commit(src, function() z.radius = old end) then
        reply(src, T.resized:format(z.id, r), 'success')
        TriggerClientEvent('NX_safezones:highlight', src, z.id)
        log('%s resized zone %s to %.1f', actor(src), z.id, r)
    end
end

sub.label = function(src, args)
    local i, z = needDynamic(src, args[2])
    if not i then return end
    local label = table.concat(args, ' ', 3):sub(1, 64)
    if label == '' then label = z.id end
    local old = z.label
    z.label = label
    if commit(src, function() z.label = old end) then
        reply(src, T.relabeled:format(z.id, label), 'success')
    end
end

sub.remove = function(src, args)
    local i, z = needDynamic(src, args[2])
    if not i then return end
    table.remove(dynamic, i)
    if commit(src, function() table.insert(dynamic, i, z) end) then
        reply(src, T.removed:format(z.id), 'success')
        log('%s removed zone %s', actor(src), z.id)
    end
end

sub.list = function(src)
    local lines, n = { '[NX_safezones] zones:' }, 0
    for _, z in ipairs(zones) do
        if not z.invalid then
            n = n + 1
            lines[#lines + 1] = ('  %-20s %-8s r=%-6.1f %s  (%.1f, %.1f, %.1f)%s'):format(z.id,
                z.dynamic and 'in-game' or 'config', z.radius, z.preset or '-', z.x, z.y, z.z,
                z.bucket ~= 0 and (' bucket ' .. z.bucket) or '')
        end
    end
    printTo(src, lines)
    reply(src, T.listHeader:format(n))
end

sub.presets = function(src)
    local names = {}
    for name in pairs(Config.Presets or {}) do names[#names + 1] = name end
    table.sort(names)
    printTo(src, { '[NX_safezones] presets: ' .. table.concat(names, ', ') })
    reply(src, table.concat(names, ', '))
end

sub.coords = function(src)
    local pos = position(src)
    if not pos then return reply(src, T.noPosition, 'error') end
    local v = ('vec3(%.1f, %.1f, %.1f)'):format(pos.x, pos.y, pos.z)
    printTo(src, { ('center = %s,'):format(v) })
    reply(src, T.coords:format(v))
end

sub.show = function(src)
    if src == 0 then return reply(src, T.noPosition, 'error') end
    TriggerClientEvent('NX_safezones:show', src)
end

sub.info = function(src)
    if src == 0 then return sub.list(src) end
    TriggerClientEvent('NX_safezones:info', src)
end

local HELP = {
    '[NX_safezones] /safezone                         your zones and exceptions',
    '  /safezone add <name> <radius> [preset] [label]  new zone where you stand',
    '  /safezone move <name>                           move it to where you stand',
    '  /safezone radius <name> <radius>',
    '  /safezone label <name> <text>',
    '  /safezone remove <name>',
    '  /safezone list | presets | show | coords',
    '  config zones can only be changed in shared/config.lua',
}

sub.help = function(src)
    printTo(src, HELP)
    reply(src, T.help)
end

local EDIT = { add = true, move = true, radius = true, label = true, remove = true }

RegisterCommand('safezone', function(source, args)
    local src = tonumber(source) or 0
    local name = (args[1] or 'info'):lower()
    local fn = sub[name]
    if not fn then return sub.help(src) end
    if EDIT[name] and not ED.enabled then return reply(src, T.editorOff, 'error') end
    fn(src, args)
end, true)

-- startup ---------------------------------------------------------------------

loadDynamic()
rebuild()

NXZ.server = {
    get = function() return zones, grid, cell end,
    perms = perms, recalc = recalc, sweep = sweep, resync = resync, onWeaponDamage = onWeaponDamage,
    playerDamageAllowed = playerDamageAllowed, can = can, dynamic = function() return dynamic end,
    version = function() return version end,
}

CreateThread(function()
    resync()
    local nextResync = GetGameTimer() + 30000
    while true do
        Wait(CS.tick)
        local now = GetGameTimer()
        if now >= nextResync then
            resync()
            nextResync = now + 30000
        end
        sweep(now)
    end
end)

CreateThread(function()
    local valid = 0
    for _, z in ipairs(zones) do if not z.invalid then valid = valid + 1 end end
    FW.init()
    log('%d active zone(s), %d made in game', valid, #dynamic)
    FW.onReady()   -- covers a restart with players already online
end)
