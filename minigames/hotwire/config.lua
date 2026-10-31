Config.hotwire = {
    enabled = true,

    command = 'hotwire',
    key = 'G',

    item = 'wire_strippers', -- false for none
    breakChance = 0.35,

    devMode = false, -- admin tools; keep it off on a live server

    vehicleTypes = { automobile = true, bike = true },
    excludeModels = { 'oppressor', 'oppressor2' },
    maxStrikes = 3,
    timeLimit = 240, -- seconds
    minTime = 10, -- seconds; faster is rejected as cheating
    minBikeTime = 8, -- seconds, the same on a bike
    minRewireTime = 5, -- seconds, when the cover is already off
    minReconnectTime = 3, -- seconds, when the car was hotwired before

    giveKeys = false, -- turn on with any keys script other than zyke_vehiclekeys

    screws = {
        turns = 4,
        maxSpeed = 3.5, -- turns per second
    },
    strip = {
        maxSpeed = 0.05, -- metres per second
    },
    crank = {
        earliest = 900, -- ms
        latest = 2200, -- ms
        window = 800, -- ms
    },

    alarmTime = 30, -- seconds
    shockDamage = 8,

    rig = { offset = vec3(0.0, 0.03, -0.08), pitch = -18.0 }, -- tune with /hotwire_rig

    classFits = { -- by vehicle class
        [9] = { offset = vec3(0.0, 0.0, -0.13), pitch = -24.0 },
        [10] = { offset = vec3(0.0, 0.0, -0.13), pitch = -24.0 },
        [11] = { offset = vec3(0.0, 0.0, -0.13), pitch = -24.0 },
        [12] = { offset = vec3(0.0, 0.0, -0.13), pitch = -24.0 },
        [17] = { offset = vec3(0.0, 0.0, -0.13), pitch = -24.0 },
        [20] = { offset = vec3(0.0, 0.0, -0.13), pitch = -24.0 },
    },

    vehicleFits = { -- by model; /hotwire_rig prints these lines
        -- ['sultan'] = { offset = vec3(0.0, 0.01, -0.09), pitch = -20.0 },
    },

    bikeFits = {}, -- by model, over the measured fits in bikes.lua; /hotwire_rig and /hotwire_cam print these lines

    camera = {
        pos = vec3(0.02, -0.17, -0.30), target = vec3(0.0, 0.10, -0.07),
        wiresPos = vec3(0.03, -0.36, -0.21), wiresTarget = vec3(0.0, 0.08, -0.15),
        fov = 46.0,
    },

    sparks = { asset = 'core', name = 'ent_sht_electrical_box', scale = 0.12 },
}
