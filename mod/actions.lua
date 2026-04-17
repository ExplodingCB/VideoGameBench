-- BalatroBench Action Handlers
-- Executes player actions by calling Balatro's game functions

local Actions = {}

---------------------------------------------------------------------------
-- Validation helpers
---------------------------------------------------------------------------

local function validate_card_indices(indices, max)
    if not indices or type(indices) ~= "table" or #indices == 0 then
        return false, "Must provide at least one card index"
    end
    for _, idx in ipairs(indices) do
        if type(idx) ~= "number" or idx < 1 or idx > max or math.floor(idx) ~= idx then
            return false, string.format("Invalid card index: %s (must be 1-%d)", tostring(idx), max)
        end
    end
    -- Check for duplicates
    local seen = {}
    for _, idx in ipairs(indices) do
        if seen[idx] then
            return false, "Duplicate card index: " .. tostring(idx)
        end
        seen[idx] = true
    end
    return true, nil
end

---------------------------------------------------------------------------
-- Card selection helpers
---------------------------------------------------------------------------

local function unhighlight_all()
    if G.hand and G.hand.unhighlight_all then
        G.hand:unhighlight_all()
    end
end

local function highlight_cards(indices)
    unhighlight_all()
    if not G.hand or not G.hand.cards then return false end

    for _, idx in ipairs(indices) do
        if G.hand.cards[idx] then
            G.hand:add_to_highlighted(G.hand.cards[idx], true)
        end
    end
    return true
end

---------------------------------------------------------------------------
-- Action: Play cards
---------------------------------------------------------------------------

function Actions.play(data)
    if not G or G.STATE ~= G.STATES.SELECTING_HAND then
        return {error = "Can only play cards during hand selection phase"}
    end

    local cards = data.cards
    if not cards or #cards == 0 then
        return {error = "Must specify cards to play (e.g., {\"action\": \"play\", \"cards\": [1, 3, 5]})"}
    end
    if #cards > 5 then
        return {error = "Cannot play more than 5 cards"}
    end

    local max = G.hand and G.hand.cards and #G.hand.cards or 0
    local ok, err = validate_card_indices(cards, max)
    if not ok then return {error = err} end

    if G.GAME.current_round.hands_left <= 0 then
        return {error = "No hands remaining this round"}
    end

    -- Highlight the selected cards
    highlight_cards(cards)

    -- Trigger play
    if G.FUNCS.play_cards_from_highlighted then
        G.FUNCS.play_cards_from_highlighted({config = {ref_table = {}}})
    end

    return {success = true, action = "play", cards = cards}
end

---------------------------------------------------------------------------
-- Action: Discard cards
---------------------------------------------------------------------------

function Actions.discard(data)
    if not G or G.STATE ~= G.STATES.SELECTING_HAND then
        return {error = "Can only discard cards during hand selection phase"}
    end

    local cards = data.cards
    if not cards or #cards == 0 then
        return {error = "Must specify cards to discard"}
    end

    local max = G.hand and G.hand.cards and #G.hand.cards or 0
    local ok, err = validate_card_indices(cards, max)
    if not ok then return {error = err} end

    if G.GAME.current_round.discards_left <= 0 then
        return {error = "No discards remaining this round"}
    end

    -- Highlight the selected cards
    highlight_cards(cards)

    -- Trigger discard
    if G.FUNCS.discard_cards_from_highlighted then
        G.FUNCS.discard_cards_from_highlighted({config = {ref_table = {}}})
    end

    return {success = true, action = "discard", cards = cards}
end

---------------------------------------------------------------------------
-- Helper: Get the blind object for the current blind on deck
---------------------------------------------------------------------------

