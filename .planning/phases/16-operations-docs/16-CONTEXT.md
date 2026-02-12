# Phase 16: Operations Documentation - Context

**Gathered:** 2026-02-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Documentation that lets an operator set up, monitor, and troubleshoot AgentCom without reading source code. Covers hub setup from scratch, dashboard/metrics/log usage, and failure mode recovery. No new code features — this phase produces documentation only.

</domain>

<decisions>
## Implementation Decisions

### Document format & structure
- Multi-file docs/ directory, organized by workflow (what the operator is doing)
- Files: setup.md, daily-operations.md, troubleshooting.md (or similar workflow-based split)
- Integrated with ExDoc — guides served alongside generated module docs
- Cross-reference module pages where relevant (e.g., "See AgentCom.TaskQueue for queue internals") so operators can drill deeper

### Audience & writing style
- Primary audience: solo operator who built the system — skip basics, focus on procedures and reference
- Narrative walkthrough style with explanations of WHY each step matters — useful when coming back months later
- Include architecture rationale in each major section explaining design reasoning (e.g., why DETS over Postgres, why GenServer per table)
- Include system architecture overview with Mermaid diagrams: component relationships, message flow, supervision tree

### Setup walkthrough scope
- Start from scratch: include installing Erlang/Elixir/Node.js prerequisites
- Dev environment only — no production deployment section
- Include full agent onboarding: provision agent, connect via sidecar, verify on dashboard (end-to-end first run)
- End with smoke test walkthrough: start hub, connect agent, submit task, verify completion — confirms the whole pipeline works

### Troubleshooting approach
- Symptom-based lookup: organized by what you see ("Tasks stuck in pending", "Agent shows offline")
- Log interpretation inline with each symptom — relevant log lines and jq queries as part of diagnosis steps, not a separate section

### Claude's Discretion
- Troubleshooting depth per issue — full diagnosis path vs quick fix based on complexity of each failure mode
- Failure mode prioritization — which issues get the most detailed coverage based on likelihood
- Exact file split within the workflow-based structure
- Mermaid diagram scope and detail level
- ExDoc configuration specifics

</decisions>

<specifics>
## Specific Ideas

- Workflow-based organization mirrors operator mental model: "I'm setting up" → setup.md, "something broke" → troubleshooting.md
- Narrative style chosen specifically for future-self readability — months-later recall of reasoning
- Architecture diagrams serve dual purpose: operational understanding + onboarding reference
- Cross-referencing ExDoc modules bridges the gap between "how to operate" and "how it works internally"

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 16-operations-docs*
*Context gathered: 2026-02-12*
