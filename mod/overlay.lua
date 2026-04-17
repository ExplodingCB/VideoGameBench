-- BalatroBench Overlay - Jimbo-style speech bubble showing live model output
-- Opt-in via BALATROBENCH_JIMBO=1. No-op when disabled.
-- Uses Balatro's own font (G.FONTS) and sound (play_sound) at runtime.

local Overlay = {
    enabled = false,
    state = "idle",         -- "idle" | "thinking" | "streaming" | "fading"
    full_text = "",         -- everything received from Python
    text = "",              -- portion currently revealed (typewriter tail)
    reveal_progress = 0,    -- float; chars-revealed target, advanced in update()
    chars_since_voice = 0,  -- counts revealed chars toward next voice sample
    dots_phase = 0,
    last_blip_time = 0,
    fade_t = 0,
    font = nil,
    font_ready = false,
    asset_warn_logged = false,
    current_action_index = -1,
    draw_hook_installed = false,
    jimbo_image = nil,
    jimbo_quad = nil,
    jimbo_jitter = 0,       -- 0..1, bumped on each voice sample, decays
    model_name = nil,       -- display string sent from Python (e.g. "grok 4.1 fast")
}

local MAX_TEXT = 2000
local DROP_CHUNK = 200
local BOX_W = 340
local BOX_H = 200
local MARGIN = 24
local PAD = 14
local FADE_DURATION = 2.0
local BLIP_DEBOUNCE = 0.06
-- Reveal speed adapts to how fast tokens are arriving. We aim to empty the
-- pending buffer over ~CATCHUP_SECS, clamped between MIN and MAX cps so a
-- slow model still feels alive and a fast one stays readable.
local REVEAL_MIN_CPS = 50   -- floor — slow streams still "type" at this pace
local REVEAL_MAX_CPS = 220  -- ceiling — fast streams cap here so you can keep up
local CATCHUP_SECS   = 0.4  -- how quickly reveal catches up to what's buffered
local VOICE_EVERY_N = 9     -- roughly: one voice sample per ~word
local JITTER_DECAY = 3.0    -- per second — how fast the shake settles

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------

function Overlay.init()
    if os.getenv("BALATROBENCH_JIMBO") == "1" then
        Overlay.enabled = true
        print("[BalatroBench] Jimbo overlay enabled")
    else
        Overlay.enabled = false
    end
end

-- Load Balatro's in-game pixel font (m6x11plus.ttf) at a readable size.
-- Inside Balatro's LÖVE process, love.filesystem is rooted at the game's
-- own resources, so we can load directly from resources/fonts/. We try at
-- a few sizes in case the first doesn't render crisply (pixel fonts look
-- best at multiples of their design size; 16 matches Balatro's UI scale).
local BALATRO_FONT_PATH = "resources/fonts/m6x11plus.ttf"
local BALATRO_FONT_SIZE = 16

local function try_resolve_font()
    if Overlay.font_ready then return end
    -- First choice: Balatro's own pixel font
    local ok, f = pcall(love.graphics.newFont, BALATRO_FONT_PATH, BALATRO_FONT_SIZE)
    if ok and f then
        Overlay.font = f
        Overlay.font_ready = true
        print("[BalatroBench] Overlay loaded m6x11plus at size " .. BALATRO_FONT_SIZE ..
              " (height=" .. tostring(f:getHeight()) .. ")")
        return
    end
    -- Fallback: LÖVE's default TTF at a sane size
    local ok2, f2 = pcall(love.graphics.newFont, BALATRO_FONT_SIZE)
    if ok2 and f2 then
        Overlay.font = f2
        Overlay.font_ready = true
        print("[BalatroBench] m6x11plus unavailable (" .. tostring(f) ..
              "), using LOVE default")
    end
end

local function get_font()
    return Overlay.font or love.graphics.getFont()
end

-- Attempt to grab the base-joker sprite from Balatro's atlas.
-- G.ASSET_ATLAS['Joker'] is the joker spritesheet; G.P_CENTERS.j_joker carries
-- pos={x,y} in atlas tiles, and the atlas has px/py for the tile size.
local function try_resolve_jimbo()
    if Overlay.jimbo_image then return end
    if not (G and G.ASSET_ATLAS and G.P_CENTERS) then return end
    local atlas = G.ASSET_ATLAS["Joker"]
    local joker = G.P_CENTERS.j_joker
    if not (atlas and atlas.image and joker and joker.pos) then return end
    local px = atlas.px or 71
    local py = atlas.py or 95
    local img = atlas.image
    local ok, quad = pcall(love.graphics.newQuad,
        joker.pos.x * px, joker.pos.y * py,
        px, py,
        img:getDimensions())
    if ok and quad then
        Overlay.jimbo_image = img
        Overlay.jimbo_quad = quad
        print("[BalatroBench] Jimbo sprite resolved from atlas")
    end
