fx_version 'cerulean'
game 'gta5'

name 'kid_sea'
author 'you'
description 'Kid-friendly deep-sea longline fishing job with tablet + classic mode'
version '1.0.0'

lua54 'yes'

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js'
}

shared_script 'config.lua'

server_scripts {
    '@mysql-async/lib/MySQL.lua',
    'server/db.lua',
    'server/main.lua'
}

client_scripts {
    'client/main.lua'
}

dependencies {
    'mysql-async'
}
