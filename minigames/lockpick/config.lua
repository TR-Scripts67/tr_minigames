Config.lockpick = {
    enabled = true,

    command = 'lockpick',
    key = 'G',
    prompt = true,
    target = true,

    item = 'lishi_pick', -- false for none
    breakChance = 1.0,

    devMode = false, -- admin tools; keep it off on a live server

    vehicleTypes = { automobile = true, bike = true },
    doors = { 'dside_f' }, -- dside_f, pside_f, dside_r, pside_r
    excludeModels = { 'oppressor', 'oppressor2' },
    reach = 1.3,

    maxStrikes = 3,
    timeLimit = 180, -- seconds
    minTime = 6, -- seconds; faster is rejected as cheating
    jamTime = 120, -- seconds

    difficulty = { -- overset and speed in mm
        easy = { wafers = 4, overset = 1.0, speed = 3.2 },
        medium = { wafers = 5, overset = 0.8, speed = 2.8 },
        hard = { wafers = 6, overset = 0.6, speed = 2.4 },
        expert = { wafers = 7, overset = 0.45, speed = 2.0 },
    },
    defaultDifficulty = 'medium',
    classDifficulty = { -- by vehicle class
        [0] = 'easy', [1] = 'medium', [2] = 'medium', [3] = 'medium', [4] = 'easy', [5] = 'easy',
        [6] = 'hard', [7] = 'expert', [8] = 'easy', [9] = 'easy', [12] = 'easy', [18] = 'expert', [19] = 'expert',
    },
    modelDifficulty = { shotaro = 'hard', reever = 'hard', hakuchou2 = 'medium', vindicator = 'medium' }, -- before the class

    alarmTime = 30, -- seconds
    defaultAlarm = 0.2,
    classAlarm = { [0] = 0.05, [1] = 0.15, [4] = 0.1, [5] = 0.05, [6] = 0.45, [7] = 0.7, [8] = 0.05, [12] = 0.05, [18] = 1.0 },

    liftSensitivity = 1.0,

    rig = { back = -0.115, up = 0.0, out = 0.004 }, -- tune with /lockpick_rig
    followSurface = true, -- tilt the lock to sit flat on curved doors

    vehicleFits = { -- by model; /lockpick_rig prints these lines
        -- ['sultan'] = { back = 0.06, up = 0.01, out = 0.0 },
    },

    camera = { pos = vec3(-0.136, -0.269, 0.071), target = vec3(0.0, -0.045, 0.002), fov = 46.0 },

    torch = 0.6, -- 0 turns it off
}
