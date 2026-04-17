# BalatroBench Design Spec

## Context

Balatro is a roguelike deck-building poker game that requires long-term strategic reasoning: economy management, hand evaluation, joker synergy building, and risk assessment across 8+ antes. This makes it an excellent benchmark for evaluating AI models on sustained multi-step reasoning and decision-making.

**Problem**: Existing Balatro AI tools (e.g., coder/balatrobench) rely on Playwright + browser automation + vision models to extract game state from screenshots. This is heavy, slow, and excludes non-visual models.

**Solution**: BalatroBench is a lightweight Lua mod + Python orchestrator that gives AI models direct text-based access to the full game state and actions. No screenshots, no vision models, no browser automation. The mod reads game state directly from Balatro's Lua runtime and exposes it as structured text over TCP.

**Goal**: Benchmark any AI model (cloud or local, any size) on its ability to play a complete Balatro run through text-based tool calls, measuring score, win rate, and decision quality.

---

## Architecture

```
+---------------------+      TCP           +------------------------+
|   Balatro + Mod     |<------------------>|  Python Orchestrator   |
|  (Lua TCP Server)   |                    |                        |
|                     | formatted text  >  |  Text -> Model API     |
|  - State extraction |                    |  Response parsing      |
|  - Text formatting  | < action JSON      |  Action dispatch       |
|  - Action handlers  |                    |  Results tracking      |
|  - Fast mode        |                    |                        |
+---------------------+                    +------------------------+
                                                    |
                                            +-------v--------+
                                            |  AI Model API  |
                                            |  (OpenRouter / |
                                            |   Local model) |
                                            +----------------+
```

### Component 1: Balatro Lua Mod

A mod installed via Lovely injector that runs a TCP server inside Balatro using LuaSocket (bundled with LOVE2D).

**Responsibilities**:
- TCP server on `127.0.0.1:12345` accepting newline-delimited JSON
- Extract full game state from Balatro's global `G` object
- Format game state as structured text in Lua and send as plain text over TCP
- Execute player actions by calling game functions
- Support fast-forward mode (skip animations, speed up game)
- Wait for action commands before advancing game state (game pauses until AI responds)

**Key game state sources**:
- `G.STATE` — current game phase
- `G.GAME` — run metadata (ante, round, dollars, interest, deck, stake, seed)
- `G.hand` — player's current hand cards
- `G.jokers` — active jokers with abilities
- `G.consumeables` — owned tarot/planet/spectral cards
- `G.shop` — shop inventory
- `G.play` — cards currently in play area
- `G.deck` — remaining deck cards
- `G.GAME.hands_left`, `G.GAME.discards_left` — remaining actions
- `G.GAME.blind` — current blind info and boss effect
- `G.GAME.chips` — current score this round
- `G.hand_text_config` — hand level data

**Protocol**:
- Mod -> Orchestrator: Formatted text game state (the exact text shown in the format examples below), terminated by a delimiter line `===END===`
- Orchestrator -> Mod: Action JSON on a single line, e.g., `{"action": "play", "cards": [3,4]}\n`
- Special request: `{"method": "gamestate"}\n` to request current state without taking an action
- The mod blocks game progression until it receives a valid action command

### Component 2: Python Orchestrator

A lightweight Python script that connects to the mod, communicates with AI models, and tracks results.

**Responsibilities**:
- TCP client connecting to the mod
- Receive formatted text game state from the mod
- Build model prompt: system prompt (once) + game state text
- Send to AI model via HTTP API (OpenRouter or local OpenAI-compatible endpoint)
- Parse JSON action from model response
- Send action JSON to mod over TCP
- Track timing, token usage, and results
- Write results to `results.jsonl`
- Print leaderboard summaries

**Model communication**: Simple JSON prompt + response parsing. No native tool-calling API required. The model receives game state as text in its prompt and responds with a JSON action object. This works with any model regardless of tool-calling support.

**Response parsing strategy**:
1. Try to extract JSON from the response using regex `\{.*\}`
2. If valid JSON with an `action` field, execute it
3. If invalid, ask the model to retry (up to 3 retries)
4. If all retries fail, take a default safe action (discard weakest cards or skip)

