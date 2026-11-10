-- shared between client and server
-- zones keep their index from Config.Zones on both sides, broken ones stay as
-- placeholders so the indices never shift

NXZ = {}

NXZ.ACTIONS = { 'weapons', 'aim', 'shoot', 'melee', 'playerDamage', 'vehicleDamage', 'explosions' }

local IS_ACTION = {}
for _, a in ipairs(NXZ.ACTIONS) do IS_ACTION[a] = true end
NXZ.IS_ACTION = IS_ACTION

local floor, abs, sqrt = math.floor, math.abs, math.sqrt

-- integer cell keys, avoids building strings on every lookup
local KEY = 1048576

local function warn(msg, ...)
    print(('^3[NX_safezones]^7 ' .. msg):format(...))
end
NXZ.warn = warn

local function number(v)
    v = tonumber(v)
    if v and v == v and v ~= math.huge and v ~= -math.huge then return v + 0.0 end
end

local function actionSet(list, where)
    local set = {}
    if type(list) ~= 'table' then return set end
    for _, a in ipairs(list) do
        if IS_ACTION[a] then
            set[a] = true
        else
            warn('unknown action "%s" in %s, skipped', tostring(a), where)
        end
    end
    return set
end

local function normalizeRule(r, where)
    if type(r) ~= 'table' then return nil end
    local grade = r.grade ~= nil and tonumber(r.grade) or 0
    if not grade then
        warn('grade is not a number in %s, rule skipped', where)
        return nil
    end
    local duty = r.duty
    if duty == nil then duty = Config.RequireDuty == true end
    return {
        grade = floor(grade),
        exact = r.exact == true,
        duty = duty == true,
        allow = actionSet(r.allow, where),
    }
end

