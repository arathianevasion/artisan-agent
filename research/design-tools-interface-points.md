# Design tools: taking in prod, handing work back

Research for #288 (child of map #285). Checked 2026-11-19 against vendor docs, help centres and changelogs. These products change monthly. A date after a claim is the date of the source. "Not confirmed" means no primary source turned up this pass. It does not mean the feature is missing.

## Findings

1. **Every tool except Figma Make has an agent-facing MCP server.** Figma's is the deepest: it reads and writes the file, and it can capture live UI into the canvas. Claude Design is reached through Claude Code (`/design`, `/design-sync`, the handoff bundle) and through the artifact URL, not through a standalone MCP. Sketch and Penpot each ship an MCP server whose main tool runs arbitrary scripts against the plugin API.
2. **Starting from a live product is first-party only in Figma and Claude Design.** Figma's `generate_figma_design` captures a running web UI into flat layers. For a live site rather than localhost, Figma says to have the agent inject its script with a tool like Playwright. Claude Design has a web capture tool and also reads the codebase. Sketch and Penpot have no first-party URL import: Penpot depends on community HTML-to-design plugins, and for Sketch none was confirmed. Every tool accepts a screenshot as a reference image.
3. **Only Figma Make and Claude Design produce running code.** Make builds a hosted web app: it publishes to a public URL, can add a Supabase backend and pushes to GitHub one way. Claude Design builds interactive, code-powered prototypes and exports standalone HTML or a handoff bundle for Claude Code. Figma Design, Sketch and Penpot prototypes are click-through interaction graphs, not code.
4. **Versioning is uneven, and real branching exists only in Figma Design.** Figma Design branching needs an Organization or Enterprise plan. Make has version history but no branching, and its GitHub push goes to the default branch only. Claude Design "doesn't have version history yet" in its help article, though artifacts get a version per publish. Sketch keeps a per-save timeline in its Workspace. Penpot has pinned (named) versions.
5. **What a tool-agnostic stage can rely on everywhere:** (a) a screenshot or PNG export, (b) a share or view link to a prototype, and (c) an MCP endpoint, with Make as the one gap: it is reached through the Figma MCP's `send_code_to_figma`, through "Copy design" into Figma Design, or through its GitHub repo. Running code exists only in Make and Claude Design. Live-URL capture exists only in Figma and Claude Design.

## Comparison