local function get_current_blind_ref()
    -- Get the P_BLINDS entry for the current blind
    if not G.GAME or not G.GAME.blind_on_deck then return nil end
    local deck = G.GAME.blind_on_deck -- "Small", "Big", or "Boss"

    if deck == "Small" then
        return G.P_BLINDS and G.P_BLINDS.bl_small
    elseif deck == "Big" then
        return G.P_BLINDS and G.P_BLINDS.bl_big
    elseif deck == "Boss" then
        -- Boss is chosen per-ante; round_resets.blind_choices.Boss holds the key
        -- (e.g. "bl_wall"), and G.P_BLINDS[key] is the actual blind definition.
        -- Fall back through a couple of other fields Balatro sometimes uses.
        local rr = G.GAME.round_resets or {}
        local boss_key = rr.blind_choices and rr.blind_choices.Boss
        if boss_key and G.P_BLINDS and G.P_BLINDS[boss_key] then
            return G.P_BLINDS[boss_key]
        end
        -- Legacy/alternate storage
        if rr.boss and G.P_BLINDS and G.P_BLINDS[rr.boss] then
            return G.P_BLINDS[rr.boss]
        end
        -- Last-resort: a random eligible boss for this ante
        if G.P_BLINDS then
            for k, v in pairs(G.P_BLINDS) do
                if v.boss then return v end
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Action: Select blind (play it)
---------------------------------------------------------------------------

function Actions.select(data)
    if not G then return {error = "Game not loaded"} end

    -- During blind select phase
    if G.STATE == G.STATES.BLIND_SELECT then
        print("[BalatroBench] Selecting blind: " .. tostring(G.GAME.blind_on_deck))

        -- Directly replicate what G.FUNCS.select_blind does
        local blind_ref = get_current_blind_ref()
        print("[BalatroBench] blind_ref: " .. tostring(blind_ref) ..
              " G.blind_select: " .. tostring(G.blind_select) ..
              " Event: " .. tostring(Event) ..
              " new_round: " .. tostring(new_round))
        if blind_ref and G.blind_select then
            G.GAME.facing_blind = true

            -- Animate out the blind select UI
            if G.blind_prompt_box then
                local d1 = G.blind_prompt_box:get_UIE_by_ID('prompt_dynatext1')
                local d2 = G.blind_prompt_box:get_UIE_by_ID('prompt_dynatext2')
                if d1 then d1.config.object.pop_delay = 0; d1.config.object:pop_out(5) end
                if d2 then d2.config.object.pop_delay = 0; d2.config.object:pop_out(5) end
            end

            -- Try the event-based approach first
            local ok1, err1 = pcall(function()
                G.GAME.facing_blind = true
                stop_use()
                G.E_MANAGER:add_event(Event({
                    trigger = 'before', delay = 0.2,
                    func = function()
                        print("[BalatroBench] Event 1 running")
                        if G.blind_prompt_box then G.blind_prompt_box.alignment.offset.y = -10 end
                        if G.blind_select then
                            G.blind_select.alignment.offset.y = 40
                            G.blind_select.alignment.offset.x = 0
                        end
                        return true
                    end
                }))
                G.E_MANAGER:add_event(Event({
                    trigger = 'immediate',
                    func = function()
                        print("[BalatroBench] Event 2 running - setting blind and removing UI")
                        ease_round(1)
                        inc_career_stat('c_rounds', 1)
                        G.GAME.round_resets.blind = blind_ref
                        G.GAME.round_resets.blind_states[G.GAME.blind_on_deck] = 'Current'
                        if G.blind_select then G.blind_select:remove() end
                        if G.blind_prompt_box then G.blind_prompt_box:remove() end
                        G.blind_select = nil
                        delay(0.2)
                        return true
                    end
                }))
                G.E_MANAGER:add_event(Event({
                    trigger = 'immediate',
                    func = function()
                        print("[BalatroBench] Event 3 running - new_round")
                        new_round()
                        return true
                    end
                }))
            end)

            if not ok1 then
                print("[BalatroBench] Event chain FAILED: " .. tostring(err1))
                return {error = "Select blind event chain failed: " .. tostring(err1)}
            end

            print("[BalatroBench] Events queued successfully")
            return {success = true, action = "select", blind = G.GAME.blind_on_deck, method = "direct"}
        end

        return {error = "Could not select blind. blind_on_deck: " .. tostring(G.GAME.blind_on_deck)}
    end

    -- During pack opening - select a card from the pack
    if data and data.index then
        return Actions.pack_select(data)
    end

    return {error = "Cannot select in current phase: " .. tostring(G.STATE)}
