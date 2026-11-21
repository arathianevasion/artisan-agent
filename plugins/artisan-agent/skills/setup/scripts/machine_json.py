#!/usr/bin/env python3
"""JSON edits for machine-setup.sh. Only touches files under the given config dir.

  machine_json.py autoupdate CFG   set marketplace auto-update (prints changes)
  machine_json.py installs CFG     list project/local-scope installs (TSV)
  machine_json.py overrides CFG N  list hiding skillOverrides keys among names N...
  machine_json.py drop-override CFG NAME
  machine_json.py enabled-value FILE PID    print enabledPlugins.PID as JSON from a settings file (nothing if absent)
  machine_json.py restore-enabled FILE PID VALUE_JSON
      add enabledPlugins.PID back when it is missing; never changes a key that is there
"""
import json
import os
import re
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
        json.dump(data, f, indent=2, ensure_ascii=False)
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
                print("\x1f".join([pid, r["scope"], r.get("projectPath", ""), str(r.get("version", "unknown"))]))


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
        print("dropped skillOverrides entry: " + name)
    else:
        print("skipped: no skillOverrides entry " + name)


def enabled_value(path, pid):
    data = load(path)
    plugins = data.get("enabledPlugins") if isinstance(data, dict) else None
    if isinstance(plugins, dict) and pid in plugins:
        print(json.dumps(plugins[pid]))


def restore_enabled(path, pid, value_json):
    """Add enabledPlugins.pid back by inserting text, so every other byte stays as it is.
    Falls back to a full rewrite only when the text edit would not give the expected JSON."""
    data = load(path)
    if not isinstance(data, dict):
        return
    plugins = data.get("enabledPlugins")
    if isinstance(plugins, dict) and pid in plugins:
        return
    with open(path) as f:
        text = f.read()
    want = json.loads(json.dumps(data))
    want.setdefault("enabledPlugins", {})
    if not isinstance(want["enabledPlugins"], dict):
        return
    want["enabledPlugins"][pid] = json.loads(value_json)
    entry = "%s: %s" % (json.dumps(pid), value_json)
    new_text = None
    m = re.search(r'"enabledPlugins"\s*:\s*\{', text)
    if m:
        line_start = text.rfind("\n", 0, m.start()) + 1
        indent = re.match(r"[ \t]*", text[line_start:]).group(0)
        unit = indent if indent else "  "
        rest = text[m.end():]
        if re.match(r"\s*\}", rest):
            tail = re.match(r"\s*", rest).end()
            new_text = text[:m.end()] + "\n" + indent + unit + entry + "\n" + indent + rest[tail:]
        else:
            new_text = text[:m.end()] + "\n" + indent + unit + entry + "," + rest
    if new_text is not None:
        try:
            ok = json.loads(new_text) == want
        except ValueError:
            ok = False
        if ok:
            tmp = path + ".machine-setup.tmp"
            with open(tmp, "w") as f:
                f.write(new_text)
            os.replace(tmp, path)
            print("restored")
            return
    save(path, want)
    print("restored")


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
    elif cmd == "enabled-value":
        enabled_value(cfg, rest[0])
    elif cmd == "restore-enabled":
        restore_enabled(cfg, rest[0], rest[1])
    else:
        sys.exit("unknown command: " + cmd)