| | Figma Design + Dev Mode | Figma Make | Claude Design | Sketch | Penpot |
|---|---|---|---|---|---|
| **Start from a live URL** | Yes: `generate_figma_design` on the remote MCP. Localhost by default; for a live site the agent injects the capture script, for example with Playwright. Output is flat layers, and variables bind if the file's library has matching ones. Third-party: html.to.design plugin (public URLs, plus an extension for logged-in pages) | Not directly. A Figma URL pasted into chat is not read (FAQ). Frames must be pasted or attached | Yes: a "web capture tool that grabs elements from your website" (launch post, 2026-04-17) | Not confirmed. The MCP docs list no HTML or URL import | Not first-party. Community plugins: HTML TO DESIGN, Ultimate HTML to Penpot, HTML2PP (self-hosted) |
| **Start from code / component library** | Code Connect maps Figma components to code components. `html_to_figma` turns a self-contained HTML document into layers. Code layers import from GitHub or a local folder (blog, 2026-10-15) | npm packages (public, and private on paid plans), Make kits, `send_code_to_figma` imports a local project as Make code | Reads a linked repo, or `/design-sync` from Claude Code, to build a design system. Also takes DOCX, PPTX, XLSX and images | `run_code` gives an agent the full SketchAPI. Not confirmed for code import | DTCG token import. The MCP's `execute_code` can write shapes, tokens and components |
| **Screenshots in** | Yes (`upload_assets`, or as images) | Yes (attach) | Yes (upload) | Yes (as images) | Yes (`import_image`, local MCP only) |
| **Prototype type** | Interaction graph (click-through, variables). Not running code | Running React web app (Make in your local codebase article). Publishes to a public URL that can't be access-restricted, hosted on AWS. Optional Supabase backend (key-value store) | Interactive, "code-powered" prototypes (HTML/JS). Shared as a claude.ai artifact | Interaction graph (links, Smart Animate) | Interaction graph (boards connected, View mode) |
| **Generated code out** | `get_design_context` returns reference code (React + Tailwind by default). Dev Mode inspect | The app's own code: export (Full or Dev seat), one-way push to a GitHub repo Make creates (default branch, no GHES) | Handoff bundle to Claude Code (local or web). Standalone HTML, .zip | "Copy code" in the browser inspector | Inspect tab: CSS, HTML, SVG |
| **Assets / specs / tokens out** | `download_assets` (PNG, JPG, SVG, PDF), `get_variable_defs`, Variables REST API (Enterprise only), Figma Specs (open beta) | Through Figma Design after "Copy design" | PDF, PPTX, Google Slides, Canva and others. Artboards as PNG or PDF | Asset export and tokens in the web inspector | Token export: CSS, SCSS, Tailwind v4, TS, DTCG JSON. `export_shape` |
| **Agent read interface** | Figma MCP: remote `mcp.figma.com/mcp` (recommended) or desktop. Read and write. REST API | Figma MCP (`send_code_to_figma` in). A Make-specific read tool not confirmed. GitHub repo | Claude Code `/design`, the artifact read by URL, the handoff bundle. A standalone MCP not confirmed | Local MCP at `localhost:31126/mcp` (Sketch 2025.2.4+, not the App Store build): `run_code`, `get_layer_tree_summary`, `get_screenshot`, `get_comments` and more | MCP (remote on design.penpot.app, or local `npx @penpot/mcp`) acting on the focused page. RPC API with access tokens |
| **Versioning** | Version history, plus branching and merging (Org and Enterprise) | Auto version history with restore. No branching | Help article: "doesn't have version history yet". Artifacts version per publish | Workspace timeline of updates per save. Restore by download and re-upload | Pinned (named) versions kept for good. Autosaves 7 days (SaaS) |
| **Share link** | Prototype link | Public published URL, or a custom domain | claude.ai artifact: private, org or public | Web previews: password, expiry, inspect toggle | View mode share links |

## Detail by tool

### Figma Design and Dev Mode
- The Figma MCP server comes in two forms. The remote server at `https://mcp.figma.com/mcp` is recommended and has the most tools. The desktop server needs a Dev or Full seat on a paid plan. Writing to the canvas is remote only, "free during the beta period", and will later be usage-based. [1]
- Design-to-code tools include `get_design_context` (React + Tailwind by default), `get_metadata`, `get_screenshot`, `get_variable_defs`, `get_code_connect_map`, `download_assets`, `get_comments` and `search_design_system`. Code-to-design tools include `use_figma`, `generate_figma_design`, `html_to_figma`, `upload_assets` and `send_code_to_figma`. [2]
- Code to canvas captures running UI from the browser as editable layers. The output is "flat layers, without a connection to your libraries", though matching variables are bound. It can capture a whole screen or one element, and a single screen or a flow. Destinations are a new file, an existing file or the clipboard. Plans: Starter and up. Supported clients include Claude Code, Codex, Cursor and VS Code. [3]
- Branching needs an Organization or Enterprise plan and a Full seat. Merging archives the branch. Libraries publish only from the main file. [4]
- The Variables REST API is Enterprise only, with a Full seat. [5]
- Not confirmed this pass: whether Figma prototypes support conditionals and expressions, and on which plans.

### Figma Make
- Make is a prompt-to-app tool. Publishing puts the app on the public web, hosted on AWS. It "can't restrict access to the published version". Only Full seats on paid plans and Starter can publish. Code export is available to Full and Dev seats. [6]
- GitHub push is one way, Make to GitHub, into a repo Make creates. Pushes go to the default branch, there is no branch management, and GitHub Enterprise Server is not supported. Plans: Starter and up. [7]
- Version history is automatic. Versions can be named and restored, and restoring keeps later versions. Supabase can be added through Integrations, and Make currently uses key-value stores, not full SQL. [8]
- In: frames pasted or attached into chat. A pasted Figma URL is not read. [6] Public npm packages can be added to `package.json`, and private packages come from a Figma-hosted registry on paid plans. [9] Make kits. [10]
- Back to design: "Copy design" converts Make's React components into Figma Design layers, as instances where Code Connect matches them. GitHub is the only code host. [11]
- Not confirmed: Make's exact stack beyond "React components" [11], and whether any MCP tool reads a Make file's code back out.