---

## Game State Text Format

The mod formats game state as readable text. The model does NOT receive pre-computed hand analysis — it must evaluate poker hands on its own.

### BLIND_SELECT Phase

```
=== BALATRO BENCH ===
Run Seed: ABC123 | Deck: Red Deck | Stake: White Stake
Ante: 3/8 | Phase: Blind Select
Money: $15 | Interest: $3/round

--- UPCOMING BLINDS ---
[Small Blind] Target: 800 | Reward: $3
  Status: Available (can skip)
  Skip Reward Tag: +$5

[Big Blind] Target: 1,200 | Reward: $4
  Status: Locked (must beat Small first)

[Boss Blind: The Wheel] Target: 1,600 | Reward: $5
  Effect: 1 in 7 cards are drawn face down
  Status: Locked

--- JOKERS [3/5 slots] ---
[1] Joker (Common, $1 sell)
    Effect: +4 Mult | Activation: After scoring
[2] Greedy Joker (Common, $2 sell)
    Effect: Played cards with Diamond suit give +3 Mult | Activation: Per scored card
[3] Blueprint (Rare, $4 sell)
    Effect: Copies the ability of the Joker to the right | Activation: Varies
    Note: Currently copying nothing (rightmost joker)

--- CONSUMABLES [1/2 slots] ---
[1] The Hanged Man (Tarot, $1 sell)
    Effect: Destroys up to 2 selected cards in your hand

--- HAND LEVELS ---
High Card      Lv.1: 5 Chips + 1 Mult    | Pair           Lv.3: 20 Chips + 4 Mult
Two Pair       Lv.1: 20 Chips + 2 Mult   | Three of Kind  Lv.2: 40 Chips + 4 Mult
Straight       Lv.1: 30 Chips + 4 Mult   | Flush          Lv.1: 35 Chips + 4 Mult
Full House     Lv.1: 40 Chips + 4 Mult   | Four of Kind   Lv.1: 60 Chips + 7 Mult
Straight Flush Lv.1: 100 Chips + 8 Mult  | Royal Flush    Lv.1: 100 Chips + 8 Mult
Five of Kind   Lv.1: 120 Chips + 12 Mult | Flush House    Lv.1: 140 Chips + 14 Mult
Flush Five     Lv.1: 160 Chips + 16 Mult

--- ACTIONS ---
select    | Play the current blind
skip      | Skip this blind and collect the skip reward tag
```

### SELECTING_HAND Phase (Playing Cards)

