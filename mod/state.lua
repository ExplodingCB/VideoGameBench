-- BalatroBench State Extraction
-- Reads game state from Balatro's global G object

local State = {}

-- Map G.STATE numbers to readable phase names
-- These MUST match globals.lua G.STATES exactly
local STATE_NAMES = {
    [1] = "SELECTING_HAND",
    [2] = "HAND_PLAYED",
    [3] = "DRAW_TO_HAND",
    [4] = "GAME_OVER",
    [5] = "SHOP",
    [6] = "PLAY_TAROT",
    [7] = "BLIND_SELECT",
    [8] = "ROUND_EVAL",
    [9] = "TAROT_PACK",
    [10] = "PLANET_PACK",
    [11] = "MENU",
    [12] = "TUTORIAL",
    [13] = "SPLASH",
    [14] = "SANDBOX",
    [15] = "SPECTRAL_PACK",
    [16] = "DEMO_CTA",
    [17] = "STANDARD_PACK",
    [18] = "BUFFOON_PACK",
    [19] = "NEW_ROUND",
    [999] = "SMODS_BOOSTER_OPENED",
}

-- States where the AI needs to make a decision
State.ACTIONABLE_STATES = {
    BLIND_SELECT = true,
    SELECTING_HAND = true,
    SHOP = true,
    TAROT_PACK = true,
    PLANET_PACK = true,
    SPECTRAL_PACK = true,
    STANDARD_PACK = true,
    BUFFOON_PACK = true,
    GAME_OVER = true,
    ROUND_EVAL = true,
    NEW_ROUND = true,
    PLAY_TAROT = true,
    SMODS_BOOSTER_OPENED = true,
}

-- Suit symbols for display
local SUIT_SYMBOLS = {
    Hearts = "Hearts",
    Diamonds = "Diamonds",
    Clubs = "Clubs",
    Spades = "Spades",
}

---------------------------------------------------------------------------
-- Effect text rendering
---------------------------------------------------------------------------
-- Balatro stores joker/tarot/voucher/blind descriptions as raw templates
-- like "Played {C:attention}face{} cards give {C:mult}+#1#{} Mult".
-- The UI normally resolves #1# / #2# / etc. at render time using each
-- center's loc_vars() callback. If we just concat the raw text, models
-- see garbage markup and missing numbers.
--
-- strip_markup(s): removes every {C:...}, {V:...}, {X:...}, {s:...},
--                  {B:...}, {E:...}, closing {} tags, and newline escapes.
-- render_description(set, key, loc_ref, card): returns a fully rendered,
--     markup-free description string. loc_ref is the center table (the
--     object with the loc_vars function), card is the instance used when
--     the substitution depends on per-instance state.
---------------------------------------------------------------------------

local function strip_markup(s)
    if not s or s == "" then return "" end
    -- Remove opening tag markers like {C:attention}, {X:mult,C:white}, {V:1}
    s = s:gsub("{[CVXSsBEe]:[^}]*}", "")
    -- Remove balance markers like {s:0.8,V:1} that mix letters and colons
    s = s:gsub("{[%a]:[^}]*}", "")
    -- Remove bare closing tags {}
    s = s:gsub("{}", "")
    -- Collapse "  " -> " " a few times
    for _ = 1, 3 do s = s:gsub("  ", " ") end
    return s
end

local function substitute_vars(lines, vars)
    if type(lines) ~= "table" then lines = {tostring(lines)} end
    if not vars then vars = {} end
    local out = {}
    for _, line in ipairs(lines) do
        local s = tostring(line)
        -- Substitute #1#, #2#, ... with vars[1], vars[2], ...
        for i, v in ipairs(vars) do
            s = s:gsub("#" .. i .. "#", tostring(v))
        end
        -- Any leftover #N# means the template wanted more vars than we had;
        -- leave it rather than erroring, but strip the markers visually.
        s = s:gsub("#%d+#", "?")
        table.insert(out, s)
    end
    return out
end

function State.render_description(set, key, loc_ref, card)
    if not set or not key then return "" end
    if not (G and G.localization and G.localization.descriptions) then return "" end
    local bucket = G.localization.descriptions[set]
    if not bucket then return "" end
    local loc = bucket[key]
    if not loc or not loc.text then return "" end

    -- Ask the center for its substitution vars. This is how Balatro's own
    -- UI resolves per-joker numeric placeholders.
    local vars = {}
    if loc_ref and type(loc_ref.loc_vars) == "function" then
        local info_queue = {}
        local ok, loc_def = pcall(loc_ref.loc_vars, loc_ref, info_queue, card)
        if ok and type(loc_def) == "table" and loc_def.vars then
            vars = loc_def.vars
        end
    end

    local rendered = substitute_vars(loc.text, vars)
    local s = table.concat(rendered, " ")
    return strip_markup(s)
