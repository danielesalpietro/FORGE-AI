"""Nothing that should stay out of Git may be in Git.

This is the test that runs on every pull request and would catch a
committed vault, an ISO, a private key or a password in a template. It
inspects the *tracked file list*, not the working tree, so a file that
is merely git-ignored still passes and a file that slipped past
.gitignore does not.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]


def tracked_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=REPO_ROOT, capture_output=True, text=True, check=True,
    )
    return [REPO_ROOT / name for name in result.stdout.split("\0") if name]


@pytest.fixture(scope="module")
def tracked() -> list[Path]:
    return tracked_files()


@pytest.fixture(scope="module")
def tracked_text(tracked) -> list[tuple[Path, str]]:
    """Tracked files that are readable as text, with their contents."""
    documents = []
    for path in tracked:
        if path.suffix in {".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf"}:
            continue
        try:
            documents.append((path, path.read_text(encoding="utf-8")))
        except (UnicodeDecodeError, OSError):
            continue
    return documents


# ---------------------------------------------------------------------
# File types that must never be committed
# ---------------------------------------------------------------------


FORBIDDEN_SUFFIXES = {
    ".iso": "installation media -- large, and often licensed",
    ".wim": "Windows imaging file -- Microsoft licensed",
    ".esd": "Windows imaging file -- Microsoft licensed",
    ".vhd": "virtual disk",
    ".vhdx": "virtual disk",
    ".qcow2": "virtual disk",
    ".pem": "likely a private key or certificate",
    ".pfx": "private key bundle",
    ".p12": "private key bundle",
    ".jks": "keystore",
}


def test_no_forbidden_binary_or_key_files_are_tracked(tracked):
    offenders = [
        (path.relative_to(REPO_ROOT), FORBIDDEN_SUFFIXES[path.suffix])
        for path in tracked
        if path.suffix in FORBIDDEN_SUFFIXES
    ]
    assert offenders == [], offenders


def test_no_private_key_file_is_tracked(tracked):
    """.key is excluded from the suffix list above because it is also a
    reasonable extension for other things; the name check is narrower."""
    offenders = [
        path.relative_to(REPO_ROOT)
        for path in tracked
        if path.suffix == ".key" or path.name in {"id_rsa", "id_ed25519", "id_ecdsa", ".vault-password"}
    ]
    assert offenders == [], offenders


def test_the_operator_configuration_is_not_tracked(tracked):
    """config/poc.yml may name local paths and is the operator's own."""
    names = {path.relative_to(REPO_ROOT).as_posix() for path in tracked}
    assert "config/poc.yml" not in names
    assert "config/poc.example.yml" in names, "the example must be tracked"


def test_the_environment_file_is_not_tracked(tracked):
    names = {path.relative_to(REPO_ROOT).as_posix() for path in tracked}
    assert "compose/.env" not in names
    assert "compose/.env.example" in names


def test_the_vault_file_if_tracked_is_actually_encrypted(tracked_text):
    """Bug 45 / #33 option A: vault.yml is now meant to be tracked and
    committed, encrypted at rest -- only the vault password that
    decrypts it stays out of the repository (docs/SECURITY.md,
    "Secrets: where each one lives"). This does not require vault.yml
    to exist (a checkout with no real secrets yet is still valid); it
    only guards against the one way this model can fail silently: the
    designated file existing but holding plaintext instead of a real
    Ansible Vault payload.
    """
    candidates = [(p, t) for p, t in tracked_text if p.name == "vault.yml"]
    for path, text in candidates:
        rel = path.relative_to(REPO_ROOT).as_posix()
        assert rel == "ansible/inventories/poc/group_vars/all/vault.yml", (
            f"a vault.yml is tracked outside its designated path: {rel}"
        )
        # Built from fragments, like SECRET_PATTERNS below, so this file
        # does not itself contain the literal marker it checks for.
        vault_header = "$ANSIBLE_" + "VAULT;"
        assert text.lstrip().startswith(vault_header), (
            f"{rel} is tracked but does not look encrypted (no Ansible Vault header)"
        )


def test_group_vars_all_has_no_other_ansible_loadable_file(tracked):
    """Bug 45: Ansible's group_vars loader parses every file in
    group_vars/all/ whose name has no extension or ends in .yml/.yaml/
    .json -- vault.yml included, which is the point once it is the
    real, tracked, encrypted vault (see #33 option A). A tracked file
    that happens to match one of those extensions is loaded right
    alongside it, silently, which is exactly how vault.example.yml
    became a live fallback for the real vault (see
    docs/logbook/07-project-review.md, bug 45). Only main.yml and
    vault.yml -- the two real, intentional vars files -- may have a
    loadable name here; anything else (vault.yml.example included)
    must not.
    """
    loadable_extensions = {"", ".yml", ".yaml", ".json"}
    intentional = {"main.yml", "vault.yml"}
    group_vars_all = REPO_ROOT / "ansible/inventories/poc/group_vars/all"
    offenders = [
        path.relative_to(REPO_ROOT)
        for path in tracked
        if path.parent == group_vars_all
        and path.name not in intentional
        and path.suffix in loadable_extensions
    ]
    assert offenders == [], offenders


