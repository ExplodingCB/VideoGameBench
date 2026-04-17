-- BalatroBench - AI Benchmark Mod for Balatro
-- Non-blocking entry point: hooks into game loop via Lovely patches

local Server = require("balatrobench_server")
local State = require("balatrobench_state")
local Format = require("balatrobench_format")
local Actions = require("balatrobench_actions")

local BalatroBench = {}

-- Mod state
local server = nil
local active = false
local waiting_for_action = false
local state_sent = false
local last_phase = nil
local last_state_key = nil
local fast_mode = os.getenv("BALATROBENCH_FAST") == "1"
local run_start_time = nil
local action_count = 0
local invalid_action_count = 0
local retry_count = 0
local MAX_RETRIES = 3
local action_cooldown = 0  -- frames to wait after action before sending new state
local phase_before_action = nil  -- track phase before action to detect real transitions
local state_key_before_action = nil  -- track state_key to detect in-phase effects (shop buys, sells, rerolls)
local wait_deadline = nil  -- hard upper bound (os.clock seconds) before we give up waiting for a transition

---------------------------------------------------------------------------
-- Initialization
---------------------------------------------------------------------------

function BalatroBench.init()
    print("[BalatroBench] Initializing...")

    server = Server.new()
    if not server:start() then
        print("[BalatroBench] Failed to start server, mod disabled")
        return
    end

    active = true

    if fast_mode then
        BalatroBench.enable_fast_mode()
    end

    print("[BalatroBench] Ready. Waiting for AI client on port " ..
          tostring(tonumber(os.getenv("BALATROBENCH_PORT")) or 12345))
end

function BalatroBench.enable_fast_mode()
    if G and G.SETTINGS then
        G.SETTINGS.GAMESPEED = 10
        G.SETTINGS.reduced_motion = true
    end
    print("[BalatroBench] Fast mode enabled")
end

---------------------------------------------------------------------------
-- Generate a state key to detect changes
---------------------------------------------------------------------------

local function state_key()
    if not G or not G.STATE then return "none" end
    local phase = State.get_phase()
    local chips = G.GAME and G.GAME.chips or 0
    local hands = G.GAME and G.GAME.current_round and G.GAME.current_round.hands_left or 0
    local dollars = G.GAME and G.GAME.dollars or 0
    local hand_count = G.hand and G.hand.cards and #G.hand.cards or 0
    return string.format("%s_%s_%s_%s_%s", phase, chips, hands, dollars, hand_count)
end

---------------------------------------------------------------------------
-- Main update loop - called every frame, must be NON-BLOCKING
---------------------------------------------------------------------------

function BalatroBench.update(dt)
    if not active or not server then return end

    -- Accept new connections (non-blocking)
    if not server:is_connected() then
        server:accept_client()
        if server:is_connected() then
            server:send_json({
                type = "connected",
                message = "BalatroBench connected. Waiting for game to start...",
                version = "1.0.0",
            })
            waiting_for_action = false
            state_sent = false
            last_phase = nil
            last_state_key = nil
            phase_before_action = nil
            state_key_before_action = nil
            wait_deadline = nil
        end
        return
    end

    -- Non-blocking: check for incoming messages
    local msg = server:receive()
    if msg then
        BalatroBench.handle_message(msg)
        return
    end

    -- Cooldown after actions - wait for game to finish transitioning
    if action_cooldown > 0 then
        action_cooldown = action_cooldown - 1
        return
    end

    -- If waiting for phase to change after an action, don't send until it does.
    -- We release the wait when ANY of these is true:
    --   1. Phase changed (play/discard/cash_out/next_round/pack_select)
    --   2. state_key changed (shop buy/sell/reroll that stays in SHOP)
    --   3. wait_deadline exceeded (safety net so we can never hard-lock)
    if phase_before_action then
        local current_phase = State.get_phase()
        local current_key = state_key()
        local phase_changed = current_phase ~= phase_before_action
        local key_changed = state_key_before_action and current_key ~= state_key_before_action
        local timed_out = wait_deadline and os.clock() >= wait_deadline

        if not (phase_changed or key_changed or timed_out) then
            return  -- Still waiting for something observable to change
        end

        if phase_changed then
            print("[BalatroBench] Phase transitioned: " .. phase_before_action .. " -> " .. current_phase)
        elseif key_changed then
            print("[BalatroBench] State key changed in-phase (" .. current_phase .. "): effective in-phase action")
        else
            print("[BalatroBench] Transition wait timed out, resuming")
        end

        phase_before_action = nil
        state_key_before_action = nil
        wait_deadline = nil
        state_sent = false
        waiting_for_action = false
        last_state_key = nil
    end

    -- Detect state changes and send new state when needed
    local current_phase = State.get_phase()
    local current_key = state_key()

    -- If the state changed
    if current_key ~= last_state_key then
        last_state_key = current_key
        last_phase = current_phase
        state_sent = false
        waiting_for_action = false
        retry_count = 0
    end

    -- If we're in an actionable state and haven't sent state yet
    if not state_sent and State.is_actionable() then
        local full_state = State.get_full_state()
        local formatted = Format.format_state(full_state)

        if formatted then
            server:send(formatted)
            state_sent = true
            waiting_for_action = true
        end
    end
