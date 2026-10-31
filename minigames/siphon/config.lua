Config.siphon = {
    enabled = true,

    command = 'siphon',
    target = true,

    item = 'siphon_hose', -- false for none
    can = { item = 'WEAPON_PETROLCAN', litres = 20 },

    devMode = false, -- admin tools; keep it off on a live server

    vehicleFits = {}, -- by model: { x, y, z, pitch, yaw }; fits.json wins over these

    vehicleTypes = { automobile = true },
    blockedClasses = { [8] = true, [13] = true, [14] = true, [15] = true, [16] = true, [21] = true },
    reach = 4.0,

    tankLitres = 60,
    classTank = { [0] = 45, [1] = 60, [2] = 80, [3] = 55, [4] = 70, [5] = 55, [6] = 65, [7] = 75, [9] = 85, [10] = 120,
        [11] = 80, [12] = 90, [17] = 90, [18] = 75, [19] = 120, [20] = 150 },
    reserve = 5, -- percent left in the tank

    minSetupTime = 8, -- seconds; faster is refused

    puffs = { 3, 5 },
    maxStrikes = 3,
    minPuffTime = 1.5, -- seconds

    flowRate = 0.25, -- litres per second
    puddles = true,
    timeLimit = 480, -- seconds
    cooldown = 20, -- seconds
    carCooldown = 120, -- seconds

    camera = { pos = vec3(-0.95, -1.35, 0.30), target = vec3(-0.12, -0.25, -0.30), fov = 50.0 }, -- tune with /siphon_cam
}
