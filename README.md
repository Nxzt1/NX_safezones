# nx_safezones

Safe zones for FiveM with per-job, per-grade and ACE exceptions.
Works on Qbox, QBCore, ESX Legacy or with no framework at all.

0.00 ms on resmon in normal play, no NUI, no SQL, no dependencies.

## Features

- Any number of zones (circle + height), overlapping is fine
- Block weapons, aiming, shooting, melee, player damage, vehicle damage and explosions, each one separately per zone
- Exceptions by job + minimum or exact grade, optional on-duty check, or by ACE
- Exceptions only give back what you list, e.g. police can aim but still can't shoot
- Weapons get holstered, never removed. Or set `weaponMode = 'block'` to keep them in hand but useless
- Create, move, resize and remove zones in game, no restart needed
- Presets, so in-game zones get full rules and job permissions from one name
- Staff-only command, players without permission don't even see it in chat
- Damage is cancelled server side, so the client can't just skip it
- Optional blip, map radius and ground ring per zone
- ox_lib notifications if you have it, GTA feed if you don't
- English and Spanish messages

## Installation

1. Drop the folder in your resources, for example `resources/[standalone]/NX_safezones`
2. Edit `shared/config.lua`
3. Add it to your `server.cfg` after your framework and ox_lib:

```cfg
ensure ox_lib          # optional
ensure qbx_core        # or qb-core / es_extended, also optional
ensure NX_safezones
```

OneSync has to be on.

Give your staff the command (admins with `command allow` already have it):

```cfg
add_ace group.admin command.safezone allow
add_ace group.mod command.safezone allow
```

## Config

Each zone looks like this:

```lua
{
    id = 'pillbox',
    label = 'Pillbox Hospital',
    center = vec3(307.0, -590.0, 43.3),
    radius = 55.0,
    height = 20.0,

    block = {
        weapons = true, aim = true, shoot = true, melee = true,
        playerDamage = true, vehicleDamage = false, explosions = true,
    },

    permissions = {
        target = 'authorized',
        jobs = {
            police = { grade = 3, allow = { 'weapons', 'aim', 'shoot', 'playerDamage' } },
        },
        ace = {},
    },
}
```

The example zones that come with the resource use rough coords. Stand where you want the center and run `/safezone coords` to get yours. Use decimals (`307.0`, not `307`).

### Permissions

```lua
permissions = {
    target = 'authorized',   -- 'anyone' lets exempt players hurt anyone, not just other exempt players
    jobs = {
        police = { grade = 3, allow = { 'weapons', 'aim' } },             -- grade 3 and up
        ambulance = {                                                     -- several rules add up
            { grade = 2, allow = { 'weapons' } },
            { grade = 4, exact = true, duty = false, allow = { 'aim' } }, -- only grade 4, on or off duty
        },
    },
    ace = {
        ['nx.safezones.staff'] = { allow = { 'weapons', 'aim', 'shoot' } },
    },
}
```

```cfg
add_ace group.admin nx.safezones.staff allow
```

Actions: `weapons`, `aim`, `shoot`, `melee`, `playerDamage`, `vehicleDamage`, `explosions`.

Anyone without a matching exception gets the full zone. That includes unknown jobs, players with no character loaded, and everyone when the framework isn't running. ACE exceptions always work.

When zones overlap, an action is allowed only if every zone you're in allows it.

### Framework

```lua
Config.Framework = 'auto'   -- 'qbx', 'qb', 'esx' or 'standalone'
```

`auto` looks for qbx_core, then qb-core, then es_extended. If you force one and it isn't started, you get a warning and only ACE exceptions work. It hooks in by itself once the framework starts. In standalone mode only the `ace` rules count.

| Framework | Job | Grade | Duty |
|---|---|---|---|
| Qbox | `PlayerData.job.name` | `job.grade.level` | `job.onduty` |
| QBCore | `PlayerData.job.name` | `job.grade.level` | `job.onduty` |
| ESX | `getJob().name` | `job.grade` | `job.onDuty`, if your version has it |

