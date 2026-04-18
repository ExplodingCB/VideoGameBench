-- BalatroBench Text Formatter
-- Converts extracted game state into readable text for AI models

local Format = {}

local function fmt_money(n)
    return "$" .. tostring(n or 0)
end

local function fmt_number(n)
    if not n then return "0" end
    if n >= 1000000 then
        return string.format("%.1fM", n / 1000000)
    elseif n >= 1000 then
        return string.format("%s,%03d", tostring(math.floor(n / 1000)), n % 1000)
    end
    return tostring(n)
end

-- Format a single playing card
local function fmt_card(card, index)
    if card.face_down then
        return string.format("[%d] ??? (Face Down)", index)
    end
    local parts = {}
    table.insert(parts, string.format("[%d] %s of %s", index, card.rank, card.suit))
    table.insert(parts, string.format("| Chips: %d", card.chips))

    if card.edition ~= "Base" then
        table.insert(parts, string.format("| Edition: %s", card.edition))
    end
    if card.enhancement ~= "None" then
        table.insert(parts, string.format("| Enhancement: %s", card.enhancement))
    end
    if card.seal ~= "None" then
        table.insert(parts, string.format("| Seal: %s", card.seal))
    end
    if card.debuffed then
        table.insert(parts, "| DEBUFFED")
    end

    return table.concat(parts, " ")
end

-- Format a joker. Intentionally omits the "sell value" dollar amount on
-- the header line — the presence of $N next to each owned joker was
-- priming weaker models into a "free money, cash it out" reflex, causing
-- them to sell their own working jokers for half price. Models that
-- actually need the sell refund can compute it (half the buy price,
-- rounded down — documented in the system prompt).
local function fmt_joker(joker, index)
    local line1 = string.format("[%d] %s (%s)",
        index, joker.name, joker.rarity)

    local extras = {}
    if joker.edition ~= "Base" then
        table.insert(extras, "Edition: " .. joker.edition)
    end
    if joker.eternal then table.insert(extras, "ETERNAL (cannot sell/destroy)") end
    if joker.perishable then
        local rounds = joker.perishable_rounds and (" - " .. joker.perishable_rounds .. " rounds left") or ""
        table.insert(extras, "PERISHABLE" .. rounds)
    end
    if joker.rental then table.insert(extras, "RENTAL (-$3/round)") end

    local line2 = "    Effect: " .. (joker.description ~= "" and joker.description or "See in-game description")
    if #extras > 0 then
        line2 = line2 .. " | " .. table.concat(extras, " | ")
    end

    return line1 .. "\n" .. line2
end

-- Format a consumable. Same rationale as fmt_joker for hiding sell value.
local function fmt_consumable(cons, index)
    return string.format("[%d] %s (%s)\n    Effect: %s",
        index, cons.name, cons.type,
        cons.description ~= "" and cons.description or "See in-game description")
end

-- Format hand levels table
local function fmt_hand_levels(levels)
    local lines = {}
    for _, h in ipairs(levels) do
        if h.visible then
            table.insert(lines, string.format("%-18s Lv.%d: %d Chips + %d Mult",
                h.name, h.level, h.chips, h.mult))
        end
    end
    return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Phase formatters
---------------------------------------------------------------------------