```
=== BALATRO BENCH ===
Run Seed: ABC123 | Deck: Red Deck | Stake: White Stake
Ante: 3/8 | Round: Boss Blind (The Wheel)
Target Score: 4,000 | Current Score: 0
Hands Remaining: 4 | Discards Remaining: 3
Money: $15 | Interest Rate: $1 per $5 (cap $5) | Next Interest: $3

--- YOUR HAND (8 cards) ---
[1] King of Hearts    | Chips: 10 | Edition: Foil (+50 Chips when scored) | No Enhancement | No Seal
[2] Queen of Spades   | Chips: 10 | Base | No Enhancement | No Seal
[3] 10 of Hearts      | Chips: 10 | Base | No Enhancement | No Seal
[4] 10 of Diamonds    | Chips: 10 | Base | No Enhancement | No Seal
[5] 7 of Clubs        | Chips: 7  | Base | No Enhancement | Seal: Gold ($3 when played)
[6] 5 of Hearts       | Chips: 5  | Base | Enhancement: Mult (+4 Mult when scored) | No Seal
[7] 3 of Spades       | Chips: 3  | Base | No Enhancement | No Seal
[8] 2 of Clubs        | Chips: 2  | Base | No Enhancement | No Seal

--- JOKERS [3/5 slots, ordered left to right] ---
[1] Joker (Common, $1 sell)
    Effect: +4 Mult | Activation: After scoring
[2] Greedy Joker (Common, $2 sell)
    Effect: Played cards with Diamond suit give +3 Mult | Activation: Per scored card
[3] Blueprint (Rare, $4 sell)
    Effect: Copies the ability of the Joker to the right | Activation: Varies
    Note: Currently copying nothing (rightmost joker)

--- CONSUMABLES [1/2 slots] ---
[1] The Hanged Man (Tarot, $1 sell)
    Effect: Destroys up to 2 selected cards in your hand

--- HAND LEVELS ---
High Card      Lv.1: 5 Chips + 1 Mult    | Pair           Lv.3: 20 Chips + 4 Mult
Two Pair       Lv.1: 20 Chips + 2 Mult   | Three of Kind  Lv.2: 40 Chips + 4 Mult
Straight       Lv.1: 30 Chips + 4 Mult   | Flush          Lv.1: 35 Chips + 4 Mult
Full House     Lv.1: 40 Chips + 4 Mult   | Four of Kind   Lv.1: 60 Chips + 7 Mult
Straight Flush Lv.1: 100 Chips + 8 Mult  | Royal Flush    Lv.1: 100 Chips + 8 Mult
Five of Kind   Lv.1: 120 Chips + 12 Mult | Flush House    Lv.1: 140 Chips + 14 Mult
Flush Five     Lv.1: 160 Chips + 16 Mult

--- DECK INFO ---
Cards remaining in deck: 44 | Cards in hand: 8 | Total deck size: 52

--- BOSS BLIND EFFECT ---
The Wheel: 1 in 7 cards are drawn face down

--- RUN STATS ---
Rounds Won: 6 | Rounds Lost: 0 | Total Hands Played: 18
Highest Single Hand Score: 2,450

--- ACTIONS ---
play <card_numbers>         | Play selected cards as a poker hand
                            | Example: "play 3 4" plays the 10 of Hearts and 10 of Diamonds
discard <card_numbers>      | Discard selected cards and draw replacements (costs 1 discard)
                            | Example: "discard 6 7 8"
use <slot> [card_numbers]   | Use consumable, optionally targeting hand cards
                            | Example: "use 1 7 8" uses Hanged Man to destroy cards 7 and 8
rearrange_jokers <order>    | Reorder jokers left-to-right (affects activation order)
                            | Example: "rearrange_jokers 2 3 1"
sort <rank|suit>            | Sort hand by rank or suit for readability
```

### SHOP Phase

```
=== BALATRO BENCH ===
Run Seed: ABC123 | Deck: Red Deck | Stake: White Stake
Ante: 3/8 | Phase: Shop
Money: $18 | Reroll Cost: $5

--- FOR SALE ---
[1] Ride the Bus (Joker, Common, $5)
    Effect: +1 Mult per consecutive hand played without a scoring face card
[2] Mercury (Planet, $3)
    Effect: Upgrades High Card by 1 level (+15 Chips, +1 Mult)
[3] The Fool (Tarot, $3)
    Effect: Creates a copy of the last Tarot or Planet card used this run

--- BOOSTER PACKS ---
[1] Arcana Pack ($4) - Choose 1 of 3 Tarot cards
[2] Standard Pack ($4) - Choose 1 of 3 playing cards (may have enhancements/editions)

--- VOUCHER ---
[1] Grabber ($10) - Permanently gain +1 hand per round

--- YOUR JOKERS [3/5 slots] ---
[1] Joker (Common, sell: $1) - +4 Mult
[2] Greedy Joker (Common, sell: $2) - +3 Mult per Diamond scored
[3] Blueprint (Rare, sell: $4) - Copies joker to the right

--- YOUR CONSUMABLES [1/2 slots] ---
[1] The Hanged Man (Tarot, sell: $1) - Destroy up to 2 cards

--- ACTIONS ---
buy card <index>       | Buy a card from the shop (e.g., "buy card 1" for Ride the Bus)
buy voucher 1          | Buy the voucher
buy pack <index>       | Buy and open a booster pack
sell joker <index>     | Sell a joker for its sell value
sell consumable <index>| Sell a consumable for its sell value
use <slot> [cards]     | Use a consumable (if applicable outside of round)
reroll                 | Reroll shop cards for $5
rearrange_jokers <order> | Reorder jokers
next_round             | Leave shop, proceed to blind select
```

### PACK_OPEN Phase