def test_the_vault_example_is_tracked_and_holds_only_placeholders(tracked_text):
    examples = [(p, t) for p, t in tracked_text if p.name == "vault.yml.example"]
    assert examples, "vault.yml.example must exist so operators know what to fill in"

    for path, text in examples:
        for line in text.splitlines():
            if not line.strip().startswith("vault_"):
                continue
            _, _, value = line.partition(":")
            value = value.strip().strip('"').strip("'")
            if not value:
                continue
            assert value in {"REPLACE_ME", "$6$REPLACE_ME"} or value.startswith("~/") or value.startswith("/"), (
                f"{path.name}: '{line.strip()}' looks like a real value, not a placeholder"
            )


# ---------------------------------------------------------------------
# Content patterns
# ---------------------------------------------------------------------


# Patterns that indicate a real credential rather than a placeholder or
# a variable reference.
# Each pattern is built from fragments rather than written literally, so
# that this file -- which is itself tracked -- does not contain the very
# markers it searches for. Without that, the scanner flags itself, and
# the usual "fix" is a blanket exclusion that quietly weakens it.
SECRET_PATTERNS = [
    (re.compile("-----BEGIN [A-Z ]*PRIVATE" + " KEY-----"), "an inlined private key"),
    (re.compile(r"\bAK" + r"IA[0-9A-Z]{16}\b"), "an AWS access key id"),
    (re.compile(r"\bgh" + r"[pousr]_[A-Za-z0-9]{36,}"), "a GitHub token"),
    (re.compile(r"\bxo" + r"x[baprs]-[A-Za-z0-9-]{10,}"), "a Slack token"),
    (re.compile(r"\$ANSIBLE_" + r"VAULT;"), "an Ansible Vault payload"),
]


def test_no_tracked_file_contains_an_obvious_credential(tracked_text):
    """The designated vault (#33 option A) is the one intentional
    exception to the Ansible Vault payload pattern -- it is SUPPOSED to
    contain one. test_the_vault_file_if_tracked_is_actually_encrypted
    covers it instead. Every other pattern, and every other file
    (including a vault.yml anywhere else), is still checked."""
    designated_vault = "ansible/inventories/poc/group_vars/all/vault.yml"
    offenders = []
    for path, text in tracked_text:
        relative = path.relative_to(REPO_ROOT).as_posix()
        for pattern, description in SECRET_PATTERNS:
            if relative == designated_vault and description == "an Ansible Vault payload":
                continue
            if pattern.search(text):
                offenders.append((relative, description))
    assert offenders == [], offenders


# Detecting a committed credential is a precision problem, not a recall
# problem: a check that cries wolf gets disabled, and then it protects
# nothing. The rules below were derived by running the naive version
# over this repository and classifying every hit.
#
# The key half deliberately allows an identifier prefix. `\bpassword\b`
# never matches `database_password`, because underscore is a word
# character -- and `<something>_password:` is by far the most common way
# a credential actually gets committed.
ASSIGNMENT = re.compile(
    r"""(?ix)
    (?:^|[^A-Za-z0-9_])
    (?P<key>[A-Za-z0-9_-]*
      (password|passwd|secret|token|api[_-]?key|private[_-]?key|credential|passphrase)
      [A-Za-z0-9_-]*)
    \s*[:=]\s*
    ["']?(?P<value>[^\s"'#,}{\]\[]{8,})["']?
    """
)

# Keys that name WHERE a secret lives, not the secret itself.
KEY_IS_A_REFERENCE = re.compile(
    r"(?i)_(file|path|paths|url|name|names|var|vars|id|dir|env|arg|args|cmd)$"
)

# publicKeyToken is the Microsoft assembly identity in Autounattend.xml.
# It is public by definition and identical in every Windows answer file
# ever written.
KEY_IS_PUBLIC = re.compile(r"(?i)^publickeytoken$")

# A value that is an interpolation, a path, a placeholder or a flag.
VALUE_IS_A_REFERENCE = re.compile(r"""^[$~/?<@%]|^-{1,2}[a-z]""")