end

-- Rank display names
local RANK_NAMES = {
    ["2"] = "2", ["3"] = "3", ["4"] = "4", ["5"] = "5",
    ["6"] = "6", ["7"] = "7", ["8"] = "8", ["9"] = "9",
    ["10"] = "10", Jack = "Jack", Queen = "Queen", King = "King", Ace = "Ace",
}

-- Chip values by rank
local RANK_CHIPS = {
    ["2"] = 2, ["3"] = 3, ["4"] = 4, ["5"] = 5,
    ["6"] = 6, ["7"] = 7, ["8"] = 8, ["9"] = 9,
    ["10"] = 10, Jack = 10, Queen = 10, King = 10, Ace = 11,
}

function State.get_phase()
    if not G or not G.STATE then return "UNKNOWN" end
    -- Direct comparison against G.STATES for accuracy
    if G.STATES then
        if G.STATE == G.STATES.SELECTING_HAND then return "SELECTING_HAND"
        elseif G.STATE == G.STATES.HAND_PLAYED then return "HAND_PLAYED"
        elseif G.STATE == G.STATES.DRAW_TO_HAND then return "DRAW_TO_HAND"
        elseif G.STATE == G.STATES.GAME_OVER then return "GAME_OVER"
        elseif G.STATE == G.STATES.SHOP then return "SHOP"
        elseif G.STATE == G.STATES.PLAY_TAROT then return "PLAY_TAROT"
        elseif G.STATE == G.STATES.BLIND_SELECT then return "BLIND_SELECT"
        elseif G.STATE == G.STATES.ROUND_EVAL then return "ROUND_EVAL"
        elseif G.STATE == G.STATES.TAROT_PACK then return "TAROT_PACK"
        elseif G.STATE == G.STATES.PLANET_PACK then return "PLANET_PACK"
        elseif G.STATE == G.STATES.MENU then return "MENU"
        elseif G.STATE == G.STATES.SPLASH then return "SPLASH"
        elseif G.STATE == G.STATES.SPECTRAL_PACK then return "SPECTRAL_PACK"
        elseif G.STATE == G.STATES.STANDARD_PACK then return "STANDARD_PACK"
        elseif G.STATE == G.STATES.BUFFOON_PACK then return "BUFFOON_PACK"
        elseif G.STATE == G.STATES.NEW_ROUND then return "NEW_ROUND"
        elseif G.STATE == G.STATES.TUTORIAL then return "TUTORIAL"
        elseif G.STATE == G.STATES.SANDBOX then return "SANDBOX"
        end
    end
    return STATE_NAMES[G.STATE] or "UNKNOWN"
end

function State.is_actionable()
    local phase = State.get_phase()
    return State.ACTIONABLE_STATES[phase] or false
end

function State.is_pack_phase()
    local phase = State.get_phase()
    return phase == "TAROT_PACK" or phase == "PLANET_PACK" or
           phase == "SPECTRAL_PACK" or phase == "STANDARD_PACK" or
           phase == "BUFFOON_PACK" or phase == "SMODS_BOOSTER_OPENED"
end

