# Phase 24: Document Format Conversion - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Convert AgentCom-internal machine-consumed documents to XML format. GSD .planning/ artifacts stay in markdown (GSD framework generates them). Only new AgentCom-specific documents (goal definitions, task context, scan results, FSM state snapshots) use XML going forward.

FORMAT-02 (convert existing .planning/ to XML) is descoped -- GSD stays markdown.
</domain>

<decisions>
## Implementation Decisions

### Scope
- New AgentCom-internal documents use XML: goal specs, FSM state exports, scan results, improvement findings, proposals
- GSD .planning/ artifacts (PROJECT.md, STATE.md, ROADMAP.md, REQUIREMENTS.md, CONTEXT.md, PLAN.md, SUMMARY.md) remain markdown -- GSD framework generates them
- Human-facing docs (README, changelogs, ExDoc) remain markdown

### XML Schema Design
- At Claude's discretion: define XSD schemas or use convention-based XML
- Goal definitions, task context, and scan results need well-defined structures
- Keep XML simple and flat where possible -- avoid deep nesting

### Claude's Discretion
- XML schema approach (formal XSD vs convention-based)
- Which existing documents to create XML equivalents for
- Naming conventions for XML files
</decisions>

<specifics>
## Specific Ideas

- Define a `<goal>` XML schema that GoalBacklog (Phase 27) will consume
- Define a `<scan-result>` schema that Improvement Scanning (Phase 32) will produce
- Define an `<fsm-snapshot>` schema for FSM state exports
- Keep schemas in a `lib/agent_com/schemas/` directory or inline in modules
</specifics>

<constraints>
## Constraints

- Must not break GSD workflow compatibility
- GSD skills continue reading/writing markdown in .planning/
- XML documents are consumed by Elixir code (parsing with built-in :xmerl or similar)
</constraints>
