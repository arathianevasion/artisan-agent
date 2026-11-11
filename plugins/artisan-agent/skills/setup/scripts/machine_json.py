#!/usr/bin/env python3
"""JSON edits for machine-setup.sh. Only touches files under the given config dir.

  machine_json.py autoupdate CFG   set marketplace auto-update (prints changes)
  machine_json.py installs CFG     list project/local-scope installs (TSV)
  machine_json.py overrides CFG N  list hiding skillOverrides keys among names N...
  machine_json.py drop-override CFG NAME
"""
import json
import os
import sys

# name -> (desired autoUpdate, source to declare if no record of the marketplace exists)
MARKETPLACES = [
    ("claude-plugins-official", False, {"source": "github", "repo": "anthropics/claude-plugins-official"}),
    ("artisan-agent", True, {"source": "github", "repo": "arathianevasion/artisan-agent"}),
]
STRAY_PLUGINS = ("artisan-agent@", "mattpocock-skills@")
HIDING = ("off", "user-invocable-only")


def load(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        try:
            return json.load(f)
        except ValueError as e:
            sys.exit("machine-setup: %s is not valid JSON (%s); fix it and rerun" % (path, e))


def save(path, data):
    tmp = path + ".machine-setup.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def autoupdate(cfg):
    settings_path = os.path.join(cfg, "settings.json")
    known_path = os.path.join(cfg, "plugins", "known_marketplaces.json")
    settings = load(settings_path) or {}
    known = load(known_path)
    settings_dirty = known_dirty = False
    ekm = settings.get("extraKnownMarketplaces")
    if ekm is None:
        ekm = {}
    for name, want, default_source in MARKETPLACES:
        entry = ekm.get(name)
        if entry is None:
            src = default_source
            if known and isinstance(known.get(name), dict) and known[name].get("source"):
                src = known[name]["source"]
            entry = {"source": src}
        if entry.get("autoUpdate") is not want:
            entry["autoUpdate"] = want
            ekm[name] = entry
            settings_dirty = True
            print("changed: auto-update %s for %s (settings.json extraKnownMarketplaces)" % ("on" if want else "off", name))
        if known and isinstance(known.get(name), dict) and known[name].get("autoUpdate") is not want:
            known[name]["autoUpdate"] = want
            known_dirty = True
            print("changed: auto-update %s for %s (plugins/known_marketplaces.json)" % ("on" if want else "off", name))
    if settings_dirty:
        settings["extraKnownMarketplaces"] = ekm
        os.makedirs(cfg, exist_ok=True)
        save(settings_path, settings)
    if known_dirty:
        save(known_path, known)
    if not settings_dirty and not known_dirty:
        print("unchanged: auto-update (off for claude-plugins-official, on for artisan-agent)")


def installs(cfg):
    data = load(os.path.join(cfg, "plugins", "installed_plugins.json")) or {}
    for pid, records in sorted((data.get("plugins") or {}).items()):
        if not pid.startswith(STRAY_PLUGINS):
            continue
        for r in records:
            if r.get("scope") in ("project", "local"):
                print("\t".join([pid, r["scope"], r.get("projectPath", ""), str(r.get("version", "unknown"))]))


def overrides(cfg, names):
    settings = load(os.path.join(cfg, "settings.json")) or {}
    for key, value in sorted((settings.get("skillOverrides") or {}).items()):
        if key in names and value in HIDING:
            print("%s\t%s" % (key, value))


def drop_override(cfg, name):
    path = os.path.join(cfg, "settings.json")
    settings = load(path) or {}
    ov = settings.get("skillOverrides") or {}
    if name in ov:
        del ov[name]
        if not ov:
            del settings["skillOverrides"]
        save(path, settings)


if __name__ == "__main__":
    cmd, cfg, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
    if cmd == "autoupdate":
        autoupdate(cfg)
    elif cmd == "installs":
        installs(cfg)
    elif cmd == "overrides":
        overrides(cfg, set(rest))
    elif cmd == "drop-override":
        drop_override(cfg, rest[0])
    else:
        sys.exit("unknown command: " + cmd)
