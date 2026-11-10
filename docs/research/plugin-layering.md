# How Claude Code layers plugins

Research for #21 (map #1). Context: [ADR 0001](../adr/0001-layer-on-matt-pocock-skills.md), which says the owner's plugin installs alongside the upstream `mattpocock-skills` plugin instead of forking it.

Researched 2026-11-10 against Claude Code 2.1.322 (`claude --version`) and the docs at code.claude.com. Each fact cites its source. **Unverified** marks anything that no source states outright.

## Short answer

- **Namespacing.** Every plugin skill loads as `/<plugin-name>:<skill-name>`, so a plugin skill never collides with a personal, project, or other plugin's skill. The namespace comes from the `name` in the manifest. The `enabledPlugins` key uses the marketplace entry name instead.
- **Nothing lets one plugin hide another plugin's skill.** A plugin can't ship `skillOverrides` or permission rules, and `skillOverrides` ignores plugin skills anyway. A replacement skill in the owner's plugin therefore runs **next to** the upstream skill. It never runs instead of it.
- **Turning off one skill.** For personal and project skills, set `skillOverrides: { "<name>": "off" }`. For a plugin skill, the only per-skill control is a permission `deny` rule such as `Skill(mattpocock-skills:grilling)`. It blocks invocation but probably doesn't take the skill out of the listing (unverified). `/plugin` only turns whole plugins on or off.
- **Per-project version pinning has no supported control.** strength-app is on 1.2.3 because it has a separate **project-scope install record** in `~/.claude/plugins/installed_plugins.json` that has never been updated. Nothing in strength-app's settings pins it. `claude plugin install` takes no version argument.
- **Dependencies** are declared in `plugin.json` and can carry semver ranges. A dependency on `mattpocock-skills@claude-plugins-official` is cross-marketplace, so the owner's marketplace has to allowlist `claude-plugins-official`. A range would then **fail**, because upstream tags releases `v1.3.1`, not the `mattpocock-skills--v1.3.1` form that ranges resolve against.
- **Private marketplace.** This works: a private GitHub repo with `.claude-plugin/marketplace.json`, added with `claude plugin marketplace add owner/repo`. Access uses the machine's own git credentials (`gh auth setup-git`). Auto-update is off by default for non-official marketplaces.
- **Precedence by bare name** is enterprise > personal (`~/.claude/skills`) > project (`.claude/skills`). Plugin skills always load alongside because of the namespace. That is why `/wayfinder` ran `~/.claude/skills/wayfinder`: the bare name matches the personal skill, while the plugin's copy is `/mattpocock-skills:wayfinder`.

## 1. Skill namespacing

