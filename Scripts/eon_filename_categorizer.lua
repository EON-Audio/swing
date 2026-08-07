-- eon_filename_categorizer.lua
-- Filename → drum/instrument category classifier.
--
-- Originally adapted from TouristKiller's tk_filename_categorizer.lua
-- (TK Media Browser). Used here under the same permissive intent — drop-in
-- pure-Lua module with no DAW coupling, no DSP, just keyword matching.
--
-- Usage:
--   local cat = categorizer.classify(filename, optional_folder_path)
--   local color = categorizer.get_category_color(cat)  -- 0xRRGGBBAA u32
--
-- Returns "other" + matched=false when no keyword fires. Folder name
-- contributes a smaller weight than filename so a "Kicks" folder bias
-- is preserved without overriding an explicit "snare.wav" inside it.

local categorizer = {}

local CATEGORY_KEYWORDS = {
    kick = {
        "kick", "kck", "kik", "kk", "bd", "bassdrum", "bass_drum", "bass drum",
        -- Compound 808/909 patterns only — bare "808" matched every TR-808
        -- file (claps, congas, cowbells, toms, rimshots) and pulled them
        -- all into kick by tie-break order. These compounds only fire
        -- when the filename actually says it's a kick from that drum
        -- machine.
        "808kick", "808 kick", "808bd", "909kick", "909bd", "909 kick"
    },
    snare = {
        "snare", "snr", "sd", "clap snare",
        "909snare", "909snr", "909 snare"
        -- "sn" removed — too short, false-matched any filename with
        -- "sn" anywhere ("kick basin", "lessons", etc.). "snare" / "snr"
        -- catch the real cases.
    },
    clap = {
        "clap", "clp", "handclap", "hand_clap", "hand clap"
    },
    -- Sidestick/cross-stick split from rimshot (different technique, sound
    -- and icon). CATEGORY_ORDER places sidestick BEFORE rimshot so explicit
    -- stick names win; bare "rim" still lands on rimshot.
    sidestick = {
        "sidestick", "side stick", "cross stick", "crosstick",
        "xstick", "x stick", "stick"  -- bare "stick" = stick hit, not a rim
    },
    rimshot = {
        "rimshot", "rim shot", "rim_shot", "rim"
    },
    -- Finger snaps promoted out of the percussion catch-all — hugely common
    -- in modern beats and nothing like generic hand-perc.
    snap = {
        "snap", "snaps", "fingersnap", "finger snap"
    },
    -- Hi-hat family split into three categories. CATEGORY_ORDER places
    -- specific (closed_hat, open_hat) BEFORE generic (hihat) so a name
    -- that contains "closed hat" wins over the "hat" generic match.
    -- ⭐ 2026-07-27 user rule: a GENERIC hi-hat name means the CLOSED
    -- articulation — CH / Closed Hat / Hi Hat / High Hat / HH / hihat all
    -- land in closed_hat ("Hi Hat"/"High Hat" tie 2-2 with hihat's "hat"
    -- and win via CATEGORY_ORDER position). Bare "hat"/"hats" stays in
    -- generic hihat — its one hard requirement is to NEVER read as open.
    -- (Dead underscore keywords removed: classify() converts the NAME's
    -- underscores to spaces, so "hi_hat"-style keywords can never match.)
    closed_hat = {
        "closed hat", "closedhat", "hat closed",
        "closed",  -- bare "closed" — unambiguous in sample-name context
        "pedal hat", "pedalhat", "ch",  -- "ch" via frontier pattern (≤3 chars)
        "hihat", "hi hat", "high hat", "highhat",
        "hh", "chh"  -- frontier patterns (≤3 chars)
    },
    open_hat = {
        "open hat", "openhat", "hat open",
        "oh", "ohh",  -- frontier patterns (≤3 chars)
        "open",  -- bare "open" — same accepted-risk class as bare "closed"
        -- Compound accumulators (2026-07-27 review): "Open Hihat"/"Open HH"
        -- style names fire generic-hihat keywords in closed_hat too — these
        -- make the open side OUTSCORE instead of tying (scores stack +2 per
        -- keyword hit, and ties are order-decided).
        "open hihat", "open hi hat", "open high hat", "open hh", "oh hihat"
    },
    hihat = {
        -- Bare/unqualified "hat" names only (everything hi-hat-specific
        -- moved to closed_hat, 2026-07-27). "hats" (4 chars, plain
        -- substring) closes the plural gap the ≤3-char frontier "hat" left.
        "hat", "hats"
    },
    -- Splash and china split from generic cymbal (distinct voices). Order
    -- places both BEFORE cymbal; china also catches trash/stack cymbals.
    splash = {
        "splash", "splsh"
    },
    china = {
        "china", "trash", "stack"
    },
    cymbal = {
        "cymbal", "cym"
    },
    ride = {
        "ride"
    },
    crash = {
        "crash", "crsh"
    },
    -- Tom family split like the hats: specific (floor_tom, rack_tom) BEFORE
    -- generic tom in CATEGORY_ORDER. Specific names also outscore generic
    -- ("Floor Tom" hits "floor tom" + "floor" = 4 vs tom's "tom" = 2).
    floor_tom = {
        "floor tom", "floortom", "floor_tom", "floor",
        "low tom", "lowtom", "lo tom"
    },
    rack_tom = {
        "rack tom", "racktom", "rack_tom", "rack",
        "hi tom", "hitom", "high tom", "mid tom", "midtom"
    },
    tom = {
        "tom", "toms"
    },
    -- Hand drums broken out so TR-808 / Latin kits get accurate filtering.
    -- Each takes priority over the generic "percussion" catch-all because
    -- the exact match scores 2 for the specific category vs 0 for percussion.
    conga = {
        "conga", "congas"
    },
    bongo = {
        "bongo", "bongos"
    },
    cowbell = {
        "cowbell", "cow bell"
    },
    clave = {
        "clave", "claves"
    },
    tambourine = {
        "tambourine", "tamb", "tambou"
    },
    shaker = {
        "shaker", "shakers", "shake"
    },
    maraca = {
        "maraca", "maracas", "marcas"  -- "marcas" handles the TR-808 typo
    },
    -- World/hand percussion promoted to real categories (each gets its own
    -- icon + colour). `percussion` below is now the pure catch-all for
    -- names that only say "perc".
    triangle = {
        "triangle"
    },
    woodblock = {
        "woodblock", "wood block", "woodblocks", "click", "clicks"
    },
    cabasa = {
        "cabasa"
    },
    guiro = {
        "guiro"
    },
    timbale = {
        "timbale", "timbales"
    },
    agogo = {
        "agogo", "agogo bell"
    },
    djembe = {
        "djembe", "jembe"
    },
    cajon = {
        "cajon"
    },
    vibraslap = {
        "vibraslap", "vibra slap"
    },
    whistle = {
        "whistle"
    },
    percussion = {
        "perc", "percussion"
    },
    bass = {
        "bass", "sub", "808bass", "subbass", "sub_bass", "sub bass",
        "reese", "bass synth", "bassline", "bass_line"
    },
    synth = {
        -- Bare "lead" removed: false-positives in "release", "leader".
        -- "synth lead" / "synthlead" are explicit and safe; bare "lead"
        -- on its own as a filename is rare and ambiguous.
        "synth", "synth lead", "synthlead", "arp", "arpeggio",
        "pluck", "stab", "chord", "chords", "saw", "square", "sine",
        "supersaw", "hoover"
    },
    pad = {
        "pad", "pads", "ambient", "atmosphere", "atmo", "drone",
        "texture", "evolving", "soundscape"
    },
    keys = {
        -- "e_piano" removed (dead — underscore normalization). "epiano"
        -- and "electric piano" cover the legitimate cases.
        "piano", "keys", "keyboard", "organ", "rhodes", "wurlitzer",
        "electric piano", "epiano", "e piano", "clav", "clavinet",
        "marimba", "vibraphone", "xylophone", "glockenspiel", "celesta",
        "harp", "harpsichord", "mallet"
    },
    guitar = {
        "guitar", "gtr", "guit", "acoustic guitar", "electric guitar",
        "clean guitar", "distorted guitar", "overdrive guitar",
        "strat", "tele", "les paul", "nylon", "steel string", "ukulele"
    },
    strings = {
        "strings", "string", "violin", "viola", "cello", "contrabass",
        "orchestral", "ensemble", "chamber", "pizzicato", "legato strings"
    },
    brass = {
        "brass", "trumpet", "trombone", "horn", "french horn", "tuba",
        "flugelhorn", "cornet"
    },
    vocal = {
        "vocal", "vox", "voice", "choir", "acapella", "a capella",
        "singing", "spoken", "speech", "adlib", "chant"
    },
    fx = {
        "fx", "sfx", "effect", "riser", "impact", "downlifter",
        "uplifter", "whoosh", "sweep", "noise", "glitch", "stutter",
        "transition", "reverse", "buildup", "build up", "build_up",
        "drop", "explosion", "boom", "siren", "alarm", "foley",
        "cinematic", "hit", "one shot"
    },
    loop = {
        "loop", "break", "breakbeat", "drum loop", "drumloop",
        "drum_loop", "top loop", "toploop", "top_loop", "groove",
        "pattern", "beat", "full loop", "construction"
    }
}

-- Each category gets a unique hue spread around the color wheel. The 5
-- core drum types (kick/snare/clap/closed_hat/open_hat) are maximally
-- spread for instant visual distinction. RGB values are computed from
-- HSL(hue, S=0.75, L=0.55) to match the JSFX pad-face rendering.
-- The JSFX-side swing_color_drumtype_hue function in rk_swing_colors.jsfx-inc
-- mirrors the same hue assignments — colors stay consistent between the
-- browser file list and the JSFX pad grid.
local CATEGORY_COLORS = {
    kick =       0xE23636FF,  -- hue 0.00 (red)
    snare =      0xE2B236FF,  -- hue 0.12 (orange)
    rimshot =    0xE27436FF,  -- hue 0.06 (orange-red)
    sidestick =  0xE28936FF,  -- hue 0.08 (orange, between rimshot and snare)
    clap =       0x59E236FF,  -- hue 0.30 (green)
    snap =       0x44E236FF,  -- hue 0.32 (green, clap family)
    closed_hat = 0x36CEE2FF,  -- hue 0.52 (teal-cyan)
    hihat =      0x36E2D8FF,  -- hue 0.49 (teal)
    open_hat =   0x6D36E2FF,  -- hue 0.72 (violet)
    ride =       0xDFE236FF,  -- hue 0.17 (yellow)
    crash =      0xCAE236FF,  -- hue 0.19 (warm gold)
    splash =     0xC0E236FF,  -- hue 0.20 (gold, cymbal family)
    cymbal =     0xB6E236FF,  -- hue 0.21 (gold)
    china =      0xABE236FF,  -- hue 0.22 (gold, cymbal family)
    brass =      0xA1E236FF,  -- hue 0.23 (chartreuse)
    cowbell =    0x8CE236FF,  -- hue 0.25 (yellow-green)
    clave =      0x78E236FF,  -- hue 0.27 (lime)
    tambourine = 0x3AE236FF,  -- hue 0.33 (green)
    shaker =     0x36E247FF,  -- hue 0.35 (forest green)
    maraca =     0x36E25CFF,  -- hue 0.37 (green)
    percussion = 0x36E27BFF,  -- hue 0.40 (deep green)
    triangle =   0x36E23DFF,  -- hue 0.34 (green, small-metal family)
    woodblock =  0xE29D36FF,  -- hue 0.10 (warm wood)
    cabasa =     0x36E266FF,  -- hue 0.38 (green, shaker family)
    guiro =      0x36E285FF,  -- hue 0.41 (green)
    agogo =      0x82E236FF,  -- hue 0.26 (yellow-green, bell family)
    timbale =    0xE23689FF,  -- hue 0.92 (pink-red, latin family)
    djembe =     0xE2367EFF,  -- hue 0.93 (pink-red, latin family)
    cajon =      0xE23640FF,  -- hue 0.99 (red, bass-box)
    vibraslap =  0x36E2E2FF,  -- hue 0.50 (cyan)
    whistle =    0x3671E2FF,  -- hue 0.61 (blue)
    tom =        0xE25536FF,  -- hue 0.03 (red-orange)
    rack_tom =   0xE26036FF,  -- hue 0.04 (red-orange, tom family)
    floor_tom =  0xE26A36FF,  -- hue 0.05 (red-orange, tom family)
    conga =      0xE2366AFF,  -- hue 0.95 (pink-red)
    bongo =      0xE23655FF,  -- hue 0.97 (magenta-red)
    guitar =     0x36E29AFF,  -- hue 0.43 (teal)
    strings =    0x36E2B9FF,  -- hue 0.46 (cyan)
    keys =       0x36AFE2FF,  -- hue 0.55 (cyan-blue)
    pad =        0x3690E2FF,  -- hue 0.58 (sky blue)
    vocal =      0x3666E2FF,  -- hue 0.62 (blue)
    synth =      0x363DE2FF,  -- hue 0.66 (indigo)
    bass =       0x9736E2FF,  -- hue 0.76 (purple)
    fx =         0xD536E2FF,  -- hue 0.82 (magenta)
    loop =       0xE236C7FF,  -- hue 0.86 (pink)
    other =      0xE2369DFF   -- hue 0.90 (warm pink)
}

local CATEGORY_ORDER = {
    -- Drum kit pieces first (most-used in the typical drum-sampler
    -- context). Hi-hat split: open_hat and closed_hat BEFORE generic
    -- hihat so specific variants win on tie-break (a name with "closed
    -- hat" picks closed_hat, not the generic "hat" keyword in hihat).
    -- ⭐ open_hat BEFORE closed_hat (2026-07-27 review): a closed-vs-open
    -- TIE can only arise from an open-marker + generic-hihat-token name
    -- ("Open Hi-Hat HH" — closed-marker names outscore outright), so ties
    -- must resolve OPEN. Pure-generic names ("Hi Hat") score 0 for open
    -- and still fall to closed_hat. ⚠️ browser digit-filter keys 7/8 bind
    -- positionally and swap with this — accepted.
    -- Sidestick before rimshot, splash/china before cymbal (specific wins),
    -- snap right after clap (its sonic neighbour).
    "kick", "snare", "sidestick", "rimshot", "clap", "snap",
    "open_hat", "closed_hat", "hihat",
    "splash", "china", "cymbal", "crash", "ride",
    -- Tom split: specific before generic (same rationale as the hats).
    "floor_tom", "rack_tom", "tom",
    "conga", "bongo", "cowbell", "clave", "tambourine", "shaker", "maraca",
    -- promoted world/hand percussion (all before the generic catch-all)
    "triangle", "woodblock", "cabasa", "guiro", "timbale", "agogo",
    "djembe", "cajon", "vibraslap", "whistle",
    "percussion",
    "bass", "synth", "pad", "keys", "guitar", "strings", "brass",
    "vocal", "fx", "loop"
}

function categorizer.classify(filename, folder_path)
    local name_lower = filename:lower():gsub("[_%-%.%(%)]", " ")
    local folder_lower = ""
    if folder_path then
        folder_lower = folder_path:lower():gsub("[_%-%.%(%)]", " ")
    end

    local scores = {}
    for cat, keywords in pairs(CATEGORY_KEYWORDS) do
        scores[cat] = 0
        for _, kw in ipairs(keywords) do
            -- Short keywords (≤3 chars) are prone to substring false
            -- positives ("rim" → "primary", "tom" → "stomach"). Use
            -- Lua frontier patterns to match only at letter/non-letter
            -- transitions. %f[%a] = "previous char is non-letter, next
            -- is letter"; %f[%A] = the reverse. This hits "rim" in
            -- "rim wav", "tom" in "tom1 wav" (digit is non-letter), and
            -- correctly skips "rim" in "primary", "tom" in "stomach".
            -- Longer keywords keep plain substring matching so
            -- "808kick" (no separator) still hits "kick".
            local name_hit, folder_hit
            if #kw <= 3 then
                local pat = "%f[%a]" .. kw .. "%f[%A]"
                name_hit   = name_lower:find(pat) ~= nil
                folder_hit = folder_lower:find(pat) ~= nil
            else
                name_hit   = name_lower:find(kw, 1, true) ~= nil
                folder_hit = folder_lower:find(kw, 1, true) ~= nil
            end
            if name_hit   then scores[cat] = scores[cat] + 2 end
            if folder_hit then scores[cat] = scores[cat] + 1 end
        end
    end

    local best_cat = "other"
    local best_score = 0
    for _, cat in ipairs(CATEGORY_ORDER) do
        if scores[cat] and scores[cat] > best_score then
            best_score = scores[cat]
            best_cat = cat
        end
    end

    return best_cat, best_score > 0
end

function categorizer.get_category_color(category)
    return CATEGORY_COLORS[category] or CATEGORY_COLORS["other"]
end

function categorizer.get_category_order()
    return CATEGORY_ORDER
end

function categorizer.get_all_colors()
    return CATEGORY_COLORS
end

return categorizer
