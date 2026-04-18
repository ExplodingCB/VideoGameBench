-- Base Game Reference Catalog
-- Deterministic fallback descriptions for base-game Balatro content.
-- Keyed by internal game key. Data sourced from game.lua dump.
--
-- Schema:
--   by_key:  internal key -> {set, name, text|template+tokens|kind}
--   by_name: display name -> internal key
--
-- Entry types:
--   text:     fully static description (no parameters)
--   template: description with {token} placeholders resolved at runtime
--   tokens:   ordered list of token names for the template
--   kind:     special computed cases (planet_level_up, tag_orbital_levelup)

return {
  by_key = {

    ---------------------------------------------------------------------------
    -- JOKERS: simple flat mult
    ---------------------------------------------------------------------------
    j_joker = {
      set = "Joker",
      name = "Joker",
      text = "+4 Mult",
    },

    ---------------------------------------------------------------------------
    -- JOKERS: Type Mult (hand type triggers)
    -- All share the same template; config.t_mult and config.type differ.
    ---------------------------------------------------------------------------
    j_jolly = {
      set = "Joker",
      name = "Jolly Joker",
      template = "+{t_mult} Mult if played hand contains a {type}",
      tokens = { "t_mult", "type" },
    },
    j_zany = {
      set = "Joker",
      name = "Zany Joker",
      template = "+{t_mult} Mult if played hand contains a {type}",
      tokens = { "t_mult", "type" },
    },
    j_mad = {
      set = "Joker",
      name = "Mad Joker",
      template = "+{t_mult} Mult if played hand contains a {type}",
      tokens = { "t_mult", "type" },
    },
    j_droll = {
      set = "Joker",
      name = "Droll Joker",
      template = "+{t_mult} Mult if played hand contains a {type}",
      tokens = { "t_mult", "type" },
    },
    j_crazy = {
      set = "Joker",
      name = "Crazy Joker",
      template = "+{t_mult} Mult if played hand contains a {type}",
      tokens = { "t_mult", "type" },
    },
    j_sly = {
      set = "Joker",
      name = "Sly Joker",
      template = "+{t_chips} Chips if played hand contains a {type}",
      tokens = { "t_chips", "type" },
    },
    j_wily = {
      set = "Joker",
      name = "Wily Joker",
      template = "+{t_chips} Chips if played hand contains a {type}",
      tokens = { "t_chips", "type" },
    },
    j_clever = {
      set = "Joker",
      name = "Clever Joker",
      template = "+{t_chips} Chips if played hand contains a {type}",
      tokens = { "t_chips", "type" },
    },
    j_devious = {
      set = "Joker",
      name = "Devious Joker",
      template = "+{t_chips} Chips if played hand contains a {type}",
      tokens = { "t_chips", "type" },
    },
    j_crafty = {
      set = "Joker",
      name = "Crafty Joker",
      template = "+{t_chips} Chips if played hand contains a {type}",
      tokens = { "t_chips", "type" },
    },

    ---------------------------------------------------------------------------
    -- JOKERS: Suit Mult (scored suit triggers)
    -- config.extra = {s_mult, suit}
    ---------------------------------------------------------------------------
    j_greedy_joker = {
      set = "Joker",
      name = "Greedy Joker",
      template = "+{s_mult} Mult for scored {suit} cards",
      tokens = { "s_mult", "suit" },
    },
    j_lusty_joker = {
      set = "Joker",
      name = "Lusty Joker",
      template = "+{s_mult} Mult for scored {suit} cards",
      tokens = { "s_mult", "suit" },
    },
    j_wrathful_joker = {
      set = "Joker",
      name = "Wrathful Joker",
      template = "+{s_mult} Mult for scored {suit} cards",
      tokens = { "s_mult", "suit" },
    },
    j_gluttenous_joker = {
      set = "Joker",
      name = "Gluttonous Joker",
      template = "+{s_mult} Mult for scored {suit} cards",
      tokens = { "s_mult", "suit" },
    },

    ---------------------------------------------------------------------------
    -- JOKERS: other common base-game jokers
    ---------------------------------------------------------------------------
    j_blueprint = {
      set = "Joker",
      name = "Blueprint",
      text = "Copies the ability of the Joker to the right",
    },
    j_brainstorm = {
      set = "Joker",
      name = "Brainstorm",
      text = "Copies the ability of the leftmost Joker",
    },
    j_gros_michel = {
      set = "Joker",
      name = "Gros Michel",
      template = "+{mult} Mult. 1 in {odds} chance of being destroyed at end of round",
      tokens = { "mult", "odds" },
    },
    j_cavendish = {
      set = "Joker",
      name = "Cavendish",
      template = "x{Xmult} Mult. 1 in {odds} chance of being destroyed at end of round",
      tokens = { "Xmult", "odds" },
    },
    j_scholar = {
      set = "Joker",
      name = "Scholar",
      template = "Played Aces give +{chips} Chips and +{mult} Mult when scored",
      tokens = { "chips", "mult" },
    },
    j_fibonacci = {
      set = "Joker",
      name = "Fibonacci",
      template = "Each played Ace, 2, 3, 5, or 8 gives +{extra} Mult when scored",
      tokens = { "extra" },
    },
    j_steel_joker = {
      set = "Joker",
      name = "Steel Joker",
      template = "Gains +{extra}x Mult per Steel Card in your full deck",
      tokens = { "extra" },
    },
    j_stone = {
      set = "Joker",
      name = "Stone Joker",
      template = "Gives +{extra} Chips per Stone Card in your full deck",
      tokens = { "extra" },
    },
    j_golden = {
      set = "Joker",
      name = "Golden Joker",
      template = "Earn ${extra} at end of round",
      tokens = { "extra" },
    },
    j_lucky_cat = {
      set = "Joker",
      name = "Lucky Cat",
      template = "Gains +{extra}x Mult when a Lucky Card triggers",
      tokens = { "extra" },
    },
    j_abstract = {
      set = "Joker",
      name = "Abstract Joker",
      template = "+{extra} Mult for each Joker card",
      tokens = { "extra" },
    },
    j_delayed_grat = {
      set = "Joker",
      name = "Delayed Gratification",
      template = "Earn ${extra} per remaining discard at end of round if no discards used",
      tokens = { "extra" },
    },
    j_hack = {
      set = "Joker",
      name = "Hack",
      text = "Retrigger each played 2, 3, 4, or 5",
    },
    j_pareidolia = {
      set = "Joker",
      name = "Pareidolia",
      text = "All cards are considered face cards",
    },
    j_misprint = {
      set = "Joker",
      name = "Misprint",
      template = "+{min}-{max} Mult (random each hand)",
      tokens = { "min", "max" },
    },
    j_dusk = {
      set = "Joker",
      name = "Dusk",
      text = "Retrigger all played cards in final hand of round",
    },
    j_raised_fist = {
      set = "Joker",
      name = "Raised Fist",
      text = "Adds double the rank of lowest ranked card held in hand to Mult",
    },
    j_chaos = {
      set = "Joker",
      name = "Chaos the Clown",
      text = "1 free reroll per shop",
    },
    j_scary_face = {
      set = "Joker",
      name = "Scary Face",
      template = "Played face cards give +{extra} Chips when scored",
      tokens = { "extra" },
    },
    j_odd_todd = {
      set = "Joker",
      name = "Odd Todd",
      template = "Played odd-ranked cards give +{extra} Chips when scored",
      tokens = { "extra" },
    },
    j_scholar = {
      set = "Joker",
      name = "Scholar",
      template = "Played Aces give +{chips} Chips and +{mult} Mult when scored",
      tokens = { "chips", "mult" },
    },
    j_business = {
      set = "Joker",
      name = "Business Card",
      template = "Played face cards have a 1 in {extra} chance of giving $2",
      tokens = { "extra" },
    },
    j_supernova = {
      set = "Joker",
      name = "Supernova",
      text = "Adds number of times poker hand has been played this run to Mult",
    },
    j_burglar = {
      set = "Joker",
      name = "Burglar",
      template = "When Blind is selected, gain +{extra} Hands and lose all discards",
      tokens = { "extra" },
    },
    j_blackboard = {
      set = "Joker",
      name = "Blackboard",
      template = "x{extra} Mult if all cards held in hand are Spades or Clubs",
      tokens = { "extra" },
    },
    j_runner = {
      set = "Joker",
      name = "Runner",
      template = "Gains +{chip_mod} Chips when a Straight is played (currently +{chips} Chips)",
      tokens = { "chip_mod", "chips" },
    },
    j_ice_cream = {
      set = "Joker",
      name = "Ice Cream",
      template = "+{chips} Chips, loses {chip_mod} Chips after each hand played",
      tokens = { "chips", "chip_mod" },
    },
    j_dna = {
      set = "Joker",
      name = "DNA",
      text = "If first hand of round has only 1 card, add copy to deck and draw it",
    },
    j_splash = {
      set = "Joker",
      name = "Splash",
      text = "Every played card counts in scoring",
    },
    j_blue_joker = {
      set = "Joker",
      name = "Blue Joker",
      template = "+{extra} Chips for each remaining card in deck",
      tokens = { "extra" },
    },
    j_sixth_sense = {
      set = "Joker",
      name = "Sixth Sense",
      text = "If first hand of round is a single 6, destroy it and create a Spectral card",
    },
    j_constellation = {
      set = "Joker",
      name = "Constellation",
      template = "Gains +{extra}x Mult each time a Planet card is used",
      tokens = { "extra" },
    },
    j_hiker = {
      set = "Joker",
      name = "Hiker",
      template = "Every played card permanently gains +{extra} Chips when scored",
      tokens = { "extra" },
    },
    j_faceless = {
      set = "Joker",
      name = "Faceless Joker",
      template = "Earn ${dollars} if 3 or more face cards are discarded at once",
      tokens = { "dollars" },
    },
    j_green_joker = {
      set = "Joker",
      name = "Green Joker",
      template = "+{hand_add} Mult per hand played, -{discard_sub} Mult per discard",
      tokens = { "hand_add", "discard_sub" },
    },
    j_superposition = {
      set = "Joker",
      name = "Superposition",
      template = "Gains a Tarot card if hand played contains an Ace and a Straight",
      tokens = {},
    },
    j_todo_list = {
      set = "Joker",
      name = "To Do List",
      template = "Earn ${dollars} if poker hand is {poker_hand}, poker hand changes at end of round",
      tokens = { "dollars", "poker_hand" },
    },
    j_caino = {
      set = "Joker",
      name = "Caino",
      template = "Gains +{extra}x Mult for every face card destroyed this run",
      tokens = { "extra" },
    },
    j_triboulet = {
      set = "Joker",
      name = "Triboulet",
      text = "Played Kings and Queens each give x2 Mult when scored",
    },
    j_yorick = {
      set = "Joker",
      name = "Yorick",
      template = "Gains +{xmult}x Mult every {discards}th discard",
      tokens = { "xmult", "discards" },
    },
    j_chicot = {
      set = "Joker",
      name = "Chicot",
      text = "Deactivates the effect of every Boss Blind",
    },
    j_perkeo = {
      set = "Joker",
      name = "Perkeo",
      text = "Creates a Negative copy of 1 random consumable in hand at end of shop",
    },

    ---------------------------------------------------------------------------
    -- PLANET CARDS
    -- All use kind="planet_level_up" for computed rendering.
    -- hand_type from config is stored but the actual render is computed from
    -- G.GAME.hands[hand_type] at runtime (level, l_mult, l_chips).
    ---------------------------------------------------------------------------
    c_mercury = {
      set = "Planet",
      name = "Mercury",
      kind = "planet_level_up",
      hand_type = "Pair",
    },
    c_venus = {
      set = "Planet",
      name = "Venus",
      kind = "planet_level_up",
      hand_type = "Three of a Kind",
    },
    c_earth = {
      set = "Planet",
      name = "Earth",
      kind = "planet_level_up",
      hand_type = "Full House",
    },
    c_mars = {
      set = "Planet",
      name = "Mars",
      kind = "planet_level_up",
      hand_type = "Four of a Kind",
    },
    c_jupiter = {
      set = "Planet",
      name = "Jupiter",
      kind = "planet_level_up",
      hand_type = "Flush",
    },
    c_saturn = {
      set = "Planet",
      name = "Saturn",
      kind = "planet_level_up",
      hand_type = "Straight",
    },
    c_uranus = {
      set = "Planet",
      name = "Uranus",
      kind = "planet_level_up",
      hand_type = "Two Pair",
    },
    c_neptune = {
      set = "Planet",
      name = "Neptune",
      kind = "planet_level_up",
      hand_type = "Straight Flush",
    },
    c_pluto = {
      set = "Planet",
      name = "Pluto",
      kind = "planet_level_up",
      hand_type = "High Card",
    },
    c_planet_x = {
      set = "Planet",
      name = "Planet X",
      kind = "planet_level_up",
      hand_type = "Five of a Kind",
    },
    c_ceres = {
      set = "Planet",
      name = "Ceres",
      kind = "planet_level_up",
      hand_type = "Flush House",
    },
    c_eris = {
      set = "Planet",
      name = "Eris",
      kind = "planet_level_up",
      hand_type = "Flush Five",
    },

    ---------------------------------------------------------------------------
    -- TAROT CARDS
    -- Source: game.lua config fields + known game effects.
    ---------------------------------------------------------------------------
    c_fool = {
      set = "Tarot",
      name = "The Fool",
      text = "Creates the last Tarot or Planet card used during this run",
    },
    c_magician = {
      set = "Tarot",
      name = "The Magician",
      text = "Enhances 1 to 2 selected cards into Lucky Cards",
    },
    c_high_priestess = {
      set = "Tarot",
      name = "The High Priestess",
      text = "Creates 2 random Planet cards",
    },
    c_empress = {
      set = "Tarot",
      name = "The Empress",
      text = "Enhances 2 selected cards into Mult Cards",
    },
    c_emperor = {
      set = "Tarot",
      name = "The Emperor",
      text = "Creates 2 random Tarot cards",
    },
    c_heirophant = {
      set = "Tarot",
      name = "The Hierophant",
      text = "Enhances 2 selected cards into Bonus Cards",
    },
    c_lovers = {
      set = "Tarot",
      name = "The Lovers",
      text = "Enhances 1 selected card into a Wild Card",
    },
    c_chariot = {
      set = "Tarot",
      name = "The Chariot",
      text = "Enhances 1 selected card into a Steel Card",
    },
    c_justice = {
      set = "Tarot",
      name = "Justice",
      text = "Enhances 1 selected card into a Glass Card",
    },
    c_hermit = {
      set = "Tarot",
      name = "The Hermit",
      text = "Doubles your money (up to $20)",
    },
    c_wheel_of_fortune = {
      set = "Tarot",
      name = "The Wheel of Fortune",
      text = "1 in 4 chance to add Foil, Holographic, or Polychrome edition to a random Joker",
    },
    c_strength = {
      set = "Tarot",
      name = "Strength",
      text = "Increases the rank of up to 2 selected cards by 1",
    },
    c_hanged_man = {
      set = "Tarot",
      name = "The Hanged Man",
      text = "Destroys up to 2 selected cards",
    },
    c_death = {
      set = "Tarot",
      name = "Death",
      text = "Select 2 cards, convert the left card into the right card",
    },
    c_temperance = {
      set = "Tarot",
      name = "Temperance",
      text = "Gives total sell value of all Jokers in possession (Max $50)",
    },
    c_devil = {
      set = "Tarot",
      name = "The Devil",
      text = "Enhances 1 selected card into a Gold Card",
    },
    c_tower = {
      set = "Tarot",
      name = "The Tower",
      text = "Enhances 1 selected card into a Stone Card",
    },
    c_star = {
      set = "Tarot",
      name = "The Star",
      text = "Converts up to 3 selected cards to Diamonds",
    },
    c_moon = {
      set = "Tarot",
      name = "The Moon",
      text = "Converts up to 3 selected cards to Clubs",
    },
    c_sun = {
      set = "Tarot",
      name = "The Sun",
      text = "Converts up to 3 selected cards to Hearts",
    },
    c_judgement = {
      set = "Tarot",
      name = "Judgement",
      text = "Creates a random Joker card (Must have room)",
    },
    c_world = {
      set = "Tarot",
      name = "The World",
      text = "Converts up to 3 selected cards to Spades",
    },

    ---------------------------------------------------------------------------
    -- SPECTRAL CARDS
    -- Source: game.lua config fields. All use c_ prefix.
    ---------------------------------------------------------------------------
    c_familiar = {
      set = "Spectral",
      name = "Familiar",
      text = "Destroys 1 random card in hand, add 3 random Enhanced face cards to deck",
    },
    c_grim = {
      set = "Spectral",
      name = "Grim",
      text = "Destroys 1 random card in hand, add 2 random Enhanced Aces to deck",
    },
    c_incantation = {
      set = "Spectral",
      name = "Incantation",
      text = "Destroys 1 random card in hand, add 4 random Enhanced numbered cards to deck",
    },
    c_talisman = {
      set = "Spectral",
      name = "Talisman",
      text = "Adds a Gold Seal to 1 selected card",
    },
    c_aura = {
      set = "Spectral",
      name = "Aura",
      text = "Adds Foil, Holographic, or Polychrome edition to 1 selected card",
    },
    c_wraith = {
      set = "Spectral",
      name = "Wraith",
      text = "Creates a random Rare Joker (Must have room), sets money to $0",
    },
    c_sigil = {
      set = "Spectral",
      name = "Sigil",
      text = "Converts all cards in hand to a single random suit",
    },
    c_ouija = {
      set = "Spectral",
      name = "Ouija",
      text = "Converts all cards in hand to a single random rank, -1 hand size",
    },
    c_ectoplasm = {
      set = "Spectral",
      name = "Ectoplasm",
      text = "Adds Negative edition to 1 random Joker, -1 Joker slot",
    },
    c_immolate = {
      set = "Spectral",
      name = "Immolate",
      text = "Destroys 5 random cards in hand, gain $20",
    },
    c_ankh = {
      set = "Spectral",
      name = "Ankh",
      text = "Creates a copy of 1 random Joker, destroys all other Jokers",
    },
    c_deja_vu = {
      set = "Spectral",
      name = "Deja Vu",
      text = "Adds a Red Seal to 1 selected card",
    },
    c_hex = {
      set = "Spectral",
      name = "Hex",
      text = "Adds Polychrome edition to 1 random Joker, destroys all other Jokers",
    },
    c_trance = {
      set = "Spectral",
      name = "Trance",
      text = "Adds a Blue Seal to 1 selected card",
    },
    c_medium = {
      set = "Spectral",
      name = "Medium",
      text = "Adds a Purple Seal to 1 selected card",
    },
    c_cryptid = {
      set = "Spectral",
      name = "Cryptid",
      text = "Creates 2 copies of 1 selected card",
    },
    c_soul = {
      set = "Spectral",
      name = "The Soul",
      text = "Creates a Legendary Joker (Must have room)",
    },
    c_black_hole = {
      set = "Spectral",
      name = "Black Hole",
      text = "Upgrades every poker hand by 1 level",
    },

    ---------------------------------------------------------------------------
    -- VOUCHERS
    -- Source: game.lua config fields + known effects.
    ---------------------------------------------------------------------------
    v_overstock_norm = {
      set = "Voucher",
      name = "Overstock",
      text = "+1 card slot available in shop",
    },
    v_overstock_plus = {
      set = "Voucher",
      name = "Overstock Plus",
      text = "+1 additional card slot available in shop",
    },
    v_clearance_sale = {
      set = "Voucher",
      name = "Clearance Sale",
      template = "All cards and packs in the shop are {extra}% off",
      tokens = { "extra" },
    },
    v_liquidation = {
      set = "Voucher",
      name = "Liquidation",
      template = "All cards and packs in the shop are {extra}% off",
      tokens = { "extra" },
    },
    v_hone = {
      set = "Voucher",
      name = "Hone",
      template = "Foil, Holographic, and Polychrome cards appear {extra}X more often",
      tokens = { "extra" },
    },
    v_glow_up = {
      set = "Voucher",
      name = "Glow Up",
      template = "Foil, Holographic, and Polychrome cards appear {extra}X more often",
      tokens = { "extra" },
    },
    v_reroll_surplus = {
      set = "Voucher",
      name = "Reroll Surplus",
      template = "Reroll costs ${extra} less",
      tokens = { "extra" },
    },
    v_reroll_glut = {
      set = "Voucher",
      name = "Reroll Glut",
      template = "Reroll costs ${extra} less",
      tokens = { "extra" },
    },
    v_crystal_ball = {
      set = "Voucher",
      name = "Crystal Ball",
      template = "+{extra} consumable slot(s)",
      tokens = { "extra" },
    },
    v_omen_globe = {
      set = "Voucher",
      name = "Omen Globe",
      text = "Spectral cards may appear in standard packs",
    },
    v_telescope = {
      set = "Voucher",
      name = "Telescope",
      text = "Celestial packs always contain the Planet card for your most played hand",
    },
    v_observatory = {
      set = "Voucher",
      name = "Observatory",
      template = "Planet cards in your consumable area give +{extra}x Mult when used",
      tokens = { "extra" },
    },
    v_grabber = {
      set = "Voucher",
      name = "Grabber",
      template = "+{extra} hand(s) per round",
      tokens = { "extra" },
    },
    v_nacho_tong = {
      set = "Voucher",
      name = "Nacho Tong",
      template = "+{extra} additional hand(s) per round",
      tokens = { "extra" },
    },
    v_wasteful = {
      set = "Voucher",
      name = "Wasteful",
      template = "+{extra} discard(s) per round",
      tokens = { "extra" },
    },
    v_recyclomancy = {
      set = "Voucher",
      name = "Recyclomancy",
      template = "+{extra} additional discard(s) per round",
      tokens = { "extra" },
    },
    v_tarot_merchant = {
      set = "Voucher",
      name = "Tarot Merchant",
      template = "Tarot cards appear {extra_disp}X more frequently in the shop",
      tokens = { "extra_disp" },
    },
    v_tarot_tycoon = {
      set = "Voucher",
      name = "Tarot Tycoon",
      template = "Tarot cards appear {extra_disp}X more frequently in the shop",
      tokens = { "extra_disp" },
    },
    v_planet_merchant = {
      set = "Voucher",
      name = "Planet Merchant",
      template = "Planet cards appear {extra_disp}X more frequently in the shop",
      tokens = { "extra_disp" },
    },
    v_planet_tycoon = {
      set = "Voucher",
      name = "Planet Tycoon",
      template = "Planet cards appear {extra_disp}X more frequently in the shop",
      tokens = { "extra_disp" },
    },
    v_seed_money = {
      set = "Voucher",
      name = "Seed Money",
      template = "Raise the cap on interest earned each round to ${extra}",
      tokens = { "extra" },
    },
    v_money_tree = {
      set = "Voucher",
      name = "Money Tree",
      template = "Raise the cap on interest earned each round to ${extra}",
      tokens = { "extra" },
    },
    v_blank = {
      set = "Voucher",
      name = "Blank",
      text = "Does nothing... for now",
    },
    v_antimatter = {
      set = "Voucher",
      name = "Antimatter",
      template = "+{extra} Joker slot(s)",
      tokens = { "extra" },
    },
    v_magic_trick = {
      set = "Voucher",
      name = "Magic Trick",
      text = "Playing cards may be purchased from the shop",
    },
    v_illusion = {
      set = "Voucher",
      name = "Illusion",
      text = "Playing cards for sale in the shop may have editions",
    },
    v_hieroglyph = {
      set = "Voucher",
      name = "Hieroglyph",
      template = "Ante decreased by {extra} at start of each round (Max 1 round ahead)",
      tokens = { "extra" },
    },
    v_petroglyph = {
      set = "Voucher",
      name = "Petroglyph",
      template = "Ante decreased by {extra} at start of each round (Max 2 rounds ahead)",
      tokens = { "extra" },
    },
    v_directors_cut = {
      set = "Voucher",
      name = "Director's Cut",
      template = "Allows {extra} reroll(s) of the Boss Blind",
      tokens = { "extra" },
    },
    v_retcon = {
      set = "Voucher",
      name = "Retcon",
      text = "Reroll all Boss Blind options",
    },
    v_paint_brush = {
      set = "Voucher",
      name = "Paint Brush",
      template = "+{extra} hand size",
      tokens = { "extra" },
    },
    v_palette = {
      set = "Voucher",
      name = "Palette",
      template = "+{extra} additional hand size",
      tokens = { "extra" },
    },

    ---------------------------------------------------------------------------
    -- TAGS
    -- Source: game.lua P_TAGS config fields.
    ---------------------------------------------------------------------------
    tag_uncommon = {
      set = "Tag",
      name = "Uncommon Tag",
      text = "Gives a free Uncommon Joker",
    },
    tag_rare = {
      set = "Tag",
      name = "Rare Tag",
      text = "Gives a free Rare Joker",
    },
    tag_negative = {
      set = "Tag",
      name = "Negative Tag",
      text = "Adds Negative edition to next purchased Joker",
    },
    tag_foil = {
      set = "Tag",
      name = "Foil Tag",
      text = "Adds Foil edition to next purchased Joker",
    },
    tag_holo = {
      set = "Tag",
      name = "Holographic Tag",
      text = "Adds Holographic edition to next purchased Joker",
    },
    tag_polychrome = {
      set = "Tag",
      name = "Polychrome Tag",
      text = "Adds Polychrome edition to next purchased Joker",
    },
    tag_investment = {
      set = "Tag",
      name = "Investment Tag",
      template = "After defeating Boss Blind, earn ${dollars}",
      tokens = { "dollars" },
    },
    tag_voucher = {
      set = "Tag",
      name = "Voucher Tag",
      text = "Gives a free Voucher in the next shop",
    },
    tag_boss = {
      set = "Tag",
      name = "Boss Tag",
      text = "Gives a free reroll of the Boss Blind",
    },
    tag_standard = {
      set = "Tag",
      name = "Standard Tag",
      text = "Gives a free Standard Pack",
    },
    tag_charm = {
      set = "Tag",
      name = "Charm Tag",
      text = "Gives a free Arcana Pack",
    },
    tag_meteor = {
      set = "Tag",
      name = "Meteor Tag",
      text = "Gives a free Celestial Pack",
    },
    tag_buffoon = {
      set = "Tag",
      name = "Buffoon Tag",
      text = "Gives a free Buffoon Pack",
    },
    tag_handy = {
      set = "Tag",
      name = "Handy Tag",
      template = "Earn ${dollars_per_hand} per hand played this run",
      tokens = { "dollars_per_hand" },
    },
    tag_garbage = {
      set = "Tag",
      name = "Garbage Tag",
      template = "Earn ${dollars_per_discard} per unused discard this run",
      tokens = { "dollars_per_discard" },
    },
    tag_ethereal = {
      set = "Tag",
      name = "Ethereal Tag",
      text = "Gives a free Spectral Pack",
    },
    tag_coupon = {
      set = "Tag",
      name = "Coupon Tag",
      text = "Selected Joker in next shop is free",
    },
    tag_double = {
      set = "Tag",
      name = "Double Tag",
      text = "Next tag earned is doubled (given twice)",
    },
    tag_juggle = {
      set = "Tag",
      name = "Juggle Tag",
      template = "+{h_size} hand size next round",
      tokens = { "h_size" },
    },
    tag_d_six = {
      set = "Tag",
      name = "D6 Tag",
      text = "Reroll the shop at start of next round",
    },
    tag_top_up = {
      set = "Tag",
      name = "Top-up Tag",
      template = "Create up to {spawn_jokers} free Common Jokers",
      tokens = { "spawn_jokers" },
    },
    tag_skip = {
      set = "Tag",
      name = "Skip Tag",
      template = "Earn ${skip_bonus} for each Blind skipped this run",
      tokens = { "skip_bonus" },
    },
    tag_orbital = {
      set = "Tag",
      name = "Orbital Tag",
      kind = "tag_orbital_levelup",
    },
    tag_economy = {
      set = "Tag",
      name = "Economy Tag",
      template = "Double your money (Max of ${max})",
      tokens = { "max" },
    },

    ---------------------------------------------------------------------------
    -- BLINDS
    -- Source: game.lua + blind.lua effect logic.
    ---------------------------------------------------------------------------
    bl_small = {
      set = "Blind",
      name = "Small Blind",
      text = "No effect",
    },
    bl_big = {
      set = "Blind",
      name = "Big Blind",
      text = "No effect",
    },
    bl_hook = {
      set = "Blind",
      name = "The Hook",
      text = "Discards 2 random cards per hand played",
    },
    bl_ox = {
      set = "Blind",
      name = "The Ox",
      text = "Playing your most played hand sets money to $0",
    },
    bl_house = {
      set = "Blind",
      name = "The House",
      text = "All cards are face down at start of round",
    },
    bl_wall = {
      set = "Blind",
      name = "The Wall",
      text = "Extra large blind (4x chip requirement)",
    },
    bl_wheel = {
      set = "Blind",
      name = "The Wheel",
      text = "1 in 7 cards are drawn face down",
    },
    bl_arm = {
      set = "Blind",
      name = "The Arm",
      text = "Decrease level of played hand after each play",
    },
    bl_club = {
      set = "Blind",
      name = "The Club",
      text = "All Club cards are debuffed",
    },
    bl_fish = {
      set = "Blind",
      name = "The Fish",
      text = "Draw 1 fewer card after each hand played",
    },
    bl_psychic = {
      set = "Blind",
      name = "The Psychic",
      text = "Must play exactly 5 cards",
    },
    bl_goad = {
      set = "Blind",
      name = "The Goad",
      text = "All Spade cards are debuffed",
    },
    bl_water = {
      set = "Blind",
      name = "The Water",
      text = "Start with 0 discards",
    },
    bl_window = {
      set = "Blind",
      name = "The Window",
      text = "All Diamond cards are debuffed",
    },
    bl_manacle = {
      set = "Blind",
      name = "The Manacle",
      text = "Left most Joker is disabled",
    },
    bl_eye = {
      set = "Blind",
      name = "The Eye",
      text = "No repeating hand types this round",
    },
    bl_mouth = {
      set = "Blind",
      name = "The Mouth",
      text = "Play only 1 hand type this round",
    },
    bl_plant = {
      set = "Blind",
      name = "The Plant",
      text = "All face cards are debuffed",
    },
    bl_serpent = {
      set = "Blind",
      name = "The Serpent",
      text = "After playing a hand, discard your entire hand and draw a new one",
    },
    bl_pillar = {
      set = "Blind",
      name = "The Pillar",
      text = "Cards previously played this ante are debuffed",
    },
    bl_needle = {
      set = "Blind",
      name = "The Needle",
      text = "Play only 1 card",
    },
    bl_head = {
      set = "Blind",
      name = "The Head",
      text = "All Heart cards are debuffed",
    },
    bl_tooth = {
      set = "Blind",
      name = "The Tooth",
      text = "Lose $1 per card played",
    },
    bl_flint = {
      set = "Blind",
      name = "The Flint",
      text = "Base Chips and Mult are halved",
    },
    bl_mark = {
      set = "Blind",
      name = "The Mark",
      text = "All face cards are drawn face down",
    },
    bl_final_acorn = {
      set = "Blind",
      name = "Amber Acorn",
      text = "Flips and shuffles all Joker cards",
    },
    bl_final_leaf = {
      set = "Blind",
      name = "Verdant Leaf",
      text = "All cards are debuffed until 1 Joker is sold",
    },
    bl_final_vessel = {
      set = "Blind",
      name = "Violet Vessel",
      text = "Very large blind (6x chip requirement)",
    },
    bl_final_heart = {
      set = "Blind",
      name = "Crimson Heart",
      text = "One random Joker is disabled every hand",
    },
    bl_final_bell = {
      set = "Blind",
      name = "Cerulean Bell",
      text = "1 card is forced and held in hand every hand",
    },
  },

  by_name = {
    -- JOKERS
    ["Joker"]               = "j_joker",
    ["Jolly Joker"]         = "j_jolly",
    ["Zany Joker"]          = "j_zany",
    ["Mad Joker"]           = "j_mad",
    ["Droll Joker"]         = "j_droll",
    ["Crazy Joker"]         = "j_crazy",
    ["Sly Joker"]           = "j_sly",
    ["Wily Joker"]          = "j_wily",
    ["Clever Joker"]        = "j_clever",
    ["Devious Joker"]       = "j_devious",
    ["Crafty Joker"]        = "j_crafty",
    ["Greedy Joker"]        = "j_greedy_joker",
    ["Lusty Joker"]         = "j_lusty_joker",
    ["Wrathful Joker"]      = "j_wrathful_joker",
    ["Gluttonous Joker"]    = "j_gluttenous_joker",
    ["Blueprint"]           = "j_blueprint",
    ["Brainstorm"]          = "j_brainstorm",
    ["Gros Michel"]         = "j_gros_michel",
    ["Cavendish"]           = "j_cavendish",
    ["Scholar"]             = "j_scholar",
    ["Fibonacci"]           = "j_fibonacci",
    ["Steel Joker"]         = "j_steel_joker",
    ["Stone Joker"]         = "j_stone",
    ["Golden Joker"]        = "j_golden",
    ["Lucky Cat"]           = "j_lucky_cat",
    ["Abstract Joker"]      = "j_abstract",
    ["Delayed Gratification"] = "j_delayed_grat",
    ["Hack"]                = "j_hack",
    ["Pareidolia"]          = "j_pareidolia",
    ["Misprint"]            = "j_misprint",
    ["Dusk"]                = "j_dusk",
    ["Raised Fist"]         = "j_raised_fist",
    ["Chaos the Clown"]     = "j_chaos",
    ["Scary Face"]          = "j_scary_face",
    ["Odd Todd"]            = "j_odd_todd",
    ["Business Card"]       = "j_business",
    ["Supernova"]           = "j_supernova",
    ["Burglar"]             = "j_burglar",
    ["Blackboard"]          = "j_blackboard",
    ["Runner"]              = "j_runner",
    ["Ice Cream"]           = "j_ice_cream",
    ["DNA"]                 = "j_dna",
    ["Splash"]              = "j_splash",
    ["Blue Joker"]          = "j_blue_joker",
    ["Sixth Sense"]         = "j_sixth_sense",
    ["Constellation"]       = "j_constellation",
    ["Hiker"]               = "j_hiker",
    ["Faceless Joker"]      = "j_faceless",
    ["Green Joker"]         = "j_green_joker",
    ["Superposition"]       = "j_superposition",
    ["To Do List"]          = "j_todo_list",
    ["Caino"]               = "j_caino",
    ["Triboulet"]           = "j_triboulet",
    ["Yorick"]              = "j_yorick",
    ["Chicot"]              = "j_chicot",
    ["Perkeo"]              = "j_perkeo",

    -- PLANETS
    ["Mercury"]   = "c_mercury",
    ["Venus"]     = "c_venus",
    ["Earth"]     = "c_earth",
    ["Mars"]      = "c_mars",
    ["Jupiter"]   = "c_jupiter",
    ["Saturn"]    = "c_saturn",
    ["Uranus"]    = "c_uranus",
    ["Neptune"]   = "c_neptune",
    ["Pluto"]     = "c_pluto",
    ["Planet X"]  = "c_planet_x",
    ["Ceres"]     = "c_ceres",
    ["Eris"]      = "c_eris",

    -- TAROTS
    ["The Fool"]            = "c_fool",
    ["The Magician"]        = "c_magician",
    ["The High Priestess"]  = "c_high_priestess",
    ["The Empress"]         = "c_empress",
    ["The Emperor"]         = "c_emperor",
    ["The Hierophant"]      = "c_heirophant",
    ["The Lovers"]          = "c_lovers",
    ["The Chariot"]         = "c_chariot",
    ["Justice"]             = "c_justice",
    ["The Hermit"]          = "c_hermit",
    ["The Wheel of Fortune"] = "c_wheel_of_fortune",
    ["Strength"]            = "c_strength",
    ["The Hanged Man"]      = "c_hanged_man",
    ["Death"]               = "c_death",
    ["Temperance"]          = "c_temperance",
    ["The Devil"]           = "c_devil",
    ["The Tower"]           = "c_tower",
    ["The Star"]            = "c_star",
    ["The Moon"]            = "c_moon",
    ["The Sun"]             = "c_sun",
    ["Judgement"]           = "c_judgement",
    ["The World"]           = "c_world",

    -- SPECTRALS
    ["Familiar"]    = "c_familiar",
    ["Grim"]        = "c_grim",
    ["Incantation"] = "c_incantation",
    ["Talisman"]    = "c_talisman",
    ["Aura"]        = "c_aura",
    ["Wraith"]      = "c_wraith",
    ["Sigil"]       = "c_sigil",
    ["Ouija"]       = "c_ouija",
    ["Ectoplasm"]   = "c_ectoplasm",
    ["Immolate"]    = "c_immolate",
    ["Ankh"]        = "c_ankh",
    ["Deja Vu"]     = "c_deja_vu",
    ["Hex"]         = "c_hex",
    ["Trance"]      = "c_trance",
    ["Medium"]      = "c_medium",
    ["Cryptid"]     = "c_cryptid",
    ["The Soul"]    = "c_soul",
    ["Black Hole"]  = "c_black_hole",

    -- VOUCHERS
    ["Overstock"]         = "v_overstock_norm",
    ["Overstock Plus"]    = "v_overstock_plus",
    ["Clearance Sale"]    = "v_clearance_sale",
    ["Liquidation"]       = "v_liquidation",
    ["Hone"]              = "v_hone",
    ["Glow Up"]           = "v_glow_up",
    ["Reroll Surplus"]    = "v_reroll_surplus",
    ["Reroll Glut"]       = "v_reroll_glut",
    ["Crystal Ball"]      = "v_crystal_ball",
    ["Omen Globe"]        = "v_omen_globe",
    ["Telescope"]         = "v_telescope",
    ["Observatory"]       = "v_observatory",
    ["Grabber"]           = "v_grabber",
    ["Nacho Tong"]        = "v_nacho_tong",
    ["Wasteful"]          = "v_wasteful",
    ["Recyclomancy"]      = "v_recyclomancy",
    ["Tarot Merchant"]    = "v_tarot_merchant",
    ["Tarot Tycoon"]      = "v_tarot_tycoon",
    ["Planet Merchant"]   = "v_planet_merchant",
    ["Planet Tycoon"]     = "v_planet_tycoon",
    ["Seed Money"]        = "v_seed_money",
    ["Money Tree"]        = "v_money_tree",
    ["Blank"]             = "v_blank",
    ["Antimatter"]        = "v_antimatter",
    ["Magic Trick"]       = "v_magic_trick",
    ["Illusion"]          = "v_illusion",
    ["Hieroglyph"]        = "v_hieroglyph",
    ["Petroglyph"]        = "v_petroglyph",
    ["Director's Cut"]    = "v_directors_cut",
    ["Retcon"]            = "v_retcon",
    ["Paint Brush"]       = "v_paint_brush",
    ["Palette"]           = "v_palette",

    -- TAGS
    ["Uncommon Tag"]      = "tag_uncommon",
    ["Rare Tag"]          = "tag_rare",
    ["Negative Tag"]      = "tag_negative",
    ["Foil Tag"]          = "tag_foil",
    ["Holographic Tag"]   = "tag_holo",
    ["Polychrome Tag"]    = "tag_polychrome",
    ["Investment Tag"]    = "tag_investment",
    ["Voucher Tag"]       = "tag_voucher",
    ["Boss Tag"]          = "tag_boss",
    ["Standard Tag"]      = "tag_standard",
    ["Charm Tag"]         = "tag_charm",
    ["Meteor Tag"]        = "tag_meteor",
    ["Buffoon Tag"]       = "tag_buffoon",
    ["Handy Tag"]         = "tag_handy",
    ["Garbage Tag"]       = "tag_garbage",
    ["Ethereal Tag"]      = "tag_ethereal",
    ["Coupon Tag"]        = "tag_coupon",
    ["Double Tag"]        = "tag_double",
    ["Juggle Tag"]        = "tag_juggle",
    ["D6 Tag"]            = "tag_d_six",
    ["Top-up Tag"]        = "tag_top_up",
    ["Skip Tag"]          = "tag_skip",
    ["Orbital Tag"]       = "tag_orbital",
    ["Economy Tag"]       = "tag_economy",

    -- BLINDS
    ["Small Blind"]   = "bl_small",
    ["Big Blind"]     = "bl_big",
    ["The Hook"]      = "bl_hook",
    ["The Ox"]        = "bl_ox",
    ["The House"]     = "bl_house",
    ["The Wall"]      = "bl_wall",
    ["The Wheel"]     = "bl_wheel",
    ["The Arm"]       = "bl_arm",
    ["The Club"]      = "bl_club",
    ["The Fish"]      = "bl_fish",
    ["The Psychic"]   = "bl_psychic",
    ["The Goad"]      = "bl_goad",
    ["The Water"]     = "bl_water",
    ["The Window"]    = "bl_window",
    ["The Manacle"]   = "bl_manacle",
    ["The Eye"]       = "bl_eye",
    ["The Mouth"]     = "bl_mouth",
    ["The Plant"]     = "bl_plant",
    ["The Serpent"]   = "bl_serpent",
    ["The Pillar"]    = "bl_pillar",
    ["The Needle"]    = "bl_needle",
    ["The Head"]      = "bl_head",
    ["The Tooth"]     = "bl_tooth",
    ["The Flint"]     = "bl_flint",
    ["The Mark"]      = "bl_mark",
    ["Amber Acorn"]   = "bl_final_acorn",
    ["Verdant Leaf"]  = "bl_final_leaf",
    ["Violet Vessel"] = "bl_final_vessel",
    ["Crimson Heart"] = "bl_final_heart",
    ["Cerulean Bell"] = "bl_final_bell",
  },
}