### Claude Design (Anthropic)
- Launched 2026-04-17 as an Anthropic Labs research preview. Inputs: prompts, images, DOCX, PPTX, XLSX, the codebase, and "a web capture tool that grabs elements from your website". Outputs: an org-internal URL, a folder, Canva, PDF, PPTX, standalone HTML, and a handoff bundle passed to Claude Code "with a single instruction". [12]
- Current help article: link a repo, or run `/design-sync` (GitHub repo, design files, uploads or local codebase) to build the design system. Export to .zip, PDF, PPTX, Google Slides and standalone HTML, plus Canva, Miro, Gamma, Vercel and Netlify. "Handoff to Claude Code" goes to a local agent or Claude Code Web. `/design` in Claude Code creates, edits and syncs designs, and can import a design into the codebase or export code as a live prototype. "Claude Design doesn't have version history yet." The standalone claude.ai/design closes 2026-12-14. [13]
- From Claude Code, `/design <brief>` publishes a Claude Design artifact (artboards on a canvas, with PNG or PDF export per artboard). It needs v2.1.265+. Artifacts are versioned per publish, shareable private, org-wide or public, and readable by URL. [14]
- Third-party (Bedrock, Vertex and similar) Claude Desktop deployments cannot send designs to Claude Code. [15]
- Not confirmed: a standalone MCP server or REST API for Claude Design files, and the exact format of the handoff bundle.

### Sketch
- MCP server built into the Mac app (2025.2.4+, not the Mac App Store build), local only at `http://localhost:31126/mcp`. Tools: `run_code` (the full SketchAPI), `get_document_info`, `get_layer_tree_summary`, `get_design_assets`, `get_screenshot`, `get_libraries`, `get_symbol_overrides`, `get_comments`, `save_comment`, `get_guide`. Doc updated 2026-11-17. [16]
- Handoff: browser inspector, free for developers, with asset export, tokens and copy code. Previews share chosen pages or prototypes with a password and expiry. [17]
- Versions: each save creates an "update" on a Workspace timeline. To restore, download the old update and upload it again. [18]
- Prototypes: links and Smart Animate. Not code. [19]
- Not confirmed: any first-party HTML or URL import, and a public REST API for Workspace documents (only the plugin JS API, file format and CLI were found).

### Penpot
- Official MCP server: remote (enable it under Your account → Integrations) or local (`npx @penpot/mcp@stable`, through a plugin). Tools: `execute_code`, `high_level_overview`, `penpot_api_info`, `export_shape`, `import_image` (local only). It acts only on the focused page. [20]
- Inspect gives CSS, HTML and SVG code. Tokens follow W3C DTCG and export to CSS, SCSS, Tailwind v4, TS and DTCG JSON. [21][22]
- Pinned versions are named and kept for good. Autosaved versions last 7 days on SaaS, and self-hosted needs a flag for auto snapshots. Latest release 2.19, 2026-10-28. [23][24]
- No built-in HTML or CSS import. Staff say pasting CSS is "not yet" supported. Community plugins exist. [25]
- Backend RPC API with personal access tokens. A self-hosted instance can expose `/api/doc`. [26]

## Common interface points for a tool-agnostic Design stage

| Interface point | Figma Design | Make | Claude Design | Sketch | Penpot | Usable as a stage contract? |
|---|---|---|---|---|---|---|
| Screenshot or image in | yes | yes | yes | yes | yes | **Yes**, the only universal input |
| Live URL capture in | yes (MCP) | via Figma Design | yes | no (not confirmed) | plugin only | No. Optional accelerator |
| Codebase / design system in | Code Connect, code layers | npm, kits | repo, `/design-sync` | no | tokens (DTCG) | No. Tool-specific |
| Share or view link out | yes | yes (public) | yes | yes | yes | **Yes** |
| PNG export out | yes | via Figma Design | yes | yes | yes | **Yes** |
| MCP an agent can read | yes | indirect | via Claude Code / artifact read | yes (local) | yes | **Mostly.** The stage needs a per-tool adapter |
| Running code out | reference snippets | yes | yes (HTML, bundle) | snippets | snippets | No. Only 2 of 5 |
| Tokens out | Enterprise API, MCP | — | not confirmed | inspector | DTCG export | No |
| Branch / version | branch (Org+) | versions | per-publish artifact versions | timeline | pinned versions | No common model. Keep the prototype's identity outside the tool |