- A plugin skill at `<plugin>/skills/<skill-name>/SKILL.md` loads "wherever the plugin is enabled, as `/plugin-name:skill-name`" ([skills](https://code.claude.com/docs/en/skills), "Where skills live").
- The command name is "Frontmatter `name` or the directory name, namespaced by plugin": `my-plugin/skills/review/SKILL.md` → `/my-plugin:review` ([skills](https://code.claude.com/docs/en/skills)).
- The manifest `name` "is the plugin identifier… Every component is namespaced under it". It can't contain `:` or `@`. It can't start with `claude-`, `anthropic-`, or `cc-plugin-` ([manifest reference](https://code.claude.com/docs/en/plugins-reference)).
- A plugin has two names. The **entry name** in `marketplace.json` is the install and `enabledPlugins` key, and also the name of the cache directory. The **manifest name** sets the skill prefix. Keep them the same ([loading](https://code.claude.com/docs/en/plugins/loading.md), "Entry name and manifest name"; [create a marketplace](https://code.claude.com/docs/en/plugins/create-marketplace.md)).
- Locally, upstream's manifest names itself `mattpocock-skills` and lists 27 skill directories (`~/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.3.1/.claude-plugin/plugin.json`).

## 2. Can one plugin override, hide, or disable another's skill?

The docs describe no mechanism for this. Each place you might expect one is closed:

- **Plugin settings.** A plugin's `settings` key and root `settings.json` take effect only for `agent` and `subagentStatusLine`. "Other keys are dropped at load" ([manifest reference](https://code.claude.com/docs/en/plugins-reference), `settings`). A plugin therefore can't ship `skillOverrides` or `permissions`.
- **`skillOverrides`.** "Plugin skills are not affected by `skillOverrides`. Manage those through `/plugin` instead" ([skills](https://code.claude.com/docs/en/skills)). This matches local evidence: `~/.claude/settings.json` sets `"supabase:supabase-postgres-best-practices": "off"`, yet that skill still appears in this session's skill listing.
- **Name conflicts** apply between *whole plugins* that share a manifest name: managed > `--plugin-dir` > installed marketplace plugin > skills-directory plugin > claude.ai-synced ([loading](https://code.claude.com/docs/en/plugins/loading.md), "Name conflicts"). A plugin can't replace a single skill of another plugin. Naming the owner's plugin `mattpocock-skills` would replace upstream wholesale, which amounts to a fork.
- **Two enabled plugins with the same manifest name from different marketplaces** both show as enabled, but the hooks of only one of them run ([loading](https://code.claude.com/docs/en/plugins/loading.md), "Hooks when two enabled plugins share a name").
- **Dependencies.** Docs on dependencies cover install, enable, and version only. Nothing lets a dependent plugin override a component of its dependency ([dependencies](https://code.claude.com/docs/en/plugins/dependencies.md)).
- **Symlinks.** A plugin can **include** another plugin's skill, but only within the same marketplace. Symlinks to "elsewhere within the same marketplace" are dereferenced. That "lets a meta-plugin's `skills/` directory link to skills defined by other plugins in the marketplace" ([host a marketplace](https://code.claude.com/docs/en/plugins/host-marketplace.md), "Share files within a marketplace with symlinks"). Upstream lives in a different marketplace, so this doesn't help here.

## 3. How a user or project turns off a single skill

| Target | Mechanism | Source |
| :- | :- | :- |
| Personal or project skill | `skillOverrides: { "<name>": "off" \| "user-invocable-only" \| "name-only" \| "on" }` in any settings file | [skills](https://code.claude.com/docs/en/skills), "Override skill visibility from settings" |
| Personal or project skill | `disable-model-invocation: true` in its frontmatter. This "removes the skill from Claude's context entirely" | [skills](https://code.claude.com/docs/en/skills), "Restrict Claude's skill access" |
| Any skill, by name | Permission `deny` rule: `Skill(name)` matches exactly, `Skill(name *)` matches as a prefix, and `Skill(skill:<name>)` "matches the skill under any of its names" | [skills](https://code.claude.com/docs/en/skills); [permissions](https://code.claude.com/docs/en/permissions) |
| Plugin skill | Only whole-plugin enable/disable through `/plugin` or `enabledPlugins`. No per-skill toggle is documented | [install](https://code.claude.com/docs/en/plugins/install.md), "Manage installed plugins" |
| Bundled skills | `disableBundledSkills` | [skills](https://code.claude.com/docs/en/skills) |

**Unverified:** that `deny: ["Skill(mattpocock-skills:grilling)"]` blocks that plugin skill. The docs' table of deny rules covers synced plugin skills (`Skill(anthropic-skills:deploy)`) but makes no general statement about marketplace plugin skills. Also unverified: whether a deny rule hides the skill from the listing Claude sees, or only refuses the call.

Local evidence: `~/.claude/settings.json` sets `"research": "off"` and `"prototype": "off"`. Both target the stale personal copies in `~/.claude/skills/`, and this session lists only `mattpocock-skills:research` and `mattpocock-skills:prototype`. `wayfinder` has no override, and its personal copy has `disable-model-invocation: true` (`~/.claude/skills/wayfinder/SKILL.md`). It therefore still answers `/wayfinder` but stays hidden from Claude.

## 4. Version pinning per project (the strength-app case)

What the files on disk show:

- `~/Claude-Projects/strength-app/.claude/settings.json` contains only `"enabledPlugins": { "mattpocock-skills@claude-plugins-official": true }`. It has **no version field**.
- `~/.claude/plugins/installed_plugins.json` holds **two install records** for `mattpocock-skills@claude-plugins-official`:
  - `scope: "project"`, `projectPath: ".../strength-app"`, `version: "1.2.3"`, `installPath: .../cache/claude-plugins-official/mattpocock-skills/1.2.3`, `installedAt` = `lastUpdated` = 2026-09-06
  - `scope: "user"`, `version: "1.3.1"`, `lastUpdated` 2026-10-23
- `claude plugin list` run in strength-app shows both, each `✔ enabled`: `1.2.3 / Scope: project` and `1.3.1 / Scope: user`.

So the "pin" is a by-product: a project-scope install that was never updated, while the user-scope install was. What the docs say:

- `installed_plugins.json` "records each install with its `scope`, `installPath`, and `version`", and the cache keeps one directory per version at `cache/<marketplace>/<plugin>/<version>/` ([loading](https://code.claude.com/docs/en/plugins/loading.md), "Find plugins on disk").
- `claude plugin update` "changes one scope's block per run". With `--scope` omitted, it updates "the most specific scope it's installed at for your current project, checking local, project, user, then managed" ([CLI reference](https://code.claude.com/docs/en/plugins/cli-reference.md), "Which scope the command updates").
- `claude plugin install` takes `--scope`, `--config`, `--yes`, `--accept-command`, `--json` and `--marketplace`. It has **no version argument** ([CLI reference](https://code.claude.com/docs/en/plugins/cli-reference.md), "plugin install").
- The only documented ways to hold users on a version are on the **marketplace side**: `ref`/`sha` on the entry, `#<ref>` on `marketplace add`, a pinned `version` field, or `<plugin>--v<version>` tags for dependency ranges ([host a marketplace](https://code.claude.com/docs/en/plugins/host-marketplace.md), "Hold users on one version"). The official marketplace's entry for upstream pins `"sha": "49dd158…"`, which is 1.3.1, even though upstream already has a `v1.3.2` tag (`~/.claude/plugins/marketplaces/claude-plugins-official/.claude-plugin/marketplace.json`; `gh api repos/mattpocock/skills/tags`).

**Unverified:**
1. Which copy loads in strength-app when a user-scope and a project-scope install of the same id are both enabled at different versions. No doc page I read covers this case.
2. Whether background auto-update touches project-scope installs. The unchanged `lastUpdated` on the project record suggests it does not.

## 5. Dependencies between plugins

All facts in this section come from [dependencies](https://code.claude.com/docs/en/plugins/dependencies.md) unless another source is named.

- Dependencies are declared in `plugin.json` under `dependencies`. Each entry is `"name"`, `"name@marketplace"`, or `{ "name", "marketplace", "version" }`. A version is a node-semver range such as `~2.1.0`.
- **Cross-marketplace dependencies are blocked by default.** The root marketplace (the one hosting the plugin being installed) must list the target in `allowCrossMarketplaceDependenciesOn`. If the dependency is declared in `plugin.json` and isn't allowlisted, "the install completes without the dependency and your plugin then fails to load". This check is skipped when the user already has the dependency installed and enabled at the same scope.
- **Ranges resolve against git tags named `<plugin-name>--v<version>`.** For a plugin with its own repository, a range with no matching tag means the install "fails with… `has no git tag satisfying`". Upstream's tags are `v1.3.2`, `v1.3.1` … `mattpocock-skills@1.0.0` (`gh api repos/mattpocock/skills/tags`), and the official marketplace sources upstream as `"source": "url"` from its own repo. **A range on upstream would therefore fail. Only an unversioned dependency would work.**
- When dependents' ranges conflict, the install fails. `=2.1.0` holds the dependency in place and makes auto-update skip it.
- Installing a plugin installs and enables its dependencies at the same scope. A dependency can't be disabled while a dependent still needs it, and uninstall leaves auto-installed dependencies until `claude plugin prune` runs ([install](https://code.claude.com/docs/en/plugins/install.md), "Plugins with dependencies").
- A plugin whose `dependencies` lists other plugins works as a **bundle**: installing it installs the whole set.

## 6. A private marketplace for the owner's plugin

- A marketplace is a repo with `.claude-plugin/marketplace.json` containing `name`, `owner`, and `plugins[]` (each with a `name` and a `source`). Check it with `claude plugin validate .`. The names `inline`, `skills-dir`, `synced` and the official marketplace names are reserved ([create a marketplace](https://code.claude.com/docs/en/plugins/create-marketplace.md); [loading](https://code.claude.com/docs/en/plugins/loading.md)).
- **Private GitHub repos work.** Claude Code clones with the machine's existing git credentials and never prompts. For HTTPS, run `gh auth login` and then `gh auth setup-git`. A `GITHUB_TOKEN` environment variable alone does not authenticate the background check ([host a marketplace](https://code.claude.com/docs/en/plugins/host-marketplace.md), "Grant access to a private marketplace", "What background auto-update does with credentials").
- **Auto-update is off by default** for non-official marketplaces. Turn it on per marketplace under `/plugin` → Marketplaces, or set `autoUpdate` on an `extraKnownMarketplaces` entry. Without it, users get changes only when they run `claude plugin update` ([install](https://code.claude.com/docs/en/plugins/install.md), "Keep plugins updated"; [loading](https://code.claude.com/docs/en/plugins/loading.md), "Which marketplaces and plugins auto-update").
- **Versioning.** Either bump `version` on every release or omit it so the commit SHA becomes the version. Users stay on a pinned `version` until it changes ([host a marketplace](https://code.claude.com/docs/en/plugins/host-marketplace.md), "Release a new version").
- **Per-repo registration.** Run `claude plugin marketplace add owner/repo --scope project` and commit `.claude/settings.json` (`extraKnownMarketplaces`). Each collaborator still runs `claude plugin install <name>@<mkt> --scope project` ([host a marketplace](https://code.claude.com/docs/en/plugins/host-marketplace.md); [install](https://code.claude.com/docs/en/plugins/install.md), "Choose an install scope").
- **Dev loop.** Add the marketplace from a local path. Relative-path plugins then load in place, and edits apply on `/reload-plugins` with no version bump ([loading](https://code.claude.com/docs/en/plugins/loading.md), "In-place and copied plugins").
- **Alternative without a marketplace.** A plugin directory with `.claude-plugin/plugin.json` saved under `~/.claude/skills/` loads as `<name>@skills-dir` ([loading](https://code.claude.com/docs/en/plugins/loading.md), "Find where a plugin came from").

## 7. Precedence between plugin skills, `~/.claude/skills`, and project `.claude/skills`

From [skills](https://code.claude.com/docs/en/skills), "Resolve skills that share a name":

| Same name in | Which one runs |
| :- | :- |
| Two of enterprise, personal, project | Enterprise over personal, personal over project |
| A skill and a `.claude/commands/` file | The skill |
| Project-root skill and nested skill | Both load (nested one as `/<dir>:name`) |
| A plugin skill and a skill at any location above | **Both load**, because plugin skills are namespaced as `/plugin-name:skill-name` |

This explains the observation: `/wayfinder` is a bare name, so it resolves to `~/.claude/skills/wayfinder`, and the plugin's copy stays available as `/mattpocock-skills:wayfinder`. The stale personal copies that ADR 0001 warns about (`~/.claude/skills/{grilling,domain-modeling,research,prototype,wayfinder,grill-with-docs,ask-matt}`) cause the wrong version to load only when someone types the bare name. Claude's own Skill-tool calls can choose either copy unless the personal one is turned off in `skillOverrides` or has `disable-model-invocation`.

**Unverified:** whether `/grilling` typed as a bare name resolves to a plugin skill when no personal or project skill has that name. This session's listing shows plugin skills only in qualified form, so don't rely on bare names reaching plugin skills.

## What this means for ADR 0001

- **Consistent with the ADR:** "each replacement takes its own name, so it never collides". Namespacing guarantees there is no technical collision even when names match.
- **Challenge:** "replace an individual upstream skill" can't actually remove the upstream skill. Both stay listed and invocable by Claude, and the owner's plugin can't hide the upstream one. Getting real replacement takes one of these:
  - (a) a `deny` rule per replaced skill in user or project settings (unverified that it works for plugin skills);
  - (b) disabling upstream entirely and vendoring the skills the owner keeps, which is a partial fork;
  - (c) descriptions written so the owner's skill wins model selection.
- **Challenge:** the plugin can't pin upstream with a dependency range, because upstream's tag format doesn't match. Upstream versions are effectively set by whatever sha `claude-plugins-official` pins, with auto-update on. The retro step that checks each upstream release can't hold the line through a dependency range.
- **Risk:** project-scope installs freeze silently (strength-app is still on 1.2.3). It is unclear which copy wins when user and project scopes both enable the plugin.

## Suggested new tickets

1. **Verify `Skill(plugin:skill)` deny rules.** Check whether `deny: ["Skill(mattpocock-skills:grilling)"]` blocks the skill, and whether it also removes it from Claude's listing. This decides how "replace" works under ADR 0001.
2. **Find which copy loads with both user and project installs.** strength-app has 1.2.3 at project scope and 1.3.1 at user scope. Decide whether project-scope pins are a feature the workflow keeps or a bug to clean up.
3. **Ask upstream for `mattpocock-skills--vX.Y.Z` tags**, or accept an unversioned dependency on upstream.
4. **Clean up stale personal copies in `~/.claude/skills`** that shadow bare-name invocations: wayfinder, grilling, domain-modeling, grill-with-docs, ask-matt.
