local SOUNDS = {
    'tick', 'screw_out', 'slip', 'cover', 'click', 'snip', 'nick', 'relay', 'arc', 'burn', 'sputter',
    'lp_insert', 'lp_lever', 'lp_tension', 'lp_detent', 'lp_spring', 'lp_set', 'lp_overset', 'lp_drop',
    'lp_bend', 'lp_snap', 'lp_unlock', 'lp_remove', 'lp_shutter', 'lp_bike_insert', 'lp_bike_unlock',
    'bike_pop', 'bike_snap', 'bike_button', 'bike_sputter',
    'sf_can_down', 'sf_can_up', 'sf_cap_thread', 'sf_cap_off', 'sf_cap_dangle', 'sf_cap_on', 'sf_cap_tap',
    'sf_ratchet', 'sf_flap', 'sf_bump', 'sf_plop', 'sf_inhale', 'sf_cough', 'sf_drip', 'sf_hose_grab',
    'sf_hose_in', 'sf_hose_out', 'sf_hose_drop', 'sf_funnel_grab', 'sf_funnel_in', 'sf_funnel_out',
    'sf_funnel_down',

    -- Loops, with the params they take
    'buzz',      -- { pattern = 'steady' | 'pulse' | 'flicker' | 'dim' }
    'crank', 'bike_crank',
    'lp_scrape', -- { level }
    'sf_blow', 'sf_gurgle', 'sf_spill', 'sf_feed', -- { level }
    'sf_pour',   -- { fill, level }
}

local list = {}
for _, name in ipairs(SOUNDS) do list[name] = { custom = true } end
TR.ui.sound.register(list)
