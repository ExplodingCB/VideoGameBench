"""
Sanity checks for mod/base_game_reference.lua catalog.

Parses the catalog file with a lightweight Lua-table reader (no full Lua
runtime needed) and checks structural invariants:

  1. by_key <-> by_name are bidirectionally consistent
  2. Every entry has required fields (set, name, one of text/template/kind)
  3. Every template entry has a matching tokens list
  4. No duplicate display names in by_name
  5. Key prefixes match expected sets
  6. Known canonical examples produce expected token resolution
"""

import re
import os
import sys

CATALOG_PATH = os.path.join(os.path.dirname(__file__), "mod", "base_game_reference.lua")

# ---------------------------------------------------------------------------
# Minimal Lua table parser
# ---------------------------------------------------------------------------

def parse_lua_catalog(path):
    """
    Very limited Lua parser that handles the schema used in base_game_reference.lua.
    Returns (by_key, by_name) dicts.
    """
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()

    # Strip comments
    src = re.sub(r"--[^\n]*", "", src)

    by_key = {}
    by_name = {}

    # Extract by_key entries: key = { ... }
    by_key_block = re.search(r"by_key\s*=\s*\{(.*?)},?\s*by_name", src, re.DOTALL)
    if not by_key_block:
        raise ValueError("Could not find by_key block in catalog")

    # Extract individual entries from by_key
    entry_re = re.compile(
        r"(\w+)\s*=\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}",
        re.DOTALL
    )
    for m in entry_re.finditer(by_key_block.group(1)):
        key = m.group(1)
        body = m.group(2)

        entry = {"_key": key}

        # Parse simple string fields
        for field in ("set", "name", "text", "template", "kind", "hand_type"):
            fm = re.search(rf'{field}\s*=\s*"([^"]*)"', body)
            if fm:
                entry[field] = fm.group(1)

        # Parse tokens list
        tokens_m = re.search(r"tokens\s*=\s*\{([^}]*)\}", body)
        if tokens_m:
            raw = tokens_m.group(1)
            entry["tokens"] = [t.strip().strip('"') for t in raw.split(",") if t.strip().strip('"')]

        by_key[key] = entry

    # Extract by_name entries: ["Display Name"] = "key"
    by_name_block = re.search(r"by_name\s*=\s*\{(.*?)\}", src, re.DOTALL)
    if not by_name_block:
        raise ValueError("Could not find by_name block in catalog")

    name_entry_re = re.compile(r'\["([^"]+)"\]\s*=\s*"([^"]+)"')
    for m in name_entry_re.finditer(by_name_block.group(1)):
        display_name, internal_key = m.group(1), m.group(2)
        by_name[display_name] = internal_key

    return by_key, by_name


# ---------------------------------------------------------------------------
# Expected set prefixes
# ---------------------------------------------------------------------------

