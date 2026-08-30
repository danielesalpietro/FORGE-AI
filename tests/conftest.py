"""Shared pytest fixtures for the FORGE-AI test suite.

Puts ``scripts/lib`` and ``ansible/filter_plugins`` on ``sys.path`` so
the tests exercise the same code the platform runs, rather than a copy.
"""

from __future__ import annotations

import sys
import types
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "lib"))


def _install_ansible_stub() -> None:
    """Let the filter plugins import without ansible-core installed.

    ``ansible/filter_plugins/forge_filters.py`` imports
    ``AnsibleFilterError``. Stubbing it keeps the filter tests runnable
    in a bare CI job -- and, more usefully, keeps the filters themselves
    honest about being plain functions with one Ansible-shaped
    exception type.
    """
    if "ansible.errors" in sys.modules:
        return
    try:
        import ansible.errors  # noqa: F401
        return
    except ImportError:
        pass

    ansible_module = types.ModuleType("ansible")
    errors_module = types.ModuleType("ansible.errors")

    class AnsibleFilterError(Exception):
        pass

    errors_module.AnsibleFilterError = AnsibleFilterError
    ansible_module.errors = errors_module
    sys.modules["ansible"] = ansible_module
    sys.modules["ansible.errors"] = errors_module


_install_ansible_stub()
sys.path.insert(0, str(REPO_ROOT / "ansible" / "filter_plugins"))


@pytest.fixture(scope="session")
def repo_root() -> Path:
    return REPO_ROOT


@pytest.fixture(scope="session")
def forge_config_module():
    import forge_config

    return forge_config


@pytest.fixture(scope="session")
def filters():
    import forge_filters

    return forge_filters


@pytest.fixture()
def base_config(forge_config_module):
    """The shipped defaults + example overlay, freshly loaded.

    Function-scoped and deep-copied by the loader, so a test that
    mutates it cannot leak into another.
    """
    return forge_config_module.load_config(
        forge_config_module.DEFAULTS_PATH,
        forge_config_module.EXAMPLE_OVERLAY_PATH,
    )


@pytest.fixture(scope="session")
def jinja_env(repo_root):
    from jinja2 import Environment, FileSystemLoader, StrictUndefined

    env = Environment(
        loader=FileSystemLoader(str(repo_root / "ansible" / "templates")),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
        trim_blocks=False,
        lstrip_blocks=False,
    )

    # Register the project's own filters so templates render exactly as
    # Ansible would render them.
    import forge_filters

    env.filters.update(forge_filters.FilterModule().filters())

    # A minimal stand-in for the Ansible-provided filters the templates
    # use. Only what is actually referenced.
    env.filters.setdefault("to_nice_json", lambda value, **_: __import__("json").dumps(value, indent=2))
    env.filters.setdefault("to_json", lambda value, **_: __import__("json").dumps(value))
    env.filters.setdefault("basename", lambda value: str(value).rsplit("/", 1)[-1])
    env.filters.setdefault("dirname", lambda value: str(value).rsplit("/", 1)[0])
    env.filters.setdefault("regex_escape", lambda value: __import__("re").escape(str(value)))
    return env
