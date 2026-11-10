fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'NX_safezones'
author 'Nxsty'
description 'Safe zones with job, grade and ACE exceptions. Qbox, QBCore, ESX or standalone.'
version '1.0.0'

-- no hard deps, frameworks and ox_lib are picked up at runtime

shared_scripts {
    'shared/config.lua',
    'shared/zones.lua'
}

client_script 'client/main.lua'

server_scripts {
    'server/framework.lua',
    'server/main.lua'
}