```
=== BALATRO BENCH ===
Phase: Pack Opening (Arcana Pack - Choose 1 of 3)

--- PACK CONTENTS ---
[1] The Magician (Tarot)
    Effect: Enhances up to 2 selected cards with Lucky enhancement
[2] The Empress (Tarot)
    Effect: Enhances up to 2 selected cards with Mult enhancement (+4 Mult)
[3] The Tower (Tarot)
    Effect: Enhances up to 1 selected card with Stone enhancement (+50 Chips, no rank/suit)

--- YOUR CONSUMABLES [1/2 slots] ---
[1] The Hanged Man (Tarot)

--- ACTIONS ---
select <index>  | Choose a card from the pack (e.g., "select 2" for The Empress)
skip            | Skip, don't take any card
```

### CASH_OUT Phase

```
=== BALATRO BENCH ===
Phase: Round Complete - Cash Out

--- REWARDS ---
Blind Reward: $5
Hands Remaining Bonus: $2 (2 unused hands)
Interest: $3 ($15 held, $1 per $5)
Total: $10

--- ACTIONS ---
cash_out  | Collect rewards and proceed to shop
```

### GAME_OVER Phase

```
=== BALATRO BENCH ===
Phase: Game Over

--- FINAL RESULTS ---
Result: DEFEAT (or VICTORY)
Ante Reached: 5/8
Final Chip Score: 125,000
Rounds Won: 12
Total Hands Played: 38

--- ACTIONS ---
new_run             | Start a new run with same config
new_run <deck> <stake> | Start with different deck/stake
quit                | End benchmark session
```

---

## Action Protocol

The model always responds with a JSON object. The orchestrator parses this and sends it to the mod.

### Action JSON Format

```json
{"action": "play", "cards": [3, 4]}
{"action": "discard", "cards": [6, 7, 8]}
{"action": "use", "slot": 1, "cards": [7, 8]}
{"action": "buy", "type": "card", "index": 1}
{"action": "sell", "type": "joker", "index": 3}
{"action": "select"}
{"action": "skip"}
{"action": "reroll"}
{"action": "cash_out"}
{"action": "next_round"}
{"action": "rearrange_jokers", "order": [2, 3, 1]}
{"action": "sort", "by": "rank"}
{"action": "select", "index": 2}
{"action": "new_run"}
{"action": "quit"}
```

### Error Handling

If the model sends an invalid action:
1. The mod returns an error message describing what went wrong
2. The orchestrator includes the error in the next prompt: "Invalid action: cannot play 6 cards, maximum is 5. Please try again."
3. The model gets 3 retry attempts per decision point
4. After 3 failures, a safe default action is taken (skip/discard lowest)
5. Retry count is tracked in results for quality assessment

### Validation Rules

The mod validates all actions before executing:
- `play`: 1-5 cards, valid indices, cards must be in hand
- `discard`: at least 1 card, valid indices, discards remaining > 0
- `buy`: sufficient money, valid shop index, available slots (joker/consumable)
- `sell`: valid index for owned items
- `use`: valid consumable slot, correct number of target cards for the consumable
- `rearrange_jokers`: must include all current joker indices exactly once

---

## Model System Prompt

Sent once at the start of each run:

```
You are playing Balatro, a roguelike deck-building poker game. Your goal is to score
enough chips to defeat all 8 antes and win the run.

CORE RULES:
- Each round, you must score at least the target number of chips to win.
- Score = Chips x Mult. Base chips and mult come from the poker hand type you play.
- You have limited hands (plays) and discards each round.
- After each round, visit the shop to buy Jokers, consumables, and vouchers.

SCORING:
- Playing cards contribute their chip value (Ace=11, Face=10, others=face value).
- The poker hand type provides base Chips + base Mult (shown in Hand Levels).
- Jokers add bonuses: +Chips, +Mult (additive), or xMult (multiplicative).
- Additive bonuses apply first, then multiplicative. Joker order (left to right) matters.
- Enhancements, editions, and seals on cards provide additional bonuses.

POKER HANDS (weakest to strongest):
High Card, Pair, Two Pair, Three of a Kind, Straight, Flush, Full House,
Four of a Kind, Straight Flush, Royal Flush, Five of a Kind, Flush House, Flush Five.

ECONOMY:
- You earn interest: $1 per $5 held (default cap: $5 interest per round).
- Balance spending on upgrades vs saving for interest.
- You can sell jokers and consumables for half their buy price.

STRATEGY TIPS:
- Focus on leveling up 1-2 hand types with Planet cards for scaling.
- Build joker synergies (e.g., mult jokers + chip jokers + xmult jokers).
- Joker order matters: place +Mult before xMult for maximum score.
- Sometimes skipping blinds for tags is worth the lost reward money.

RESPONSE FORMAT:
Analyze the game state, then respond with ONLY a JSON action on a single line.
Example: {"action": "play", "cards": [1, 3, 5]}

Do not include any text after the JSON. Only output the JSON action object.
```