end

---------------------------------------------------------------------------
-- Handle incoming messages (non-blocking)
---------------------------------------------------------------------------

function BalatroBench.handle_message(msg)
    if not msg then return end

    -- Method calls (gamestate, health, start, stats)
    if msg.method then
        if msg.method == "gamestate" then
            local full_state = State.get_full_state()
            local formatted = Format.format_state(full_state)
            if formatted then
                server:send(formatted)
            else
                server:send_json({type = "state", phase = State.get_phase(), message = "Transitional state"})
            end

        elseif msg.method == "start" then
            BalatroBench.start_new_run(msg.deck, msg.stake, msg.seed)

        elseif msg.method == "health" then
            server:send_json({type = "health", status = "ok", phase = State.get_phase(), version = "1.0.0"})

        elseif msg.method == "stats" then
            server:send_json({
                type = "stats",
                actions = action_count,
                invalid_actions = invalid_action_count,
                elapsed = run_start_time and (os.clock() - run_start_time) or 0,
            })

        else
            server:send_json({type = "error", error = "Unknown method: " .. tostring(msg.method)})
        end
        return
    end

    -- Action execution
    if msg.action then
        if not waiting_for_action then
            server:send_json({type = "error", error = "Not waiting for an action right now. Current phase: " .. State.get_phase()})
            return
        end

        -- Handle quit
        if msg.action == "quit" then
            BalatroBench.send_final_results()
            active = false
            return
        end

        -- Handle new_run
        if msg.action == "new_run" then
            BalatroBench.start_new_run(msg.deck, msg.stake, msg.seed)
            waiting_for_action = false
            state_sent = false
            return
        end

        -- Execute the action
        local result = Actions.dispatch(msg)

        if result.error then
            invalid_action_count = invalid_action_count + 1
            retry_count = retry_count + 1

            if retry_count > MAX_RETRIES then
                -- Take default action
                print("[BalatroBench] Max retries, taking default action")
                BalatroBench.take_default_action()
                waiting_for_action = false
                state_sent = false
                retry_count = 0
                server:send_json({type = "action_result", result = {success = true, action = "default_fallback"}})
            else
                server:send_json({
                    type = "error",
                    error = result.error,
                    retries_left = MAX_RETRIES - retry_count,
                })
            end
        else
            -- Success
            action_count = action_count + 1
            retry_count = 0
            waiting_for_action = false
            state_sent = false
            -- Wait for the game to transition (or produce an observable state change) before sending new state
            phase_before_action = State.get_phase()
            state_key_before_action = state_key()
            wait_deadline = os.clock() + 3.0  -- never block longer than 3 real seconds
            action_cooldown = 30  -- wait ~0.5s (at 60fps) before checking
            server:send_json({type = "action_result", result = result})

            -- Check for game over
            if State.get_phase() == "GAME_OVER" then
                BalatroBench.send_final_results()
            end
        end
        return
    end

    -- Unknown message format
    server:send_json({type = "error", error = "Message must have 'action' or 'method' field"})
