#!/usr/bin/env python3
"""Read JSON so the shell does not have to.

Two jobs, both deliberately dumb: this file looks things up and reports what it
found. Every judgement about whether a version is acceptable belongs to
scripts/ci/support-window-decision.sh, which is a pure function with a
self-test. Nothing here decides anything.

  --manifest <package.json>
      prints `name<TAB>version` for each DIRECT dependency.

  --lifetime <product.json> --cycle <cycle> --today <YYYY-MM-DD>
      prints `eol<TAB>support<TAB>best_cycle<TAB>best_eol` for one release line.

The upstream booleans are passed through as the literal strings `true` and
`false` rather than being interpreted here, because they do not mean what they
look like -- `eol: false` is "no end-of-life date has been announced", not "this
version never ends -- and the rule that knows that is the one that must see them
unmodified.
"""

import argparse
import json
import sys


def raw(value):
    """Render an upstream field for the shell without deciding what it means."""
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return ""
    return str(value)


def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        # An unreadable manifest or a truncated download prints nothing, and the
        # caller turns "nothing" into an undecided verdict. Guessing at the
        # contents of a file we could not parse is the one option that could
        # produce a false clean.
        return None


def manifest(path):
    data = load(path)
    if not isinstance(data, dict):
        return
    for field in ("dependencies", "devDependencies", "peerDependencies"):
        for name, version in (data.get(field) or {}).items():
            if isinstance(version, str):
                print("%s\t%s" % (name, version))
    engines = data.get("engines") or {}
    if isinstance(engines, dict) and isinstance(engines.get("node"), str):
        print("node\t%s" % engines["node"])


def is_past(value, today):
    """A date already gone. `true`/`false`/absent are not dates and are not past."""
    return isinstance(value, str) and value <= today


def is_future(value, today):
    return isinstance(value, str) and value > today


def best_line(cycles, today):
    """The release line a new project should choose today.

    Not "the newest": the newest is routinely a line that has shipped but has
    not yet become LTS -- Node 26 on 2026-08-16, whose LTS date was still two
    months away. Recommending it would be recommending something no team should
    put in production yet.

    So: among the lines that have ALREADY become LTS and are still in active
    support, take the one with the furthest end of life. Products that publish
    no LTS dates at all (React, and most frameworks) fall back to the same
    question without the LTS clause.
    """
    def supported(entry):
        support = entry.get("support")
        return support is True or is_future(support, today)

    def eol_key(entry):
        eol = entry.get("eol")
        return eol if isinstance(eol, str) else ""

    lts_ready = [c for c in cycles if is_past(c.get("lts"), today) and supported(c)]
    pool = lts_ready or [c for c in cycles if supported(c)]
    if not pool:
        return "", ""
    winner = max(pool, key=eol_key)
    return str(winner.get("cycle", "")), raw(winner.get("eol"))


def lifetime(path, cycle, today):
    data = load(path)
    if not isinstance(data, list):
        print("\t\t\t")
        return
    match = next((c for c in data if str(c.get("cycle")) == str(cycle)), None)
    best_cycle, best_eol = best_line(data, today)
    if match is None:
        # The product is known, this release line is not -- someone is on a
        # version upstream never shipped, or on one so old it has been dropped
        # from the feed. Undecided, and the alternative is still worth printing.
        print("\t\t%s\t%s" % (best_cycle, best_eol))
        return
    print("%s\t%s\t%s\t%s" % (raw(match.get("eol")), raw(match.get("support")),
                              best_cycle, best_eol))


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--manifest")
    parser.add_argument("--lifetime")
    parser.add_argument("--cycle")
    parser.add_argument("--today")
    args = parser.parse_args()

    if args.manifest:
        manifest(args.manifest)
    elif args.lifetime:
        if not args.cycle or not args.today:
            parser.error("--lifetime requires --cycle and --today")
        lifetime(args.lifetime, args.cycle, args.today)
    else:
        parser.error("one of --manifest or --lifetime is required")
    return 0


if __name__ == "__main__":
    sys.exit(main())
