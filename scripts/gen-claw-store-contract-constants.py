#!/usr/bin/env python3
"""Generate Swift test constants (route IDs, auth kinds, household operations, and
path templates) from the vendored Claw Store contract.

Run after syncing the contract (sync-cross-repo-fixtures.sh calls this), or manually:
    uv run python scripts/gen-claw-store-contract-constants.py

Output is deterministic (sorted) so re-running on an unchanged contract yields no
diff. Path templates are emitted in raw contract form (placeholders preserved) and
are NOT consumed by tests; the drift guard `ClawStoreContractConstantsGuardTests`
fails if the generated file is stale relative to the contract, forcing a regen when
a route / auth / operation / path template changes.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CONTRACT = os.path.join(
    ROOT, "Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/claw-store/v1/contract.json"
)
OUT = os.path.join(
    ROOT, "Packages/SoyehtCore/Tests/SoyehtCoreTests/Generated/ClawStoreContractConstants.generated.swift"
)


def camel(value):
    """Deterministic snake_case / dotted -> lowerCamelCase Swift identifier."""
    parts = [p for p in value.replace(".", "_").split("_") if p]
    return parts[0].lower() + "".join(p[:1].upper() + p[1:] for p in parts[1:])


def section(enum_name, values, doc):
    lines = [f"    /// {doc}", f"    enum {enum_name} {{"]
    for v in values:
        lines.append(f'        static let {camel(v)} = "{v}"')
    refs = ", ".join(f"Self.{camel(v)}" for v in values)
    lines.append(f"        static let all: [String] = [{refs}]")
    lines.append("    }")
    return "\n".join(lines)


def path_section(routes):
    # (id, path_template) sorted by id; ids are unique so each route gets one
    # named constant plus an entry in the id-keyed map the drift guard checks.
    pairs = sorted((r["id"], r["path_template"]) for r in routes)
    lines = [
        "    /// Path templates per route id, in raw contract form with the",
        "    /// {name} / {id} / {container} placeholders preserved. Not consumed by",
        "    /// tests; the drift guard pins `byRouteID` == the vendored contract so a",
        "    /// synced path-template change forces a regen.",
        "    enum PathTemplate {",
    ]
    for rid, tmpl in pairs:
        lines.append(f'        static let {camel(rid)} = "{tmpl}"')
    lines.append("        static let byRouteID: [String: String] = [")
    for rid, _ in pairs:
        lines.append(f'            "{rid}": Self.{camel(rid)},')
    lines.append("        ]")
    lines.append("    }")
    return "\n".join(lines)


def main():
    with open(CONTRACT, encoding="utf-8") as f:
        routes = json.load(f)["routes"]

    ids = sorted({r["id"] for r in routes})
    auths = sorted({r["auth_kind"] for r in routes})
    ops = sorted({r["household_operation"] for r in routes if r.get("household_operation")})

    header = (
        "// GENERATED - do not edit; run scripts/gen-claw-store-contract-constants.py\n"
        "//\n"
        "// Derived from the vendored Claw Store contract:\n"
        "//   Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/claw-store/v1/contract.json\n"
        "// Route IDs, auth kinds, household operations, and path templates. The drift\n"
        "// guard ClawStoreContractConstantsGuardTests fails if this file goes stale.\n"
    )
    body = "\n\n".join([
        section("RouteID", ids, "Claw Store route identifiers (one per contract route)."),
        section("AuthKind", auths, "Distinct auth kinds across the contract routes."),
        section("HouseholdOperation", ops, "Distinct household PoP operations."),
        path_section(routes),
    ])
    content = f"{header}\nenum ClawStoreContractConstants {{\n{body}\n}}\n"

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(content)

    print(
        f"wrote {os.path.relpath(OUT, ROOT)} "
        f"({len(ids)} ids, {len(auths)} auth kinds, {len(ops)} operations, "
        f"{len(routes)} path templates)"
    )


if __name__ == "__main__":
    main()