function State.extract_card(card)
    if not card then return nil end
    local data = {
        rank = "Unknown",
        suit = "Unknown",
        chips = 0,
        enhancement = "None",
        edition = "Base",
        seal = "None",
        debuffed = false,
        face_down = false,
    }

    -- Check if card is face down
    if card.facing and card.facing == "back" then
        data.face_down = true
        return data
    end

    -- Basic card info
    if card.base then
        local rank_key = card.base.value or "Unknown"
        data.rank = RANK_NAMES[rank_key] or rank_key
        data.suit = card.base.suit or "Unknown"
        data.chips = RANK_CHIPS[rank_key] or 0
    end

    -- Enhancement
    if card.config and card.config.center then
        local center = card.config.center
        if center.name and center.name ~= "Default Base" and center.name ~= "c_base" then
            data.enhancement = center.name
            -- Add enhancement description
            if center.name == "m_bonus" then
                data.enhancement = "Bonus (+30 Chips)"
            elseif center.name == "m_mult" then
                data.enhancement = "Mult (+4 Mult)"
            elseif center.name == "m_wild" then
                data.enhancement = "Wild (counts as all suits)"
            elseif center.name == "m_glass" then
                data.enhancement = "Glass (x2 Mult, 1/4 chance to destroy)"
            elseif center.name == "m_steel" then
                data.enhancement = "Steel (x1.5 Mult while held)"
            elseif center.name == "m_stone" then
                data.enhancement = "Stone (+50 Chips, no rank/suit, always scores)"
                data.chips = 50
            elseif center.name == "m_gold" then
                data.enhancement = "Gold ($3 at end of round if held)"
            elseif center.name == "m_lucky" then
                data.enhancement = "Lucky (1/5 for +20 Mult, 1/15 for $20)"
            end
        else
            data.enhancement = "None"
        end
    end

    -- Edition
    if card.edition then
        if card.edition.foil then
            data.edition = "Foil (+50 Chips)"
        elseif card.edition.holo then
            data.edition = "Holographic (+10 Mult)"
        elseif card.edition.polychrome then
            data.edition = "Polychrome (x1.5 Mult)"
        elseif card.edition.negative then
            data.edition = "Negative (+1 slot)"
        else
            data.edition = "Base"
        end
    end

    -- Seal
    if card.seal then
        if card.seal == "Gold" then
            data.seal = "Gold ($3 when played/scored)"
        elseif card.seal == "Red" then
            data.seal = "Red (retrigger 1x)"
        elseif card.seal == "Blue" then
            data.seal = "Blue (creates Planet if held at end)"
        elseif card.seal == "Purple" then
            data.seal = "Purple (creates Tarot when discarded)"
        else
            data.seal = card.seal
        end
    end

    -- Debuff
    data.debuffed = card.debuff or false

    return data
end

function State.extract_joker(card)
    if not card then return nil end
    local data = {
        name = "Unknown",
        rarity = "Common",
        description = "",
        sell_value = 0,
        edition = "Base",
        eternal = false,
        perishable = false,
        perishable_rounds = nil,
        rental = false,
    }

    -- Name
    if card.ability and card.ability.name then
        data.name = card.ability.name
    elseif card.config and card.config.center and card.config.center.name then
        data.name = card.config.center.name
    end

    -- Rarity
    if card.config and card.config.center then
        local rarity = card.config.center.rarity
        if rarity == 1 then data.rarity = "Common"
        elseif rarity == 2 then data.rarity = "Uncommon"
        elseif rarity == 3 then data.rarity = "Rare"
        elseif rarity == 4 then data.rarity = "Legendary"
        end
    end

    -- Description from localization, with variable substitution + markup stripped
    if card.config and card.config.center and card.config.center.key then
        local key = card.config.center.key
        data.description = State.render_description("Joker", key, card.config.center, card)
    end
    -- Fallback: try to build description from ability
    if data.description == "" and card.ability then
        data.description = State.describe_joker_ability(card)
    end

    -- Sell value
    data.sell_value = card.sell_cost or 0

    -- Edition
    if card.edition then
        if card.edition.foil then data.edition = "Foil (+50 Chips)"
        elseif card.edition.holo then data.edition = "Holographic (+10 Mult)"
        elseif card.edition.polychrome then data.edition = "Polychrome (x1.5 Mult)"
        elseif card.edition.negative then data.edition = "Negative (+1 Joker slot)"
        end
    end

    -- Stickers
    if card.ability then
        data.eternal = card.ability.eternal or false
        data.perishable = card.ability.perishable or false
        if data.perishable and card.ability.perish_tally then
            data.perishable_rounds = card.ability.perish_tally
        end
        data.rental = card.ability.rental or false
    end

    return data
end

function State.describe_joker_ability(card)
    if not card or not card.ability then return "No description available" end
    -- Try to get the label text that Balatro generates
    if card.label then return card.label end
    -- Build from generate_UIBox_ability_table if available
    if card.generate_UIBox_ability_table then
        local ok, info = pcall(card.generate_UIBox_ability_table, card)
        if ok and info and info.main then
            local parts = {}
            for _, item in ipairs(info.main) do
                if item.config and item.config.text then
                    for _, t in ipairs(item.config.text) do
                        if type(t) == "string" then
                            table.insert(parts, t)
                        end
                    end
                end
            end
            if #parts > 0 then return table.concat(parts, " ") end
        end
    end
    return "Effect varies based on context"
end

