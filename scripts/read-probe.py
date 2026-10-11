#!/usr/bin/env python3
"""Read ForeverProbe's SavedVariables file and print what the last session measured.

Usage:
  scripts/read-probe.py                 summary + last 40 log lines
  scripts/read-probe.py -n 200          more log lines
  scripts/read-probe.py --src HP        only one source (FP, SV, HP, EV, LUA)
  scripts/read-probe.py --grep range    only lines containing a string
  scripts/read-probe.py --all           everything, no summary trimming
  scripts/read-probe.py --port          per-addon porting report (errors by kind,
                                        forbidden actions, nil-global reads, load state)
  scripts/read-probe.py --json          dump the whole DB as JSON
  scripts/read-probe.py --file PATH     a specific SavedVariables file

The client writes the file on logout and on /reload. Run with python3 -I.
"""
import argparse
import datetime as dt
import glob
import json
import os
import sys

DEFAULT_GLOB = "/Applications/World of Warcraft/_classic_beta_/WTF/Account/*/SavedVariables/ForeverProbe.lua"
CHAR_GLOB = "/Applications/World of Warcraft/_classic_beta_/WTF/Account/*/*/*/SavedVariables/ForeverProbe.lua"


class LuaParser:
    """Parses the restricted Lua that WoW writes for SavedVariables."""

    def __init__(self, text):
        self.s = text
        self.i = 0
        self.n = len(text)

    def error(self, msg):
        line = self.s.count("\n", 0, self.i) + 1
        raise SyntaxError(f"{msg} at line {line}")

    def skip(self):
        while self.i < self.n:
            c = self.s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif self.s.startswith("--", self.i):
                j = self.s.find("\n", self.i)
                self.i = self.n if j < 0 else j + 1
            else:
                break

    def peek(self):
        self.skip()
        return self.s[self.i] if self.i < self.n else ""

    def expect(self, ch):
        if self.peek() != ch:
            self.error(f"expected {ch!r}, got {self.s[self.i:self.i+10]!r}")
        self.i += 1

    def ident(self):
        self.skip()
        j = self.i
        while j < self.n and (self.s[j].isalnum() or self.s[j] == "_"):
            j += 1
        if j == self.i:
            self.error("expected identifier")
        name = self.s[self.i:j]
        self.i = j
        return name

    def file(self):
        out = {}
        while True:
            self.skip()
            if self.i >= self.n:
                return out
            name = self.ident()
            self.expect("=")
            out[name] = self.value()

    def value(self):
        c = self.peek()
        if c == "{":
            return self.table()
        if c == '"':
            return self.string()
        if self.s.startswith("true", self.i):
            self.i += 4
            return True
        if self.s.startswith("false", self.i):
            self.i += 5
            return False
        if self.s.startswith("nil", self.i):
            self.i += 3
            return None
        return self.number()

    def number(self):
        j = self.i
        while j < self.n and self.s[j] in "+-0123456789.eExXabcdefABCDEF":
            j += 1
        tok = self.s[self.i:j]
        if not tok:
            self.error("expected value")
        self.i = j
        try:
            if tok.lower().startswith(("0x", "-0x")):
                return int(tok, 16)
            if any(ch in tok for ch in ".eE") and not tok.lower().startswith("0x"):
                return float(tok)
            return int(tok)
        except ValueError:
            try:
                return float(tok)
            except ValueError:
                self.error(f"bad number {tok!r}")

    def string(self):
        self.expect('"')
        out = []
        while self.i < self.n:
            c = self.s[self.i]
            if c == '"':
                self.i += 1
                return "".join(out)
            if c == "\\":
                self.i += 1
                e = self.s[self.i]
                if e.isdigit():
                    j = self.i
                    while j < self.n and j < self.i + 3 and self.s[j].isdigit():
                        j += 1
                    out.append(chr(int(self.s[self.i:j])))
                    self.i = j
                    continue
                out.append({"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "\n": "\n"}.get(e, e))
                self.i += 1
                continue
            out.append(c)
            self.i += 1
        self.error("unterminated string")

    def table(self):
        self.expect("{")
        d = {}
        arr = []
        is_array = True
        auto = 1
        while True:
            c = self.peek()
            if c == "}":
                self.i += 1
                break
            if c == "[":
                self.i += 1
                key = self.value()
                self.expect("]")
                self.expect("=")
                val = self.value()
                d[key] = val
                if not (isinstance(key, int) and key == auto):
                    is_array = False
                else:
                    arr.append(val)
                    auto += 1
            elif c.isalpha() or c == "_":
                save = self.i
                name = self.ident()
                if self.peek() == "=":
                    self.i += 1
                    d[name] = self.value()
                    is_array = False
                else:
                    self.i = save
                    val = self.value()
                    d[auto] = val
                    arr.append(val)
                    auto += 1
            else:
                val = self.value()
                d[auto] = val
                arr.append(val)
                auto += 1
            c = self.peek()
            if c in ",;":
                self.i += 1
        if is_array and len(arr) == len(d):
            return arr
        return d


def load(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return LuaParser(f.read()).file()


def ts(v):
    if isinstance(v, (int, float)) and v > 0:
        return dt.datetime.fromtimestamp(v).strftime("%Y-%m-%d %H:%M:%S")
    return "never"


def section(title):
    print()
    print(f"== {title}")


def summary(db, char_dbs, args):
    section("SavedVariables")
    print(f"sessions written: {db.get('sessions')}   first seen {ts(db.get('firstSeen'))}   last seen {ts(db.get('lastSeen'))}   last logout {ts(db.get('lastLogout'))}")
    if db.get("seeded"):
        print(f"seed still present (seeded {db.get('seededAt')}): the game has not yet loaded and rewritten this file after a seen seed")
    if db.get("seedSeenAt"):
        print(f"seed was seen by the addon at {ts(db.get('seedSeenAt'))}")
    for v in (db.get("verdicts") or [])[-5:]:
        print(f"  [{ts(v.get('at'))}] build {v.get('build')}: {v.get('text')}")
        if v.get("char"):
            print(f"      {v.get('char')}")
    hist = db.get("history") or []
    if hist:
        print("recent sessions:")
        for h in hist[-6:]:
            kind = "reload" if h.get("reload") else "login"
            print(f"  #{h.get('session')} {kind:6s} {ts(h.get('started'))} -> {ts(h.get('ended'))}")
    for path, cdb in char_dbs:
        print(f"per-character file {os.path.relpath(path, os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(path)))))}: sessions={cdb.get('sessions')} seeded={cdb.get('seeded')} lastSeen {ts(cdb.get('lastSeen'))}")

    rep = db.get("report") or {}
    b = rep.get("build")
    if b:
        section("build")
        keys = ["version", "build", "date", "interface", "buildType", "projectId", "projectMainline", "projectClassic",
                "isMainline", "classicExpansionLevel", "hasIsSecretValue", "hasSecretRestrictions", "locale", "isMacClient",
                "scriptErrorsCVar", "realm", "player", "class", "level", "luaVersion", "loadstringUntainted", "probeVersion"]
        for k in keys:
            if k in b:
                print(f"  {k:24s} {b[k]}")
        addons = b.get("addons") or []
        loaded = [a["name"] for a in addons if a.get("loaded")]
        notloaded = [f"{a['name']}({a.get('reason')})" for a in addons if not a.get("loaded")]
        print(f"  addons loaded: {', '.join(loaded) or 'none'}")
        if notloaded:
            print(f"  addons not loaded: {', '.join(notloaded)}")

    api = rep.get("api")
    if api:
        section("API presence")
        print(f"  present {len(api.get('present', []))}, missing {len(api.get('missing', []))}")
        for m in api.get("missing", []):
            print(f"  missing: {m}")
        for s in api.get("surprises", []):
            print(f"  SURPRISE: {s}")
        if args.all:
            for p in api.get("present", []):
                print(f"  present: {p}")

    ev = rep.get("events")
    if ev:
        section("events")
        print(f"  registrable {len(ev.get('present', []))}")
        for m in ev.get("missing", []):
            print(f"  unknown: {m}")
        for m in ev.get("forbidden", []):
            print(f"  FORBIDDEN (raises the Blizzard-UI popup): {m}")

    sec = rep.get("secrets")
    if sec:
        section("secret-value snapshots")
        for reason in ["login", "combatStart", "combatEnd", "manual"]:
            s = sec.get(reason)
            if not s:
                continue
            print(f"  {reason} at {ts(s.get('at'))} combat={s.get('combat')}: aurasSecret={s.get('shouldAurasBeSecret')} restrictions={s.get('hasSecretRestrictions')} auraRead={s.get('auraRead')} auraTableSecret={s.get('auraTableSecret')}")
            print(f"      targetHealthMaxSecret={s.get('targetHealthMaxSecret')} playerPowerSecret={s.get('playerPowerSecret')} targetThreatStateSecret={s.get('targetThreatStateSecret')}")
            for unit, u in (s.get("units") or {}).items():
                print(f"      {unit:7s} " + "  ".join(f"{k}={v}" for k, v in u.items()))

    errs = db.get("errors") or {}
    order = db.get("errorOrder") or []
    section(f"Lua errors ({len(order)} unique)")
    for key in order[-(args.lines if args.all else 15):]:
        e = errs.get(key) or {}
        print(f"  x{e.get('count')} [{ts(e.get('first'))}] {e.get('msg')}")
        if args.all and e.get("stack"):
            for line in str(e["stack"]).splitlines()[:8]:
                print(f"        {line}")


def port_report(db):
    """Per-addon porting report, built from the errors, actions and tracer data in the DB."""
    rep = db.get("report") or {}
    addons = {}

    def bucket(name):
        name = name or "unknown"
        return addons.setdefault(name, {"errors": [], "actions": {}, "nil": None, "loaded": None, "reason": None})

    for a in (rep.get("build") or {}).get("addons") or []:
        b = bucket(a.get("name"))
        b["loaded"] = a.get("loaded")
        b["reason"] = a.get("reason")
    errs = db.get("errors") or {}
    for key in db.get("errorOrder") or []:
        e = errs.get(key)
        if e:
            bucket(e.get("addon")).get("errors").append(e)
    for who, acts in (rep.get("actions") or {}).items():
        bucket(who)["actions"] = acts
    for who, ng in (rep.get("nilGlobals") or {}).items():
        bucket(who)["nil"] = ng

    section(f"porting report ({len(addons)} addons seen)")
    for name in sorted(addons):
        b = addons[name]
        if name.startswith("Blizzard_"):
            continue
        state = "?" if b["loaded"] is None else ("loaded" if b["loaded"] else f"not loaded ({b['reason']})")
        kinds = {}
        for e in b["errors"]:
            kinds[e.get("kind", "other")] = kinds.get(e.get("kind", "other"), 0) + int(e.get("count") or 1)
        acts = sum(int(v) for v in b["actions"].values())
        nil_count = (b["nil"] or {}).get("count", 0)
        print(f"\n  {name}: {state}; {len(b['errors'])} distinct errors"
              + (f" ({', '.join(f'{k} {v}' for k, v in sorted(kinds.items()))})" if kinds else "")
              + f"; forbidden actions {acts}; nil-global reads {nil_count}")
        for e in b["errors"]:
            kind = e.get("kind", "other")
            detail = f" [{e.get('detail')}]" if e.get("detail") else ""
            print(f"      {kind}{detail} x{e.get('count')}: {str(e.get('msg'))[:160]}")
        for what, n in sorted(b["actions"].items()):
            print(f"      forbidden x{n}: {what}")
        names = (b["nil"] or {}).get("names") or {}
        if names:
            top = sorted(names.items(), key=lambda kv: -int(kv[1].get("n", 0)))[:25]
            print("      nil globals read: " + ", ".join(f"{k} x{v.get('n')}" for k, v in top))
            for k, v in top[:5]:
                print(f"        {k}: first at {v.get('at')}")


def show_log(db, args):
    log = db.get("log") or []
    rows = log
    if args.src:
        rows = [r for r in rows if str(r.get("src", "")).upper() == args.src.upper()]
    if args.grep:
        rows = [r for r in rows if args.grep.lower() in str(r.get("msg", "")).lower()]
    if not args.all:
        rows = rows[-args.lines:]
    section(f"log ({len(rows)} of {len(log)} lines)")
    for r in rows:
        combat = " (combat)" if r.get("c") else ""
        print(f"  {ts(r.get('st'))} {str(r.get('t', '')):>9} [{r.get('src')}:{r.get('lvl')}]{combat} {r.get('msg')}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file")
    ap.add_argument("-n", "--lines", type=int, default=40)
    ap.add_argument("--src")
    ap.add_argument("--grep")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--port", action="store_true")
    args = ap.parse_args()

    files = [args.file] if args.file else sorted(glob.glob(DEFAULT_GLOB))
    if not files:
        sys.exit(f"no SavedVariables file found at {DEFAULT_GLOB}; log out of the game once with ForeverProbe enabled")
    path = files[-1]
    data = load(path)
    db = data.get("ForeverProbeDB")
    if db is None:
        sys.exit(f"{path} has no ForeverProbeDB table (keys: {list(data)})")
    char_dbs = []
    if not args.file:
        for cp in sorted(glob.glob(CHAR_GLOB)):
            try:
                cdb = load(cp).get("ForeverProbeCharDB")
                if cdb is not None:
                    char_dbs.append((cp, cdb))
            except SyntaxError as e:
                print(f"warning: could not parse {cp}: {e}")

    if args.json:
        json.dump({"file": path, "ForeverProbeDB": db, "chars": [{"file": p, "db": d} for p, d in char_dbs]}, sys.stdout, indent=1, default=str)
        print()
        return
    print(f"file: {path}")
    print(f"written: {ts(os.path.getmtime(path))}   size {os.path.getsize(path)} bytes")
    if args.port:
        port_report(db)
        return
    summary(db, char_dbs, args)
    show_log(db, args)


if __name__ == "__main__":
    main()
