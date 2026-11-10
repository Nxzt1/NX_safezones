Config = {}

-- 'auto', 'qbx', 'qb', 'esx' or 'standalone'
-- auto checks qbx_core, qb-core, es_extended in that order (qbx provides qb-core, so it goes first)
Config.Framework = 'auto'

Config.Debug = false

-- 'en' or 'es', see Config.Locales below
Config.Locale = 'en'

-- 'auto' uses ox_lib if it's running, otherwise the GTA feed
-- 'ox_lib', 'native' or false to turn them off
Config.Notify = 'auto'

-- 'holster' puts the weapon away (never removed), 'block' keeps it in hand but can't aim/shoot
-- zones can override this with weaponMode
Config.WeaponMode = 'holster'

-- job exceptions need the player on duty unless the rule says duty = false
Config.RequireDuty = true

-- used for any rule a zone leaves out
Config.DefaultRules = {
    weapons       = true,
    aim           = true,
    shoot         = true,
    melee         = true,
    playerDamage  = true,
    vehicleDamage = false,
    explosions    = true,
}

Config.DefaultHeight = 25.0   -- metres above and below the center
Config.GridSize = 250.0       -- lookup grid cell size, no need to touch it

-- client check intervals (ms)
Config.Client = {
    far          = 2000,
    near         = 500,
    edge         = 200,    -- closer than 30 m to a zone
    insideCheck  = 200,
    nearDistance = 150.0,  -- metres
}

-- server checks each player on its own timer: every `interval` near a zone,
-- up to `farInterval` when far away. damage checks don't wait for this.
Config.Server = {
    tick        = 250,
    interval    = 1000,
    farInterval = 4000,
    farDistance = 400.0,
    maxSpeed    = 100.0,   -- m/s, used to guess how soon a far player can reach a zone
    recalcMs    = 1500,    -- min time between permission refreshes of one player
}

-- in-game editor (/safezone add, move, radius, remove...)
-- only players allowed to use the command see it: add_ace group.admin command.safezone allow
Config.Editor = {
    enabled       = true,
    file          = 'data/zones.json',   -- inside this resource
    maxZones      = 100,
    minRadius     = 2.0,
    maxRadius     = 500.0,
    defaultPreset = 'default',
}

-- presets hold everything except position and size. zones made in game pick
-- one, config zones can use one too with preset = 'name' and override fields.
Config.Presets = {
    default = {
        block = {
            weapons = true, aim = true, shoot = true, melee = true,
            playerDamage = true, vehicleDamage = false, explosions = true,
        },
        permissions = { jobs = {}, ace = {} },
    },

    hospital = {
        block = {
            weapons = true, aim = true, shoot = true, melee = true,
            playerDamage = true, vehicleDamage = false, explosions = true,
        },
        permissions = {
            target = 'authorized',
            jobs = {
                police    = { grade = 3, allow = { 'weapons', 'aim', 'shoot', 'playerDamage' } },
                ambulance = { grade = 2, allow = { 'weapons' } },
            },
            ace = {},
        },
    },

    public = {
        block = {
            weapons = true, aim = true, shoot = true, melee = true,
            playerDamage = true, vehicleDamage = true, explosions = true,
        },
        weaponMode = 'block',
        permissions = {
            jobs = { police = { grade = 1, allow = { 'weapons', 'aim' } } },
            ace = {},
        },
        map = { blip = true, radius = true, sprite = 487, color = 2 },
    },
}