local function normalizePermissions(p, name)
    local out = { target = 'authorized', jobs = {}, ace = {}, any = false }
    if type(p) ~= 'table' then return out end
    if p.target == 'anyone' then out.target = 'anyone' end

    if type(p.jobs) == 'table' then
        for job, rules in pairs(p.jobs) do
            if type(job) == 'string' and type(rules) == 'table' then
                -- accept a single rule or a list of them
                local list = rules[1] ~= nil and rules or { rules }
                local norm = {}
                for i, r in ipairs(list) do
                    norm[#norm + 1] = normalizeRule(r, ('%s > jobs.%s[%d]'):format(name, job, i))
                end
                if #norm > 0 then
                    out.jobs[job] = norm
                    out.any = true
                end
            end
        end
    end

    if type(p.ace) == 'table' then
        for ace, r in pairs(p.ace) do
            if type(ace) == 'string' and ace ~= '' then
                local rule = normalizeRule(type(r) == 'table' and r or {}, ('%s > ace.%s'):format(name, ace))
                if rule then
                    out.ace[#out.ace + 1] = { ace = ace, allow = rule.allow }
                    out.any = true
                end
            end
        end
        table.sort(out.ace, function(a, b) return a.ace < b.ace end)
    end
    return out
end

local function color(c)
    c = type(c) == 'table' and c or {}
    return { tonumber(c[1]) or 124, tonumber(c[2]) or 58, tonumber(c[3]) or 237, tonumber(c[4]) or 45 }
end

-- returns zones, grid, cell size and the near map
--   grid[key] = zones touching that cell
--   near[key] = { edge = closest distance from the cell to a zone edge, shows = zones with a drawn boundary }
-- no near entry means the cell is further than `margin` from every zone
-- `extra` is the list of zones created in game, appended after Config.Zones
function NXZ.load(cfg, margin, extra)
    local zones, grid, near = {}, {}, {}
    local cell = number(cfg.GridSize) or 250.0
    margin = number(margin) or 0.0

    -- config zones first, then the ones made in game, always in that order
    local defs = {}
    for _, z in ipairs(cfg.Zones or {}) do defs[#defs + 1] = z end
    for _, z in ipairs(extra or {}) do defs[#defs + 1] = z end
    local seen = {}

    for idx, z in ipairs(defs) do
        local name = type(z) == 'table' and (z.id or z.label) or ('#' .. idx)
        local zone = { idx = idx, invalid = true }
        zones[idx] = zone

        -- a preset fills in whatever the zone leaves out
        local base = type(z) == 'table' and z.preset and cfg.Presets and cfg.Presets[z.preset]
        if type(z) == 'table' and z.preset and not base then
            warn('zone %s uses unknown preset "%s"', tostring(name), tostring(z.preset))
        end
        local function get(k)
            if z[k] ~= nil then return z[k] end
            return base and base[k]
        end

        local c = type(z) == 'table' and z.center
        local x = c and number(c.x)
        local y = c and number(c.y)
        local zc = c and number(c.z)
        local radius = type(z) == 'table' and number(z.radius)
        local id = type(z) == 'table' and tostring(z.id or idx)

        if type(z) ~= 'table' or z.enabled == false then
            -- disabled
        elseif seen[id] then
            warn('zone id "%s" is used twice, the second one is skipped', id)
        elseif not (x and y and zc) then
            warn('zone %s has no valid center, skipped', tostring(name))
        elseif not radius or radius <= 0 then
            warn('zone %s has no valid radius, skipped', tostring(name))
        else
            seen[id] = true
            local block = {}
            local rules = type(get('block')) == 'table' and get('block') or {}
            for _, a in ipairs(NXZ.ACTIONS) do
                local v = rules[a]
                if v == nil then v = cfg.DefaultRules and cfg.DefaultRules[a] end
                block[a] = v == true
            end

            local map = type(get('map')) == 'table' and get('map') or {}
            local boundary = type(get('boundary')) == 'table' and get('boundary') or {}
            local mode = get('weaponMode') or cfg.WeaponMode

            zone.invalid = nil
            zone.id = id
            zone.label = tostring(z.label or z.id or ('zone ' .. idx))
            zone.dynamic = z.dynamic == true
            zone.preset = z.preset
            zone.x, zone.y, zone.z = x, y, zc
            zone.radius, zone.r2 = radius, radius * radius
            zone.height = number(get('height')) or number(cfg.DefaultHeight) or 25.0
            zone.bucket = floor(tonumber(z.bucket) or 0)
            zone.priority = tonumber(get('priority')) or 0
            zone.block = block
            zone.weaponMode = (mode == 'block') and 'block' or 'holster'
            zone.invincibleVehicle = get('invincibleVehicle') == true
            zone.permissions = normalizePermissions(get('permissions'), zone.id)
            zone.notify = get('notify') ~= false
            zone.map = {
                blip = map.blip == true,
                radius = map.radius == true,
                sprite = tonumber(map.sprite) or 61,
                color = tonumber(map.color) or 27,
            }
            zone.boundary = {
                show = boundary.show == true,
                distance = number(boundary.distance) or 80.0,
                height = number(boundary.height) or 1.5,
                color = color(boundary.color),
            }
            zone.boundary.d2 = (zone.boundary.distance + radius) ^ 2

            for cx = floor((x - radius) / cell), floor((x + radius) / cell) do
                for cy = floor((y - radius) / cell), floor((y + radius) / cell) do
                    local k = cx * KEY + cy
                    local list = grid[k]
                    if not list then list = {}; grid[k] = list end
                    list[#list + 1] = zone
                end
            end

            -- distance from each nearby cell to this zone, worked out once here
            -- so the runtime only needs a table read
            -- a drawn boundary may reach further than the margin
            local m = margin
            if zone.boundary.show and zone.boundary.distance > m then m = zone.boundary.distance end
            local reach = radius + m
            for cx = floor((x - reach) / cell), floor((x + reach) / cell) do
                for cy = floor((y - reach) / cell), floor((y + reach) / cell) do
                    local x0, y0 = cx * cell, cy * cell
                    local dx = (x < x0 and x0 - x) or (x > x0 + cell and x - x0 - cell) or 0.0
                    local dy = (y < y0 and y0 - y) or (y > y0 + cell and y - y0 - cell) or 0.0
                    local edge = sqrt(dx * dx + dy * dy) - radius
                    if edge < 0.0 then edge = 0.0 end
                    if edge <= m then
                        local k = cx * KEY + cy
                        local nr = near[k]
                        if not nr then nr = { edge = edge }; near[k] = nr end
                        if edge < nr.edge then nr.edge = edge end
                        if zone.boundary.show then
                            nr.shows = nr.shows or {}
                            nr.shows[#nr.shows + 1] = zone
                        end
                    end
                end
            end
        end
    end

    return zones, grid, cell, near
end

function NXZ.key(cell, x, y)
    return floor(x / cell) * KEY + floor(y / cell)
end

function NXZ.candidates(grid, cell, x, y)
    return grid[floor(x / cell) * KEY + floor(y / cell)]
end

function NXZ.inside(z, x, y, zc)
    local dx, dy = x - z.x, y - z.y
    return dx * dx + dy * dy <= z.r2 and abs(zc - z.z) <= z.height
end

-- fills `out` with the zones at this point, returns the count
-- `out` gets reused so nothing is allocated
function NXZ.zonesAt(grid, cell, x, y, zc, bucket, out)
    local n = 0
    local list = grid[floor(x / cell) * KEY + floor(y / cell)]
    if list then
        for i = 1, #list do
            local z = list[i]
            local dx, dy = x - z.x, y - z.y
            if dx * dx + dy * dy <= z.r2 and z.bucket == bucket and abs(zc - z.z) <= z.height then
                n = n + 1
                out[n] = z
            end
        end
    end
    for i = n + 1, #out do out[i] = nil end
    return n
end

-- what a player can do in one zone
-- data = { job, grade, duty } from the framework, or nil
-- returns the allowed actions and whether any exception matched at all
function NXZ.resolve(zone, data, hasAce)
    local caps, authorized = {}, false
    local p = zone.permissions
    if not p or not p.any then return caps, false end

    if type(data) == 'table' and type(data.job) == 'string' and type(data.grade) == 'number' then
        local rules = p.jobs[data.job]
        if rules then
            for _, r in ipairs(rules) do
                local gradeOk
                if r.exact then gradeOk = data.grade == r.grade else gradeOk = data.grade >= r.grade end
                if gradeOk and (not r.duty or data.duty == true) then
                    authorized = true
                    for a in pairs(r.allow) do caps[a] = true end
                end
            end
        end
    end

    if hasAce then
        for _, e in ipairs(p.ace) do
            if hasAce(e.ace) then
                authorized = true
                for a in pairs(e.allow) do caps[a] = true end
            end
        end
    end
    return caps, authorized
end

-- every active zone has to allow it, the strictest one wins
function NXZ.allowed(active, n, caps, action)
    for i = 1, n do
        local z = active[i]
        if z.block[action] then
            local c = caps and caps[z.idx]
            if not (c and c[action]) then return false end
        end
    end
    return true
end