function State.extract_consumable(card)
    if not card then return nil end
    local data = {
        name = "Unknown",
        type = "Unknown", -- Tarot, Planet, Spectral
        description = "",
        sell_value = 0,
    }

    if card.ability and card.ability.name then
        data.name = card.ability.name
    end

    -- Determine type
    if card.ability and card.ability.set then
        data.type = card.ability.set
    elseif card.config and card.config.center then
        local center = card.config.center
        if center.set then
            data.type = center.set
        end
    end

    -- Description
    if card.config and card.config.center and card.config.center.key then
        local key = card.config.center.key
        local set_key = data.type
        data.description = State.render_description(set_key, key, card.config.center, card)
    end

    data.sell_value = card.sell_cost or 0

    return data
end

function State.extract_hand_levels()
    local levels = {}
    if not G or not G.GAME or not G.GAME.hands then return levels end

    local hand_order = {
        "High Card", "Pair", "Two Pair", "Three of a Kind",
        "Straight", "Flush", "Full House", "Four of a Kind",
        "Straight Flush", "Royal Flush", "Five of a Kind",
        "Flush House", "Flush Five"
    }

    for _, name in ipairs(hand_order) do
        local hand = G.GAME.hands[name]
        if hand then
            table.insert(levels, {
                name = name,
                level = hand.level or 1,
                chips = hand.chips or 0,
                mult = hand.mult or 0,
                played = hand.played or 0,
                visible = hand.visible or false,
            })
        end
    end
    return levels
end

function State.extract_shop()
    local shop = {
        cards = {},
        boosters = {},
        vouchers = {},
        reroll_cost = 5,
    }
    if not G then return shop end

    -- Shop cards (jokers, tarots, planets)
    if G.shop_jokers and G.shop_jokers.cards then
        for i, card in ipairs(G.shop_jokers.cards) do
            local item = {
                index = i,
                cost = card.cost or 0,
            }
            if card.ability and card.ability.set == "Joker" then
                item.type = "Joker"
                item.data = State.extract_joker(card)
            else
                item.type = card.ability and card.ability.set or "Unknown"
                item.data = State.extract_consumable(card)
            end
            table.insert(shop.cards, item)
        end
    end

    -- Booster packs
    if G.shop_booster and G.shop_booster.cards then
        for i, card in ipairs(G.shop_booster.cards) do
            local pack = {
                index = i,
                name = card.ability and card.ability.name or "Pack",
                cost = card.cost or 0,
                description = "",
            }
            -- Get pack description
            if card.config and card.config.center then
                local center = card.config.center
                if center.name then
                    pack.name = center.name
                end
                if center.config then
                    local c = center.config
                    pack.description = string.format("Choose %d of %d", c.choose or 1, c.extra or 3)
                end
            end
            table.insert(shop.boosters, pack)
        end
    end

    -- Vouchers
    if G.shop_vouchers and G.shop_vouchers.cards then
        for i, card in ipairs(G.shop_vouchers.cards) do
            local voucher = {
                index = i,
                name = card.ability and card.ability.name or "Voucher",
                cost = card.cost or 10,
                description = "",
            }
            if card.config and card.config.center and card.config.center.key then
                local key = card.config.center.key
                voucher.description = State.render_description("Voucher", key, card.config.center, card)
            end
            table.insert(shop.vouchers, voucher)
        end
    end

    -- Reroll cost
    if G.GAME then
        shop.reroll_cost = G.GAME.current_round and G.GAME.current_round.reroll_cost or 5
    end

    return shop
end