Implication for #285: define the stage's output as **a link, screenshots and a written spec**. Treat MCP read access as a per-tool adapter. Treat running code as an optional extra that only Make and Claude Design provide. For input, give the stage screenshots plus the repo, and use live-URL capture only where the tool has it. Since prototypes live only until the feature ships, the tool's own version model is enough. The stage needs no common branching model.

## Sources

1. Figma, "Guide to the Figma MCP server": https://help.figma.com/hc/en-us/articles/32132100833559-Guide-to-the-Dev-Mode-MCP-Server
2. Figma developer docs, "Tools and prompts": https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/
3. Figma, "Code to canvas": https://help.figma.com/hc/en-us/articles/42495237955095-Code-to-canvas
4. Figma, "Guide to branching": https://help.figma.com/hc/en-us/articles/360063144053-Guide-to-branching (and "Merge branch into main file", 5691189138839)
5. Figma REST API, Variables: https://developers.figma.com/docs/rest-api/variables/
6. Figma, "Figma Make FAQs": https://help.figma.com/hc/en-us/articles/31722591905559-Figma-Make-FAQs
7. Figma, "Push from Figma Make to GitHub": https://help.figma.com/hc/en-us/articles/35463818346647-Push-from-Figma-Make-to-GitHub
8. Figma, "Create and edit a Figma Make file" / "Add a backend…": https://help.figma.com/hc/en-us/articles/31304485164695 and https://help.figma.com/hc/en-us/articles/32640822050199
9. Figma developer docs, "Use packages and third-party libraries": https://developers.figma.com/docs/code/use-packages-and-third-party-libraries/
10. Figma, "Use your design system package in Make kits": https://help.figma.com/hc/en-us/articles/35946832653975
11. Figma, "Make in your local codebase: Copy components to Figma Design": https://help.figma.com/hc/en-us/articles/43365023930391
12. Anthropic, "Introducing Claude Design by Anthropic Labs" (2026-04-17): https://www.anthropic.com/news/claude-design-anthropic-labs
13. Claude Help Center, "Get started with Claude Design": https://support.claude.com/en/articles/14604416-get-started-with-claude-design
14. Claude Code docs, "Share session output as artifacts": https://code.claude.com/docs/en/artifacts
15. Claude docs, "Design and Slides in Claude Desktop on 3P": https://claude.com/docs/third-party/claude-desktop/design-and-slides
16. Sketch, "MCP Server": https://www.sketch.com/docs/mcp-server/
17. Sketch, "Developer handoff": https://www.sketch.com/docs/developer-handoff/ and Previews changelog https://www.sketch.com/changelog/previews/
18. Sketch, "Saving and managing documents": https://www.sketch.com/docs/sketch-cloud/versions
19. Sketch, "Adding animations": https://www.sketch.com/docs/prototyping/animating/
20. Penpot, "Penpot MCP server": https://help.penpot.app/mcp/
21. Penpot, "Interface tour" (Inspect): https://help.penpot.app/user-guide/first-steps/the-interface/
22. Penpot, "Design Tokens": https://help.penpot.app/user-guide/design-systems/design-tokens/
23. Penpot, "Workspace basics" (History): https://help.penpot.app/user-guide/designing/workspace-basics/
24. Penpot release notes 2.19 (2026-10-28): https://penpot.app/release-notes/2-19-is-this-it
25. Penpot Hub, HTML TO DESIGN plugin: https://penpot.app/penpothub/plugins/html-to-design, plus community FAQ https://community.penpot.app/t/faq-can-i-paste-css-in-penpot-inspect-to-create-design/2576
26. Penpot, "Integration guide": https://help.penpot.app/technical-guide/integration/
27. html.to.design docs (third-party Figma plugin): https://html.to.design/docs/what-is-html-to-design
28. Figma blog, "Build by Design" (2026-10-15): https://www.figma.com/blog/build-by-design/