end

---------------------------------------------------------------------------
-- Action: Skip blind
---------------------------------------------------------------------------

function Actions.skip(data)
    if not G then return {error = "Game not loaded"} end

    -- During blind select
    if G.STATE == G.STATES.BLIND_SELECT then
        local deck = string.lower(G.GAME.blind_on_deck or "Small")
        local blind_uibox = G.blind_select_opts and G.blind_select_opts[deck]

        if blind_uibox then
            -- The skip button is inside the tag area
            -- Find any element with config.button == 'skip_blind'
            local tag_id = 'tag_' .. (G.GAME.blind_on_deck or "Small")
            local tag_elem = blind_uibox:get_UIE_by_ID(tag_id)
            if tag_elem and tag_elem.children then
                for _, child in ipairs(tag_elem.children) do
                    if child.config and child.config.button == 'skip_blind' then
                        print("[BalatroBench] Found skip button, clicking it")
                        G.FUNCS.skip_blind(child)
                        return {success = true, action = "skip", blind = G.GAME.blind_on_deck, method = "button_click"}
                    end
                end
            end
            -- Try searching more broadly
            -- The skip button text says "Skip Blind" in the UI
        end

        -- Fallback: directly manipulate game state
        print("[BalatroBench] Using direct blind skip fallback")
        if G.GAME.blind_on_deck then
            local skipped = G.GAME.blind_on_deck
            local skip_to = skipped == "Small" and "Big" or skipped == "Big" and "Boss" or "Boss"

            G.GAME.skips = (G.GAME.skips or 0) + 1
            G.GAME.round_resets.blind_states[skipped] = "Skipped"
            G.GAME.round_resets.blind_states[skip_to] = "Select"
            G.GAME.blind_on_deck = skip_to

            -- Trigger tag and blind refresh
            G.E_MANAGER:add_event(Event({
                trigger = 'immediate',
                func = function()
                    SMODS.calculate_context({skip_blind = true})
                    save_run()
                    for i = 1, #G.GAME.tags do
                        G.GAME.tags[i]:apply_to_run({type = 'immediate'})
                    end
                    for i = 1, #G.GAME.tags do
                        if G.GAME.tags[i]:apply_to_run({type = 'new_blind_choice'}) then break end
                    end
                    return true
                end
            }))
            return {success = true, action = "skip", skipped = skipped, next = skip_to}
        end

        return {error = "Could not skip blind"}
    end

    -- During pack opening (any booster state, or just pack UI present)
    local in_pack = G.STATE == G.STATES.TAROT_PACK or G.STATE == G.STATES.PLANET_PACK or
                    G.STATE == G.STATES.SPECTRAL_PACK or G.STATE == G.STATES.STANDARD_PACK or
                    G.STATE == G.STATES.BUFFOON_PACK or
                    (G.STATES.SMODS_BOOSTER_OPENED and G.STATE == G.STATES.SMODS_BOOSTER_OPENED) or
                    (G.pack_cards and G.pack_cards.cards and #G.pack_cards.cards > 0)
    if in_pack then
        if G.FUNCS.skip_booster then
            G.FUNCS.skip_booster({config = {}, UIBox = G.pack_cards or {}})
        end
        return {success = true, action = "skip_pack"}
    end

    return {error = "Cannot skip in current phase"}
end

---------------------------------------------------------------------------
-- Action: Buy from shop
---------------------------------------------------------------------------

function Actions.buy(data)
    if not G or G.STATE ~= G.STATES.SHOP then
        return {error = "Can only buy items during shop phase"}
    end

    local buy_type = data.type
    local index = data.index

    if not buy_type then
        return {error = "Must specify buy type: card, voucher, or pack"}
    end
    if not index or type(index) ~= "number" then
        return {error = "Must specify item index (number)"}
    end

    if buy_type == "card" then
        -- Buy from shop card slots
        if G.shop_jokers and G.shop_jokers.cards and G.shop_jokers.cards[index] then
            local card = G.shop_jokers.cards[index]
            if G.GAME.dollars < card.cost then
                return {error = string.format("Not enough money. Need %s, have %s",
                    "$" .. card.cost, "$" .. G.GAME.dollars)}
            end
            -- Check if there's room
            if card.ability and card.ability.set == "Joker" then
                if G.jokers and #G.jokers.cards >= (G.jokers.config.card_limit or 5) then
                    if not (card.edition and card.edition.negative) then
                        return {error = "No joker slots available"}
                    end
                end
            elseif card.ability and (card.ability.set == "Tarot" or card.ability.set == "Planet" or card.ability.set == "Spectral") then
                if G.consumeables and #G.consumeables.cards >= (G.consumeables.config.card_limit or 2) then
                    if not (card.edition and card.edition.negative) then
                        return {error = "No consumable slots available"}
                    end
                end
            end
            -- Execute buy
            if G.FUNCS.buy_from_shop then
                G.FUNCS.buy_from_shop({config = {ref_table = card}})
            end
            return {success = true, action = "buy", type = "card", index = index}
        else
            return {error = "Invalid card index: " .. tostring(index)}
        end

    elseif buy_type == "voucher" then
        if G.shop_vouchers and G.shop_vouchers.cards and G.shop_vouchers.cards[index] then
            local card = G.shop_vouchers.cards[index]
            if G.GAME.dollars < card.cost then
                return {error = "Not enough money for voucher"}
            end
            if G.FUNCS.buy_from_shop then
                G.FUNCS.buy_from_shop({config = {ref_table = card}})
            end
            return {success = true, action = "buy", type = "voucher", index = index}
        else
            return {error = "Invalid voucher index: " .. tostring(index)}
        end

    elseif buy_type == "pack" then
        if G.shop_booster and G.shop_booster.cards and G.shop_booster.cards[index] then
            local card = G.shop_booster.cards[index]
            if G.GAME.dollars < card.cost then
                return {error = "Not enough money for pack"}
            end
            -- IMPORTANT: packs go through G.FUNCS.use_card, NOT buy_from_shop.
            -- The shop UI's can_open() sets e.config.button = 'use_card' for
            -- boosters, because Card:open() handles the dollar deduction itself
            -- (ease_dollars(-self.cost) in card.lua). Going through buy_from_shop
            -- would double-charge: buy_from_shop's ease_dollars(-c1.cost) PLUS
            -- Card:open()'s ease_dollars(-self.cost).
            if G.FUNCS.use_card then
                G.FUNCS.use_card({config = {ref_table = card}})
            end
            return {success = true, action = "buy", type = "pack", index = index}
        else
            return {error = "Invalid pack index: " .. tostring(index)}
        end
    else
        return {error = "Invalid buy type: " .. tostring(buy_type) .. ". Use: card, voucher, or pack"}
    end
end

---------------------------------------------------------------------------
-- Action: Sell items
---------------------------------------------------------------------------

function Actions.sell(data)
    if not G or G.STATE ~= G.STATES.SHOP then
        return {error = "Can only sell items during shop phase"}
    end

    local sell_type = data.type
    local index = data.index

    if not sell_type then
        return {error = "Must specify sell type: joker or consumable"}
    end
    if not index or type(index) ~= "number" then
        return {error = "Must specify item index (number)"}
    end

    if sell_type == "joker" then
        if G.jokers and G.jokers.cards and G.jokers.cards[index] then
            local card = G.jokers.cards[index]
            if card.ability and card.ability.eternal then
                return {error = "Cannot sell an Eternal joker"}
            end
            if G.FUNCS.sell_card then
                G.FUNCS.sell_card({config = {ref_table = card}})
            end
            return {success = true, action = "sell", type = "joker", index = index}
        else
            return {error = "Invalid joker index: " .. tostring(index)}
        end

    elseif sell_type == "consumable" then
        if G.consumeables and G.consumeables.cards and G.consumeables.cards[index] then
            local card = G.consumeables.cards[index]
            if G.FUNCS.sell_card then
                G.FUNCS.sell_card({config = {ref_table = card}})
            end
            return {success = true, action = "sell", type = "consumable", index = index}
        else
            return {error = "Invalid consumable index: " .. tostring(index)}
        end
    else
        return {error = "Invalid sell type: " .. tostring(sell_type) .. ". Use: joker or consumable"}
    end
end

---------------------------------------------------------------------------
-- Action: Use consumable
---------------------------------------------------------------------------

function Actions.use(data)
    if not G then return {error = "Game not loaded"} end

    local slot = data.slot
    if not slot or type(slot) ~= "number" then
        return {error = "Must specify consumable slot number"}
    end

    if not G.consumeables or not G.consumeables.cards or not G.consumeables.cards[slot] then
        return {error = "Invalid consumable slot: " .. tostring(slot)}
    end

    local card = G.consumeables.cards[slot]

    -- If targeting hand cards, highlight them first
    if data.cards and #data.cards > 0 then
        if G.hand and G.hand.cards then
            local max = #G.hand.cards
            local ok, err = validate_card_indices(data.cards, max)
            if not ok then return {error = err} end
            highlight_cards(data.cards)
        end
    else
        unhighlight_all()
    end

    -- Use the consumable
    if G.FUNCS.use_card then
        G.FUNCS.use_card({config = {ref_table = card}})
    end

    return {success = true, action = "use", slot = slot, cards = data.cards}
end

---------------------------------------------------------------------------
-- Action: Reroll shop
---------------------------------------------------------------------------

function Actions.reroll(data)
    if not G or G.STATE ~= G.STATES.SHOP then
        return {error = "Can only reroll during shop phase"}
    end

    local cost = G.GAME.current_round and G.GAME.current_round.reroll_cost or 5
    if G.GAME.dollars < cost then
        return {error = string.format("Not enough money to reroll. Need %s, have %s",
            "$" .. cost, "$" .. G.GAME.dollars)}
    end

    if G.FUNCS.reroll_shop then
        G.FUNCS.reroll_shop({config = {ref_table = {}}})
    end

    return {success = true, action = "reroll", cost = cost}
end

---------------------------------------------------------------------------
-- Action: Next round (leave shop)
---------------------------------------------------------------------------

function Actions.next_round(data)
    if not G or G.STATE ~= G.STATES.SHOP then
        return {error = "Can only proceed to next round from shop phase"}
    end

    -- Replicate G.FUNCS.toggle_shop logic
    if G.shop then
        stop_use()
        SMODS.calculate_context({ending_shop = true})
        G.E_MANAGER:add_event(Event({
            trigger = 'immediate',
            func = function()
                G.shop.alignment.offset.y = (G.ROOM and G.ROOM.T and G.ROOM.T.y or 0) + 29
                if G.SHOP_SIGN then G.SHOP_SIGN.alignment.offset.y = -15 end
                return true
            end
        }))
        G.E_MANAGER:add_event(Event({
            trigger = 'after',
            delay = 0.5,
            func = function()
                if G.shop then G.shop:remove(); G.shop = nil end
                if G.SHOP_SIGN then G.SHOP_SIGN:remove(); G.SHOP_SIGN = nil end
                G.STATE_COMPLETE = false
                G.STATE = G.STATES.BLIND_SELECT
                return true
            end
        }))
        print("[BalatroBench] Leaving shop")
        return {success = true, action = "next_round"}
    end

    return {error = "No shop to exit"}
end

---------------------------------------------------------------------------
-- Action: Cash out
---------------------------------------------------------------------------

function Actions.cash_out(data)
    if not G then return {error = "Game not loaded"} end

    -- Replicate G.FUNCS.cash_out logic directly
    if G.round_eval then
        stop_use()
        G.round_eval.alignment.offset.y = (G.ROOM and G.ROOM.T and G.ROOM.T.y or 0) + 15
        G.round_eval.alignment.offset.x = 0
        if G.deck and G.deck.shuffle then
            G.deck:shuffle('cashout' .. (G.GAME.round_resets.ante or 1))
            G.deck:hard_set_T()
        end
        delay(0.3)
        G.E_MANAGER:add_event(Event({
            trigger = 'immediate',
            func = function()
                if G.round_eval then
                    G.round_eval:remove()
                    G.round_eval = nil
                end
                G.GAME.current_round.jokers_purchased = 0
                G.GAME.current_round.discards_left = math.max(0, G.GAME.round_resets.discards + G.GAME.round_bonus.discards)
                G.GAME.current_round.hands_left = math.max(1, G.GAME.round_resets.hands + G.GAME.round_bonus.next_hands)
                G.STATE = G.STATES.SHOP
                G.GAME.shop_free = nil
                G.GAME.shop_d6ed = nil
                G.STATE_COMPLETE = false
                return true
            end
        }))
        ease_dollars(G.GAME.current_round.dollars)
        G.E_MANAGER:add_event(Event({
            func = function()
                G.GAME.previous_round.dollars = G.GAME.dollars
                return true
            end
        }))
        ease_chips(0)

        -- Handle ante progression if boss defeated.
        -- Mirrors Balatro's G.FUNCS.cash_out + reset_blinds() for Boss defeat.
        -- IMPORTANT: we do NOT increment round_resets.ante here — end_round()
        -- (state_events.lua) already calls ease_ante(1) when the Boss is beaten,
        -- so incrementing again would skip a whole ante.
        if G.GAME.round_resets.blind_states.Boss == 'Defeated' then
            G.GAME.round_resets.blind_ante = G.GAME.round_resets.ante
            G.GAME.round_resets.blind_tags.Small = get_next_tag_key()
            G.GAME.round_resets.blind_tags.Big = get_next_tag_key()
            G.GAME.round_resets.blind_states = {Small = 'Select', Big = 'Upcoming', Boss = 'Upcoming'}
            G.GAME.blind_on_deck = 'Small'
            -- Pick a fresh boss for the new ante
            if get_new_boss then
                G.GAME.round_resets.blind_choices = G.GAME.round_resets.blind_choices or {}
                G.GAME.round_resets.blind_choices.Boss = get_new_boss()
                G.GAME.round_resets.boss_rerolled = false
            end
        end

        print("[BalatroBench] Cash out executed")
        return {success = true, action = "cash_out"}
    end

    return {error = "No round_eval screen to cash out from"}
end

---------------------------------------------------------------------------
-- Action: Rearrange jokers
---------------------------------------------------------------------------

function Actions.rearrange_jokers(data)
    if not G or not G.jokers or not G.jokers.cards then
        return {error = "No jokers to rearrange"}
    end

    local order = data.order
    if not order or type(order) ~= "table" then
        return {error = "Must provide new order as array of indices"}
    end

    local count = #G.jokers.cards
    if #order ~= count then
        return {error = string.format("Order must include all %d joker indices", count)}
    end

    -- Validate: must be a permutation of 1..count
    local seen = {}
    for _, idx in ipairs(order) do
        if type(idx) ~= "number" or idx < 1 or idx > count or math.floor(idx) ~= idx then
            return {error = "Invalid joker index in order: " .. tostring(idx)}
        end
        if seen[idx] then
            return {error = "Duplicate index in order: " .. tostring(idx)}
        end
        seen[idx] = true
    end

    -- Rearrange by building new card order
    local new_cards = {}
    for _, idx in ipairs(order) do
        table.insert(new_cards, G.jokers.cards[idx])
    end

    -- Update joker positions
    for i, card in ipairs(new_cards) do
        G.jokers.cards[i] = card
    end

    -- Trigger UI update
    if G.jokers.align_cards then
        G.jokers:align_cards()
    end

    return {success = true, action = "rearrange_jokers", order = order}
end

---------------------------------------------------------------------------
-- Action: Sort hand
---------------------------------------------------------------------------

function Actions.sort(data)
    if not G or not G.hand or not G.hand.cards then
        return {error = "No hand to sort"}
    end

    local by = data.by or "rank"
    if by ~= "rank" and by ~= "suit" then
        return {error = "Sort by 'rank' or 'suit'"}
    end

    if G.FUNCS.sort_hand_suit and by == "suit" then
        G.FUNCS.sort_hand_suit({config = {ref_table = {}}})
    elseif G.FUNCS.sort_hand_value then
        G.FUNCS.sort_hand_value({config = {ref_table = {}}})
    end

    return {success = true, action = "sort", by = by}
end

---------------------------------------------------------------------------
-- Action: Select card from booster pack
---------------------------------------------------------------------------

function Actions.pack_select(data)
    if not G then return {error = "Game not loaded"} end

    local pack_states = {
        [G.STATES.TAROT_PACK] = true,
        [G.STATES.PLANET_PACK] = true,
        [G.STATES.SPECTRAL_PACK] = true,
        [G.STATES.STANDARD_PACK] = true,
        [G.STATES.BUFFOON_PACK] = true,
    }
    -- Steamodded may use a unified SMODS_BOOSTER_OPENED state (commonly G.STATE == 999)
    if G.STATES.SMODS_BOOSTER_OPENED then
        pack_states[G.STATES.SMODS_BOOSTER_OPENED] = true
    end
    -- Fall back: if pack UI is present, allow selection regardless of named state
    local pack_open = (G.pack_cards and G.pack_cards.cards and #G.pack_cards.cards > 0)
    if not pack_states[G.STATE] and not pack_open then
        return {error = "Not in a pack opening phase"}
    end

    local index = data.index
    if not index or type(index) ~= "number" then
        return {error = "Must specify card index to select"}
    end

    if not G.pack_cards or not G.pack_cards.cards or not G.pack_cards.cards[index] then
        return {error = "Invalid pack card index: " .. tostring(index)}
    end

    local card = G.pack_cards.cards[index]

    -- For standard packs, need to check for card targeting
    if G.STATE == G.STATES.STANDARD_PACK then
        -- Standard pack cards are added to deck directly
        if G.FUNCS.buy_from_shop then
            G.FUNCS.buy_from_shop({config = {ref_table = card}})
        end
    else
        -- Consumable packs - use the card
        if data.cards and #data.cards > 0 and G.hand and G.hand.cards then
            highlight_cards(data.cards)
        end
        if G.FUNCS.use_card then
            G.FUNCS.use_card({config = {ref_table = card}})
        end
    end

    return {success = true, action = "pack_select", index = index}
end

---------------------------------------------------------------------------
-- Action: New run
---------------------------------------------------------------------------

function Actions.new_run(data)
    -- Return to menu and start new run
    -- This is handled at a higher level by the entry point
    return {success = true, action = "new_run", deck = data.deck, stake = data.stake}
end

---------------------------------------------------------------------------
-- Action: Quit
---------------------------------------------------------------------------

function Actions.quit(data)
    return {success = true, action = "quit"}
end

---------------------------------------------------------------------------
-- Action: Reroll boss blind (Director's Cut voucher)
---------------------------------------------------------------------------

function Actions.reroll_boss(data)
    if not G or G.STATE ~= G.STATES.BLIND_SELECT then
        return {error = "Can only reroll boss during blind select phase"}
    end

    if G.FUNCS.reroll_boss then
        G.FUNCS.reroll_boss({config = {ref_table = {}}})
        return {success = true, action = "reroll_boss"}
    end

    return {error = "Boss reroll not available (requires Director's Cut voucher)"}
end

---------------------------------------------------------------------------
-- Dispatch: route action name to handler
---------------------------------------------------------------------------

function Actions.dispatch(data)
    if not data or not data.action then
        return {error = "No action specified. Send JSON with an 'action' field."}
    end

    local action = data.action
    local handler = Actions[action]

    if not handler then
        local valid_actions = {
            "play", "discard", "select", "skip", "buy", "sell",
            "use", "reroll", "next_round", "cash_out",
            "rearrange_jokers", "sort", "new_run", "quit", "reroll_boss"
        }
        return {error = string.format("Unknown action: '%s'. Valid actions: %s",
            tostring(action), table.concat(valid_actions, ", "))}
    end

    -- Call the handler
    local ok, result = pcall(handler, data)
    if not ok then
        return {error = "Action failed: " .. tostring(result)}
    end

    return result
end

return Actions
