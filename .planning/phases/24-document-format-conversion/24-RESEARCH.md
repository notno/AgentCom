# Phase 24: Document Format Conversion - Research

**Researched:** 2026-02-13
**Domain:** Elixir XML generation, parsing, and schema conventions for internal machine-consumed documents
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- New AgentCom-internal documents use XML: goal specs, FSM state exports, scan results, improvement findings, proposals
- GSD .planning/ artifacts (PROJECT.md, STATE.md, ROADMAP.md, REQUIREMENTS.md, CONTEXT.md, PLAN.md, SUMMARY.md) remain markdown -- GSD framework generates them
- Human-facing docs (README, changelogs, ExDoc) remain markdown
- Goal definitions, task context, and scan results need well-defined structures
- Keep XML simple and flat where possible -- avoid deep nesting

### Claude's Discretion
- XML schema approach (formal XSD vs convention-based)
- Which existing documents to create XML equivalents for
- Naming conventions for XML files

### Deferred Ideas (OUT OF SCOPE)
- FORMAT-02 (convert existing .planning/ to XML) is DESCOPED -- GSD stays markdown
</user_constraints>

## Summary

Phase 24 establishes XML as the format for all new machine-consumed documents in AgentCom's v1.3 autonomous loop. The scope is narrow but foundational: define XML schemas for goal definitions (Phase 27), scan results (Phase 32), FSM state snapshots (Phase 29), improvement findings (Phase 32), and feature proposals (Phase 33). GSD .planning/ artifacts and human-facing docs stay in markdown.

The Elixir ecosystem offers two viable approaches for XML generation: the built-in `:xmerl` OTP module (available on OTP 28) and the third-party `saxy` library (v1.6.0, 8M+ downloads). For this project's use case -- generating small, flat XML documents consumed only by Elixir code -- **Saxy is the clear choice**. It provides both fast SAX parsing and an elegant `Saxy.Builder` protocol that derives XML encoding directly from Elixir structs. This maps perfectly to AgentCom's existing struct-based patterns. Saxy's `encode!` is 10-30x faster than alternatives, though performance is not the primary concern here -- developer ergonomics are.

For schema validation, the recommendation is **convention-based validation using Elixir structs and pattern matching**, NOT formal XSD. This matches the existing `AgentCom.Validation` pattern (pure Elixir, no external deps for validation). XSD validation via `:xmerl_xsd` is available in OTP 28 but adds complexity with no benefit for internal-only documents. The schemas are defined in code (Elixir structs with `@derive Saxy.Builder`), validated at parse time by struct construction, and are self-documenting.

**Primary recommendation:** Use Saxy 1.6 with `@derive Saxy.Builder` on Elixir structs for XML generation, and convention-based Elixir validation (not XSD) for parsing.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| saxy | ~> 1.6 | XML SAX parsing and encoding | 8M+ downloads, 10-30x faster encoding than alternatives, `Saxy.Builder` protocol maps Elixir structs to XML automatically |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| :xmerl (OTP) | 2.1.8 (OTP 28) | XSD validation (if ever needed) | Only if external XML validation requirement emerges; not needed for internal docs |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| saxy | xml_builder ~> 2.4 | xml_builder has more downloads (73M total) but Saxy is 10-30x faster for encoding; Saxy's Builder protocol better fits struct-based patterns |
| saxy | :xmerl (built-in) | Zero deps but xmerl's record-based API is ergonomically painful in Elixir; no builder protocol |
| Convention-based validation | XSD via :xmerl_xsd | XSD adds schema files and complex tooling for documents only consumed by our own code |

**Installation:**
```elixir
# In mix.exs deps:
{:saxy, "~> 1.6"}
```

No changes to `extra_applications` needed -- Saxy is pure Elixir.

## Architecture Patterns

### Recommended Project Structure
```
lib/agent_com/
  xml/                       # NEW: XML document module namespace
    schemas/                 # Schema struct definitions with Saxy.Builder
      goal.ex                # <goal> schema struct
      scan_result.ex         # <scan-result> schema struct
      fsm_snapshot.ex        # <fsm-snapshot> schema struct
      improvement.ex         # <improvement> schema struct
      proposal.ex            # <proposal> schema struct
    xml.ex                   # Public API: encode/decode functions
    parser.ex                # SAX event handler for parsing XML back to structs
```