On ESX versions without `onDuty`, having the job counts as on duty. If you use off-duty jobs like `offpolice`, just leave them out of the config.

Permissions refresh on job change, duty change, character load/unload, entering a zone and routing bucket change.

### Presets

Presets hold the rules and permissions, everything except position and size. Zones made in game pick one, config zones can use one too and override any field:

```lua
Config.Presets = {
    hospital = {
        block = { weapons = true, aim = true, shoot = true, melee = true, playerDamage = true },
        permissions = {
            jobs = { police = { grade = 3, allow = { 'weapons', 'aim', 'shoot', 'playerDamage' } } },
        },
    },
}

-- in Config.Zones
{ id = 'pillbox', center = vec3(307.0, -590.0, 43.3), radius = 55.0, preset = 'hospital' }
```

## In-game editor

Stand where you want the zone and run:

```
/safezone add sandy_med 40 hospital Sandy Medical
```

That creates a 40 m zone called `sandy_med` with the `hospital` preset. It applies to everyone right away and the zone ring is drawn for you for a few seconds so you can see where it landed.

Zones made in game are saved to `data/zones.json` inside the resource and loaded on start, no database needed. Zones from `shared/config.lua` can't be changed in game, edit them in the file.

Settings live in `Config.Editor` (on/off, file, max zones, radius limits, default preset).

## Commands

All of them need the `command.safezone` ACE. Players without it don't get the chat suggestion and can't run it.

| Command | What it does |
|---|---|
| `/safezone` | The zones you're in, your exceptions and whether the per-frame loop is running (F8) |
| `/safezone add <name> <radius> [preset] [label]` | New zone where you stand |
| `/safezone move <name>` | Move a zone to where you stand |
| `/safezone radius <name> <radius>` | Change the size |
| `/safezone label <name> <text>` | Change the name shown in notifications and on the map |
| `/safezone remove <name>` | Delete a zone made in game |
| `/safezone list` | Every zone with its type, size and position (F8) |
| `/safezone presets` | Available presets |
| `/safezone show` | Toggle drawing every zone around you |
| `/safezone coords` | Prints your position ready to paste as `center` |

`list`, `remove`, `radius` and `label` also work from the server console.

## Performance

There is no per-frame loop in normal play. The client checks your position every 2 s when far, faster when close, and every 0.2 s inside a zone. It only runs every frame when you hold a weapon the zone won't let you use, sit in an armed vehicle, or have a ground ring turned on.

The server checks each player on their own timer depending on how far they are from a zone. With 128 players and 500 zones that came out at around 0.005 ms per server frame in testing. Damage checks take about 1 µs each.

## What it can't stop

- Running people over, crashes, falls, fire spreading and other environment damage are mostly worked out on the victim's own game, so the server can't always see or cancel them. `invincibleVehicle = true` makes the driver's car invincible inside a zone if you need that.
- Damage between an NPC and the player who owns it never hits the network.
- Explosions attached to an entity can report a position relative to it, so they might not count as inside.
- A modded client can ignore its own control blocks. Damage it deals to other players still goes through the server.
- When a script equips a weapon, up to 200 ms can pass before it gets holstered. The server still blocks any damage in that window.

## Troubleshooting

- **Nobody gets their exception:** check the console line saying which framework was picked, and the `duty` setting.
- **ACE not working:** the name must match your `add_ace` line exactly, and the player has to be in that group.
- **Zone doesn't trigger:** check `height` (25 m up and down by default) and `bucket` (0 by default).
- **"Could not save the zones file":** the server needs write access to the resource folder, and the `data` folder has to exist.
- **Command not showing up:** you need `command.safezone`, then reconnect so the chat refreshes its suggestions.
- **Weapon keeps coming back:** another script is equipping it again. Try `weaponMode = 'block'`.

## License

MIT, see [LICENSE](LICENSE).

Made by Nxsty.
