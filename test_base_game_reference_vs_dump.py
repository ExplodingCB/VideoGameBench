"""
Cross-validator: base_game_reference.lua vs. live game dump.

For every catalog entry with `template` + `tokens`, confirm:
  1. The internal key exists in the game's P_CENTERS/P_TAGS/P_BLINDS dump.
  2. The display name matches the dump.
  3. Every declared token can be resolved from the dump's config
     (either directly on config[token] or under config.extra[token]).

Skips entries with `kind` (runtime-computed) and entries with only `text`
(no parameters to verify). Reports any mismatches as failures.

The dump path is:
  C:\\Users\\thedu\\AppData\\Roaming\\Balatro\\Mods\\lovely\\dump\\game.lua
"""

import re
import os
import sys

CATALOG_PATH = os.path.join(os.path.dirname(__file__), "mod", "base_game_reference.lua")
DUMP_PATH = os.path.expanduser("~") + r"\AppData\Roaming\Balatro\Mods\lovely\dump\game.lua"


# ---------------------------------------------------------------------------
# Catalog parser (reuse structure from the self-test)
# ---------------------------------------------------------------------------

def parse_lua_catalog(path):
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    src = re.sub(r"--[^\n]*", "", src)

    by_key_m = re.search(r"by_key\s*=\s*\{(.*?)},?\s*by_name", src, re.DOTALL)
    if not by_key_m:
        raise ValueError("Could not find by_key block")

    entries = {}
    entry_re = re.compile(
        r"(\w+)\s*=\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}",
        re.DOTALL
    )
    for m in entry_re.finditer(by_key_m.group(1)):
        key = m.group(1)
        body = m.group(2)
        entry = {"_key": key}
        for field in ("set", "name", "text", "template", "kind", "hand_type"):
            fm = re.search(rf'{field}\s*=\s*"([^"]*)"', body)
            if fm:
                entry[field] = fm.group(1)
        tokens_m = re.search(r"tokens\s*=\s*\{([^}]*)\}", body)
        if tokens_m:
            raw = tokens_m.group(1)
            entry["tokens"] = [t.strip().strip('"') for t in raw.split(",") if t.strip().strip('"')]
        entries[key] = entry
    return entries


# ---------------------------------------------------------------------------
# Dump parser: extract each center/tag/blind row with its name and config
# ---------------------------------------------------------------------------

def parse_dump(path):
    """
    Returns dict: internal_key -> {name, set, config_fields}
    where config_fields is a flat set of field names that live on
    config.X or config.extra.X (where the template resolver looks).
    """
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()

    results = {}

    # Each line of interest looks like:
    #   key = { ... name = "X" ... set = "Y" ... config = { ... } ... }
    # We scan line by line since each row is effectively self-contained.
    for line in content.splitlines():
        key_m = re.search(
            r"(j_[a-z_0-9]+|c_[a-z_0-9]+|v_[a-z_0-9]+|tag_[a-z_0-9]+|bl_[a-z_0-9]+)\s*=\s*\{",
            line,
        )
        if not key_m:
            continue
        key = key_m.group(1)

        # Match "..." or '...' properly without mixing quote types.
        name_m = re.search(r'name\s*=\s*"([^"]*)"|name\s*=\s*\'([^\']*)\'', line)
        name = (name_m.group(1) or name_m.group(2)) if name_m else None

        set_m = re.search(r'set\s*=\s*"([^"]*)"|set\s*=\s*\'([^\']*)\'', line)
        set_type = (set_m.group(1) or set_m.group(2)) if set_m else None

        # Pull every {k = v} pair from the config block(s)
        config_fields = set()
        # Find outermost config = { ... } block on this line, handling nested braces
        cfg_start = line.find("config")
        if cfg_start >= 0:
            eq = line.find("=", cfg_start)
            if eq >= 0:
                brace = line.find("{", eq)
                if brace >= 0:
                    depth = 0
                    end = brace
                    while end < len(line):
                        ch = line[end]
                        if ch == "{":
                            depth += 1
                        elif ch == "}":
                            depth -= 1
                            if depth == 0:
                                end += 1
                                break
                        end += 1
                    cfg_str = line[brace:end]
                    # Every `word =` inside (including nested `extra = {...}`)
                    for fm in re.finditer(r"([A-Za-z_][A-Za-z_0-9]*)\s*=", cfg_str):
                        config_fields.add(fm.group(1))

        if key not in results:
            results[key] = {
                "name": name,
                "set": set_type,
                "config_fields": config_fields,
            }
    return results


# ---------------------------------------------------------------------------
# Cross-validation
# ---------------------------------------------------------------------------

# Tokens that are computed / game-state derived and not literal config fields
SPECIAL_TOKENS = {
    "hand_type",    # planet: from loc_ref.config.hand_type
    "orbital_hand", # tag: from card.config.hand_type
    "levels",       # tag: from card.config.levels (present as "levels")
}


def run():
    failures = []

    catalog = parse_lua_catalog(CATALOG_PATH)
    if not os.path.exists(DUMP_PATH):
        print(f"SKIP: dump file not found at {DUMP_PATH}")
        sys.exit(0)

    dump = parse_dump(DUMP_PATH)
    print(f"Parsed {len(catalog)} catalog entries and {len(dump)} dump entries")

    checked = 0
    name_mismatches = 0
    key_missing = 0
    token_missing = 0

    for key, entry in catalog.items():
        # Only validate entries that reference the dump — skip kind-only
        if "template" not in entry and "text" not in entry:
            # has only kind, skip config validation
            if key not in dump:
                failures.append(f"[{key}] key not in dump")
                key_missing += 1
            continue

        if key not in dump:
            failures.append(f"[{key}] key not in dump")
            key_missing += 1
            continue

        dump_entry = dump[key]
        checked += 1

        # Name match
        if entry.get("name") and dump_entry.get("name") and entry["name"] != dump_entry["name"]:
            failures.append(
                f"[{key}] name mismatch: catalog='{entry['name']}',"
                f" dump='{dump_entry['name']}'"
            )
            name_mismatches += 1

        # Token resolvability
        if "tokens" in entry:
            for token in entry["tokens"]:
                if token in SPECIAL_TOKENS:
                    continue
                if token not in dump_entry["config_fields"]:
                    failures.append(
                        f"[{key}] token '{token}' not in dump config"
                        f" (available: {sorted(dump_entry['config_fields'])})"
                    )
                    token_missing += 1

    print(f"\nValidated {checked} cataloged-vs-dump entries")
    print(f"  Key missing in dump:  {key_missing}")
    print(f"  Name mismatches:      {name_mismatches}")
    print(f"  Unresolvable tokens:  {token_missing}")

    if failures:
        print(f"\nFAILED: {len(failures)} issue(s):")
        for f in failures[:50]:
            print(f"  - {f}")
        if len(failures) > 50:
            print(f"  ... and {len(failures) - 50} more")
        sys.exit(1)
    else:
        print("\nOK: All catalog entries cross-validate against the dump.")


if __name__ == "__main__":
    run()