---

## Benchmark Results & Leaderboard

### Result Record (per run)

```json
{
  "model": "qwen2.5-7b",
  "provider": "openrouter",
  "run_id": "run_20260415_001",
  "seed": "RAND_8f3a2b",
  "config": {
    "deck": "Red Deck",
    "stake": "White Stake"
  },
  "result": {
    "won": false,
    "ante_reached": 5,
    "final_score": 125000,
    "rounds_won": 12,
    "rounds_lost": 1,
    "highest_hand_score": 48000,
    "total_money_earned": 89,
    "total_hands_played": 38,
    "total_discards_used": 22,
    "total_actions": 156,
    "invalid_actions": 4,
    "retries": 6
  },
  "timing": {
    "total_seconds": 342.5,
    "avg_decision_seconds": 2.2,
    "model_time_seconds": 310.0,
    "game_time_seconds": 32.5
  },
  "tokens": {
    "prompt_tokens": 125000,
    "completion_tokens": 8500,
    "total_cost_usd": 0.42
  },
  "timestamp": "2026-04-15T17:30:00Z"
}
```

### Leaderboard

Stored as `results.jsonl` (one JSON record per line). CLI command to print summary:

```
python -m bench leaderboard

Model               Wins   Avg Ante   Avg Score   Avg Time   Runs   Errors
claude-sonnet-4     3/5    7.2        89,400      280s       5      2
gpt-4o              2/5    6.8        72,100      195s       5      5
qwen2.5-72b         1/5    5.4        45,200      410s       5      12
llama-3.3-70b       0/5    3.8        22,800      520s       5      31
```

### CLI Usage

```bash
# Run a single benchmark
python -m bench run --model "qwen/qwen-2.5-72b" --provider openrouter --deck "Red Deck" --stake "White Stake"

# Run multiple benchmarks
python -m bench run --model "qwen/qwen-2.5-72b" --runs 5

# Use a local model
python -m bench run --model "llama3.3" --provider local --endpoint http://localhost:11434/v1

# View leaderboard
python -m bench leaderboard

# View detailed run results
python -m bench results --run-id run_20260415_001
```

### Config File (config.yaml)

```yaml
default:
  deck: "Red Deck"
  stake: "White Stake"
  mod_host: "127.0.0.1"
  mod_port: 12345
  max_retries: 3
  timeout_seconds: 60  # per action, kill run if model takes too long

models:
  openrouter:
    api_key_env: "OPENROUTER_API_KEY"
    base_url: "https://openrouter.ai/api/v1"
  local:
    base_url: "http://localhost:11434/v1"
```

---

## File Structure

```
BalatroBench/
├── mod/                            # Balatro Lua mod (copy entire folder to %AppData%/Balatro/Mods/)
│   ├── BalatroBench.lua            # Mod entry point (loaded by Lovely)
│   ├── lovely.toml                 # Lovely injector patch config
│   ├── server.lua                  # TCP server using LuaSocket
│   ├── state.lua                   # Game state extraction from G object
│   ├── actions.lua                 # Action handlers (play, buy, sell, etc.)
│   └── format.lua                  # State -> structured text formatting
├── bench/                          # Python orchestrator
│   ├── __init__.py
│   ├── __main__.py                 # CLI entry point (argparse)
│   ├── client.py                   # TCP client to connect to mod
│   ├── runner.py                   # Run orchestration loop
│   ├── models.py                   # Model API adapters (OpenRouter, local/Ollama)
│   ├── prompt.py                   # System prompt + JSON response parsing
│   ├── results.py                  # Results tracking, JSONL I/O, leaderboard
│   └── config.py                   # Config loading (YAML + CLI args)
├── results.jsonl                   # Benchmark results (auto-created)
├── config.yaml                     # Default configuration
├── requirements.txt                # Python deps: requests, pyyaml
└── README.md                       # Setup & usage guide
```

