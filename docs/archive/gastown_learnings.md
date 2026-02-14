# Gas Town — Learnings & Analysis

**Source:** https://github.com/steveyegge/gastown  
**Author:** Steve Yegge  
**Reviewed:** 2026-02-10

## What It Is

Gas Town is a multi-agent orchestration system built on top of **Claude Code** (with optional Codex support). It coordinates 20-30 AI coding agents working on different tasks within a shared workspace, with persistent state that survives agent restarts.

Think of it as a project manager layer on top of Claude Code's CLI — you talk to "The Mayor" (a coordinator agent), it breaks work into units, farms them out to worker agents, and tracks everything in git.

## Core Architecture

| Concept | Role |
|---------|------|
| **Mayor** 🎩 | Primary AI coordinator — a Claude Code instance you talk to |
| **Town** 🏘️ | Workspace root (`~/gt/`), contains all projects and config |
| **Rigs** 🏗️ | Project containers wrapping a git repo + its agents |
| **Crew Members** 👤 | Your personal workspace within a rig (human's working area) |
| **Polecats** 🦨 | Worker agents — persistent identity, ephemeral sessions |
| **Hooks** 🪝 | Git worktree-based persistent storage for agent work state |
| **Convoys** 🚚 | Work tracking bundles — group multiple issues for assignment |
| **Beads** 📿 | Git-backed issue/work-item tracking (structured data in git) |

## Key Design Decisions

### 1. Git as the persistence layer
Everything — work state, hooks, issue tracking — lives in git worktrees. This is the "propulsion principle": agents can crash, restart, lose memory, but their work state survives in version-controlled worktrees with full rollback capability.

### 2. Mad Max theming (seriously)
The entire vocabulary is Mad Max: Fury Road themed. Rigs, polecats, convoys, hooks, the Mayor. It's... a choice. Makes it memorable, if occasionally confusing.

### 3. Coordinator pattern (Mayor)
Rather than peer-to-peer agent communication, there's a central Mayor that orchestrates. You tell the Mayor what to build, it creates convoys, assigns beads to agents, and tracks progress. Classic hub-and-spoke.

### 4. Identity persistence, session ephemerality
Polecats (worker agents) keep their identity and work history across sessions, but individual sessions are ephemeral. This matches the reality of LLM agents — context windows reset, but you can reload state from disk.

### 5. Multi-runtime support
Not locked to Claude Code. Supports Codex CLI, Cursor, and custom agent commands via config. Built-in presets: `claude`, `gemini`, `codex`, `cursor`, `auggie`, `amp`.

## What's Interesting

- **Scale target of 20-30 agents** — most multi-agent systems struggle past 4-10. The git-backed state and convoy tracking is how they claim to handle this.
- **Beads** is a separate project (`steveyegge/beads`) — a git-backed issue tracker with "formulas" (TOML-defined repeatable workflows). Formulas let you define multi-step processes like releases with dependency ordering.
- **Mailbox system** — agents have built-in mailboxes for coordination, plus a `gt prime` command for context recovery.
- **Web dashboard** for real-time monitoring of agent status, convoy progress, and hook state.
- **tmux integration** — full experience uses tmux for managing multiple agent sessions.

## Relevance to OpenClaw

Some parallels worth noting:

| Gas Town | OpenClaw |
|----------|----------|
| Mayor (coordinator) | Main session |
| Polecats (workers) | `sessions_spawn` sub-agents |
| Hooks (persistent state) | Workspace files + memory system |
| Convoys (work tracking) | Cron jobs / heartbeat tasks |
| Mailboxes | `sessions_send` / AgentCom |
| Beads (issue tracking) | No direct equivalent |

**Key differences:**
- Gas Town is CLI-first, designed for developers running many agents locally on code tasks
- OpenClaw is chat-first, designed for personal assistant workflows across messaging platforms
- Gas Town uses git worktrees for everything; OpenClaw uses flat files + memory search
- Gas Town's scale target (20-30 agents) is much higher than typical OpenClaw usage

**Ideas worth stealing:**
- The git-backed persistent state pattern is solid — more robust than flat files for multi-agent scenarios
- Formula/workflow definitions (TOML-based repeatable processes) could be useful for recurring OpenClaw tasks
- The convoy concept (bundling related work items with progress tracking) could improve sub-agent coordination
- Explicit agent identity persistence across sessions — OpenClaw does this with SOUL.md but Gas Town formalizes it more

## Verdict

Clever system with good engineering instincts (git as truth, persistent identity, central coordination). The Mad Max theming is peak Yegge. Primary use case is scaling AI-assisted software development — not directly applicable to our setup, but the persistence and coordination patterns are worth studying.