Config.Locales = {
    en = {
        title     = 'Safe zone',
        enter     = 'You entered %s.',
        leave     = 'You left %s.',
        noWeapons = 'You cannot use weapons here.',
        none      = 'You are not in any safe zone.',
        inside    = 'Inside %d zone(s). Details in F8.',
        coords    = '%s (also printed in F8)',

        help        = 'Usage: /safezone [add|move|radius|label|remove|list|presets|show|coords]. Details in F8.',
        added       = 'Zone %s created (%.1f m, preset %s).',
        moved       = 'Zone %s moved to your position.',
        resized     = 'Zone %s radius set to %.1f m.',
        relabeled   = 'Zone %s renamed to "%s".',
        removed     = 'Zone %s removed.',
        notFound    = 'There is no zone made in game called %s.',
        configZone  = '%s comes from the config file, edit it there.',
        badId       = 'Use letters, numbers, - or _ for the name (max 32).',
        idTaken     = 'A zone called %s already exists.',
        badRadius   = 'Radius has to be between %.0f and %.0f.',
        badPreset   = 'Unknown preset %s. Use /safezone presets.',
        tooMany     = 'Limit of %d zones made in game reached.',
        noPosition  = 'This needs a player position, use it in game.',
        saveFailed  = 'Could not save the zones file, check the server console.',
        editorOff   = 'The in-game editor is turned off in the config.',
        showOn      = 'Showing every zone around you.',
        showOff     = 'Zone view off.',
        listHeader  = '%d zone(s), list in F8.',
    },
    es = {
        title     = 'Zona segura',
        enter     = 'Has entrado en %s.',
        leave     = 'Has salido de %s.',
        noWeapons = 'Aquí no puedes usar armas.',
        none      = 'No estás en ninguna zona segura.',
        inside    = 'Dentro de %d zona(s). Detalle en F8.',
        coords    = '%s (también en F8)',

        help        = 'Uso: /safezone [add|move|radius|label|remove|list|presets|show|coords]. Detalle en F8.',
        added       = 'Zona %s creada (%.1f m, plantilla %s).',
        moved       = 'Zona %s movida a tu posición.',
        resized     = 'Radio de %s cambiado a %.1f m.',
        relabeled   = 'Zona %s renombrada a "%s".',
        removed     = 'Zona %s borrada.',
        notFound    = 'No hay ninguna zona creada en el juego llamada %s.',
        configZone  = '%s viene del archivo de config, cámbiala allí.',
        badId       = 'Usa letras, números, - o _ para el nombre (máx. 32).',
        idTaken     = 'Ya existe una zona llamada %s.',
        badRadius   = 'El radio tiene que estar entre %.0f y %.0f.',
        badPreset   = 'Plantilla %s desconocida. Usa /safezone presets.',
        tooMany     = 'Límite de %d zonas creadas en el juego alcanzado.',
        noPosition  = 'Esto necesita la posición de un jugador, úsalo en el juego.',
        saveFailed  = 'No se pudo guardar el archivo de zonas, mira la consola del servidor.',
        editorOff   = 'El editor del juego está desactivado en el config.',
        showOn      = 'Mostrando todas las zonas a tu alrededor.',
        showOff     = 'Vista de zonas desactivada.',
        listHeader  = '%d zona(s), lista en F8.',
    },
}

--[[
  Actions (same names in `block` and `allow`):
    weapons, aim, shoot, melee, playerDamage, vehicleDamage, explosions

  permissions = {
      target = 'authorized',   -- or 'anyone': who an exempt player is allowed to hurt
      jobs = {
          police = { grade = 3, allow = { 'weapons', 'aim' } },        -- grade 3 and up
          ambulance = {                                                -- several rules add up
              { grade = 2, allow = { 'weapons' } },
              { grade = 4, exact = true, duty = false, allow = { 'aim' } },
          },
      },
      ace = {
          ['nx.safezones.staff'] = { allow = { 'weapons', 'aim', 'shoot' } },
      },
  }

  Get coords in game with /safezone coords. Use decimals (307.0, not 307).
  The zones below are examples, the coords are rough.
]]

Config.Zones = {
    {
        id = 'pillbox',
        label = 'Pillbox Hospital',
        enabled = true,
        center = vec3(307.0, -590.0, 43.3),
        radius = 55.0,
        height = 20.0,
        bucket = 0,
        priority = 10,   -- only decides which name shows when zones overlap

        -- rules and permissions come from Config.Presets.hospital,
        -- anything written here (block, permissions...) overrides the preset
        preset = 'hospital',

        -- driver's vehicle takes no damage at all inside (client side, ignores exceptions)
        invincibleVehicle = false,

        map      = { blip = false, radius = false, sprite = 61, color = 27 },
        boundary = { show = false, distance = 90.0, height = 1.5, color = { 124, 58, 237, 45 } },  -- draws every frame when on
        notify   = true,
    },

    {
        id = 'legion',
        label = 'Legion Square',
        enabled = false,
        center = vec3(195.0, -934.0, 30.7),
        radius = 70.0,

        block = {
            weapons = true, aim = true, shoot = true, melee = true,
            playerDamage = true, vehicleDamage = true, explosions = true,
        },
        weaponMode = 'block',

        permissions = {
            jobs = {
                police = { grade = 1, allow = { 'weapons', 'aim' } },
            },
            ace = {
                ['nx.safezones.staff'] = { allow = { 'weapons', 'aim', 'shoot', 'playerDamage' } },
            },
        },

        map      = { blip = true, radius = true, sprite = 487, color = 2 },
        boundary = { show = false },
        notify   = true,
    },
}