function State.extract_blinds()
    local blinds = {
        small = nil,
        big = nil,
        boss = nil,
        current = nil,
        on_deck = nil,  -- "Small" | "Big" | "Boss" — which blind the select is pointing at
        states = nil,   -- {Small=..., Big=..., Boss=...}
    }
    if not G or not G.GAME then return blinds end

    -- The base chip amount for THIS ante (300 at ante 1, 800 at 2, etc.)
    -- Real computation is get_blind_amount(ante); fall back to vanilla scaling.
    local ante = (G.GAME.round_resets and G.GAME.round_resets.ante) or 1
    local base = 300
    if type(get_blind_amount) == "function" then
        local ok, amt = pcall(get_blind_amount, ante)
        if ok and type(amt) == "number" then base = amt end
    else
        local vanilla = {300, 800, 2000, 5000, 11000, 20000, 35000, 50000}
        base = vanilla[ante] or 300
    end

    -- Pull the three mults from P_BLINDS so we report correct ratios
    local small_mult = (G.P_BLINDS and G.P_BLINDS.bl_small and G.P_BLINDS.bl_small.mult) or 1
    local big_mult   = (G.P_BLINDS and G.P_BLINDS.bl_big   and G.P_BLINDS.bl_big.mult)   or 1.5
    local boss_mult  = 2

    blinds.on_deck = G.GAME.blind_on_deck
    if G.GAME.round_resets and G.GAME.round_resets.blind_states then
        local bs = G.GAME.round_resets.blind_states
        blinds.states = { Small = bs.Small, Big = bs.Big, Boss = bs.Boss }
    end

    -- Current blind info (set once a blind is selected)
    if G.GAME.blind then
        blinds.current = {
            name = G.GAME.blind.name or "Unknown",
            chips = G.GAME.blind.chips or 0,
            effect = "",
        }
        if G.GAME.blind.config and G.GAME.blind.config.blind then
            local b = G.GAME.blind.config.blind
            blinds.current.effect = State.render_description("Blind", b.key, b, G.GAME.blind)
        end
    end

    -- Skip-tag lookup: when the player SKIPS Small or Big, they earn the
    -- tag pre-selected in G.GAME.round_resets.blind_tags. Boss can't be
    -- skipped. We resolve both the display name and the description text
    -- so the model can reason about whether skipping is worth it.
    local function _tag_info(tag_key)
        if not tag_key then return nil end
        local tag_def = G.P_TAGS and G.P_TAGS[tag_key] or nil
        if not tag_def then return { key = tag_key, name = tag_key, description = "" } end
        return {
            key = tag_key,
            name = tag_def.name or tag_key,
            description = State.render_description("Tag", tag_key, tag_def, nil),
        }
    end
    local skip_small = G.GAME.round_resets and G.GAME.round_resets.blind_tags
                       and G.GAME.round_resets.blind_tags.Small or nil
    local skip_big   = G.GAME.round_resets and G.GAME.round_resets.blind_tags
                       and G.GAME.round_resets.blind_tags.Big or nil

    -- Small / Big targets for the CURRENT ante
    blinds.small = {
        name = "Small Blind",
        chips = math.floor(small_mult * base),
        reward = 3,
        skip_tag = _tag_info(skip_small),
    }
    blinds.big = {
        name = "Big Blind",
        chips = math.floor(big_mult * base),
        reward = 4,
        skip_tag = _tag_info(skip_big),
    }

    -- Boss blind: name, effect, and its actual chip target for this ante
    local boss_key = G.GAME.round_resets and G.GAME.round_resets.blind_choices and
                     G.GAME.round_resets.blind_choices.Boss
    local boss_def = boss_key and G.P_BLINDS and G.P_BLINDS[boss_key] or nil
    if boss_def then
        boss_mult = boss_def.mult or 2
    end
    blinds.boss = {
        name = (boss_def and boss_def.name) or "Boss Blind",
        chips = math.floor(boss_mult * base),
        reward = 5,
        effect = "",
    }
    if boss_key then
        blinds.boss.effect = State.render_description("Blind", boss_key, boss_def, G.GAME.blind)
    end

    return blinds
end

function State.extract_pack_cards()
    local cards = {}
    if not G or not G.pack_cards then return cards end

    if G.pack_cards and G.pack_cards.cards then
        for i, card in ipairs(G.pack_cards.cards) do
            local data
            if card.ability and card.ability.set == "Joker" then
                data = State.extract_joker(card)
                data.item_type = "Joker"
            elseif card.ability and (card.ability.set == "Tarot" or card.ability.set == "Planet" or card.ability.set == "Spectral") then
                data = State.extract_consumable(card)
                data.item_type = card.ability.set
            else
                -- Standard pack playing card
                data = State.extract_card(card)
                data.item_type = "Playing Card"
            end
            data.index = i
            table.insert(cards, data)
        end
    end
    return cards
end

function State.extract_tags()
    local tags = {}
    if not G or not G.GAME or not G.GAME.tags then return tags end

    for _, tag in ipairs(G.GAME.tags) do
        local key = tag.key or (tag.config and tag.config.type)
        local tag_def = key and G.P_TAGS and G.P_TAGS[key] or nil
        local desc = ""
        if key then
            desc = State.render_description("Tag", key, tag_def, tag)
        end
        if desc == "" then
            desc = (tag.config and tag.config.text) or ""
        end
        table.insert(tags, {
            name = tag.name or "Unknown Tag",
            description = desc,
        })
    end
    return tags
end

