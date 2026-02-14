# Phase 31: Hub Event Wiring - Research

**Researched:** 2026-02-13
**Domain:** GitHub webhooks, HMAC signature verification, Plug HTTP, FSM event triggering
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Hub exposes POST /api/webhooks/github endpoint
- Verify webhook signature (HMAC-SHA256 with webhook secret)
- Handle push events: extract repo, branch, commit info
- Handle pull_request events (action: "closed" + merged: true): extract repo, PR info
- Match incoming repo to active repos in RepoRegistry
- Expose hub's port 4000 via `tailscale funnel 4000`
- HTTPS termination handled by Tailscale
- Funnel URL becomes the webhook URL configured in GitHub repo settings
- Git push on active repo -> wake FSM from Resting to Improving
- PR merge on active repo -> wake FSM from Resting to Improving
- Goal submission (already handled by GoalBacklog PubSub in Phase 27) -> wake FSM to Executing
- Events on non-active repos are ignored

### Claude's Discretion
- Webhook event filtering (which GitHub events to subscribe to beyond push/PR)
- Event debouncing (rapid pushes shouldn't trigger multiple transitions)
- Whether to store webhook event history
- Tailscale Funnel setup documentation

### Deferred Ideas (OUT OF SCOPE)
(none specified)
</user_constraints>

## Summary

Phase 31 wires external GitHub events into the HubFSM. The hub exposes a `POST /api/webhooks/github` endpoint that receives push and PR merge events, verifies HMAC-SHA256 signatures, matches the repo against the RepoRegistry, and triggers FSM transitions. The existing HubFSM only has two states (`:resting` and `:executing`), but the phase description calls for waking to `:improving` -- this means the HubFSM will need a third state added. Goal backlog waking to `:executing` is already handled by the tick-based Predicates evaluation in Phase 29.

The main technical challenge is the raw body caching needed for HMAC signature verification. Plug.Parsers consumes the body on read, so a custom `body_reader` must cache the raw bytes before JSON parsing. The existing `Plug.Parsers` configuration in `AgentCom.Endpoint` must be updated to use this custom reader. Since the webhook endpoint is unauthenticated (GitHub cannot provide a Bearer token), it relies solely on HMAC verification for security.

**Primary recommendation:** Implement webhook handling as a thin endpoint handler in the existing Endpoint module, with a separate `WebhookVerifier` plug for HMAC verification. Use `HubFSM.force_transition/2` or a new dedicated API to trigger FSM wakeups from webhook events.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Plug | ~> 1.15 | HTTP endpoint, body parsing, conn pipeline | Already in project deps |
| :crypto (Erlang) | (stdlib) | HMAC-SHA256 computation via `:crypto.mac/4` | Standard Erlang crypto module |
| Plug.Crypto | (via plug) | `secure_compare/2` for timing-safe signature comparison | Prevents timing attacks |
| Jason | ~> 1.4 | JSON parsing of webhook payloads | Already in project deps |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| AgentCom.Config | (internal) | Store webhook secret | Already exists, DETS-backed |
| AgentCom.RepoRegistry | (internal) | Match repo URL to active repos | Already exists with `active_repo_ids/0` |
| AgentCom.HubFSM | (internal) | Trigger state transitions | Already exists with `force_transition/2` |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Custom HMAC plug | `plug_hmac` hex package | Too heavyweight; 10 lines of code doesn't need a dep |
| Storing secret in Config GenServer | Environment variable | Config GenServer already exists and is the project pattern |

**Installation:** No new dependencies needed. Everything is available in existing deps.

## Architecture Patterns

### Recommended Module Structure
```
lib/agent_com/
  endpoint.ex              # Add POST /api/webhooks/github route
  webhook_verifier.ex      # Plug for HMAC-SHA256 signature verification
  cache_body_reader.ex     # Custom body reader for raw body caching
  hub_fsm.ex               # Add :improving state and webhook_event/1 API
  hub_fsm/predicates.ex    # Add :improving state transitions
```

### Pattern 1: Custom Body Reader for HMAC Verification
**What:** Cache raw request body in `conn.assigns[:raw_body]` before JSON parsing
**When to use:** Any webhook endpoint requiring signature verification
**Example:**
```elixir
# Source: https://hexdocs.pm/plug/Plug.Parsers.html
defmodule AgentCom.CacheBodyReader do
  @moduledoc "Caches raw request body for HMAC signature verification."

  def read_body(conn, opts) do
    with {:ok, body, conn} <- Plug.Conn.read_body(conn, opts) do
      conn = update_in(conn.assigns[:raw_body], &[body | &1 || []])
      {:ok, body, conn}
    end
  end
end
```

**IMPORTANT:** The `Plug.Parsers` configuration in `endpoint.ex` must be updated:
```elixir
plug(Plug.Parsers,
  parsers: [:json],
  pass: ["application/json"],
  body_reader: {AgentCom.CacheBodyReader, :read_body, []},
  json_decoder: Jason
)
```

### Pattern 2: Webhook Signature Verification Plug
**What:** Inline verification of GitHub's `X-Hub-Signature-256` header
**When to use:** Called only on the webhook route, not globally
**Example:**
```elixir
defmodule AgentCom.WebhookVerifier do
  @moduledoc "Verifies GitHub webhook HMAC-SHA256 signatures."
  import Plug.Conn

  def verify_signature(conn) do
    with [signature_header] <- get_req_header(conn, "x-hub-signature-256"),
         "sha256=" <> received_digest <- signature_header,
         {:ok, secret} <- get_webhook_secret(),
         raw_body <- Enum.join(conn.assigns[:raw_body] || []) do
      computed = :crypto.mac(:hmac, :sha256, secret, raw_body)
                 |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(computed, received_digest) do
        {:ok, conn}
      else
        {:error, :invalid_signature}
      end
    else
      _ -> {:error, :missing_signature}
    end
  end

  defp get_webhook_secret do
    case AgentCom.Config.get(:github_webhook_secret) do
      nil -> {:error, :no_secret_configured}
      secret -> {:ok, secret}
    end
  end
end
```

### Pattern 3: Webhook Route Handler
**What:** Endpoint route that verifies signature, extracts event, matches repo, triggers FSM
**When to use:** POST /api/webhooks/github
**Example:**
```elixir
post "/api/webhooks/github" do
  case AgentCom.WebhookVerifier.verify_signature(conn) do
    {:ok, conn} ->
      event_type = get_req_header(conn, "x-github-event") |> List.first()
      handle_github_event(conn, event_type, conn.body_params)

    {:error, reason} ->
      Logger.warning("webhook_signature_failed", reason: reason)
      send_json(conn, 401, %{"error" => "invalid_signature"})
  end
end
```

### Pattern 4: FSM Third State (:improving)
**What:** The phase description says push/PR merge wakes FSM to `:improving`, not `:executing`. This means the HubFSM needs a third state.
**When to use:** When external code events arrive (push/PR merge on active repos)
**Key change:** The `@valid_transitions` map in HubFSM must be extended:
```elixir
@valid_transitions %{
  resting: [:executing, :improving],
  executing: [:resting],
  improving: [:resting]
}
```
The Predicates module needs corresponding evaluate clauses for `:improving`.

### Anti-Patterns to Avoid
- **Processing webhook synchronously before responding:** GitHub has a 10-second timeout. Always respond 200 immediately, then process asynchronously if work is heavy. In our case, the processing is lightweight (repo lookup + FSM transition), so synchronous is fine.
- **Using parsed JSON for HMAC:** The HMAC must be computed on the raw bytes. Re-encoding parsed JSON will produce different byte sequences than the original.
- **Global body caching:** The `CacheBodyReader` caches raw body for ALL requests. This is low-cost (body is already being read anyway) but the `raw_body` assign is only used by the webhook route.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| HMAC computation | Custom hash function | `:crypto.mac(:hmac, :sha256, key, data)` | Erlang stdlib, battle-tested |
| Timing-safe comparison | `==` operator | `Plug.Crypto.secure_compare/2` | Prevents timing attacks |
| Raw body caching | Custom plug pipeline | `Plug.Parsers` `:body_reader` option | Official documented approach |
| Webhook secret storage | Env var or hardcoded | `AgentCom.Config.get/1` | Project pattern, DETS-backed |

**Key insight:** The only non-trivial piece is the body reader caching pattern, and it's a documented Plug feature, not custom engineering.

## Common Pitfalls

### Pitfall 1: Body Already Consumed
**What goes wrong:** `Plug.Parsers` reads and consumes the request body. Attempting to read it again for HMAC verification returns empty.
**Why it happens:** HTTP bodies are streams that can only be read once in Plug.
**How to avoid:** Use the `:body_reader` option on `Plug.Parsers` to cache raw bytes in `conn.assigns[:raw_body]` BEFORE parsing.
**Warning signs:** HMAC always fails because computed hash is of empty string.

### Pitfall 2: GitHub Signature Format
**What goes wrong:** Comparing raw HMAC output to the header value fails.
**Why it happens:** GitHub's `X-Hub-Signature-256` header has the format `sha256=<hex>` (lowercase hex). Must strip the `sha256=` prefix and encode HMAC output with `Base.encode16(case: :lower)`.
**How to avoid:** Pattern-match `"sha256=" <> digest` on the header value.
**Warning signs:** Signature verification always fails even with correct secret.

### Pitfall 3: Webhook Replay / Idempotency
**What goes wrong:** GitHub may redeliver the same webhook (manual redeliver, network issues). Processing the same event twice could cause duplicate FSM transitions.
**Why it happens:** Webhooks are at-least-once delivery.
**How to avoid:** Since FSM transitions are idempotent (transitioning to the same state is either a no-op or already there), this is low risk. The `X-GitHub-Delivery` header contains a unique ID that could be logged for deduplication if needed.
**Warning signs:** Duplicate transition log entries with same commit SHA.

### Pitfall 4: Missing X-Hub-Signature-256 Header
**What goes wrong:** If webhook secret is not configured in GitHub, the signature header is absent.
**Why it happens:** GitHub only sends the signature header when a secret is configured.
**How to avoid:** Return 401 immediately if header is missing. Never allow unsigned webhooks.
**Warning signs:** Webhook calls consistently return 401.

### Pitfall 5: FSM State Mismatch with :improving
**What goes wrong:** The current HubFSM only has `:resting` and `:executing`. The phase description says push/PR merge wakes to `:improving`. Adding a third state requires updating Predicates, History expectations, and dashboard rendering.
**Why it happens:** Phase 29 was designed with 2 states; Phase 31 adds a third.
**How to avoid:** Carefully update `@valid_transitions`, add Predicates clauses for `:improving`, and add exit conditions (when does `:improving` transition to `:resting`?).
**Warning signs:** `{:error, :invalid_transition}` on force_transition calls.

### Pitfall 6: RepoRegistry URL Matching
**What goes wrong:** GitHub sends `repository.full_name` as `"owner/repo"` but RepoRegistry stores full URLs like `"https://github.com/owner/repo"`. Direct string comparison fails.
**Why it happens:** Different representations of the same repository.
**How to avoid:** RepoRegistry's `url_to_id/1` normalizes URLs to `"owner-repo"` format. Extract the same from GitHub's `repository.full_name` (replace `/` with `-`).
**Warning signs:** All webhook events are classified as "non-active repo" and ignored.

## Code Examples

### GitHub Push Event Handling
```elixir
# Source: GitHub Webhook docs + codebase analysis
defp handle_github_event(conn, "push", payload) do
  repo_full_name = get_in(payload, ["repository", "full_name"])
  ref = payload["ref"]
  branch = String.replace_prefix(ref || "", "refs/heads/", "")
  head_commit = get_in(payload, ["head_commit", "id"]) || "unknown"

  case match_active_repo(repo_full_name) do
    {:ok, _repo} ->
      Logger.info("webhook_push_received",
        repo: repo_full_name, branch: branch, commit: head_commit)
      wake_fsm(:improving, "push on #{repo_full_name}:#{branch}")
      send_json(conn, 200, %{"status" => "accepted", "event" => "push"})

    :not_active ->
      Logger.debug("webhook_push_ignored", repo: repo_full_name, reason: "not active")
      send_json(conn, 200, %{"status" => "ignored", "reason" => "repo not active"})
  end
end
```

### GitHub PR Merge Event Handling
```elixir
defp handle_github_event(conn, "pull_request", payload) do
  action = payload["action"]
  merged = get_in(payload, ["pull_request", "merged"])
  repo_full_name = get_in(payload, ["repository", "full_name"])

  if action == "closed" and merged == true do
    pr_number = get_in(payload, ["pull_request", "number"])
    base_branch = get_in(payload, ["pull_request", "base", "ref"])

    case match_active_repo(repo_full_name) do
      {:ok, _repo} ->
        Logger.info("webhook_pr_merged",
          repo: repo_full_name, pr: pr_number, branch: base_branch)
        wake_fsm(:improving, "PR ##{pr_number} merged on #{repo_full_name}")
        send_json(conn, 200, %{"status" => "accepted", "event" => "pr_merge"})

      :not_active ->
        send_json(conn, 200, %{"status" => "ignored", "reason" => "repo not active"})
    end
  else
    # Non-merge PR events are acknowledged but not acted on
    send_json(conn, 200, %{"status" => "ignored", "reason" => "not a merge"})
  end
end
```

### Repo Matching Against RepoRegistry
```elixir
defp match_active_repo(full_name) do
  # GitHub sends "owner/repo", RepoRegistry stores normalized URLs
  # RepoRegistry.url_to_id normalizes "https://github.com/owner/repo" -> "owner-repo"
  # So we normalize full_name the same way: "owner/repo" -> "owner-repo"
  target_id = String.replace(full_name, "/", "-")

  active_repos = AgentCom.RepoRegistry.list_repos()

  case Enum.find(active_repos, fn r -> r.id == target_id and r.status == :active end) do
    nil -> :not_active
    repo -> {:ok, repo}
  end
end
```

### FSM Wake Helper
```elixir
defp wake_fsm(target_state, reason) do
  try do
    case AgentCom.HubFSM.force_transition(target_state, reason) do
      :ok ->
        Logger.info("webhook_fsm_wake", target: target_state, reason: reason)

      {:error, :invalid_transition} ->
        # FSM already in an active state -- that's fine
        Logger.debug("webhook_fsm_already_active",
          target: target_state, reason: reason)
    end
  catch
    :exit, _ ->
      Logger.warning("webhook_fsm_unavailable")
  end
end
```

## Discretion Recommendations

### 1. Webhook Event Filtering
**Recommendation:** Subscribe only to `push` and `pull_request` events in GitHub webhook settings. Handle all other event types with a 200 "ignored" response. The `X-GitHub-Event` header identifies the event type -- use it to route handling.

**Rationale:** Minimal surface area. Other events (issues, releases, etc.) have no FSM mapping yet. Accepting them gracefully (200 response) prevents GitHub from marking the webhook as unhealthy.

### 2. Event Debouncing
**Recommendation:** Do NOT debounce at the webhook level. The FSM already uses tick-based evaluation at 1-second intervals. If the FSM is already in `:improving` when a second push arrives, `force_transition` will return `{:error, :invalid_transition}` which is handled gracefully. The tick-based design inherently debounces.

**Rationale:** The FSM's tick-based architecture means rapid pushes simply see the FSM already awake. No extra debounce logic needed.

### 3. Webhook Event History
**Recommendation:** YES, store a lightweight webhook event log. Use an ETS table (similar to `HubFSM.History`) capped at 100 entries. Store: timestamp, event_type, repo, action taken (accepted/ignored), delivery ID. This aids debugging without adding DETS persistence overhead.

**Rationale:** Webhook debugging is notoriously difficult. Having a recent event log visible via an API endpoint (`GET /api/webhooks/github/history`) is invaluable. ETS is ephemeral (survives restarts only if we want it to) and fast.

### 4. Tailscale Funnel Setup
**Recommendation:** Document setup in a brief section at the top of the endpoint module's `@moduledoc`. The command is simply `tailscale funnel 4000`. No code changes needed -- Tailscale handles HTTPS termination externally.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `:crypto.hmac/3` | `:crypto.mac(:hmac, :sha256, key, data)` | OTP 22+ | Old function removed in OTP 24 |
| `X-Hub-Signature` (SHA1) | `X-Hub-Signature-256` (SHA256) | GitHub 2021 | Must use the -256 header |
| Global auth plugs | Route-specific verification | Always | Webhook uses HMAC, not Bearer tokens |

**Deprecated/outdated:**
- `:crypto.hmac/3` -- removed in OTP 24. Use `:crypto.mac/4` instead.
- `X-Hub-Signature` (SHA1) -- GitHub still sends it for backward compat but recommends SHA256.

## Open Questions

1. **What are the exit conditions for :improving state?**
   - What we know: Push/PR merge transitions resting -> improving. The phase description says "wakes FSM from Resting to Improving".
   - What's unclear: When does :improving -> resting? After a fixed timeout? After some scan completes? On tick evaluation?
   - Recommendation: Define a simple predicate -- :improving transitions to :resting after a configurable timeout (e.g., 5 minutes) or when the improvement cycle completes. This mirrors the executing -> resting pattern. The planner should define this clearly.

2. **Does :improving state interact with :executing?**
   - What we know: Currently :resting and :executing are the only states. Goal submission wakes to :executing.
   - What's unclear: Can :improving transition to :executing if a goal is submitted? Can :executing transition to :improving on a push?
   - Recommendation: Keep it simple -- :improving is a peer of :executing, both transition back to :resting. If both triggers fire simultaneously, the first one wins (FSM is already awake).

3. **Webhook secret initial provisioning**
   - What we know: Secret stored in Config GenServer. Needs to be set before webhooks work.
   - What's unclear: How does the admin set the webhook secret? API endpoint? CLI task?
   - Recommendation: Add `PUT /api/config/webhook-secret` (auth required) and also support reading from `GITHUB_WEBHOOK_SECRET` environment variable on startup (Config GenServer can check env on init).

## Sources

### Primary (HIGH confidence)
- [Plug.Parsers documentation](https://hexdocs.pm/plug/Plug.Parsers.html) - `:body_reader` option for raw body caching
- [GitHub webhook validation docs](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries) - X-Hub-Signature-256 format
- [GitHub webhook events and payloads](https://docs.github.com/en/webhooks/webhook-events-and-payloads) - push and pull_request payload structures
- [GitHub handling failed deliveries](https://docs.github.com/en/webhooks/using-webhooks/handling-failed-webhook-deliveries) - retry behavior (no auto-retry, 10s timeout)
- Codebase: `lib/agent_com/endpoint.ex` - existing Plug.Router patterns
- Codebase: `lib/agent_com/hub_fsm.ex` - existing FSM with `force_transition/2`
- Codebase: `lib/agent_com/repo_registry.ex` - `url_to_id/1` normalization, `list_repos/0`
- Codebase: `lib/agent_com/config.ex` - Config GenServer pattern

### Secondary (MEDIUM confidence)
- [GitHub webhook authentication with Elixir Plug](https://jeremykreutzbender.com/blog/github-webhook-authentication-with-elixir-plug) - Complete Elixir implementation pattern
- [Verifying request signatures in Elixir](https://www.adamconrad.dev/blog/verifying-request-signatures-in-elixir-phoenix/) - `:crypto.mac/4` and `Plug.Crypto.secure_compare/2` usage
- [GitHub push webhook payload example](https://gist.github.com/walkingtospace/0dcfe43116ca6481f129cdaa0e112dc4) - Full push payload JSON structure

### Tertiary (LOW confidence)
- (none -- all findings verified against official sources)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - all libraries already in project deps, no new dependencies
- Architecture: HIGH - follows existing codebase patterns (Plug.Router, GenServer, ETS)
- Pitfalls: HIGH - body caching pattern is well-documented, GitHub webhook format is stable
- FSM :improving state: MEDIUM - requires design decisions about exit conditions and state interactions

**Research date:** 2026-02-13
**Valid until:** 2026-03-15 (stable domain, GitHub webhook API is mature)