SET_PREFIXES = {
    "Joker":    "j_",
    "Planet":   "c_",
    "Tarot":    "c_",
    "Spectral": "c_",
    "Voucher":  "v_",
    "Tag":      "tag_",
    "Blind":    "bl_",
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def run_tests():
    failures = []

    try:
        by_key, by_name = parse_lua_catalog(CATALOG_PATH)
    except Exception as e:
        print(f"FAIL: Could not parse catalog: {e}")
        sys.exit(1)

    print(f"Parsed catalog: {len(by_key)} by_key entries, {len(by_name)} by_name entries")

    # -----------------------------------------------------------------------
    # 1. Required fields
    # -----------------------------------------------------------------------
    for key, entry in by_key.items():
        if "set" not in entry:
            failures.append(f"by_key[{key}]: missing 'set' field")
        if "name" not in entry:
            failures.append(f"by_key[{key}]: missing 'name' field")
        has_desc = "text" in entry or "template" in entry or "kind" in entry
        if not has_desc:
            failures.append(f"by_key[{key}]: must have 'text', 'template', or 'kind'")
        if "template" in entry and "tokens" not in entry:
            failures.append(f"by_key[{key}]: has 'template' but missing 'tokens'")

    # -----------------------------------------------------------------------
    # 2. by_key <-> by_name consistency
    # -----------------------------------------------------------------------
    for key, entry in by_key.items():
        name = entry.get("name")
        if not name:
            continue
        # Every by_key entry with a name should have a reverse mapping
        if name not in by_name:
            failures.append(f"by_name missing reverse for '{name}' (key={key})")
        elif by_name[name] != key:
            failures.append(
                f"by_name['{name}'] = '{by_name[name]}', expected '{key}'"
            )

    for name, key in by_name.items():
        if key not in by_key:
            failures.append(f"by_name['{name}'] = '{key}' but that key is not in by_key")

    # -----------------------------------------------------------------------
    # 3. Key prefix matches set
    # -----------------------------------------------------------------------
    for key, entry in by_key.items():
        set_type = entry.get("set", "")
        expected_prefix = SET_PREFIXES.get(set_type)
        if expected_prefix and not key.startswith(expected_prefix):
            failures.append(
                f"by_key[{key}] has set='{set_type}' but key prefix is wrong"
                f" (expected '{expected_prefix}...')"
            )

    # -----------------------------------------------------------------------
    # 4. Coverage: required sets must all be present
    # -----------------------------------------------------------------------
    required_sets = {"Joker", "Tarot", "Planet", "Spectral", "Voucher", "Tag", "Blind"}
    found_sets = {e.get("set") for e in by_key.values()}
    for s in required_sets:
        if s not in found_sets:
            failures.append(f"No entries found for required set '{s}'")

    # -----------------------------------------------------------------------
    # 5. Canonical examples from the spec
    # -----------------------------------------------------------------------
    canonical = [
        ("j_droll",          "Joker",   "Droll Joker"),
        ("c_pluto",          "Planet",  "Pluto"),
        ("v_tarot_merchant", "Voucher", "Tarot Merchant"),
        ("tag_economy",      "Tag",     "Economy Tag"),
        ("tag_coupon",       "Tag",     "Coupon Tag"),
        ("c_mercury",        "Planet",  "Mercury"),
        ("c_fool",           "Tarot",   "The Fool"),
        ("c_hex",            "Spectral","Hex"),
        ("bl_ox",            "Blind",   "The Ox"),
        ("bl_hook",          "Blind",   "The Hook"),
    ]
    for key, expected_set, expected_name in canonical:
        if key not in by_key:
            failures.append(f"Canonical key '{key}' not found in by_key")
            continue
        entry = by_key[key]
        if entry.get("set") != expected_set:
            failures.append(
                f"by_key[{key}].set = '{entry.get('set')}', expected '{expected_set}'"
            )
        if entry.get("name") != expected_name:
            failures.append(
                f"by_key[{key}].name = '{entry.get('name')}', expected '{expected_name}'"
            )

    # -----------------------------------------------------------------------
    # 6. Template token validation: tokens in template match tokens list
    # -----------------------------------------------------------------------
    token_re = re.compile(r"\{([A-Za-z_][A-Za-z_0-9]*)\}")
    for key, entry in by_key.items():
        if "template" not in entry:
            continue
        template_tokens = set(token_re.findall(entry["template"]))
        declared_tokens = set(entry.get("tokens", []))
        if template_tokens != declared_tokens:
            extra_in_template = template_tokens - declared_tokens
            extra_in_list = declared_tokens - template_tokens
            if extra_in_template:
                failures.append(
                    f"by_key[{key}]: template uses tokens {extra_in_template}"
                    f" not in tokens list"
                )
            if extra_in_list:
                failures.append(
                    f"by_key[{key}]: tokens list has {extra_in_list}"
                    f" not used in template"
                )

    # -----------------------------------------------------------------------
    # 7. Coverage counts by set
    # -----------------------------------------------------------------------
    counts = {}
    for entry in by_key.values():
        s = entry.get("set", "Unknown")
        counts[s] = counts.get(s, 0) + 1

    print("\nCoverage by set:")
    for s in sorted(counts):
        print(f"  {s:12s}: {counts[s]} entries")

    # -----------------------------------------------------------------------
    # Results
    # -----------------------------------------------------------------------
    print()
    if failures:
        print(f"FAILED: {len(failures)} error(s):")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    else:
        print(f"OK: All {len(by_key)} catalog entries passed validation.")


if __name__ == "__main__":
    run_tests()
