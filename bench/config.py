"""Configuration loading for BalatroBench."""

import os

import yaml


DEFAULT_CONFIG = {
    "default": {
        "deck": "Red Deck",
        "stake": 1,
        "mod_host": "127.0.0.1",
        "mod_port": 12345,
        "max_retries": 3,
        "timeout_seconds": 300,
    },
    "models": {
        "openrouter": {
            "api_key_env": "OPENROUTER_API_KEY",
            "base_url": "https://openrouter.ai/api/v1",
        },
        "local": {
            "base_url": "http://localhost:11434/v1",
        },
    },
}


def load_config(config_path: str = "config.yaml") -> dict:
    """Load config from YAML file, falling back to defaults."""
    config = DEFAULT_CONFIG.copy()

    if os.path.exists(config_path):
        with open(config_path, "r", encoding="utf-8") as f:
            user_config = yaml.safe_load(f) or {}

        # Merge user config
        for section in ("default", "models"):
            if section in user_config:
                if section in config:
                    config[section].update(user_config[section])
                else:
                    config[section] = user_config[section]

    return config
