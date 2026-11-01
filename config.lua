Config = {
    volume = 0.8, -- 0..1

    mirror = {
        range = 30.0, -- metres nearby players see the props
        soundRange = 12.0, -- metres
        rate = 100, -- ms between updates
    },

    police = {
        jobs = { 'police' },
        alerts = { -- chance: percent, radius: metres, time: minutes, cooldown: seconds per car
            lockpickAlarm = { enabled = true, chance = 100, code = '10-16', priority = 'medium', radius = 20.0, time = 5, cooldown = 60 },
            hotwireAlarm = { enabled = true, chance = 100, code = '10-16', priority = 'medium', radius = 20.0, time = 5, cooldown = 60 },
            hotwired = { enabled = true, chance = 25, code = '10-16', priority = 'high', radius = 30.0, time = 5, cooldown = 60 },
            siphoned = { enabled = true, chance = 20, code = '10-31', priority = 'low', radius = 30.0, time = 5, cooldown = 120 },
        },
    },
}
