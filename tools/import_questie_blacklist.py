#!/usr/bin/env python3
"""Import Questie's quest blacklist for WoW Forever into OldmanJava/NotInGame.lua.

Reads Questie's Database/Corrections/QuestieQuestBlacklist.lua as text; it never executes it.
Each entry's value is evaluated the way Questie evaluates it on a Forever client
(Era content rules, not Season of Discovery, not Titan-forged, not the China region).
Any expression this script does not understand stops the import, so nothing is silently guessed.

Usage:
    python3 tools/import_questie_blacklist.py <Questie checkout or QuestieQuestBlacklist.lua>
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT = os.path.join(ROOT, "OldmanJava", "NotInGame.lua")

# Questie's values on a Forever client.
ENV = {
    "Expansions.Current": 1,   # Forever uses Era content (Questie Modules/Expansions.lua)
    "Expansions.Era": 1,
    "Expansions.Tbc": 2,
    "Expansions.Wotlk": 3,
    "Expansions.Cata": 4,
    "Expansions.MoP": 5,
    "HIDE_ON_MAP": "HIDE_ON_MAP",  # truthy: Questie's IsDoable rejects these too
    "Questie.IsSoD": False,
    "Questie.IsTitanReforged": False,
    "Questie.IsChinaRegion": False,
    "ContentPhases.activePhases.TBC": 0,  # only read when Current == Tbc, which is false here
    "true": True,
    "false": False,
}

TOKEN = re.compile(r"\s*(>=|<=|~=|==|<|>|\(|\)|\band\b|\bor\b|\bnot\b|\d+|[A-Za-z_][A-Za-z_0-9.]*)")


def tokenize(expr):
    tokens, pos = [], 0
    while pos < len(expr):
        m = TOKEN.match(expr, pos)
        if not m:
            raise ValueError("cannot read %r at %r" % (expr, expr[pos:]))
        tokens.append(m.group(1))
        pos = m.end()
        while pos < len(expr) and expr[pos].isspace():
            pos += 1
    return tokens


class Parser:
    """Recursive descent over Lua's precedence: or < and < comparison < not < atom."""

    def __init__(self, expr):
        self.expr, self.tokens, self.i = expr, tokenize(expr), 0

    def peek(self):
        return self.tokens[self.i] if self.i < len(self.tokens) else None

    def take(self):
        tok = self.peek()
        self.i += 1
        return tok

    def parse(self):
        value = self.parse_or()
        if self.peek() is not None:
            raise ValueError("unexpected %r in %r" % (self.peek(), self.expr))
        return value

    def parse_or(self):
        value = self.parse_and()
        while self.peek() == "or":
            self.take()
            right = self.parse_and()
            value = value if truthy(value) else right
        return value

    def parse_and(self):
        value = self.parse_cmp()
        while self.peek() == "and":
            self.take()
            right = self.parse_cmp()
            value = right if truthy(value) else value
        return value

    def parse_cmp(self):
        left = self.parse_unary()
        op = self.peek()
        if op in (">=", "<=", "~=", "==", "<", ">"):
            self.take()
            right = self.parse_unary()
            return {
                ">=": left >= right, "<=": left <= right, "<": left < right, ">": left > right,
                "==": left == right, "~=": left != right,
            }[op]
        return left

    def parse_unary(self):
        if self.peek() == "not":
            self.take()
            return not truthy(self.parse_unary())
        return self.parse_atom()

    def parse_atom(self):
        tok = self.take()
        if tok == "(":
            value = self.parse_or()
            if self.take() != ")":
                raise ValueError("missing ) in %r" % self.expr)
            return value
        if tok is not None and tok.isdigit():
            return int(tok)
        if tok in ENV:
            return ENV[tok]
        raise ValueError("unknown name %r in %r" % (tok, self.expr))


def truthy(value):
    return value is not False and value is not None


def find_source(path):
    if os.path.isdir(path):
        path = os.path.join(path, "Database", "Corrections", "QuestieQuestBlacklist.lua")
    if not os.path.isfile(path):
        sys.exit("not found: " + path)
    return path


def questie_version(blacklist_path):
    root = os.path.dirname(os.path.dirname(os.path.dirname(blacklist_path)))
    toc = os.path.join(root, "Questie_Forever.toc")
    if os.path.isfile(toc):
        for line in open(toc, encoding="utf-8"):
            m = re.match(r"## Version:\s*(\S+)", line)
            if m:
                return m.group(1)
    return "unknown"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    source = find_source(sys.argv[1])
    lines = open(source, encoding="utf-8").read().splitlines()

    # The main table runs from "local questsToBlacklist = {" to its closing brace.
    try:
        start = next(i for i, l in enumerate(lines) if re.match(r"\s*local questsToBlacklist = \{\s*$", l))
    except StopIteration:
        sys.exit("QuestieQuestBlacklist.lua changed shape: no 'local questsToBlacklist = {'")
    entry = re.compile(r"^\s*\[(\d+)\]\s*=\s*(.*?)\s*,\s*(--.*)?$")
    hidden, kept, end = [], 0, None
    for i in range(start + 1, len(lines)):
        line = lines[i]
        if re.match(r"^\s*\}\s*$", line):
            end = i
            break
        stripped = line.strip()
        if not stripped or stripped.startswith("--"):
            continue
        m = entry.match(line)
        if not m:
            sys.exit("line %d is not a plain entry, update this importer: %s" % (i + 1, stripped))
        try:
            value = Parser(m.group(2)).parse()
        except ValueError as err:
            sys.exit("line %d: %s" % (i + 1, err))
        if truthy(value):
            hidden.append(int(m.group(1)))
        else:
            kept += 1
    if end is None:
        sys.exit("QuestieQuestBlacklist.lua changed shape: table never closes")

    hidden = sorted(set(hidden))
    version = questie_version(source)
    out = [
        "-- GENERATED by tools/import_questie_blacklist.py. Do not edit; rerun the script instead.",
        "-- Quests that QuestieDB lists but that are not available on WoW Forever (removed, duplicate,",
        "-- never implemented, later-expansion or event-only), as decided by Questie's quest blacklist.",
        "-- Source: Questie %s, Database/Corrections/QuestieQuestBlacklist.lua (GPL-3.0)." % version,
        "-- %d quests hidden on Forever; %d blacklist entries do not apply to Forever." % (len(hidden), kept),
        "local _, SP = ...",
        "",
        "local ids = {",
    ]
    for i in range(0, len(hidden), 16):
        out.append("    " + ", ".join(str(q) for q in hidden[i:i + 16]) + ",")
    out += [
        "}",
        "",
        "local set = {}",
        "for i = 1, #ids do set[ids[i]] = true end",
        "SP.NotInGame = set",
        "",
    ]
    with open(OUTPUT, "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    print("wrote %s: %d quests hidden, %d entries not applicable (Questie %s)"
          % (os.path.relpath(OUTPUT, ROOT), len(hidden), kept, version))


if __name__ == "__main__":
    main()