# Values that are obviously not live credentials.
SAFE_VALUE = re.compile(
    r"""(?ix)
    ^(
      changeme | change-me | placeholder | replace_me | example |
      true | false | none | null | omit | yes | no | undefined |
      \.\.\. | xxx+ |
      .*REPLACE_ME.* | .*CHANGEME.* | .*FIXTURE.* | .*[Ee]xample.* |
      \$[y6512][a-z]?\$.*                    # crypt(3) hash placeholders
    )$
    """
)

# A credential has entropy. A sentence fragment caught from inside an
# error message does not. Requiring a digit and a letter, with no
# spaces, removes the whole class of `"password is undefined"` hits
# without weakening detection of real secrets, which are generated.
VALUE_LOOKS_GENERATED = re.compile(r"^[A-Za-z0-9+/=_.-]{8,}$")


def _is_credential(key: str, value: str, line: str) -> bool:
    if KEY_IS_A_REFERENCE.search(key) or KEY_IS_PUBLIC.match(key):
        return False
    if any(marker in line for marker in ("${", "$(", "{{", "vault_", "lookup(")):
        return False
    if VALUE_IS_A_REFERENCE.match(value):
        return False
    if SAFE_VALUE.match(value):
        return False
    if not VALUE_LOOKS_GENERATED.match(value):
        return False
    # Needs both a letter and a digit, or to be long and mixed-case:
    # that is what a generated secret looks like and a English word
    # does not.
    has_digit = any(character.isdigit() for character in value)
    has_letter = any(character.isalpha() for character in value)
    mixed_case = value != value.lower() and value != value.upper()
    return (has_digit and has_letter) or (mixed_case and len(value) >= 16)


def test_no_tracked_file_assigns_a_literal_credential(tracked_text):
    """Catches `password: hunter2` in a template, a role default or a
    compose file -- the mistake .gitignore cannot prevent."""
    offenders = []
    for path, text in tracked_text:
        if path.name == "test_secret_hygiene.py":
            continue
        relative = path.relative_to(REPO_ROOT).as_posix()

        for number, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith(("#", "//", "rem ", ";", "*")):
                continue
            for match in ASSIGNMENT.finditer(line):
                if _is_credential(match.group("key"), match.group("value"), line):
                    offenders.append(f"{relative}:{number}: {stripped[:100]}")
                    break

    assert offenders == [], "literal credentials found:\n" + "\n".join(offenders)


# ---------------------------------------------------------------------
# .gitignore must actually cover what it claims to
# ---------------------------------------------------------------------


@pytest.mark.parametrize(
    "path",
    [
        "compose/.env",
        "config/poc.yml",
        ".vault-password",
        "compose/nginx/tls/forge-ai.key",
        "compose/nginx/tls/forge-ai.crt",
        "some-image.iso",
        "sources/install.wim",
        "id_ed25519",
    ],
)
def test_gitignore_covers_the_sensitive_paths(path):
    result = subprocess.run(
        ["git", "check-ignore", "-q", path],
        cwd=REPO_ROOT, capture_output=True,
    )
    assert result.returncode == 0, f"{path} is NOT ignored by .gitignore"


@pytest.mark.parametrize(
    "path",
    [
        "config/poc.example.yml",
        "compose/.env.example",
        "ansible/inventories/poc/group_vars/all/vault.yml.example",
        "ansible/inventories/poc/group_vars/all/vault.yml",
        "ansible/templates/windows/Autounattend.xml.j2",
        "ansible/templates/ubuntu/user-data.j2",
    ],
)
def test_gitignore_does_not_swallow_the_examples_and_templates(path):
    """The .gitignore rules for `**/Autounattend.xml` and `**/user-data`
    must not also exclude the templates that generate them -- and, since
    #33 option A, must not exclude the (encrypted, tracked) vault.yml
    either."""
    result = subprocess.run(
        ["git", "check-ignore", "-q", path],
        cwd=REPO_ROOT, capture_output=True,
    )
    assert result.returncode != 0, f"{path} is wrongly ignored and would not be committed"


def test_generated_secret_files_would_be_created_with_mode_0600():
    """Read the generator rather than the filesystem: the assertion is
    about the code, so it holds on a machine that has never run it."""
    script = (REPO_ROOT / "bootstrap" / "create-secrets.sh").read_text()

    assert "install -m 0600 /dev/null" in script, (
        "secret files must have their mode set before content is written, "
        "otherwise there is a window in which they are world-readable"
    )
    assert 'chmod 0600 "$ENV_FILE"' in script
    assert "forge_write_secret_file" in script


def test_the_common_library_sets_the_mode_before_writing():
    library = (REPO_ROOT / "bootstrap" / "lib" / "common.sh").read_text()

    helper = library.split("forge_write_secret_file()")[1].split("\n}")[0]
    install_index = helper.index("install -m")
    write_index = helper.index("printf")

    assert install_index < write_index, (
        "the mode must be set before the secret is written into the file"
    )
