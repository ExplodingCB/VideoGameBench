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

-- Load base-game reference catalog (deterministic fallback for numbered items)
local base_game_ref = nil
local function _load_base_game_ref()
    if base_game_ref then return base_game_ref end
    local ok, ref = pcall(function()
        return require("balatrobench_base_game_ref")
    end)
    if ok and type(ref) == "table" then
        base_game_ref = ref
        return ref
    end
    return nil
end

---------------------------------------------------------------------------
-- Base game reference lookup and token resolution
---------------------------------------------------------------------------

local function _resolve_token(token_name, loc_ref, card)
    -- Resolve placeholder tokens like {t_mult}, {type}, {suit}, etc.
    -- from card.config, card.ability, loc_ref.config, etc.

    if not token_name or token_name == "" then return nil end

    -- Check card.config first (primary location for most abilities)
    if card and type(card.config) == "table" then
        if card.config[token_name] ~= nil then return card.config[token_name] end
        if type(card.config.extra) == "table" and card.config.extra[token_name] ~= nil then
            return card.config.extra[token_name]
        end
    end

    -- Check card.ability (for instance-specific state)
    if card and type(card.ability) == "table" then
        if card.ability[token_name] ~= nil then return card.ability[token_name] end
        if type(card.ability.extra) == "table" and card.ability.extra[token_name] ~= nil then
            return card.ability.extra[token_name]
        end
    end

    -- Check loc_ref.config (center definition)
    if loc_ref and type(loc_ref.config) == "table" then
        if loc_ref.config[token_name] ~= nil then return loc_ref.config[token_name] end
        if type(loc_ref.config.extra) == "table" and loc_ref.config.extra[token_name] ~= nil then
            return loc_ref.config.extra[token_name]
        end
    end

    -- For planet cards, resolve hand_type as the hand name
    if token_name == "hand_type" and loc_ref and loc_ref.config and loc_ref.config.hand_type then
        return loc_ref.config.hand_type
    end

    -- For tags with special lookups (orbital, etc.)
    if card and type(card.config) == "table" then
        if token_name == "orbital_hand" then return card.config.hand_type end
        if token_name == "levels" then return card.config.levels end
    end

    return nil
end