---

## Game Mechanics Coverage

Every aspect a human player can interact with is exposed:

| Game Aspect | How It's Exposed |
|-------------|-----------------|
| Card viewing | Full card details: rank, suit, chips, enhancement, edition, seal |
| Hand playing | `play` action with card indices |
| Discarding | `discard` action with card indices |
| Scoring | Target, current score, hand levels shown |
| Jokers | Full descriptions, effects, sell values, activation types |
| Joker ordering | `rearrange_jokers` action |
| Shop buying | `buy` action for cards, vouchers, packs |
| Shop rerolling | `reroll` action |
| Selling items | `sell` action for jokers and consumables |
| Consumable use | `use` action with optional card targets |
| Tarot cards | Shown in consumables, usable via `use` |
| Planet cards | Shown in consumables, usable via `use` |
| Spectral cards | Shown in consumables, usable via `use` |
| Vouchers | Shown in shop, buyable |
| Booster packs | `buy pack`, then `select`/`skip` in pack phase |
| Boss blind effects | Described in text, model must strategize around them |
| Skip/select blinds | `skip`/`select` in blind select phase |
| Tags (skip rewards) | Shown in blind select phase |
| Deck composition | Card count and remaining deck info shown |
| Economy/interest | Money, interest rate, cap shown |
| Hand levels | Full table with chips + mult per level |
| Stickers (Eternal, Perishable, Rental) | Shown on jokers at higher stakes |
| Seals (Gold, Red, Blue, Purple) | Shown on cards |
| Editions (Foil, Holo, Poly, Negative) | Shown on cards and jokers |
| Enhancements (Bonus, Mult, Wild, Glass, Steel, Stone, Gold, Lucky) | Shown on cards |

---

## Technical Notes

### Lua Mod Implementation

- Uses `require("socket")` (LuaSocket, bundled with LOVE2D) for TCP server
- Non-blocking accept with `settimeout(0)` on the server socket
- Blocking read on client socket once connected (game waits for AI input)
- Game state extraction reads directly from the global `G` object
- Action execution calls existing game functions (e.g., `G.FUNCS.play_cards_from_highlighted()`)
- Fast mode: set `G.SETTINGS.GAMESPEED` to max, skip card movement animations
- The mod hooks into the game's update loop to check for TCP messages each frame

### Python Orchestrator Implementation

- Uses Python's built-in `socket` module for TCP client (no dependencies for comms)
- Uses `requests` for model API calls (OpenRouter compatible endpoint)
- JSON parsing with `json` module, regex fallback for extracting JSON from model output
- Results written as JSONL using `json.dumps()` per line
- Config loaded from YAML with `pyyaml`
- CLI built with `argparse`
- Total Python dependencies: `requests`, `pyyaml` (2 packages)

### Lovely Injector Setup

The mod uses Lovely injector to hook into Balatro. The `lovely.toml` defines patches that:
1. Load the BalatroBench mod at game startup
2. Hook into the game's main update loop for TCP polling
3. Hook into state transitions to detect phase changes

---

## Verification Plan

1. **Mod loads**: Start Balatro with mod installed, verify TCP server starts (test with `telnet 127.0.0.1 12345`)
2. **State extraction**: Send `{"method": "gamestate"}`, verify complete JSON response with all game fields
3. **Action execution**: Send action commands, verify game responds correctly
4. **Full run**: Run orchestrator with a simple heuristic (play highest pair, buy cheapest joker) to verify end-to-end flow
5. **Model integration**: Run with a real model via OpenRouter, verify it can play multiple rounds
6. **Results tracking**: Verify results.jsonl is written correctly after each run
7. **Leaderboard**: Run multiple models, verify leaderboard output