### Pattern 1: Struct-Based XML Schema with Saxy.Builder
**What:** Define each XML document type as an Elixir struct with `@derive Saxy.Builder`, then use `Saxy.encode!/2` to generate XML.
**When to use:** For every new machine-consumed document type.
**Example:**
```elixir
# lib/agent_com/xml/schemas/goal.ex
defmodule AgentCom.XML.Schemas.Goal do
  @moduledoc "XML schema for goal definitions consumed by GoalBacklog (Phase 27)."

  @derive {Saxy.Builder,
    name: "goal",
    attributes: [:id, :priority, :source, :status],
    children: [:description, :success_criteria, :context]}

  defstruct [
    :id,
    :priority,
    :source,
    :status,
    :description,
    :success_criteria,
    :context
  ]
end
```

### Pattern 2: Centralized Encode/Decode API
**What:** A single `AgentCom.XML` module provides `encode/1` and `decode/2` functions, dispatching to the correct schema based on struct type or root element name.
**When to use:** All XML serialization should go through this module for consistency.
**Example:**
```elixir
# lib/agent_com/xml/xml.ex
defmodule AgentCom.XML do
  @moduledoc "Central API for encoding and decoding AgentCom XML documents."

  import Saxy.XML

  alias AgentCom.XML.Schemas.{Goal, ScanResult, FsmSnapshot, Improvement, Proposal}

  @doc "Encode an XML schema struct to an XML binary string."
  def encode!(%Goal{} = goal), do: Saxy.encode!(element("goal", build_attrs(goal), build_children(goal)), version: "1.0")
  def encode!(%ScanResult{} = result), do: Saxy.encode!(Saxy.Builder.build(result), version: "1.0")
  # ... pattern for each type

  @doc "Decode XML binary string into the appropriate schema struct."
  def decode!(xml_string, schema_module) do
    {:ok, simple_form} = Saxy.SimpleForm.parse_string(xml_string)
    schema_module.from_simple_form(simple_form)
  end
end
```

### Pattern 3: Convention-Based Validation via Struct Construction
**What:** Parsing XML validates by constructing the target struct -- if required fields are missing or types are wrong, the parse function returns `{:error, reason}`. No XSD needed.
**When to use:** Every time XML is read back from disk or received as input.
**Example:**
```elixir
# In each schema module, add from_simple_form/1:
def from_simple_form({"goal", attrs, children}) do
  goal = %__MODULE__{
    id: get_attr(attrs, "id"),
    priority: get_attr(attrs, "priority"),
    # ...
  }
  validate(goal)
end

defp validate(%{id: nil}), do: {:error, "goal id is required"}
defp validate(%{priority: p}) when p not in ~w(urgent high normal low), do: {:error, "invalid priority"}
defp validate(goal), do: {:ok, goal}
```

### Pattern 4: Flat XML with Child Elements for Lists
**What:** Keep XML simple and flat. Use attributes for scalar values, child elements for text content and lists. Avoid deep nesting.
**When to use:** All schemas should follow this convention per user constraint.
**Example output:**
```xml
<?xml version="1.0"?>
<goal id="goal-abc123" priority="high" source="api" status="submitted">
  <description>Add rate limiting to webhook endpoint</description>
  <success-criteria>
    <criterion>Webhook endpoint returns 429 after 100 requests per minute</criterion>
    <criterion>Rate limit is configurable via Config GenServer</criterion>
  </success-criteria>
  <context>
    <repo>https://github.com/user/AgentCom</repo>
    <tags>
      <tag>security</tag>
      <tag>infrastructure</tag>
    </tags>
  </context>
</goal>
```

### Anti-Patterns to Avoid
- **Deep nesting beyond 3 levels:** User constraint says flat where possible. If you need > 3 levels deep, the schema design is wrong.
- **Attributes for complex values:** Lists, multi-line text, and nested structures go in child elements, not attributes.
- **Mixed content (text + elements in same parent):** Keep elements-only or text-only -- no mixing.
- **Namespace prefixes:** These are internal documents, not interchange format. No namespaces needed.
- **Processing instructions beyond xml declaration:** No `<?stylesheet?>` or other PIs.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| XML generation | String concatenation/interpolation | Saxy.Builder + Saxy.encode!/2 | Proper escaping, encoding declaration, well-formedness guaranteed |
| XML parsing | Regex-based extraction | Saxy.SimpleForm.parse_string/1 | Handles CDATA, entities, encoding; regex breaks on edge cases |
| XSD validation | Custom XSD validator | Skip XSD entirely; use struct-based validation | Internal documents don't need formal schema files |
| XML pretty-printing | Manual indentation | Saxy handles formatting | Consistent output without manual effort |

**Key insight:** Since these XML documents are only consumed by AgentCom's own Elixir code, formal XML tooling (XSD, DTD, namespaces) adds zero value. The schemas live in code as Elixir structs -- that IS the schema definition.