local function _render_from_catalog(set, key, loc_ref, card)
    -- Render using the base-game reference catalog.
    -- Returns nil if entry not found or if catalog can't be loaded.
    local ref = _load_base_game_ref()
    if not ref or not ref.by_key then return nil end

    local entry = ref.by_key[key]
    if not entry or entry.set ~= set then return nil end

    -- Handle static text entries
    if entry.text then
        return entry.text
    end

    -- Handle template entries with token substitution
    if entry.template and entry.tokens then
        local result = entry.template
        for _, token in ipairs(entry.tokens) do
            local value = _resolve_token(token, loc_ref, card)
            if value ~= nil then
                value = tostring(value)
                result = result:gsub("{" .. token .. "}", value)
            end
        end

        -- Remove any unreplaced tokens (shouldn't happen for base game)
        result = result:gsub("{[%w_]+}", "?")
        return result
    end

    -- Handle special computed cases
    if entry.kind == "planet_level_up" then
        -- hand_type from loc_ref.config takes precedence; fall back to
        -- the hint stored in the catalog entry itself.
        local hand_type = (loc_ref and loc_ref.config and loc_ref.config.hand_type)
                          or entry.hand_type
        if hand_type then
            local hand = G and G.GAME and G.GAME.hands and G.GAME.hands[hand_type]
            local level = (hand and hand.level) or 1
            local scale_mult = (hand and hand.l_mult) or loc_ref.mult or loc_ref.l_mult
            local scale_chips = (hand and hand.l_chips) or loc_ref.chips or loc_ref.l_chips
            local mult_part = scale_mult and ("+" .. tostring(scale_mult) .. " Mult") or ""
            local chips_part = scale_chips and ("+" .. tostring(scale_chips) .. " Chips") or ""
            local joiner = (mult_part ~= "" and chips_part ~= "") and " and " or ""
            return string.format(
                "(Lvl %d) Levels up %s: %s%s%s per use",
                level, hand_type, mult_part, joiner, chips_part
            )
        end
    end

    if entry.kind == "tag_orbital_levelup" and card then
        -- Orbital tag: "Upgrade {hand_type} by {levels} levels"
        local hand_type = card.config and card.config.hand_type
        local levels = card.config and card.config.levels
        if hand_type and levels and not tostring(hand_type):find("^%[") then
            return string.format("Upgrade %s by %s levels", tostring(hand_type), tostring(levels))
        end
    end

    return nil
end

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

    -- Find the highest numeric index in `vars`. We CAN'T use ipairs or #vars
    -- because either stops at the first nil — and loc_vars on partially-
    -- initialized shop cards often returns sparse tables like {15, nil}
    -- (when a late-populated ability.extra field isn't set yet). That
    -- would leave #2# unsubstituted and rendered as "?", which is the
    -- exact bug that made Mystic Summit show "+? Mult when ? discards".
    local max_idx = 0
    for k, _ in pairs(vars) do
        if type(k) == "number" and k > max_idx then max_idx = k end
    end

    local out = {}
    for _, line in ipairs(lines) do
        local s = tostring(line)
        -- Substitute #1#, #2#, ... up to the highest present index,
        -- skipping nil entries rather than stopping at them.
        for i = 1, max_idx do
            local v = vars[i]
            if v ~= nil then
                s = s:gsub("#" .. i .. "#", tostring(v))
            end
        end
        -- Any leftover #N# means the template wanted more vars than the
        -- center's loc_vars provided. Replace with ? so the text is at
        -- least legible, but leave a comment so readers of a JSONL event
        -- log can tell this was a best-effort substitution, not a real
        -- game value.
        s = s:gsub("#%d+#", "?")
        table.insert(out, s)
    end
    return out
end

-- Helper for _walk_ui_text: extract text from something that might be
-- a plain string, a list, a DynaText segment, or a callable. Returns
-- a list of strings (possibly empty). Function-valued fields are
-- invoked with pcall — DynaText often stores `string` as a closure
-- over the current mult/chips/level value so the displayed text stays
-- live as the game state changes. Calling the closure gives us the
-- current render.
local function _extract_strings(value, acc)
    acc = acc or {}
    if type(value) == "string" then
        if value ~= "" then table.insert(acc, value) end
    elseif type(value) == "function" then
        local ok, result = pcall(value)
        if ok then _extract_strings(result, acc) end
    elseif type(value) == "table" then
        -- Plain list of strings / segments
        for _, piece in ipairs(value) do
            if type(piece) == "string" then
                if piece ~= "" then table.insert(acc, piece) end
            elseif type(piece) == "table" then
                -- DynaText segments are {string=..., colour=..., scale=...}
                if type(piece.string) == "string" then
                    table.insert(acc, piece.string)
                elseif type(piece.string) == "function" then
                    local ok, s = pcall(piece.string)
                    if ok and type(s) == "string" then table.insert(acc, s) end
                end
            end
        end
    end
    return acc
end

-- Recursively walk a UIBox node tree collecting text chunks. Balatro's
-- description nodes store their strings across MULTIPLE locations
-- depending on node type and version:
--   node.config.text             — static text on G.UIT.T nodes
--   node.config.object.string    — on some Moveable objects
--   node.config.object.strings   — DynaText's processed strings list
--   node.config.object.config.string — DynaText's raw input segments
-- Any of these can be a plain string, a list, or a callable closure
-- (DynaText uses closures for live values like joker mult/chips that
-- scale with the game state). _extract_strings handles all four shapes.
local function _walk_ui_text(node, out, depth, visited)
    depth = depth or 0
    visited = visited or {}
    if depth > 40 then return end
    if type(node) ~= "table" then return end
    if visited[node] then return end
    visited[node] = true

    if node.config then
        _extract_strings(node.config.text, out)
        local obj = node.config.object
        if type(obj) == "table" then
            -- All four candidate locations for DynaText text
            _extract_strings(obj.string, out)
            _extract_strings(obj.strings, out)
            if type(obj.config) == "table" then
                _extract_strings(obj.config.string, out)
                _extract_strings(obj.config.strings, out)
            end
        end
    end

    -- Recurse into children. Skip `parent` to avoid cycles and `config`
    -- (already handled above).
    for k, v in pairs(node) do
        if k ~= "parent" and k ~= "config" and type(v) == "table" then
            _walk_ui_text(v, out, depth + 1, visited)
        end
    end
end

-- Canonical path: ask Balatro's own Card class to build the rendered
-- description (name, main body, info) as a UIBox fragment, then extract
-- the text. This handles Planet cards (where the hand name/level/scaling
-- come from `card.config.center.config.hand_type` + the hand's own level
-- table, and the center has NO loc_vars), Jokers with special-cased vars,
-- Vouchers, Tags, etc. — whatever the game would show you on hover. We
-- only consume abil.main (the description body) so we don't duplicate the
-- item name (already printed by the format layer) or the badge labels
-- (eternal/perishable — already surfaced separately in fmt_joker).
local function _render_via_ability_table(card)
    if not card or type(card.generate_UIBox_ability_table) ~= "function" then
        return nil
    end
    local ok, abil = pcall(card.generate_UIBox_ability_table, card)
    if not ok or type(abil) ~= "table" then return nil end

    local parts = {}
    if abil.main then _walk_ui_text(abil.main, parts) end
    if abil.info then _walk_ui_text(abil.info, parts) end
    -- Some set-types return the description nested under other keys
    -- (e.g. `abil.loc_vars`-less Tags put their lines at the top level).
    -- If main/info produced nothing, fall back to walking everything
    -- except the name and badge subtrees.
    if #parts == 0 then
        for k, v in pairs(abil) do
            if type(v) == "table" and k ~= "name" and k ~= "badges"
                    and k ~= "card_type" and k ~= "h_popup" then
                _walk_ui_text(v, parts)
            end
        end
    end

    if #parts == 0 then return nil end
    local s = table.concat(parts, " ")
    -- Collapse internal whitespace so we don't leak tab/newline artifacts
    -- from UIBox layout spacing.
    s = s:gsub("[\n\t]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- Direct Planet fallback for when ability-table extraction isn't
-- available (card hasn't been fully initialized, or SMODS hook has
-- replaced generate_UIBox_ability_table in an incompatible way). Builds a
-- human-readable sentence from the planet center's `config.hand_type`
-- plus the current hand level values from G.GAME.hands. Never produces
-- `?` placeholders.
local function _render_planet_fallback(loc_ref)
    if not loc_ref or not loc_ref.config or not loc_ref.config.hand_type then return nil end
    local hand_type = loc_ref.config.hand_type
    local hand = G.GAME and G.GAME.hands and G.GAME.hands[hand_type]
    local level = (hand and hand.level) or 1
    -- Per-level scaling lives on the hand definition (l_mult / l_chips).
    -- Fall back to the planet's own fields if present.
    local scale_mult = (hand and hand.l_mult) or loc_ref.mult or loc_ref.l_mult
    local scale_chips = (hand and hand.l_chips) or loc_ref.chips or loc_ref.l_chips
    local mult_part = scale_mult and ("+" .. tostring(scale_mult) .. " Mult") or ""
    local chips_part = scale_chips and ("+" .. tostring(scale_chips) .. " Chips") or ""
    local joiner = (mult_part ~= "" and chips_part ~= "") and " and " or ""
    return string.format(
        "(Lvl %d) Levels up %s: %s%s%s per use",
        level, hand_type, mult_part, joiner, chips_part
    )
end

local function _clean_description(s)
    if not s or s == "" then return nil end
    s = strip_markup(s)
    s = s:gsub("[\n\t]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

local function _count_placeholders(s)
    local cleaned = _clean_description(s)
    if not cleaned then return math.huge end
    local n = 0
    for _ in cleaned:gmatch("%?") do
        n = n + 1
    end
    return n
end

local function _pick_better_description(best, candidate)
    local normalized_best = _clean_description(best)
    local normalized_candidate = _clean_description(candidate)
    if not normalized_candidate then return normalized_best end
    if not normalized_best then return normalized_candidate end

    local best_placeholders = _count_placeholders(normalized_best)
    local candidate_placeholders = _count_placeholders(normalized_candidate)
    if candidate_placeholders < best_placeholders then
        return normalized_candidate
    end
    if candidate_placeholders > best_placeholders then
        return normalized_best
    end
    if best_placeholders > 0 and #normalized_candidate > #normalized_best then
        return normalized_candidate
    end
    return normalized_best
end

local function _lookup_structured_value(loc_ref, card, name)
    if loc_ref and type(loc_ref.config) == "table" and loc_ref.config[name] ~= nil then
        return loc_ref.config[name]
    end
    if loc_ref and type(loc_ref.config) == "table"
            and type(loc_ref.config.extra) == "table"
            and loc_ref.config.extra[name] ~= nil then
        return loc_ref.config.extra[name]
    end
    if card and type(card.config) == "table" and card.config[name] ~= nil then
        return card.config[name]
    end
    if card and type(card.ability) == "table" and card.ability[name] ~= nil then
        return card.ability[name]
    end
    if card and type(card.ability) == "table"
            and type(card.ability.extra) == "table"
            and card.ability.extra[name] ~= nil then
        return card.ability.extra[name]
    end
    return nil
end

local function _push_known_pair(out, seen, label, value)
    local value_type = type(value)
    if value_type ~= "number" and value_type ~= "string" and value_type ~= "boolean" then
        return
    end
    local entry = label .. "=" .. tostring(value)
    if not seen[entry] then
        seen[entry] = true
        table.insert(out, entry)
    end
end

local function _append_table_values(out, seen, prefix, tbl, names)
    if type(tbl) ~= "table" then return end
    for _, name in ipairs(names) do
        _push_known_pair(out, seen, prefix .. name, tbl[name])
    end
end

local function _append_known_values(description, loc_ref, card)
    local s = _clean_description(description)
    if not s then return "" end
    if not s:find("%?") then return s end

    local pairs_list = {}
    local seen = {}
    local fields = {
        "t_mult", "t_chips", "s_mult", "x_mult", "mult", "chips",
        "extra", "extra_disp", "type", "suit", "hand_type",
        "levels", "dollars", "odds", "max", "h_size",
        "dollars_per_hand", "dollars_per_discard",
        "spawn_jokers", "skip_bonus", "orbital_hand"
    }

    if loc_ref then
        _append_table_values(pairs_list, seen, "center.", loc_ref, fields)
        if type(loc_ref.config) == "table" then
            _append_table_values(pairs_list, seen, "config.", loc_ref.config, fields)
            if type(loc_ref.config.extra) == "table" then
                _append_table_values(pairs_list, seen, "config.extra.", loc_ref.config.extra, fields)
            end
        end
    end

    if card then
        _append_table_values(pairs_list, seen, "card.", card, fields)
        if type(card.config) == "table" then
            _append_table_values(pairs_list, seen, "card.config.", card.config, fields)
        end
        if type(card.ability) == "table" then
            _append_table_values(pairs_list, seen, "ability.", card.ability, fields)
            if type(card.ability.extra) == "table" then
                _append_table_values(pairs_list, seen, "ability.extra.", card.ability.extra, fields)
            end
        end
    end

    table.sort(pairs_list)
    if #pairs_list > 0 then
        s = s .. " [known values: " .. table.concat(pairs_list, ", ") .. "]"
    end
    return s
end

local function _render_known_fallback(set, key, loc_ref, card)
    local played_type = _lookup_structured_value(loc_ref, card, "type")
    local t_mult = _lookup_structured_value(loc_ref, card, "t_mult")
    if played_type and t_mult then
        return string.format("+%s Mult if played hand contains a %s", tostring(t_mult), tostring(played_type))
    end

    local t_chips = _lookup_structured_value(loc_ref, card, "t_chips")
    if played_type and t_chips then
        return string.format("+%s Chips if played hand contains a %s", tostring(t_chips), tostring(played_type))
    end

    local suit = _lookup_structured_value(loc_ref, card, "suit")
    local s_mult = _lookup_structured_value(loc_ref, card, "s_mult")
    if suit and s_mult then
        return string.format("+%s Mult for scored %s cards", tostring(s_mult), tostring(suit))
    end

    if set == "Voucher" then
        local display_extra = _lookup_structured_value(loc_ref, card, "extra_disp")
        local raw_extra = _lookup_structured_value(loc_ref, card, "extra")
        local shown_extra = display_extra or raw_extra
        if (key == "v_tarot_merchant" or key == "v_tarot_tycoon") and shown_extra then
            return string.format("Tarot cards appear %sX more frequently in the shop", tostring(shown_extra))
        end
        if (key == "v_planet_merchant" or key == "v_planet_tycoon") and shown_extra then
            return string.format("Planet cards appear %sX more frequently in the shop", tostring(shown_extra))
        end
        if (key == "v_clearance_sale" or key == "v_liquidation") and raw_extra then
            return string.format("All cards and packs in the shop are %s%% off", tostring(raw_extra))
        end
        if (key == "v_hone" or key == "v_glow_up") and raw_extra then
            return string.format(
                "Foil, Holographic, and Polychrome cards appear %sX more often",
                tostring(raw_extra)
            )
        end
    end

    if set == "Tag" then
        if key == "tag_investment" then
            local dollars = _lookup_structured_value(loc_ref, card, "dollars")
            if dollars then
                return string.format("After defeating the Boss Blind, gain $%s", tostring(dollars))
            end
        end
        if key == "tag_handy" then
            local dollars_per_hand = _lookup_structured_value(loc_ref, card, "dollars_per_hand")
            if dollars_per_hand then
                return string.format("Earn $%s per hand played this run", tostring(dollars_per_hand))
            end
        end
        if key == "tag_garbage" then
            local dollars_per_discard = _lookup_structured_value(loc_ref, card, "dollars_per_discard")
            if dollars_per_discard then
                return string.format("Earn $%s per unused discard this run", tostring(dollars_per_discard))
            end
        end
        if key == "tag_juggle" then
            local hand_size = _lookup_structured_value(loc_ref, card, "h_size")
            if hand_size then
                return string.format("+%s hand size next round", tostring(hand_size))
            end
        end
        if key == "tag_top_up" then
            local spawn_jokers = _lookup_structured_value(loc_ref, card, "spawn_jokers")
            if spawn_jokers then
                return string.format("Create up to %s Common Jokers", tostring(spawn_jokers))
            end
        end
        if key == "tag_skip" then
            local skip_bonus = _lookup_structured_value(loc_ref, card, "skip_bonus")
            if skip_bonus then
                return string.format("Earn $%s per skipped Blind this run", tostring(skip_bonus))
            end
        end
        if key == "tag_orbital" then
            local hand_type = _lookup_structured_value(loc_ref, card, "orbital_hand")
            local levels = _lookup_structured_value(loc_ref, card, "levels")
            if hand_type and levels and not tostring(hand_type):find("^%[") then
                return string.format("Upgrade %s by %s levels", tostring(hand_type), tostring(levels))
            end
        end
        if key == "tag_economy" then
            local dollars = _lookup_structured_value(loc_ref, card, "max")
            if dollars then
                return string.format("Double your money (Max of $%s)", tostring(dollars))
            end
        end
    end

    return nil
end

function State.render_description(set, key, loc_ref, card)
    local best = nil

    -- PRIMARY: Try the base-game reference catalog first.
    -- This provides deterministic, known-good descriptions for all
    -- base-game items and avoids unresolved #N# placeholders.
    if set and key then
        best = _pick_better_description(best, _render_from_catalog(set, key, loc_ref, card))
    end

    -- PREFERRED: canonical Balatro render via the Card's ability table.
    -- This handles Planets, Jokers, Vouchers, Tarots, Spectrals — anything
    -- with per-card variable substitution. Only available when we have a
    -- live Card instance (not for tags or blinds, which go through the
    -- loc_vars path below).
    if card then
        best = _pick_better_description(best, _render_via_ability_table(card))
    end

    best = _pick_better_description(best, _render_known_fallback(set, key, loc_ref, card))
    if set == "Planet" then
        best = _pick_better_description(best, _render_planet_fallback(loc_ref))
    end

    if not set or not key then return _append_known_values(best, loc_ref, card) end
    if not (G and G.localization and G.localization.descriptions) then
        return _append_known_values(best, loc_ref, card)
    end
    local bucket = G.localization.descriptions[set]
    if not bucket then return _append_known_values(best, loc_ref, card) end
    local loc = bucket[key]
    if not loc or not loc.text then return _append_known_values(best, loc_ref, card) end

    -- Ask the center for its substitution vars. This is how Balatro's own
    -- UI resolves per-joker numeric placeholders for cards whose centers
    -- implement `loc_vars()` directly (most Jokers, some consumables).
    local vars = {}
    if loc_ref and type(loc_ref.loc_vars) == "function" then
        local info_queue = {}
        local ok, loc_def = pcall(loc_ref.loc_vars, loc_ref, info_queue, card)
        if ok and type(loc_def) == "table" and loc_def.vars then
            vars = loc_def.vars
        end
    elseif set == "Tag" and card and type(card.get_uibox_table) == "function" then
        local ok, tag_vars = pcall(card.get_uibox_table, card, nil, true)
        if ok and type(tag_vars) == "table" then
            vars = tag_vars
        end
    end

    local rendered = substitute_vars(loc.text, vars)
    local s = table.concat(rendered, " ")
    best = _pick_better_description(best, s)

    -- TRAILING-NIL DISCLOSURE: even after substitute_vars, `?` markers
    -- can remain in two cases:
    --   1. loc_vars returned a sparse table where the missing index is
    --      at the tail (e.g. `{15, nil}` in Lua has no index 2 stored;
    --      pairs() sees max_idx == 1 and we substitute #1# but leave
    --      #2# for the `?` fallback).
    --   2. loc_vars wasn't defined on the center at all and returned no
    --      vars.
    -- In both cases the model reads something like "+15 Mult when ?
    -- discards remaining", which is actively harmful — the model
    -- doesn't know if "?" is a small number or a large one, whether
    -- the joker is situational, etc.
    --
    -- Best we can do without refactoring loc_vars is DUMP the raw
    -- ability.extra key/value pairs next to the description so the
    -- model at least sees the numbers that exist, in a format it can
    -- read. Only fires when the rendered description still has `?`
    -- (the common case is zero).
    return _append_known_values(best, loc_ref, card)
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

        -- Tag centers' loc_vars reads from a Tag INSTANCE's config
        -- (Investment Tag wants `tag.config.dollars`, Orbital Tag wants
        -- `tag.config.hand_type` and `tag.config.levels`, Economy Tag
        -- wants `tag.config.dollars` for the cap, etc.). For
        -- upcoming-skip-reward previews we don't have a live instance
        -- yet, so we build one. Tag() is Balatro's canonical
        -- constructor (Object:extend() __call metamethod) — it copies
        -- the center's config into a fresh instance and fills in any
        -- defaults loc_vars relies on. The `true` second arg signals
        -- "preview mode" which populates chip/coin amounts for display.
        local instance = nil
        local ok, t = pcall(function()
            if type(Tag) == "table" or type(Tag) == "function" then
                return Tag(tag_key, true)
            end
            return nil
        end)
        if ok and type(t) == "table" then
            instance = t
            if type(instance.set_ability) == "function" then
                pcall(instance.set_ability, instance)
            end
        end

        if not instance then
            -- Fallback: hand-build a minimal tag-like table with just
            -- the center's config copied. Enough for most simple
            -- loc_vars implementations even when Balatro's Tag class
            -- isn't hooked up yet (very early load).
            instance = {
                key = tag_key,
                config = {},
                ability = {set = "Tag", name = tag_def.name},
            }
            if type(tag_def.config) == "table" then
                for k, v in pairs(tag_def.config) do instance.config[k] = v end
            end
        end

        return {
            key = tag_key,
            name = tag_def.name or tag_key,
            description = State.render_description("Tag", tag_key, tag_def, instance),
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