end

---------------------------------------------------------------------------
-- Sound (uses Balatro's global play_sound if available)
---------------------------------------------------------------------------

local function play_blip()
    local now = love and love.timer and love.timer.getTime() or 0
    if now - Overlay.last_blip_time < BLIP_DEBOUNCE then return end
    Overlay.last_blip_time = now
    if type(_G.play_sound) == "function" then
        pcall(_G.play_sound, "generic1", 1.0, 0.35)
    end
end

-- Mirrors Card_Character:say_stuff — Balatro ships 11 voice samples
-- (voice1 ... voice11) meant exactly for this "Jimbo is chatting" effect.
local function play_voice()
    if type(_G.play_sound) ~= "function" then return end
    local n = math.random(1, 11)
    local pitch = 0.9 + math.random() * 0.25
    pcall(_G.play_sound, "voice" .. n, pitch, 0.45)
end

---------------------------------------------------------------------------
-- Text buffer — tokens go into full_text; update() reveals them slowly
---------------------------------------------------------------------------

local function append_text(chunk)
    if not chunk or chunk == "" then return end
    Overlay.full_text = Overlay.full_text .. chunk
    -- Cap the buffer from growing unbounded. When we trim the head, also
    -- shift reveal_progress so the already-revealed portion doesn't "jump."
    if #Overlay.full_text > MAX_TEXT then
        Overlay.full_text = Overlay.full_text:sub(DROP_CHUNK + 1)
        Overlay.reveal_progress = math.max(0, Overlay.reveal_progress - DROP_CHUNK)
    end
end

---------------------------------------------------------------------------
-- Message handling (returns true if message was consumed)
---------------------------------------------------------------------------

function Overlay.on_message(msg)
    if not Overlay.enabled then return false end
    local t = msg.type
    if t == "jimbo_thinking_start" then
        print("[BalatroBench] jimbo: thinking_start (action " .. tostring(msg.action_index) .. ")")
        Overlay.state = "thinking"
        Overlay.full_text = ""
        Overlay.text = ""
        Overlay.reveal_progress = 0
        Overlay.chars_since_voice = 0
        Overlay.dots_phase = 0
        Overlay.jimbo_jitter = 0
        Overlay.fade_t = 0
        Overlay.current_action_index = msg.action_index or -1
        if msg.model_name then Overlay.model_name = msg.model_name end
        return true
    elseif t == "jimbo_token" then
        if Overlay.state == "idle" or Overlay.state == "fading" then
            Overlay.state = "streaming"
            Overlay.full_text = ""
            Overlay.text = ""
            Overlay.reveal_progress = 0
            Overlay.fade_t = 0
        end
        if Overlay.state == "thinking" then
            Overlay.state = "streaming"
            print("[BalatroBench] jimbo: first token received (" .. tostring(#(msg.text or "")) .. " chars)")
            play_blip()
        end
        append_text(msg.text)
        return true
    elseif t == "jimbo_thinking_end" then
        if Overlay.state == "thinking" then
            Overlay.state = "fading"
            Overlay.fade_t = FADE_DURATION * 0.5
        end
        return true
    elseif t == "jimbo_dispatched" then
        Overlay.state = "fading"
        Overlay.fade_t = FADE_DURATION
        return true
    elseif t == "jimbo_reset" then
        Overlay.state = "idle"
        Overlay.full_text = ""
        Overlay.text = ""
        Overlay.reveal_progress = 0
        Overlay.jimbo_jitter = 0
        Overlay.fade_t = 0
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Update
---------------------------------------------------------------------------

-- Install a wrapper around love.draw so the overlay renders AFTER the game
-- has drawn everything else (i.e. on top). We do this lazily because main.lua
-- (where love.draw is defined) hasn't loaded when Overlay.init() runs.
local function maybe_install_draw_hook()
    if Overlay.draw_hook_installed then return end
    if type(love) ~= "table" or type(love.draw) ~= "function" then return end
    local prev_draw = love.draw
    love.draw = function(...)
        prev_draw(...)
        local ok, err = pcall(Overlay.draw)
        if not ok then
            -- Don't let a broken overlay crash the whole frame
            print("[BalatroBench] Overlay.draw error: " .. tostring(err))
        end
    end
    Overlay.draw_hook_installed = true
    print("[BalatroBench] Overlay draw hook installed")
end

function Overlay.update(dt)
    if not Overlay.enabled then return end
    maybe_install_draw_hook()
    try_resolve_font()
    try_resolve_jimbo()

    if Overlay.state == "thinking" then
        Overlay.dots_phase = (Overlay.dots_phase + dt * 2.0) % 3

    elseif Overlay.state == "streaming" then
        -- Advance the typewriter reveal. Speed adapts: we compute the rate
        -- needed to empty the pending buffer over CATCHUP_SECS, then clamp
        -- between MIN and MAX. Result: the bubble naturally tracks the
        -- model's actual streaming pace without ever feeling stalled or
        -- flooding past you.
        local prev = #Overlay.text
        local pending = #Overlay.full_text - prev
        local desired = pending / CATCHUP_SECS
        local cps = math.min(REVEAL_MAX_CPS, math.max(REVEAL_MIN_CPS, desired))
        Overlay.reveal_progress = Overlay.reveal_progress + dt * cps
        local target = math.min(math.floor(Overlay.reveal_progress), #Overlay.full_text)
        if target > prev then
            Overlay.text = Overlay.full_text:sub(1, target)
            -- Count newly-revealed non-whitespace chars for voice cadence
            for i = prev + 1, target do
                local c = Overlay.full_text:sub(i, i)
                if not c:match("%s") then
                    Overlay.chars_since_voice = Overlay.chars_since_voice + 1
                end
            end
            if Overlay.chars_since_voice >= VOICE_EVERY_N then
                Overlay.chars_since_voice = 0
                play_voice()
                Overlay.jimbo_jitter = 1.0
            end
        end

    elseif Overlay.state == "fading" then
        Overlay.fade_t = Overlay.fade_t - dt
        if Overlay.fade_t <= 0 then
            Overlay.state = "idle"
            Overlay.text = ""
            Overlay.full_text = ""
            Overlay.reveal_progress = 0
            Overlay.fade_t = 0
        end
    end

    -- Decay the shake regardless of state so Jimbo settles after the last sample
    Overlay.jimbo_jitter = math.max(0, Overlay.jimbo_jitter - dt * JITTER_DECAY)
end

---------------------------------------------------------------------------
-- Draw
---------------------------------------------------------------------------

local function compute_box()
    local w = love.graphics.getWidth()
    local x = w - BOX_W - MARGIN
    local y = MARGIN
    return x, y, BOX_W, BOX_H
end

local function draw_dots(x, y, alpha)
    local cy = y + BOX_H / 2
    local cx = x + BOX_W / 2
    local radius = 5
    local spacing = 18
    for i = 1, 3 do
        local phase_offset = (i - 1) / 3
        local s = math.sin((Overlay.dots_phase - phase_offset) * 2 * math.pi)
        local a = 0.35 + 0.65 * math.max(0, s)
        love.graphics.setColor(0.12, 0.10, 0.08, alpha * a)
        love.graphics.circle("fill", cx + (i - 2) * spacing, cy, radius)
    end
end

-- Actual drawing payload. Isolated so Overlay.draw can call it under pcall
-- and still guarantee the matching graphics pop runs, avoiding a push leak
-- on error that would eventually crash Balatro's own renderer.
local function draw_body(alpha)
    local x, y, w, h = compute_box()

    -- Mirror G.UIDEF.speech_bubble: JOKER_GREY outer, WHITE inner, nested
    -- rounded rects with a drop shadow. Colors sourced from G.C when available
    -- so the bubble auto-updates if Balatro's theme changes; fallbacks below.
    local grey = (G and G.C and G.C.JOKER_GREY) or {0.749, 0.780, 0.835, 1}
    local white = (G and G.C and G.C.WHITE) or {1, 1, 1, 1}

    -- Drop shadow
    love.graphics.setColor(0, 0, 0, 0.35 * alpha)
    love.graphics.rectangle("fill", x + 5, y + 6, w, h, 16, 16)

    -- Outer grey border
    love.graphics.setColor(grey[1], grey[2], grey[3], (grey[4] or 1) * alpha)
    love.graphics.rectangle("fill", x, y, w, h, 16, 16)

    -- Inner white panel
    local inset = 7
    love.graphics.setColor(white[1], white[2], white[3], (white[4] or 1) * alpha)
    love.graphics.rectangle("fill", x + inset, y + inset, w - 2 * inset, h - 2 * inset, 10, 10)

    -- Jimbo sprite tucked under the bubble (the speaker cue).
    local jimbo_right_x, jimbo_center_y, jimbo_dx, jimbo_dy
    if Overlay.jimbo_image and Overlay.jimbo_quad then
        local _, _, qw, qh = Overlay.jimbo_quad:getViewport()
        local scale = 0.9
        local dw, dh = qw * scale, qh * scale
        local jx = x - dw * 0.1
        local jy = y + h + 14
        local t = (love.timer and love.timer.getTime() or 0)
        local shake = Overlay.jimbo_jitter
        jimbo_dx = math.sin(t * 34) * 6 * shake
        jimbo_dy = math.cos(t * 27) * 4 * shake
        local rot = math.sin(t * 41) * 0.12 * shake
        love.graphics.setColor(1, 1, 1, alpha)
        love.graphics.draw(Overlay.jimbo_image, Overlay.jimbo_quad,
            jx + dw / 2 + jimbo_dx, jy + dh / 2 + jimbo_dy,
            rot, scale, scale,
            qw / 2, qh / 2)
        jimbo_right_x = jx + dw
        jimbo_center_y = jy + dh / 2
    end

    -- Model name tag, to the right of Jimbo. Shakes with him.
    if Overlay.model_name and jimbo_right_x then
        local name_font = get_font()
        love.graphics.setFont(name_font)
        local nx = jimbo_right_x + 12 + (jimbo_dx or 0)
        local ny = jimbo_center_y - name_font:getHeight() / 2 + (jimbo_dy or 0)
        love.graphics.setColor(0.10, 0.08, 0.06, 0.85 * alpha)
        for _, off in ipairs({{2,2},{-2,2},{2,-2},{-2,-2}}) do
            love.graphics.print(Overlay.model_name, nx + off[1], ny + off[2])
        end
        love.graphics.setColor(0.96, 0.91, 0.70, alpha)
        love.graphics.print(Overlay.model_name, nx, ny)
    end

    -- Bubble content
    local font = get_font()
    love.graphics.setFont(font)
    if Overlay.state == "thinking" and Overlay.text == "" then
        draw_dots(x, y, alpha)
    else
        local text_x = x + PAD
        local text_y = y + PAD
        local text_w = w - 2 * PAD
        local text_h = h - 2 * PAD
        local line_h = font:getHeight() * 1.08
        local max_lines = math.max(1, math.floor(text_h / line_h))
        local _, lines = font:getWrap(Overlay.text, text_w)
        local start_idx = math.max(1, #lines - max_lines + 1)
        for i = start_idx, #lines do
            local rel = i - start_idx
            local line_alpha = alpha
            if rel == 0 and #lines > max_lines then
                line_alpha = alpha * 0.45
            end
            love.graphics.setColor(0.10, 0.08, 0.06, line_alpha)
            love.graphics.print(lines[i], text_x, text_y + rel * line_h)
        end
    end
end

function Overlay.draw()
    if not Overlay.enabled then return end
    if Overlay.state == "idle" then return end

    local alpha = 1.0
    if Overlay.state == "fading" then
        alpha = math.max(0, Overlay.fade_t / FADE_DURATION)
    end

    -- Save ALL graphics state AND reset transforms. Balatro applies a UI scale
    -- inside its love.draw, which would otherwise make our overlay 2-3x larger
    -- than intended. The body is wrapped in pcall so any error between push
    -- and pop can't leak a push — previously such leaks accumulated and
    -- eventually overflowed LÖVE's graphics stack, crashing the game.
    love.graphics.push("all")
    love.graphics.origin()
    love.graphics.setScissor()
    local ok, err = pcall(draw_body, alpha)
    love.graphics.pop()  -- GUARANTEED to run, even on body error

    if not ok then
        print("[BalatroBench] Overlay.draw body error: " .. tostring(err))
    end
end

return Overlay