## Common Pitfalls

### Pitfall 1: Atom Exhaustion from :xmerl
**What goes wrong:** `:xmerl_scan.string/1` creates atoms for every XML tag name. With untrusted or large input, this exhausts the atom table and crashes the BEAM.
**Why it happens:** xmerl was designed for trusted XML; it uses atoms for element names.
**How to avoid:** Use Saxy instead of :xmerl for parsing. Saxy uses strings, not atoms.
**Warning signs:** Growing atom count in `:erlang.system_info(:atom_count)`.

### Pitfall 2: Forgetting XML Escaping
**What goes wrong:** Special characters (`<`, `>`, `&`, `"`, `'`) in text content break XML well-formedness.
**Why it happens:** String interpolation into XML templates bypasses escaping.
**How to avoid:** Always use Saxy.Builder or Saxy.XML.element/3 to construct XML. Never build XML via string concatenation.
**Warning signs:** XML parse errors on documents containing user-provided text.

### Pitfall 3: Breaking GSD Compatibility
**What goes wrong:** Converting a .planning/ file to XML breaks the GSD framework which expects markdown.
**Why it happens:** Scope creep -- FORMAT-02 was descoped but might be attempted accidentally.
**How to avoid:** XML modules live in `lib/agent_com/xml/`, completely separate from .planning/. No code reads .planning/ files as XML.
**Warning signs:** Any code in `lib/agent_com/xml/` referencing `.planning/` paths.

### Pitfall 4: Inconsistent Schema Evolution
**What goes wrong:** Adding a field to a struct but not updating the `from_simple_form/1` parser means old XML files can't include the new field, or the parser silently drops it.
**Why it happens:** Schema and parser are in the same module but can drift.
**How to avoid:** Each schema module has a test that round-trips: `struct |> encode! |> decode! == struct`. Any field addition automatically caught by test.
**Warning signs:** `from_simple_form/1` has fewer fields than the struct definition.

### Pitfall 5: Overengineering the Schema
**What goes wrong:** Creating deeply nested, namespace-heavy, XSD-validated XML for simple internal documents.
**Why it happens:** XML has a reputation for complexity; developers bring enterprise patterns to simple problems.
**How to avoid:** Follow the user constraint: "Keep XML simple and flat where possible." If a schema has more than 3 levels of nesting, redesign it.
**Warning signs:** Schema module is more than ~80 lines. Child element has child elements that have child elements.

## Code Examples

Verified patterns from official sources:

### Adding Saxy Dependency
```elixir
# mix.exs
defp deps do
  [
    # ... existing deps
    {:saxy, "~> 1.6"}
  ]
end
```

### Defining a Schema Struct with Saxy.Builder
```elixir
# Source: https://hexdocs.pm/saxy/readme.html
defmodule AgentCom.XML.Schemas.ScanResult do
  @moduledoc "XML schema for improvement scan results (Phase 32)."

  @derive {Saxy.Builder,
    name: "scan-result",
    attributes: [:id, :repo, :scan_type, :timestamp],
    children: [:findings]}

  defstruct [
    :id,
    :repo,
    :scan_type,
    :timestamp,
    :findings  # list of Finding structs
  ]
end

defmodule AgentCom.XML.Schemas.Finding do
  @derive {Saxy.Builder,
    name: "finding",
    attributes: [:severity, :category],
    children: [:file, :description, :suggested_fix]}

  defstruct [:severity, :category, :file, :description, :suggested_fix]
end
```

### Encoding a Struct to XML
```elixir
# Source: https://hexdocs.pm/saxy/readme.html
import Saxy.XML

scan = %AgentCom.XML.Schemas.ScanResult{
  id: "scan-001",
  repo: "https://github.com/user/AgentCom",
  scan_type: "deterministic",
  timestamp: "2026-02-13T10:00:00Z",
  findings: [
    %AgentCom.XML.Schemas.Finding{
      severity: "medium",
      category: "test_gap",
      file: "lib/agent_com/scheduler.ex",
      description: "Module has no corresponding test file",
      suggested_fix: "Create test/agent_com/scheduler_test.exs"
    }
  ]
}

xml = Saxy.encode!(Saxy.Builder.build(scan), [])
# => "<?xml version=\"1.0\"?><scan-result id=\"scan-001\" ...>..."
```

