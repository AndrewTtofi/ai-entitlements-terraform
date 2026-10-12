"""Check `entitlements/entitlements.yaml` before Terraform sees it.

    python -m tools.validate                       # is the file sound?
    python -m tools.validate --summary             # who gets what, as a Markdown table
    python -m tools.validate --gateway-policy P    # and does it agree with the gateway?

Terraform's own variable validations refuse the same mistakes. This runs first, in
seconds and without providers, and says what is wrong in plain words. It also checks two
things Terraform can't see: the shape of a rule expression, and agreement with the AI
gateway's policy file, which maps these same group names to roles.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any

import yaml
from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator

NAME = re.compile(r"[a-z][a-z0-9-]{1,62}")
SCOPE = re.compile(r"[a-z][a-z0-9_.:-]{1,62}")
LOGIN = re.compile(r"[^@\s]+@[^@\s]+\.[^@\s]+")
REDIRECT = re.compile(r"(https://|http://(localhost|127\.0\.0\.1)(:[0-9]+)?/)\S*")
# A rule is an Okta expression over the user's profile. One that doesn't mention the
# user, or that is trivially true, would put everyone in the group.
ALWAYS_TRUE = re.compile(r"\btrue\b|\b1\s*==\s*1\b", re.IGNORECASE)


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Tier(Strict):
    rank: int = Field(ge=1)
    description: str = Field(min_length=1)
    scopes: list[str] = Field(min_length=1)
    apps: list[str] = []


class App(Strict):
    label: str = Field(min_length=1)
    redirect_uris: list[str] = Field(min_length=1)


class Team(Strict):
    tier: str
    description: str = Field(min_length=1)
    rule: str | None = None
    members: list[str] = []
    privileged: bool = False

    @model_validator(mode="after")
    def _membership(self) -> Team:
        if self.rule is not None and self.members:
            raise ValueError("a team has a rule or a list of members, not both")
        if self.rule is None and not self.members:
            raise ValueError("a team needs a rule or a list of members")
        if self.privileged and self.rule is not None:
            raise ValueError("a privileged team lists its members; it cannot have a rule")
        if self.privileged and len(set(self.members)) < 2:
            raise ValueError("a privileged team needs at least two different named members")
        if self.rule is not None and ("user." not in self.rule or ALWAYS_TRUE.search(self.rule)):
            raise ValueError("a rule must test the user's profile, and must not be always true")
        for login in self.members:
            if not LOGIN.fullmatch(login):
                raise ValueError(f"{login!r} is not a login")
        return self


class Entitlements(Strict):
    tiers: dict[str, Tier]
    apps: dict[str, App]
    teams: dict[str, Team]

    @model_validator(mode="after")
    def _consistent(self) -> Entitlements:
        for kind, names in (("team", self.teams), ("tier", self.tiers), ("app", self.apps)):
            for name in names:
                if not NAME.fullmatch(name):
                    raise ValueError(f"{kind} name {name!r}: lower-case letters, digits, hyphens")
        ranks = [t.rank for t in self.tiers.values()]
        if len(set(ranks)) != len(ranks):
            raise ValueError("each tier needs its own rank")
        for name, tier in self.tiers.items():
            for app in tier.apps:
                if app not in self.apps:
                    raise ValueError(f"tiers.{name}: unknown app {app!r}")
            for scope in tier.scopes:
                if not SCOPE.fullmatch(scope):
                    raise ValueError(f"tiers.{name}: {scope!r} is not a scope name")
        for name, client in self.apps.items():
            for uri in client.redirect_uris:
                if not REDIRECT.fullmatch(uri):
                    raise ValueError(f"apps.{name}: {uri!r} must be https, or http on localhost")
        for name, team in self.teams.items():
            if team.tier not in self.tiers:
                raise ValueError(f"teams.{name}: unknown tier {team.tier!r}")
        return self


def load(path: str | Path) -> Entitlements:
    return Entitlements.model_validate(yaml.safe_load(Path(path).read_text()))


def against_gateway(entitlements: Entitlements, policy: dict[str, Any]) -> list[str]:
    """Disagreements with the AI gateway's policy.yaml, which gives each group a role.

    A group the gateway maps but Okta never creates means nobody can ever have that role.
    A team here that the gateway doesn't map gets a token and then no entitlement."""
    mapped = set(policy.get("group_roles") or {})
    teams = set(entitlements.teams)
    problems = [
        f"the gateway maps group {g!r} to a role, but no team here creates it"
        for g in sorted(mapped - teams)
    ]
    problems += [
        f"team {t!r} is created here, but the gateway maps it to no role"
        for t in sorted(teams - mapped)
    ]
    approvers = set((policy.get("spend_exceptions") or {}).get("approver_groups") or [])
    problems += [
        f"{g!r} approves spend exceptions in the gateway, so it must be privileged here"
        for g in sorted(approvers & teams)
        if not entitlements.teams[g].privileged
    ]
    return problems


def summary(entitlements: Entitlements) -> str:
    lines = ["| Team | Tier | Scopes | Apps | Members come from |", "|---|---|---|---|---|"]
    for name, team in sorted(entitlements.teams.items()):
        tier = entitlements.tiers[team.tier]
        source = f"rule: `{team.rule}`" if team.rule else f"{len(team.members)} named people"
        if team.privileged:
            source += " (privileged)"
        scopes, apps = ", ".join(tier.scopes), ", ".join(tier.apps) or "-"
        lines.append(f"| {name} | {team.tier} | {scopes} | {apps} | {source} |")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--file", default="entitlements/entitlements.yaml")
    parser.add_argument("--summary", action="store_true", help="print who gets what")
    parser.add_argument("--gateway-policy", help="the AI gateway's config/policy.yaml")
    args = parser.parse_args(argv)
    try:
        entitlements = load(args.file)
    except (OSError, yaml.YAMLError) as exc:
        print(f"{args.file}: {exc}", file=sys.stderr)
        return 2
    except ValidationError as exc:
        for error in exc.errors():
            where = ".".join(str(part) for part in error["loc"])
            print(f"{args.file}: {where}: {error['msg']}", file=sys.stderr)
        return 1
    if args.gateway_policy:
        policy = yaml.safe_load(Path(args.gateway_policy).read_text())
        problems = against_gateway(entitlements, policy)
        for problem in problems:
            print(f"{args.gateway_policy}: {problem}", file=sys.stderr)
        if problems:
            return 1
    if args.summary:
        print(summary(entitlements))
    else:
        print(f"{args.file}: ok ({len(entitlements.teams)} teams, {len(entitlements.tiers)} tiers)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