function Format.blind_select(state)
    local lines = {}

    table.insert(lines, "=== BALATRO BENCH ===")
    table.insert(lines, string.format("Run Seed: %s | Deck: %s | Stake: %d",
        state.seed, state.deck, state.stake))
    table.insert(lines, string.format("Ante: %d/%d | Phase: Blind Select",
        state.ante, state.max_ante))
    table.insert(lines, string.format("Money: %s | Interest: %s/round",
        fmt_money(state.dollars), fmt_money(state.interest_amount)))
    table.insert(lines, "")

    -- Upcoming blinds. Show state per blind from G.GAME.round_resets.blind_states,
    -- and mark which one the `select` action will play (on_deck).
    table.insert(lines, "--- UPCOMING BLINDS ---")
    local states = state.blinds.states or {}
    local on_deck = state.blinds.on_deck
    local function fmt_status(key)
        local s = states[key]
        if key == on_deck then return "On Deck" end
        if s == "Defeated" then return "Defeated"
        elseif s == "Skipped"  then return "Skipped"
        elseif s == "Current"  then return "In Progress"
        elseif s == "Upcoming" then return "Upcoming"
        elseif s == "Select"   then return "Available"
        end
        return s or "Upcoming"
    end
    local function _skip_line(tag)
        if not tag or not tag.name or tag.name == "" then return nil end
        if tag.description and tag.description ~= "" then
            return string.format("  If skipped: %s — %s", tag.name, tag.description)
        end
        return string.format("  If skipped: %s", tag.name)
    end
    if state.blinds.small then
        local b = state.blinds.small
        table.insert(lines, string.format("[Small Blind] Target: %s | Reward: %s | Status: %s",
            fmt_number(b.chips), fmt_money(b.reward), fmt_status("Small")))
        local sl = _skip_line(b.skip_tag)
        if sl then table.insert(lines, sl) end
    end
    if state.blinds.big then
        local b = state.blinds.big
        table.insert(lines, string.format("[Big Blind]   Target: %s | Reward: %s | Status: %s",
            fmt_number(b.chips), fmt_money(b.reward), fmt_status("Big")))
        local sl = _skip_line(b.skip_tag)
        if sl then table.insert(lines, sl) end
    end
    if state.blinds.boss then
        local b = state.blinds.boss
        table.insert(lines, string.format("[Boss Blind: %s] Target: %s | Reward: %s | Status: %s",
            b.name, fmt_number(b.chips), fmt_money(b.reward), fmt_status("Boss")))
        if b.effect and b.effect ~= "" then
            table.insert(lines, "  Effect: " .. b.effect)
        end
        -- Boss Blind cannot be skipped — no skip line
    end
    table.insert(lines, "")

    -- Tags (skip rewards)
    if #state.tags > 0 then
        table.insert(lines, "--- SKIP REWARD TAGS ---")
        for _, tag in ipairs(state.tags) do
            table.insert(lines, string.format("  %s: %s", tag.name, tag.description))
        end
        table.insert(lines, "")
    end

    -- Jokers
    table.insert(lines, string.format("--- JOKERS [%d/%d slots] ---",
        #state.jokers, state.joker_slots))
    if #state.jokers == 0 then
        table.insert(lines, "  (empty)")
    else
        for _, j in ipairs(state.jokers) do
            table.insert(lines, fmt_joker(j, j.index))
        end
    end
    table.insert(lines, "")

    -- Consumables
    table.insert(lines, string.format("--- CONSUMABLES [%d/%d slots] ---",
        #state.consumables, state.consumable_slots))
    if #state.consumables == 0 then
        table.insert(lines, "  (empty)")
    else
        for _, c in ipairs(state.consumables) do
            table.insert(lines, fmt_consumable(c, c.index))
        end
    end
    table.insert(lines, "")

    -- Hand levels
    table.insert(lines, "--- HAND LEVELS ---")
    table.insert(lines, fmt_hand_levels(state.hand_levels))
    table.insert(lines, "")

    -- Actions. IMPORTANT: Balatro does NOT let you skip the Boss Blind.
    -- The UI has no skip button on Boss, and the mod's skip fallback no-ops
    -- when Boss is on deck (see actions.lua). If we advertised `skip` here
    -- while Boss is on deck, a weak model that picks `skip` would get an
    -- unchanged state back and loop on `skip` forever (observed with
    -- liquid/lfm-2.5-1.2b). So only offer `skip` when Small or Big is on
    -- deck.
    table.insert(lines, "--- ACTIONS ---")
    table.insert(lines, "select    | Play the current blind")
    if on_deck ~= "Boss" then
        table.insert(lines, "skip      | Skip this blind and collect the skip reward tag")
    else
        table.insert(lines, "(Boss Blind cannot be skipped — only `select` is available)")
    end

    return table.concat(lines, "\n")
end

function Format.selecting_hand(state)
    local lines = {}

    table.insert(lines, "=== BALATRO BENCH ===")
    table.insert(lines, string.format("Run Seed: %s | Deck: %s | Stake: %d",
        state.seed, state.deck, state.stake))

    -- Blind info
    local blind_name = "Unknown Blind"
    local blind_effect = ""
    if state.blinds.current then
        blind_name = state.blinds.current.name
        blind_effect = state.blinds.current.effect
    end
    table.insert(lines, string.format("Ante: %d/%d | Round: %s",
        state.ante, state.max_ante, blind_name))
    table.insert(lines, string.format("Target Score: %s | Current Score: %s",
        fmt_number(state.target_score), fmt_number(state.current_score)))
    table.insert(lines, string.format("Hands Remaining: %d | Discards Remaining: %d",
        state.hands_left, state.discards_left))
    table.insert(lines, string.format("Money: %s | Interest Rate: $1 per $5 (cap %s) | Next Interest: %s",
        fmt_money(state.dollars), fmt_money(state.interest_cap), fmt_money(state.interest_amount)))
    table.insert(lines, "")

    -- Hand cards
    table.insert(lines, string.format("--- YOUR HAND (%d cards) ---", #state.hand))
    for _, card in ipairs(state.hand) do
        table.insert(lines, fmt_card(card, card.index))
    end

    -- HAND ANALYSIS: pre-computed suit and rank distribution so weaker
    -- models don't have to count cards visually (they get it wrong —
    -- observed a model claiming "3 spades" when the hand had 4,
    -- hallucinating a 7-of-Diamonds that wasn't present, etc.). Strong
    -- models will ignore this if they've already counted; weaker models
    -- get an accurate ground-truth summary to reason against. Also
    -- calls out "near" hands explicitly so the survey-for-flush rule
    -- from the system prompt has something concrete to match on.
    if #state.hand > 0 then
        local suits = {Hearts = 0, Diamonds = 0, Clubs = 0, Spades = 0}
        local ranks = {}  -- rank_name -> count
        local rank_order = {["2"]=2,["3"]=3,["4"]=4,["5"]=5,["6"]=6,
                            ["7"]=7,["8"]=8,["9"]=9,["10"]=10,
                            Jack=11, Queen=12, King=13, Ace=14}
        -- Indices grouped by suit — helpful when the model wants to
        -- pick "all my spades" without transcribing card-by-card.
        local suit_indices = {Hearts={}, Diamonds={}, Clubs={}, Spades={}}
        for _, card in ipairs(state.hand) do
            if card.suit and suits[card.suit] ~= nil then
                suits[card.suit] = suits[card.suit] + 1
                table.insert(suit_indices[card.suit], tostring(card.index))
            end
            if card.rank then
                ranks[card.rank] = (ranks[card.rank] or 0) + 1
            end
        end
        table.insert(lines, "--- HAND ANALYSIS (auto-computed from above) ---")
        -- Suit histogram, sorted descending so the dominant suit is first
        local suit_pairs = {}
        for name, n in pairs(suits) do
            if n > 0 then table.insert(suit_pairs, {name=name, count=n}) end
        end
        table.sort(suit_pairs, function(a,b) return a.count > b.count end)
        local suit_strs = {}
        for _, p in ipairs(suit_pairs) do
            local idxs = table.concat(suit_indices[p.name], ",")
            table.insert(suit_strs, string.format("%s=%d (indices: %s)", p.name, p.count, idxs))
        end
        table.insert(lines, "  Suits: " .. table.concat(suit_strs, " | "))

        -- Rank counts, only for ranks that appear. Ordered by rank.
        local rank_pairs = {}
        for rname, n in pairs(ranks) do
            table.insert(rank_pairs, {name=rname, count=n, ord=rank_order[rname] or 0})
        end
        table.sort(rank_pairs, function(a,b) return a.ord > b.ord end)
        local rank_strs = {}
        for _, p in ipairs(rank_pairs) do
            if p.count > 1 then
                table.insert(rank_strs, string.format("%sx%d", p.name, p.count))
            end
        end
        if #rank_strs > 0 then
            table.insert(lines, "  Paired ranks: " .. table.concat(rank_strs, ", "))
        else
            table.insert(lines, "  Paired ranks: (none)")
        end

        -- Reachability hints — explicit callouts for Flush/Straight
        -- potential. Uses the counts we just computed so we don't re-
        -- scan the hand.
        local hints = {}
        for _, p in ipairs(suit_pairs) do
            if p.count == 5 then
                table.insert(hints, string.format("FLUSH READY in %s (play 5 cards, any index of suit)", p.name))
            elseif p.count == 4 then
                table.insert(hints, string.format("FLUSH REACHABLE in %s — 1 discard needed (discard non-%s cards, draw for 5th)", p.name, p.name))
            elseif p.count == 3 and (state.discards_left or 0) >= 2 then
                table.insert(hints, string.format("Flush possible in %s (3 of 5 — needs ~2 discards and luck)", p.name))
            end
        end
        -- Straight detection: slide a 5-window over rank_order, count
        -- how many distinct ranks in hand fall in each window.
        local present = {}
        for r in pairs(ranks) do
            local o = rank_order[r]
            if o then present[o] = true end
        end
        -- Include Ace-low option: if Ace is present, also mark rank 1
        if present[14] then present[1] = true end
        for lo = 1, 10 do
            local hi = lo + 4
            local cnt = 0
            for v = lo, hi do if present[v] then cnt = cnt + 1 end end
            if cnt == 5 then
                table.insert(hints, string.format("STRAIGHT READY (ranks %d-%d in hand)", lo, hi))
            elseif cnt == 4 then
                table.insert(hints, string.format("STRAIGHT REACHABLE — 1 discard (4 of 5 ranks %d-%d present)", lo, hi))
            end
        end
        if #hints > 0 then
            table.insert(lines, "  Hints: " .. table.concat(hints, " ; "))
        end
    end
    table.insert(lines, "")

    -- Jokers
    table.insert(lines, string.format("--- JOKERS [%d/%d slots, ordered left to right] ---",
        #state.jokers, state.joker_slots))
    if #state.jokers == 0 then
        table.insert(lines, "  (empty)")
    else
        for _, j in ipairs(state.jokers) do
            table.insert(lines, fmt_joker(j, j.index))
        end
    end
    table.insert(lines, "")

    -- Consumables
    table.insert(lines, string.format("--- CONSUMABLES [%d/%d slots] ---",
        #state.consumables, state.consumable_slots))
    if #state.consumables == 0 then
        table.insert(lines, "  (empty)")
    else
        for _, c in ipairs(state.consumables) do
            table.insert(lines, fmt_consumable(c, c.index))
        end
    end
    table.insert(lines, "")

    -- Hand levels
    table.insert(lines, "--- HAND LEVELS ---")
    table.insert(lines, fmt_hand_levels(state.hand_levels))
    table.insert(lines, "")

    -- Deck info
    table.insert(lines, "--- DECK INFO ---")
    table.insert(lines, string.format("Cards remaining in deck: %d | Cards in hand: %d | Total deck size: %d",
        state.deck_size, state.hand_count, state.total_deck_size))
    table.insert(lines, "")

    -- Boss blind effect (if applicable)
    if blind_effect ~= "" then
        table.insert(lines, "--- BOSS BLIND EFFECT ---")
        table.insert(lines, blind_name .. ": " .. blind_effect)
        table.insert(lines, "")
    end

    -- Run stats
    table.insert(lines, "--- RUN STATS ---")
    table.insert(lines, string.format("Rounds Won: %d | Highest Single Hand Score: %s",
        state.stats.rounds_won, fmt_number(state.stats.highest_hand)))
    table.insert(lines, "")

    -- Actions. Kept intentionally minimal: no ordering emphasis on any
    -- one action (models pattern-match on the first listed or on the
    -- "example" text), no CLI examples (the model must respond in JSON
    -- regardless — the system prompt documents the exact schema). We just
    -- state which action names are legal right now.
    table.insert(lines, "--- AVAILABLE ACTIONS ---")
    table.insert(lines, "play     | play 1-5 hand cards as a poker hand (costs 1 hand, scores chips)")
    table.insert(lines, "discard  | discard 1-5 hand cards and draw replacements (costs 1 discard, no scoring)")
    if #state.consumables > 0 then
        table.insert(lines, "use      | use an owned consumable (tarot/planet/spectral)")
    end
    if #state.jokers > 1 then
        table.insert(lines, "rearrange_jokers | reorder your jokers (left-to-right matters for scoring)")
    end
    table.insert(lines, "sort     | sort hand cards by rank or suit (display only, no game effect)")

    return table.concat(lines, "\n")
end

function Format.shop(state)
    local lines = {}
    local shop = state.shop or {}

    table.insert(lines, "=== BALATRO BENCH ===")
    table.insert(lines, string.format("Run Seed: %s | Deck: %s | Stake: %d",
        state.seed, state.deck, state.stake))
    table.insert(lines, string.format("Ante: %d/%d | Phase: Shop",
        state.ante, state.max_ante))
    table.insert(lines, string.format("Money: %s | Reroll Cost: %s",
        fmt_money(state.dollars), fmt_money(shop.reroll_cost)))
    table.insert(lines, "")

    -- For sale
    table.insert(lines, "--- FOR SALE ---")
    if shop.cards and #shop.cards > 0 then
        for _, item in ipairs(shop.cards) do
            if item.type == "Joker" and item.data then
                table.insert(lines, string.format("[%d] %s (%s, %s, %s)",
                    item.index, item.data.name, item.type, item.data.rarity, fmt_money(item.cost)))
                table.insert(lines, "    Effect: " .. (item.data.description ~= "" and item.data.description or "See description"))
            elseif item.data then
                table.insert(lines, string.format("[%d] %s (%s, %s)",
                    item.index, item.data.name, item.data.type or item.type, fmt_money(item.cost)))
                if item.data.description ~= "" then
                    table.insert(lines, "    Effect: " .. item.data.description)
                end
            end
        end
    else
        table.insert(lines, "  (empty)")
    end
    table.insert(lines, "")

    -- Booster packs
    table.insert(lines, "--- BOOSTER PACKS ---")
    if shop.boosters and #shop.boosters > 0 then
        for _, pack in ipairs(shop.boosters) do
            table.insert(lines, string.format("[%d] %s (%s) - %s",
                pack.index, pack.name, fmt_money(pack.cost), pack.description))
        end
    else
        table.insert(lines, "  (none available)")
    end
    table.insert(lines, "")

    -- Vouchers
    table.insert(lines, "--- VOUCHER ---")
    if shop.vouchers and #shop.vouchers > 0 then
        for _, v in ipairs(shop.vouchers) do
            table.insert(lines, string.format("[%d] %s (%s) - %s",
                v.index, v.name, fmt_money(v.cost), v.description))
        end
    else
        table.insert(lines, "  (none available)")
    end
    table.insert(lines, "")

    -- Owned jokers
    table.insert(lines, string.format("--- YOUR JOKERS [%d/%d slots] ---",
        #state.jokers, state.joker_slots))
    if #state.jokers == 0 then
        table.insert(lines, "  (empty)")
    else
        for _, j in ipairs(state.jokers) do
            table.insert(lines, fmt_joker(j, j.index))
        end
    end
    table.insert(lines, "")

    -- Owned consumables
    table.insert(lines, string.format("--- YOUR CONSUMABLES [%d/%d slots] ---",
        #state.consumables, state.consumable_slots))
    if #state.consumables == 0 then
        table.insert(lines, "  (empty)")
    else
        for _, c in ipairs(state.consumables) do
            table.insert(lines, fmt_consumable(c, c.index))
        end
    end
    table.insert(lines, "")

    -- Hand levels
    table.insert(lines, "--- HAND LEVELS ---")
    table.insert(lines, fmt_hand_levels(state.hand_levels))
    table.insert(lines, "")

    -- Actions. Primary shop flow is: look at what's for sale, decide if
    -- anything's worth buying, next_round. We deliberately do NOT list
    -- `sell` here — even demoted to "corner case", its mere presence in
    -- the list primes weaker models to try it whenever they're low on
    -- money. The full sell JSON schema is still documented in section 16
    -- of the system prompt; a model that genuinely needs to sell can use
    -- it from there.
    table.insert(lines, "--- AVAILABLE ACTIONS ---")
    table.insert(lines, "buy         | buy a card / voucher / pack from the shop")
    local _rc = (state.shop and state.shop.reroll_cost) or 5
    table.insert(lines, "reroll      | reroll shop cards (costs $" .. _rc .. ")")
    if #state.consumables > 0 then
        table.insert(lines, "use         | use an owned consumable")
    end
    if #state.jokers > 1 then
        table.insert(lines, "rearrange_jokers | reorder your jokers (left-to-right matters for scoring)")
    end
    table.insert(lines, "next_round  | leave the shop and proceed to the next blind (valid even if you buy nothing)")

    return table.concat(lines, "\n")
end

function Format.pack_open(state)
    local lines = {}
    local pack = state.pack or {}

    -- Determine pack type
    local pack_type = "Pack"
    if state.phase == "TAROT_PACK" then pack_type = "Arcana Pack"
    elseif state.phase == "PLANET_PACK" then pack_type = "Celestial Pack"
    elseif state.phase == "SPECTRAL_PACK" then pack_type = "Spectral Pack"
    elseif state.phase == "STANDARD_PACK" then pack_type = "Standard Pack"
    elseif state.phase == "BUFFOON_PACK" then pack_type = "Buffoon Pack"
    elseif state.phase == "SMODS_BOOSTER_OPENED" then
        -- Steamodded reclassifies booster phases; detect type from current pack cards
        local first = pack.cards and pack.cards[1]
        if first and first.item_type == "Joker" then pack_type = "Buffoon Pack"
        elseif first and first.item_type == "Playing Card" then pack_type = "Standard Pack"
        elseif first and first.item_type then pack_type = first.item_type .. " Pack"
        else pack_type = "Booster Pack" end
    end

    local choose = pack.choose or 1
    local total = pack.cards and #pack.cards or 0

    -- Whether the pack contents could include a consumable that targets
    -- hand cards (tarots in Arcana packs, spectrals in Spectral packs,
    -- or the equivalent in unified SMODS_BOOSTER_OPENED state). If yes
    -- we'll show the hand below so the model can pick targets.
    local pack_may_need_targets = (
        state.phase == "TAROT_PACK"
        or state.phase == "SPECTRAL_PACK"
        or state.phase == "SMODS_BOOSTER_OPENED"
    )

    table.insert(lines, "=== BALATRO BENCH ===")
    table.insert(lines, string.format("Phase: Pack Opening (%s)", pack_type))
    table.insert(lines, "")

    -- PACK RULES: put the "Choose N of M" info in its own prominent
    -- block with an explicit explanation. The header version was being
    -- missed by models — they didn't register it as a constraint and
    -- would sometimes select beyond the allowed count, or not realize
    -- they could select multiple times for "Choose 2" packs.
    table.insert(lines, "--- PACK RULES ---")
    if choose >= total then
        table.insert(lines, string.format(
            "You may take ALL %d cards from this pack. Each `select` takes ONE card; after selecting, the pack reopens with the remaining cards and you can select again. Use `skip` at any point to stop opening the pack (you keep whatever you already selected).",
            total))
    else
        local cards_word = (choose == 1) and "card" or "cards"
        table.insert(lines, string.format(
            "You may take UP TO %d %s from this pack of %d options. Each `select` takes ONE card; after selecting, the pack reopens with the remaining cards and you can select again (up to %d total selections). Use `skip` at any point to stop — you keep whatever you already selected and forfeit the rest.",
            choose, cards_word, total, choose))
    end
    table.insert(lines, "")

    -- Pack contents
    table.insert(lines, "--- PACK CONTENTS ---")
    if pack.cards then
        for _, card in ipairs(pack.cards) do
            if card.item_type == "Playing Card" then
                table.insert(lines, fmt_card(card, card.index))
            elseif card.item_type == "Joker" then
                table.insert(lines, fmt_joker(card, card.index))
            else
                table.insert(lines, fmt_consumable(card, card.index))
            end
        end
    end
    table.insert(lines, "")

    -- Your hand. CRITICAL for Arcana / Spectral packs: many tarots and
    -- spectrals target hand cards (Deja Vu adds a Red Seal, The Lovers
    -- makes a card Wild, Death converts one card to another, etc.). If
    -- the model doesn't see the hand, it has no way to specify
    -- `cards: [...]` targets when picking one of those, and the game
    -- crashes with `conv_card nil` at card.lua:1411. Always show the
    -- hand during tarot/spectral/mixed pack phases.
    if pack_may_need_targets and state.hand and #state.hand > 0 then
        table.insert(lines, string.format("--- YOUR HAND (%d cards — potential targets) ---", #state.hand))
        for _, card in ipairs(state.hand) do
            table.insert(lines, fmt_card(card, card.index))
        end
        table.insert(lines, "")
    end

    -- Current consumables/jokers for context
    table.insert(lines, string.format("--- YOUR CONSUMABLES [%d/%d slots] ---",
        #state.consumables, state.consumable_slots))
    for _, c in ipairs(state.consumables) do
        table.insert(lines, fmt_consumable(c, c.index))
    end
    table.insert(lines, "")

    table.insert(lines, string.format("--- YOUR JOKERS [%d/%d slots] ---",
        #state.jokers, state.joker_slots))
    for _, j in ipairs(state.jokers) do
        table.insert(lines, fmt_joker(j, j.index))
    end
    table.insert(lines, "")

    -- Actions. For targeted tarots/spectrals (Deja Vu, The Lovers, Death,
    -- Cryptid, etc.) the `select` MUST include a `cards` array of hand
    -- indices, otherwise Balatro's consumable logic dereferences a nil
    -- target card and crashes. We document both call shapes here so the
    -- model can construct the right JSON based on what it chose.
    table.insert(lines, "--- ACTIONS ---")
    local remaining_selects = (choose == 1) and "1 selection" or (tostring(choose) .. " selections")
    table.insert(lines, string.format(
        "select          | Take ONE card from the pack (this turn). You have %s remaining.",
        remaining_selects))
    table.insert(lines, '                | Plain form:    {"action":"select","index":<N>}')
    if pack_may_need_targets then
        table.insert(lines, '                | Targeted form: {"action":"select","index":<N>,"cards":[<hand_idx>,...]}')
        table.insert(lines, "                |   Use the targeted form if the pack card is a tarot/spectral that")
        table.insert(lines, "                |   acts on hand cards (Deja Vu/Trance/Medium → 1 card,")
        table.insert(lines, "                |   The Lovers/Tower/Chariot/Devil/Justice → 1 card,")
        table.insert(lines, "                |   Cryptid → 1 card, Death → 2 cards,")
        table.insert(lines, "                |   The Magician/Empress/Hierophant/Hanged Man → up to 2 cards,")
        table.insert(lines, "                |   The Star/Moon/Sun/World → up to 3 cards).")
        table.insert(lines, "                |   If you pick a NON-targeting card (Wraith, Ankh, Hex, Soul,")
        table.insert(lines, "                |   Black Hole, Sigil, Ouija, Judgement, etc.) omit `cards`.")
    end
    if choose > 1 then
        table.insert(lines, "                | After selecting, the pack will reopen with the remaining cards")
        table.insert(lines, "                | and a decremented `Choose` count, so you can pick another.")
    end
    table.insert(lines, "skip            | Stop opening the pack. You keep anything already selected.")

    return table.concat(lines, "\n")
end

function Format.cash_out(state)
    local lines = {}

    table.insert(lines, "=== BALATRO BENCH ===")
    table.insert(lines, "Phase: Round Complete - Cash Out")
    table.insert(lines, "")

    table.insert(lines, "--- REWARDS ---")
    table.insert(lines, string.format("Money: %s | Interest: %s",
        fmt_money(state.dollars), fmt_money(state.interest_amount)))
    table.insert(lines, "")

    table.insert(lines, "--- ACTIONS ---")
    table.insert(lines, "cash_out  | Collect rewards and proceed to shop")

    return table.concat(lines, "\n")
end

function Format.game_over(state)
    local lines = {}

    table.insert(lines, "=== BALATRO BENCH ===")
    table.insert(lines, "Phase: Game Over")
    table.insert(lines, "")

    -- Determine if win or loss
    local won = state.ante > state.max_ante or (state.ante == state.max_ante and state.phase == "GAME_OVER")
    local result = won and "VICTORY" or "DEFEAT"

    table.insert(lines, "--- FINAL RESULTS ---")
    table.insert(lines, string.format("Result: %s", result))
    table.insert(lines, string.format("Ante Reached: %d/%d", state.ante, state.max_ante))
    table.insert(lines, string.format("Rounds Won: %d", state.stats.rounds_won))
    table.insert(lines, string.format("Highest Single Hand Score: %s",
        fmt_number(state.stats.highest_hand)))
    table.insert(lines, "")

    table.insert(lines, "--- ACTIONS ---")
    table.insert(lines, "new_run                     | Start a new run with same config")
    table.insert(lines, "quit                        | End benchmark session")

    return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Main format function - dispatches to phase-specific formatter
---------------------------------------------------------------------------

function Format.format_state(state)
    if not state then return "Error: No game state available" end

    local phase = state.phase

    if phase == "BLIND_SELECT" then
        return Format.blind_select(state)
    elseif phase == "SELECTING_HAND" then
        return Format.selecting_hand(state)
    elseif phase == "SHOP" then
        return Format.shop(state)
    elseif phase == "TAROT_PACK" or phase == "PLANET_PACK" or
           phase == "SPECTRAL_PACK" or phase == "STANDARD_PACK" or
           phase == "BUFFOON_PACK" or phase == "SMODS_BOOSTER_OPENED" then
        return Format.pack_open(state)
    elseif phase == "GAME_OVER" then
        return Format.game_over(state)
    elseif phase == "ROUND_EVAL" or phase == "NEW_ROUND" then
        return Format.cash_out(state)
    elseif phase == "MENU" then
        return "=== BALATRO BENCH ===\nPhase: Main Menu\n\n--- ACTIONS ---\nnew_run | Start a new benchmark run"
    else
        -- Transitional states (HAND_PLAYED, DRAW_TO_HAND, etc.)
        return nil -- Signal to wait
    end
end

return Format
