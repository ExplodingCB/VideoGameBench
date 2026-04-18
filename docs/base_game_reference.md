# Base Game Reference Catalog

## Overview

The base-game reference catalog (`mod/base_game_reference.lua`) provides deterministic, machine-readable descriptions for all prompt-visible base-game Balatro content. It serves as a fallback for cases where Balatro's UI text or localization still contains unresolved `?` placeholders.

## Why This Is Needed

Balatro's description system uses templates with numeric placeholders like `#1#`, `#2#`, etc. These are resolved at render time via each card's `loc_vars()` callback. However, in early-stage shop generation or under certain state conditions, some values may not be fully initialized yet, leaving `?` markers in the rendered text.

The model needs exact numerical values to reason about card effects. For example:
- "Tarot cards appear **?X** more frequently" is unusable
- "Tarot cards appear **2X** more frequently" is actionable

This catalog guarantees known-good descriptions for all base-game items.

## Schema

### Structure

```lua
return {
  by_key = {
    j_droll = {
      set = "Joker",
      name = "Droll Joker",
      template = "+{t_mult} Mult if played hand contains a {type}",
      tokens = { "t_mult", "type" },
    },
    -- ... other entries
  },
  by_name = {
    ["Droll Joker"] = "j_droll",
    -- ... reverse lookup
  },
}
```

### Entry Fields

- **set**: One of `"Joker"`, `"Tarot"`, `"Planet"`, `"Spectral"`, `"Voucher"`, `"Tag"`, `"Blind"`
- **name**: Display name (human-readable)
- **text**: Static, fully-resolved description (for items with no parameters)
- **template**: Description with `{token}` placeholders (for parameterized effects)
- **tokens**: List of token names that appear in the template (matched against card config/ability/state)
- **kind**: Special handling directive for computed cases
  - `"planet_level_up"`: Computed from hand level and scaling values
  - `"tag_orbital_levelup"`: Computed from tag instance hand selection

### Token Resolution Order

When rendering a template, tokens are resolved in this order:

1. `card.config[token]`
2. `card.config.extra[token]`
3. `card.ability[token]` (instance-specific state)
4. `card.ability.extra[token]`
5. `loc_ref.config[token]` (center definition)
6. `loc_ref.config.extra[token]`
7. Special cases like `hand_type`, `orbital_hand`, `levels`

## Coverage

### Currently Cataloged

**Jokers**: ~20 examples (type-mult, suit-mult, simple static effects)
- Droll Joker (type-mult template)
- Greedy/Lusty/Wrathful/Gluttonous Joker (suit-mult template)
- Basic jokers (Joker, Blueprint, Card Sharp, Stone, Cavendish, Triboulet, Stuntman)

**Tarot Cards**: All 22 major arcana
- Cards with static effects (e.g., "The Fool": Destroys Blind if hand is played with no discards)
- Cards with parameters (e.g., "The Magician": Enhances N selected cards into Lucky Cards)

**Planet Cards**: All 12 planets
- All use `kind = "planet_level_up"` for computed descriptions

**Spectral Cards**: Sample (Hex, Ghost, Wraith, Access)

**Vouchers**: Key examples (Overstock, Clearance Sale, Tarot Merchant, Tarot Tycoon, Planet Merchant, Planet Tycoon, Hone, Glow Up)
- All with `extra_disp` or `extra` tokens

**Tags**: Priority tags with numbered effects
- Economy Tag (max dollars)
- Coupon Tag (free item marker)
- Investment Tag (dollars after boss)
- Handy Tag (dollars per hand)
- Garbage Tag (dollars per discard)
- Juggle Tag (hand size increase)
- Top-Up Tag (spawned jokers)
- Skip Tag (skip bonus)
- Orbital Tag (computed hand levelup)

**Blinds**: Sample (Small Blind, Big Blind, The Ox, The House, The Wall)

### Not Yet Cataloged

The current catalog provides comprehensive coverage of the most important base-game items—especially those with numbered effects that commonly generate `?` placeholders. Additional jokers, blinds, and other items can be added iteratively as needed.

To extend the catalog:
1. Identify the internal key (e.g., `j_mystic_summit`)
2. Look up the display name and any templated values in the game dump
3. Add an entry following the schema
4. Test with a live game instance