end

---------------------------------------------------------------------------
-- Start a new run
---------------------------------------------------------------------------

function BalatroBench.start_new_run(deck, stake, seed)
    -- Re-activate the mod in case a previous run ended with `quit`, which
    -- sets active=false. Without this, sequential benchmark runs can't
    -- start a second run because the update loop early-returns on !active.
    active = true
    run_start_time = os.clock()
    action_count = 0
    invalid_action_count = 0
    last_phase = nil
    last_state_key = nil
    state_sent = false
    waiting_for_action = false
    retry_count = 0
    phase_before_action = nil
    state_key_before_action = nil
    wait_deadline = nil

    print("[BalatroBench] Starting new run - deck: " .. tostring(deck) .. " stake: " .. tostring(stake))

    if not G then
        server:send_json({type = "error", error = "Game object not ready"})
        return
    end

    -- Set the viewed back (deck) before starting
    if deck then
        local found = false
        if G.P_CENTER_POOLS and G.P_CENTER_POOLS.Back then
            for _, v in ipairs(G.P_CENTER_POOLS.Back) do
                if v.name == deck then
                    G.GAME.viewed_back = v
                    found = true
                    break
                end
            end
        end
        if not found then
            print("[BalatroBench] Deck '" .. tostring(deck) .. "' not found, using default")
        end
    end

    local args = {
        stake = stake or 1,
    }
    if seed then
        args.seed = seed
    end

    -- Use the proper G.FUNCS.start_run which handles wipe, delete_run, event queue
    local ok, err = pcall(function()
        G.FUNCS.start_run(nil, args)
    end)

    if ok then
        print("[BalatroBench] Run started successfully")
        server:send_json({type = "run_started", message = "New run started"})
    else
        print("[BalatroBench] Error starting run: " .. tostring(err))
        server:send_json({type = "error", error = "Failed to start run: " .. tostring(err)})
    end
end

---------------------------------------------------------------------------
-- Default safe actions when retries are exhausted
---------------------------------------------------------------------------

function BalatroBench.take_default_action()
    local phase = State.get_phase()

    if phase == "SELECTING_HAND" then
        local count = math.min(5, G.hand and G.hand.cards and #G.hand.cards or 0)
        if count > 0 then
            local cards = {}
            for i = 1, count do cards[#cards + 1] = i end
            Actions.play({cards = cards})
        end
    elseif phase == "BLIND_SELECT" then
        Actions.select({})
    elseif phase == "SHOP" then
        Actions.next_round({})
    elseif phase == "TAROT_PACK" or phase == "PLANET_PACK" or
           phase == "SPECTRAL_PACK" or phase == "STANDARD_PACK" or
           phase == "BUFFOON_PACK" then
        Actions.skip({})
    end
end

---------------------------------------------------------------------------
-- Send final run results
---------------------------------------------------------------------------

function BalatroBench.send_final_results()
    if not server or not server:is_connected() then return end

    local full_state = State.get_full_state()
    local elapsed = run_start_time and (os.clock() - run_start_time) or 0

    server:send_json({
        type = "run_complete",
        result = {
            won = full_state.ante >= full_state.max_ante,
            ante_reached = full_state.ante,
            rounds_won = full_state.stats.rounds_won,
            highest_hand = full_state.stats.highest_hand,
            final_dollars = full_state.dollars,
            total_actions = action_count,
            invalid_actions = invalid_action_count,
            elapsed_seconds = elapsed,
            seed = full_state.seed,
            deck = full_state.deck,
            stake = full_state.stake,
        },
    })
end

---------------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------------

function BalatroBench.shutdown()
    if server then
        BalatroBench.send_final_results()
        server:stop()
    end
    active = false
    print("[BalatroBench] Shutdown complete")
end

-- Initialize immediately when module is loaded
BalatroBench.init()

return BalatroBench