function State.get_full_state()
    if not G or not G.GAME then
        return {
            phase = "MENU",
            error = "Game not loaded",
        }
    end

    local state = {
        phase = State.get_phase(),
        -- Run info
        seed = G.GAME.pseudorandom and G.GAME.pseudorandom.seed or "",
        ante = G.GAME.round_resets and G.GAME.round_resets.ante or 0,
        max_ante = 8,
        round = G.GAME.round or 0,
        stake = G.GAME.stake or 1,
        deck = G.GAME.selected_back and G.GAME.selected_back.name or "Unknown",

        -- Economy. Interest is floor(dollars/5) capped at interest_cap, and
        -- clamped to >= 0 — you don't earn negative interest when broke.
        dollars = G.GAME.dollars or 0,
        interest_cap = G.GAME.interest_cap or 5,
        interest_amount = math.max(0, math.min(
            math.floor((G.GAME.dollars or 0) / 5),
            G.GAME.interest_cap or 5
        )),

        -- Round state
        hands_left = G.GAME.current_round and G.GAME.current_round.hands_left or 0,
        discards_left = G.GAME.current_round and G.GAME.current_round.discards_left or 0,
        hand_size = G.hand and G.hand.config and G.hand.config.card_limit or 8,
        target_score = G.GAME.blind and G.GAME.blind.chips or 0,
        current_score = G.GAME.chips or 0,

        -- Cards in hand
        hand = {},
        -- Jokers
        jokers = {},
        joker_slots = G.jokers and G.jokers.config and G.jokers.config.card_limit or 5,
        -- Consumables
        consumables = {},
        consumable_slots = G.consumeables and G.consumeables.config and G.consumeables.config.card_limit or 2,

        -- Hand levels
        hand_levels = State.extract_hand_levels(),

        -- Deck info
        deck_size = G.deck and G.deck.cards and #G.deck.cards or 0,
        hand_count = G.hand and G.hand.cards and #G.hand.cards or 0,

        -- Blinds
        blinds = State.extract_blinds(),

        -- Shop (only in shop phase)
        shop = nil,

        -- Pack cards (only in pack phase)
        pack = nil,

        -- Tags
        tags = State.extract_tags(),

        -- Run stats. G.GAME.round is Balatro's round counter; it increments at
        -- blind-select via ease_round(1). Before the first blind it's 0, and
        -- while a blind is in progress the current round is already counted.
        -- So "rounds completed" = round - (1 if currently facing a blind else 0).
        stats = (function()
            local round = G.GAME.round or 0
            local in_blind = G.GAME.facing_blind and 1 or 0
            local completed = math.max(0, round - in_blind)
            local highest = 0
            if G.GAME.round_scores and G.GAME.round_scores.hand then
                highest = G.GAME.round_scores.hand.high_score or 0
            end
            return {
                rounds_won = completed,
                round = round,
                highest_hand = highest,
            }
        end)(),
    }

    -- Extract hand cards
    if G.hand and G.hand.cards then
        for i, card in ipairs(G.hand.cards) do
            local extracted = State.extract_card(card)
            if extracted then
                extracted.index = i
                table.insert(state.hand, extracted)
            end
        end
    end

    -- Extract jokers
    if G.jokers and G.jokers.cards then
        for i, card in ipairs(G.jokers.cards) do
            local extracted = State.extract_joker(card)
            if extracted then
                extracted.index = i
                table.insert(state.jokers, extracted)
            end
        end
    end

    -- Extract consumables
    if G.consumeables and G.consumeables.cards then
        for i, card in ipairs(G.consumeables.cards) do
            local extracted = State.extract_consumable(card)
            if extracted then
                extracted.index = i
                table.insert(state.consumables, extracted)
            end
        end
    end

    -- Shop data (only in shop phase)
    if state.phase == "SHOP" then
        state.shop = State.extract_shop()
    end

    -- Pack data (only in pack phases)
    if State.is_pack_phase() then
        state.pack = {
            cards = State.extract_pack_cards(),
            phase = state.phase,
        }
        -- Pack choose/total info
        if G.pack_cards then
            state.pack.choose = G.pack_cards.config and G.pack_cards.config.card_limit or 1
        end
    end

    -- Calculate total deck size including all locations
    local total_deck = (G.deck and G.deck.cards and #G.deck.cards or 0)
                     + (G.hand and G.hand.cards and #G.hand.cards or 0)
                     + (G.play and G.play.cards and #G.play.cards or 0)
                     + (G.discard and G.discard.cards and #G.discard.cards or 0)
    state.total_deck_size = total_deck

    return state
end

return State
