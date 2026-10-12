"""The data-file validator: what it accepts, what it refuses and why."""

from __future__ import annotations

import copy
from pathlib import Path
from typing import Any

import pytest
import yaml
from pydantic import ValidationError

from tools import validate
from tools.validate import Entitlements, against_gateway, load, summary

SHIPPED = "entitlements/entitlements.yaml"
GOOD: dict[str, Any] = yaml.safe_load(Path(SHIPPED).read_text())


def changed(path: str, value: Any) -> dict[str, Any]:
    """The shipped file with one value replaced: 'teams.everyone.rule' → value."""
    data = copy.deepcopy(GOOD)
    *parents, last = path.split(".")
    node = data
    for key in parents:
        node = node[key]
    if value is None:
        node.pop(last, None)
    else:
        node[last] = value
    return data


def test_the_shipped_file_is_sound() -> None:
    entitlements = load(SHIPPED)
    assert set(entitlements.teams) >= {"everyone", "platform-admin"}
    assert entitlements.teams["platform-admin"].privileged


@pytest.mark.parametrize(
    ("path", "value", "says"),
    [
        ("teams.eng-backend.tier", "gold", "unknown tier"),
        ("tiers.dev.apps", ["ai-cli", "ghost"], "unknown app"),
        ("tiers.dev.rank", 2, "its own rank"),
        ("tiers.dev.scopes", [], "at least 1 item"),
        ("tiers.dev.scopes", ["Gateway Use"], "not a scope name"),
        ("teams.platform-admin.rule", 'user.department == "IT"', "not both"),
        ("teams.platform-admin.members", ["alice.admin@example.com"], "at least two"),
        ("teams.platform-admin.members", ["a@example.com", "a@example.com"], "at least two"),
        ("teams.platform-admin.members", ["alice", "bob"], "is not a login"),
        ("teams.everyone.rule", None, "needs a rule or a list of members"),
        ("teams.everyone.rule", "true", "must test the user's profile"),
        ("teams.everyone.rule", 'user.userType == "Employee" or 1 == 1', "always true"),
        ("teams.everyone.rule", 'department == "X"', "must test the user's profile"),
        ("teams.everyone.surprise", 1, "Extra inputs"),
        ("apps.ai-cli.redirect_uris", ["http://evil.example/cb"], "https, or http on localhost"),
        ("apps.ai-cli.redirect_uris", [], "at least 1 item"),
    ],
)
def test_mistakes_are_refused_with_a_reason(path: str, value: Any, says: str) -> None:
    with pytest.raises(ValidationError, match=says):
        Entitlements.model_validate(changed(path, value))


def test_a_privileged_team_cannot_be_filled_by_a_rule() -> None:
    data = changed("teams.platform-admin.members", None)
    data["teams"]["platform-admin"]["rule"] = 'user.department == "IT"'
    with pytest.raises(ValidationError, match="cannot have a rule"):
        Entitlements.model_validate(data)


def test_names_are_constrained() -> None:
    data = copy.deepcopy(GOOD)
    data["teams"]["Eng Backend"] = data["teams"].pop("eng-backend")
    with pytest.raises(ValidationError, match="lower-case"):
        Entitlements.model_validate(data)


# --- agreement with the gateway's policy -----------------------------------------------

POLICY = {
    "group_roles": {
        "eng-backend": "engineer",
        "eng-platform": "engineer",
        "trading-desk": "trader",
        "compliance": "compliance",
        "everyone": "staff",
        "platform-admin": "platform-admin",
    },
    "spend_exceptions": {"approver_groups": ["platform-admin"]},
}


def test_the_shipped_file_agrees_with_a_matching_gateway_policy() -> None:
    assert against_gateway(load(SHIPPED), POLICY) == []


def test_disagreements_with_the_gateway_are_named() -> None:
    policy = copy.deepcopy(POLICY)
    policy["group_roles"]["quants"] = "trader"  # the gateway knows a group Okta never creates
    del policy["group_roles"]["everyone"]  # and doesn't know one that Okta does
    problems = against_gateway(load(SHIPPED), policy)
    assert problems == [
        "the gateway maps group 'quants' to a role, but no team here creates it",
        "team 'everyone' is created here, but the gateway maps it to no role",
    ]


def test_a_group_that_approves_spend_must_be_privileged() -> None:
    data = changed("teams.platform-admin.privileged", False)
    (problem,) = against_gateway(Entitlements.model_validate(data), POLICY)
    assert "approves spend exceptions" in problem and "must be privileged" in problem


# --- the command line ------------------------------------------------------------------


def test_the_command_line(capsys: pytest.CaptureFixture[str], tmp_path: Path) -> None:
    assert validate.main([]) == 0
    assert "ok (6 teams, 2 tiers)" in capsys.readouterr().out
    assert validate.main(["--summary"]) == 0
    table = capsys.readouterr().out
    assert "| platform-admin | standard |" in table and "2 named people (privileged)" in table
    assert table == summary(load(SHIPPED)) + "\n"

    bad = tmp_path / "bad.yaml"
    bad.write_text(yaml.safe_dump(changed("teams.eng-backend.tier", "gold")))
    assert validate.main(["--file", str(bad)]) == 1
    assert "unknown tier 'gold'" in capsys.readouterr().err
    assert validate.main(["--file", str(tmp_path / "missing.yaml")]) == 2

    policy = tmp_path / "policy.yaml"
    policy.write_text(yaml.safe_dump(POLICY))
    assert validate.main(["--gateway-policy", str(policy)]) == 0
    drifted = {**POLICY, "group_roles": {**POLICY["group_roles"], "quants": "trader"}}
    policy.write_text(yaml.safe_dump(drifted))
    assert validate.main(["--gateway-policy", str(policy)]) == 1
    assert "'quants'" in capsys.readouterr().err
