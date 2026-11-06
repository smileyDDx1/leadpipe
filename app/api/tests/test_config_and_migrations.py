from __future__ import annotations

import re

import pytest

from leadpipe_api.config import ConfigError, DatabaseSettings, Settings
from leadpipe_api.migrate import discover_migrations

ENV = {
    "API_KEY": "secret-key",
    "DB_HOST": "db.internal",
    "DB_NAME": "leadpipe",
    "DB_USER": "app",
    "DB_PASSWORD": "p@ss word/#1",
    "REDIS_HOST": "redis",
}


def test_settings_load_from_environment():
    settings = Settings.from_env(ENV)

    assert settings.database.host == "db.internal"
    assert settings.database.port == 5432
    assert settings.redis_port == 6379
    assert settings.queue_stream == "leads:jobs"


def test_missing_settings_are_all_reported_at_once():
    with pytest.raises(ConfigError) as error:
        Settings.from_env({"DB_HOST": "db"})

    for name in ("API_KEY", "DB_NAME", "DB_USER", "DB_PASSWORD", "REDIS_HOST"):
        assert name in str(error.value)


def test_non_numeric_port_is_rejected():
    with pytest.raises(ConfigError, match="DB_PORT"):
        Settings.from_env({**ENV, "DB_PORT": "abc"})


def test_secrets_never_appear_in_repr():
    text = repr(Settings.from_env(ENV))

    assert "secret-key" not in text
    assert "p@ss" not in text


def test_conninfo_escapes_special_characters_in_the_password():
    conninfo = DatabaseSettings.from_env(ENV).conninfo()

    assert "password='p@ss word/#1'" in conninfo


def test_conninfo_can_target_the_maintenance_database():
    assert "dbname=postgres" in DatabaseSettings.from_env(ENV).conninfo("postgres")


def test_migrations_are_uniquely_numbered_and_sorted():
    names = [path.name for path in discover_migrations()]

    assert names, "no migrations found"
    assert names == sorted(names)
    prefixes = [re.match(r"(\d{4})_", name).group(1) for name in names]
    assert len(prefixes) == len(set(prefixes))
