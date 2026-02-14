---
status: diagnosed
trigger: "Investigate why Mermaid diagrams in docs/architecture.md are rendering as raw code text instead of visual diagrams in ExDoc-generated HTML"
created: 2026-02-12T00:00:00Z
updated: 2026-02-12T00:00:00Z
---

## Current Focus

hypothesis: ExDoc v0.40.1 correctly converts ```mermaid fenced blocks to <pre><code class="mermaid"> HTML, but does NOT bundle or load the Mermaid.js library -- a before_closing_body_tag or before_closing_head_tag hook is required to inject the Mermaid JS CDN script
test: Checked generated HTML structure, ExDoc docs config, and doc/dist/ for any mermaid runtime
expecting: No mermaid.js present anywhere in output; HTML has correct class but no renderer
next_action: Return structured diagnosis

## Symptoms

expected: Mermaid code blocks in docs/architecture.md should render as visual SVG diagrams in doc/architecture.html
actual: Diagrams appear as raw code text in <pre><code class="mermaid"> blocks -- the markup is correct but no JS library exists to transform it into SVG
errors: None (no errors, just un-rendered code blocks)
reproduction: Run `mix docs`, open doc/architecture.html in browser, observe 3 mermaid blocks shown as plain text
started: Has never worked -- no Mermaid JS configuration has ever been added to mix.exs docs config

## Eliminated

(none needed -- root cause confirmed on first inspection)

## Evidence

- timestamp: 2026-02-12T00:00:00Z
  checked: docs/architecture.md -- all 3 mermaid fenced blocks
  found: Blocks use correct ```mermaid syntax (lines 13-38, 48-70, 82-107). Formatting is proper.
  implication: The markdown source is correct. ExDoc's earmark parser recognizes the mermaid language tag.

- timestamp: 2026-02-12T00:00:00Z
  checked: doc/architecture.html -- generated HTML output
  found: ExDoc correctly converts ```mermaid blocks to `<pre><code class="mermaid">...</code></pre>` (lines 106-129, 129-149, 149-172). The class="mermaid" is present and correct.
  implication: ExDoc's markdown-to-HTML pipeline handles mermaid blocks properly. The issue is client-side: no JS library loads to process these elements.

- timestamp: 2026-02-12T00:00:00Z
  checked: doc/architecture.html <head> section (lines 1-19)
  found: Only 3 assets loaded: dist/html-elixir-YJO4MOOW.css, dist/sidebar_items-55BE7E7D.js, dist/html-YU4BZFVS.js. No mermaid script tag.
  implication: No Mermaid JS library is injected into the HTML head or body.

- timestamp: 2026-02-12T00:00:00Z
  checked: doc/architecture.html <body> closing section (lines 220-229)
  found: No script tags before </body>. No mermaid initialization code.
  implication: No before_closing_body_tag hook is configured.

- timestamp: 2026-02-12T00:00:00Z
  checked: doc/dist/ directory -- all bundled assets
  found: Only 9 files: 1 CSS, 2 JS (html + sidebar_items + search_data), 4 fonts, 1 icon font. No mermaid.min.js or similar.
  implication: ExDoc v0.40.1 does NOT bundle Mermaid.js. It must be provided externally.

- timestamp: 2026-02-12T00:00:00Z
  checked: Grep for "mermaid" in doc/dist/ directory
  found: Only appears in search_data-B2A15F91.js (search index contains the raw mermaid text from the page). Zero matches in html-YU4BZFVS.js or CSS.
  implication: Confirms ExDoc's core JS bundle has no mermaid rendering capability.

- timestamp: 2026-02-12T00:00:00Z
  checked: mix.exs docs() function (lines 37-101)
  found: Config has main, extras, groups_for_extras, groups_for_modules. NO before_closing_head_tag, NO before_closing_body_tag hook.
  implication: This is the missing configuration. ExDoc supports these hooks specifically for injecting third-party JS like Mermaid.

- timestamp: 2026-02-12T00:00:00Z
  checked: ExDoc version in mix.lock
  found: ex_doc v0.40.1 (hex package). Depends on earmark_parser ~> 1.4.44.
  implication: This is a recent version. ExDoc has supported before_closing_body_tag since at least v0.28. The feature is available but not used.

## Resolution

root_cause: ExDoc v0.40.1 correctly parses ```mermaid fenced code blocks and outputs `<pre><code class="mermaid">` HTML elements, but it does NOT include the Mermaid.js rendering library. The mix.exs docs() config is missing a `before_closing_body_tag` hook that would inject the Mermaid CDN script and initialization code. Without this script, browsers display the mermaid syntax as raw preformatted text because no JavaScript exists to transform the `<code class="mermaid">` elements into SVG diagrams.

fix: (diagnosis only -- not applied)

verification: (diagnosis only)

files_changed: []