## Integration Points

### In state.lua

The renderer (`State.render_description`) checks sources in this priority order:

1. **Base-game reference catalog** (NEW) — `_render_from_catalog()`
2. Canonical Balatro render via `Card:generate_UIBox_ability_table()`
3. Fallback known-value render (`_render_known_fallback()`)
4. Planet-specific fallback (`_render_planet_fallback()`)
5. Localization system with `loc_vars()` substitution
6. Dump of known raw values if description still contains `?`

The catalog output is preferred because it is deterministic and guaranteed not to contain `?` markers.

### How Tokens Are Resolved

The `_resolve_token()` function checks a fixed hierarchy of locations:

```lua
function _resolve_token(token_name, loc_ref, card)
  -- 1. card.config[token_name]
  -- 2. card.config.extra[token_name]
  -- 3. card.ability[token_name]
  -- 4. card.ability.extra[token_name]
  -- 5. loc_ref.config[token_name]
  -- 6. loc_ref.config.extra[token_name]
  -- 7. Special resolvers (hand_type, orbital_hand, levels, etc.)
end
```

This ensures that instance-level overrides are used before center-level defaults.

## Examples

### Example 1: Droll Joker (Template with Config Values)

**Game Data**:
```lua
j_droll = {
  name = "Droll Joker",
  config = { t_mult = 10, type = 'Flush' }
}
```

**Catalog Entry**:
```lua
j_droll = {
  set = "Joker",
  name = "Droll Joker",
  template = "+{t_mult} Mult if played hand contains a {type}",
  tokens = { "t_mult", "type" },
}
```

**Rendered Output**: `"+10 Mult if played hand contains a Flush"`

### Example 2: Pluto Planet (Computed from Hand Level)

**Catalog Entry**:
```lua
c_pluto = {
  set = "Planet",
  name = "Pluto",
  kind = "planet_level_up",
}
```

**Render Logic** (in `_render_from_catalog`):
- Extracts `hand_type = 'High Card'` from `loc_ref.config.hand_type`
- Looks up current `G.GAME.hands['High Card'].level`
- Retrieves `l_mult` and `l_chips` scaling factors
- Outputs: `"(Lvl 2) Levels up High Card: +1 Mult and +1 Chips per use"`

### Example 3: Tarot Merchant Voucher (Numeric Parameter)

**Game Data**:
```lua
v_tarot_merchant = {
  name = "Tarot Merchant",
  config = { extra = 2.4, extra_disp = 2 }
}
```

**Catalog Entry**:
```lua
v_tarot_merchant = {
  set = "Voucher",
  name = "Tarot Merchant",
  template = "Tarot cards appear {extra_disp}X more frequently in the shop",
  tokens = { "extra_disp" },
}
```

**Rendered Output**: `"Tarot cards appear 2X more frequently in the shop"`

Note: The `extra_disp` field is used for display purposes; the `extra` field (raw multiplier) is used internally by the game.

## Maintenance

### Adding New Entries

When adding new items:
1. Use the internal game key (e.g., `j_`, `c_`, `v_`, `tag_`, `bl_`)
2. Extract the display name from the game dump
3. Determine if the description is static (`text`) or templated (`template` + `tokens`)
4. If templated, identify which fields from the config hold the values
5. Add both `by_key` and `by_name` entries
6. Test in a live game session

### Validation

Run the test suite (`test_base_game_reference.py`) to check:
- All entries in `by_key` and `by_name` are consistent
- No duplicate names or keys
- All token references are resolved at runtime
- Live game seed rendering produces no `?` markers

### Coverage Gaps

Known areas for future extension:
- Additional jokers (currently ~20 of 150+ base-game jokers)
- Modifiers and special blinds
- Shop-level effects that depend on run state
- Interactively-discovered or lock-based item descriptions

## References

- **Game Data Source**: `C:\Users\thedu\AppData\Roaming\Balatro\Mods\lovely\dump\game.lua`
- **Renderer Logic**: `mod/state.lua` — `_render_from_catalog()`, `_resolve_token()`, `State.render_description()`
- **Test Suite**: `test_base_game_reference.py`
