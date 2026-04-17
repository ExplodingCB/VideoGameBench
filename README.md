# BalatroBench

Benchmark AI models by having them play [Balatro](https://www.playbalatro.com/), a roguelike deck-building poker game.

Models receive the full game state as structured text and respond with JSON actions. No screenshots, no vision models, no browser automation. Tests long-term strategic reasoning, hand evaluation, economy management, and decision-making.

## How It Works

```
Balatro + Lua Mod  <--TCP-->  Python Orchestrator  <--HTTP-->  AI Model
(game state text)             (bridge)                        (OpenRouter/Local)
```

1. The Lua mod reads game state directly from Balatro's runtime
2. Formats it as readable text (cards, jokers, scores, actions)
3. Python orchestrator sends state to the AI model
4. Model responds with a JSON action (play, discard, buy, etc.)
5. Orchestrator sends action back to the mod
6. Repeat until the run ends

## Prerequisites

- **Balatro** (Steam, v1.0.1+)
- **Lovely Injector** (v0.8.0+) - [Download](https://github.com/ethangreen-dev/lovely-injector/releases)
- **Python 3.10+**
- An AI model API (OpenRouter account or local model via Ollama)

## Setup

### 1. Install Lovely Injector

Download `version.dll` from [Lovely releases](https://github.com/ethangreen-dev/lovely-injector/releases) and place it in your Balatro game directory:
```
C:\Program Files (x86)\Steam\steamapps\common\Balatro\version.dll
```

### 2. Install the BalatroBench Mod

Copy the `mod/` folder contents to your Balatro mods directory:
```
%AppData%\Balatro\Mods\BalatroBench\
    BalatroBench.lua
    lovely.toml
    server.lua
    state.lua
    actions.lua
    format.lua
```

### 3. Install Python Dependencies

```bash
pip install -r requirements.txt
```

### 4. Set Up API Key (for OpenRouter)

```bash
export OPENROUTER_API_KEY="your-key-here"
```

Or on Windows:
```powershell
$env:OPENROUTER_API_KEY = "your-key-here"
```

## Usage

### Run a Benchmark

Start Balatro first, then run:

```bash
# OpenRouter model
python -m bench run --model "qwen/qwen-2.5-72b-instruct" --provider openrouter

# Local model (Ollama)
python -m bench run --model "llama3.3" --provider local

# Multiple runs
python -m bench run --model "qwen/qwen-2.5-72b-instruct" --runs 5

# Custom deck and stake
python -m bench run --model "qwen/qwen-2.5-72b-instruct" --deck "Blue Deck" --stake 2

# Custom endpoint
python -m bench run --model "my-model" --provider local --endpoint http://localhost:8080/v1
```

### View Leaderboard

```bash
python -m bench leaderboard
```

Output:
```
Model                          Wins   Avg Ante   Avg Score   Avg Time   Errors   Runs
------------------------------------------------------------------------------------------
claude-sonnet-4                 3/5       7.2       89,400     280.0s      2.0      5
gpt-4o                          2/5       6.8       72,100     195.0s      5.0      5
qwen2.5-72b                     1/5       5.4       45,200     410.0s     12.0      5
```

### View Run Details

```bash
python -m bench results --run-id run_20260415_001
```

## Configuration

Edit `config.yaml` to change defaults:

```yaml
default:
  deck: "Red Deck"
  stake: 1
  mod_host: "127.0.0.1"
  mod_port: 12345
  max_retries: 3
  timeout_seconds: 300
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `OPENROUTER_API_KEY` | OpenRouter API key |
| `MODEL_API_KEY` | Generic model API key |
| `BALATROBENCH_PORT` | Override mod TCP port (default: 12345) |
| `BALATROBENCH_FAST` | Set to `1` for fast mode (10x speed, reduced animations) |

## What the AI Sees

The model receives structured text like this for each decision:

```
=== BALATRO BENCH ===
Run Seed: ABC123 | Deck: Red Deck | Stake: 1
Ante: 3/8 | Round: Boss Blind (The Wheel)
Target Score: 4,000 | Current Score: 0
Hands Remaining: 4 | Discards Remaining: 3
Money: $15 | Interest Rate: $1 per $5 (cap $5) | Next Interest: $3

--- YOUR HAND (8 cards) ---
[1] King of Hearts    | Chips: 10 | Edition: Foil (+50 Chips) | No Enhancement | No Seal
[2] Queen of Spades   | Chips: 10 | Base | No Enhancement | No Seal
[3] 10 of Hearts      | Chips: 10 | Base | No Enhancement | No Seal
[4] 10 of Diamonds    | Chips: 10 | Base | No Enhancement | No Seal
...

--- JOKERS [3/5 slots, ordered left to right] ---
[1] Joker (Common, sell: $1)
    Effect: +4 Mult
...

--- ACTIONS ---
play <card_numbers>  | Play selected cards as a poker hand
discard <card_numbers> | Discard and draw replacements
...
```

The model must identify poker hands, evaluate joker synergies, and manage its economy on its own.

## Available Actions

| Phase | Actions |
|-------|---------|
| Blind Select | `select`, `skip`, `reroll_boss` |
| Playing Hand | `play`, `discard`, `use`, `rearrange_jokers`, `sort` |
| Shop | `buy`, `sell`, `use`, `reroll`, `rearrange_jokers`, `next_round` |
| Pack Opening | `select`, `skip` |
| Cash Out | `cash_out` |
| Game Over | `new_run`, `quit` |

## Available Decks

Red Deck, Blue Deck, Yellow Deck, Green Deck, Black Deck, Magic Deck, Nebula Deck, Ghost Deck, Abandoned Deck, Checkered Deck, Zodiac Deck, Painted Deck, Anaglyph Deck, Plasma Deck, Erratic Deck

## Project Structure

```
BalatroBench/
├── mod/                    # Balatro Lua mod
│   ├── BalatroBench.lua    # Entry point
│   ├── lovely.toml         # Lovely injector config
│   ├── server.lua          # TCP server
│   ├── state.lua           # Game state extraction
│   ├── actions.lua         # Action handlers
│   └── format.lua          # Text formatting
├── bench/                  # Python orchestrator
│   ├── __main__.py         # CLI
│   ├── client.py           # TCP client
│   ├── runner.py           # Run orchestration
│   ├── models.py           # Model API adapters
│   ├── prompt.py           # System prompt + parsing
│   ├── results.py          # Results tracking
│   └── config.py           # Configuration
├── config.yaml             # Default config
├── requirements.txt        # Python dependencies
└── results.jsonl           # Benchmark results (auto-created)
```
