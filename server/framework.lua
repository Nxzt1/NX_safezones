-- framework bridge
-- all we need is { job, grade, duty } for a player and a ping when it changes
--
--   qbx  exports.qbx_core:GetPlayer(src).PlayerData.job          name, grade.level, onduty
--   qb   QBCore.Functions.GetPlayer(src).PlayerData.job          name, grade.level, onduty
--   esx  ESX.GetPlayerFromId(src).getJob()                       name, grade, onDuty (newer versions only)
--
-- if the configured framework isn't running we don't fall back to another one,
-- job exceptions are just off until it starts (ace still works)

FW = { name = 'standalone', ready = false }

local RESOURCE = { qbx = 'qbx_core', qb = 'qb-core', esx = 'es_extended' }
local AUTO_ORDER = { 'qbx', 'qb', 'esx' }

local QBCore, ESX
local onChange

local function log(msg, ...)
    print(('^5[NX_safezones]^7 ' .. msg):format(...))
end

local function started(res)
    return GetResourceState(res) == 'started'
end

local function bind(name)
    local ok, err = pcall(function()
        if name == 'qb' then
            QBCore = exports['qb-core']:GetCoreObject()
            assert(QBCore and QBCore.Functions, 'GetCoreObject returned nothing useful')
        elseif name == 'esx' then
            local okExp, obj = pcall(function() return exports.es_extended:getSharedObject() end)
            if okExp and obj then
                ESX = obj
            else
                -- pre 1.9 esx
                TriggerEvent('esx:getSharedObject', function(o) ESX = o end)
            end
            assert(ESX and ESX.GetPlayerFromId, 'could not get the ESX object')
        end
    end)
    if not ok then
        log('^1failed to hook into %s: %s, running with ace only^7', RESOURCE[name], tostring(err))
        FW.name, FW.ready = 'standalone', false
        return false
    end
    FW.name, FW.ready = name, true
    log('framework: %s (%s)', name, RESOURCE[name])
    return true
end

function FW.init()
    local wanted = Config.Framework or 'auto'
    QBCore, ESX = nil, nil
    FW.name, FW.ready = 'standalone', false

    if wanted == 'standalone' then
        log('standalone, ace exceptions only')
        return
    end

    if wanted == 'auto' then
        for _, n in ipairs(AUTO_ORDER) do
            if started(RESOURCE[n]) then return bind(n) end
        end
        log('no framework found, running standalone (will hook in if one starts later)')
        return
    end

    local res = RESOURCE[wanted]
    if not res then
        log('^1unknown Config.Framework "%s", running with ace only^7', tostring(wanted))
        return
    end
    if not started(res) then
        log('^1Config.Framework is "%s" but %s is not started, ace only until it does^7', wanted, res)
        return
    end
    bind(wanted)
end

function FW.data(src)
    if not FW.ready then return nil end
    local ok, res = pcall(function()
        if FW.name == 'qbx' or FW.name == 'qb' then
            local p
            if FW.name == 'qbx' then p = exports.qbx_core:GetPlayer(src) else p = QBCore.Functions.GetPlayer(src) end
            local job = p and p.PlayerData and p.PlayerData.job
            if not job then return nil end
            local grade = type(job.grade) == 'table' and job.grade.level or nil
            return { job = job.name, grade = tonumber(grade), duty = job.onduty == true }
        elseif FW.name == 'esx' then
            local x = ESX.GetPlayerFromId(src)
            if not x then return nil end
            local job = x.getJob and x.getJob() or x.job
            if not job then return nil end
            -- older esx has no duty field, treat having the job as on duty
            local duty = true
            if job.onDuty ~= nil then duty = job.onDuty == true end
            return { job = job.name, grade = tonumber(job.grade), duty = duty }
        end
    end)
    if not ok then
        if Config.Debug then log('error reading player %s: %s', src, tostring(res)) end
        return nil
    end
    if res and type(res.job) ~= 'string' then return nil end
    return res
end

-- framework events only tell us to re-read the player, the payload is ignored

-- logout events fire before the framework drops the player object, so those
-- are re-read a bit later or we'd keep the old job
local function notify(fw, src, later)
    if FW.name ~= fw or not onChange then return end
    src = tonumber(src)
    if not src or src <= 0 then return end
    if later then
        SetTimeout(500, function() onChange(src, true) end)
    else
        onChange(src, false)
    end
end

function FW.onChange(cb) onChange = cb end

for _, fw in ipairs({ 'qbx', 'qb' }) do
    AddEventHandler('QBCore:Server:OnJobUpdate', function(src) notify(fw, src) end)
    AddEventHandler('QBCore:Server:SetDuty', function(src) notify(fw, src) end)
    AddEventHandler('QBCore:Server:OnPlayerUnload', function(src) notify(fw, src, true) end)
    AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
        notify(fw, type(player) == 'table' and player.PlayerData and player.PlayerData.source)
    end)
end
AddEventHandler('qbx_core:server:playerLoggedOut', function(src) notify('qbx', src, true) end)

AddEventHandler('esx:setJob', function(src) notify('esx', src) end)
AddEventHandler('esx:playerLoaded', function(src) notify('esx', src) end)
AddEventHandler('esx:playerLogout', function(src) notify('esx', src, true) end)

AddEventHandler('onResourceStart', function(res)
    for n, r in pairs(RESOURCE) do
        if r == res and (Config.Framework == n or (Config.Framework == 'auto' and FW.name == 'standalone')) then
            SetTimeout(500, function()
                FW.init()
                if FW.onReady then FW.onReady() end
            end)
            return
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if FW.ready and RESOURCE[FW.name] == res then
        log('%s stopped, ace only for now', res)
        FW.name, FW.ready = 'standalone', false
        QBCore, ESX = nil, nil
        if FW.onReady then FW.onReady() end
    end
end)