### Parsing XML Back to Struct (SimpleForm)
```elixir
# Source: https://hexdocs.pm/saxy/readme.html
{:ok, simple_form} = Saxy.SimpleForm.parse_string(xml_string)
# simple_form = {"goal", [{"id", "goal-abc"}, {"priority", "high"}], [
#   {"description", [], ["Add rate limiting"]},
#   {"success-criteria", [], [{"criterion", [], ["..."]}]}
# ]}

# Then convert SimpleForm tuple to struct:
defmodule AgentCom.XML.Schemas.Goal do
  # ... struct definition ...

  def from_simple_form({"goal", attrs, children}) do
    %__MODULE__{
      id: find_attr(attrs, "id"),
      priority: find_attr(attrs, "priority"),
      source: find_attr(attrs, "source"),
      status: find_attr(attrs, "status"),
      description: find_child_text(children, "description"),
      success_criteria: find_child_list(children, "success-criteria", "criterion")
    }
  end

  defp find_attr(attrs, name), do: Enum.find_value(attrs, fn {k, v} -> if k == name, do: v end)
  defp find_child_text(children, name) do
    case Enum.find(children, fn {tag, _, _} -> tag == name end) do
      {_, _, [text]} when is_binary(text) -> text
      _ -> nil
    end
  end
  defp find_child_list(children, parent_name, item_name) do
    case Enum.find(children, fn {tag, _, _} -> tag == parent_name end) do
      {_, _, items} -> Enum.flat_map(items, fn
        {^item_name, _, [text]} -> [text]
        _ -> []
      end)
      _ -> []
    end
  end
end
```

### FSM Snapshot Schema Example
```elixir
defmodule AgentCom.XML.Schemas.FsmSnapshot do
  @moduledoc "XML schema for Hub FSM state exports (Phase 29)."

  @derive {Saxy.Builder,
    name: "fsm-snapshot",
    attributes: [:state, :timestamp, :cycle_count, :paused],
    children: [:active_goals, :transition_history]}

  defstruct [
    :state,          # "executing" | "improving" | "contemplating" | "resting"
    :timestamp,      # ISO 8601
    :cycle_count,    # integer as string in XML
    :paused,         # "true" | "false"
    :active_goals,   # list of goal ID strings
    :transition_history  # list of Transition structs
  ]
end
```

### Proposal Schema Example (Phase 33)
```elixir
defmodule AgentCom.XML.Schemas.Proposal do
  @moduledoc "XML schema for feature proposals (Phase 33 Contemplation)."

  @derive {Saxy.Builder,
    name: "proposal",
    attributes: [:id, :timestamp, :estimated_complexity],
    children: [:problem, :solution, :why_now, :why_not, :dependencies, :file_references]}

  defstruct [
    :id,
    :timestamp,
    :estimated_complexity,  # "small" | "medium" | "large"
    :problem,
    :solution,
    :why_now,
    :why_not,
    :dependencies,
    :file_references
  ]
end
```

## Discretion Recommendations

### XML Schema Approach: Convention-Based (NOT XSD)
**Recommendation:** Use convention-based Elixir struct validation. Do NOT use formal XSD schemas.

**Rationale:**
1. These documents are consumed exclusively by AgentCom's own Elixir code -- no external consumers
2. The existing `AgentCom.Validation` module uses pure Elixir pattern matching, not JSON Schema
3. Elixir structs with `@derive Saxy.Builder` ARE the schema definition
4. XSD via `:xmerl_xsd` requires maintaining separate `.xsd` files, adds parse-time complexity, and provides no benefit for internal docs
5. Round-trip tests (encode -> decode -> compare) provide stronger guarantees than XSD validation

### Which Documents Get XML Equivalents
**Recommendation:** Create XML schemas ONLY for documents consumed by downstream phases:

| Document | XML Schema | Consumer Phase | Priority |
|----------|-----------|---------------|----------|
| Goal definition | `goal.ex` | Phase 27 (GoalBacklog), Phase 30 (Decomposition) | HIGH -- needed first |
| Scan result | `scan_result.ex` | Phase 32 (Improvement Scanning) | MEDIUM |
| FSM snapshot | `fsm_snapshot.ex` | Phase 29 (Hub FSM Core) | MEDIUM |
| Improvement finding | `improvement.ex` | Phase 32 (Improvement Scanning) | MEDIUM |
| Feature proposal | `proposal.ex` | Phase 33 (Contemplation) | LOW -- last consumer phase |

Do NOT create XML equivalents for: task queue data (already in DETS maps), WebSocket messages (already JSON), dashboard state (already ETS), verification reports (already JSON maps).

### Naming Conventions
**Recommendation:**
- **Module names:** `AgentCom.XML.Schemas.{GoalName}` (PascalCase, matches Elixir convention)
- **XML element names:** kebab-case (`<scan-result>`, `<fsm-snapshot>`, `<success-criteria>`)
- **XML attribute names:** snake_case (`scan_type`, `cycle_count`) -- matches Elixir field names
- **File paths for stored XML:** `priv/xml/{type}/{id}.xml` (e.g., `priv/xml/proposals/proposal-001.xml`)
- **Schema module files:** `lib/agent_com/xml/schemas/{snake_case}.ex`

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| :xmerl for all XML | Saxy for parsing + encoding | Saxy 1.0 (2019), stabilized 1.6 (2024) | No atom exhaustion risk, 10x+ faster encoding |
| xml_builder for generation | Saxy.Builder protocol | Saxy 1.2+ | Single library for both parse and encode |
| XSD validation for internal docs | Struct-based validation | Elixir community convention | Simpler, no separate schema files, tests cover correctness |
| SweetXml + xpath queries | Saxy SimpleForm | Ongoing trend | Lower memory, no atom exhaustion, adequate for flat docs |

**Deprecated/outdated:**
- `:xmerl_scan.string/1` on untrusted input: known atom exhaustion vulnerability. Use Saxy instead.
- xml_builder for new projects: Saxy.Builder covers the same use case with better performance.

## Open Questions

1. **Custom Saxy.Builder for list children**
   - What we know: `@derive Saxy.Builder` handles simple children well, but list children (like a list of `<criterion>` elements inside `<success-criteria>`) may need custom builder functions
   - What's unclear: Whether `@derive` handles nested struct lists automatically or needs explicit `children: [criteria: &build_criteria/1]` callbacks
   - Recommendation: Implement the Goal schema first as a spike. If `@derive` handles lists of structs natively, use it everywhere. If not, add custom builder functions per the advanced Saxy.Builder example.

2. **XML file storage location**
   - What we know: Proposals (Phase 33) are explicitly written as "XML files in a proposals/ directory"
   - What's unclear: Whether other document types (scan results, FSM snapshots) are persisted to disk or only exist transiently in memory
   - Recommendation: Define the schemas now, let downstream phases decide persistence. Goal specs and proposals get disk persistence (`priv/xml/`); scan results and FSM snapshots may stay in-memory only.

3. **Saxy version compatibility with OTP 28 / Elixir 1.19**
   - What we know: Saxy 1.6.0 was published Oct 2024; the project uses Elixir 1.19.5 / OTP 28
   - What's unclear: Whether Saxy 1.6 has been tested against OTP 28 specifically
   - Recommendation: Add the dependency, run `mix deps.get && mix compile`. If compilation succeeds, compatibility is confirmed. Saxy is pure Elixir with no NIFs, so OTP version compatibility risk is very low.

## Sources

### Primary (HIGH confidence)
- [Saxy v1.6.0 HexDocs](https://hexdocs.pm/saxy/readme.html) - Builder protocol, SimpleForm, encoding API
- [Saxy v1.6.0 Hex.pm](https://hex.pm/packages/saxy) - Version 1.6.0, Oct 2024, 8M+ total downloads
- [Erlang xmerl_xsd docs](https://www.erlang.org/doc/man/xmerl_xsd.html) - XSD validation API for OTP 28

### Secondary (MEDIUM confidence)
- [AppSignal: Faster XML Parsing with Elixir](https://blog.appsignal.com/2022/10/04/faster-xml-parsing-with-elixir.html) - Saxy vs xmerl performance benchmarks (12x faster)
- [Saxy GitHub](https://github.com/qcam/saxy) - Builder protocol examples, advanced usage
- [XmlBuilder v2.4.0 HexDocs](https://hexdocs.pm/xml_builder/XmlBuilder.html) - Alternative considered

### Tertiary (LOW confidence)
- [Elixir Forum: XML atom creation safety](https://elixirforum.com/t/library-to-safely-parse-xml-by-avoiding-random-atom-creation/47493) - Community discussion on xmerl risks

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Saxy is well-established (8M+ downloads), pure Elixir, actively maintained, verified via HexDocs
- Architecture: HIGH - Struct-based pattern matches existing AgentCom conventions; Saxy.Builder protocol verified in official docs
- Pitfalls: HIGH - Atom exhaustion and escaping issues are well-documented; GSD compatibility risk is straightforward to prevent
- Discretion recommendations: MEDIUM - Convention-based vs XSD recommendation is based on project patterns and community convention, not a definitive benchmark

**Research date:** 2026-02-13
**Valid until:** 2026-03-15 (Saxy is stable; XML conventions change slowly)
