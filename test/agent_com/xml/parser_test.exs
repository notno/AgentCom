defmodule AgentCom.XML.ParserTest do
  use ExUnit.Case, async: true

  alias AgentCom.XML.Parser

  describe "find_attr/2" do
    test "returns value for existing attribute" do
      attrs = [{"id", "g-001"}, {"priority", "high"}]
      assert Parser.find_attr(attrs, "id") == "g-001"
      assert Parser.find_attr(attrs, "priority") == "high"
    end

    test "returns nil for missing attribute" do
      attrs = [{"id", "g-001"}]
      assert Parser.find_attr(attrs, "missing") == nil
    end

    test "returns nil for empty attribute list" do
      assert Parser.find_attr([], "anything") == nil
    end
  end

  describe "find_child_text/2" do
    test "returns text content of named child" do
      children = [{"title", [], ["My Goal"]}, {"description", [], ["A description"]}]
      assert Parser.find_child_text(children, "title") == "My Goal"
      assert Parser.find_child_text(children, "description") == "A description"
    end

    test "returns nil for missing child element" do
      children = [{"title", [], ["My Goal"]}]
      assert Parser.find_child_text(children, "missing") == nil
    end

    test "returns nil when child has no text content" do
      children = [{"empty", [], []}]
      assert Parser.find_child_text(children, "empty") == nil
    end

    test "returns nil for empty children list" do
      assert Parser.find_child_text([], "anything") == nil
    end
  end

  describe "find_child_list/3" do
    test "returns list of text values from repeated child elements" do
      children = [
        {"success-criteria", [], [
          {"criterion", [], ["First"]},
          {"criterion", [], ["Second"]},
          {"criterion", [], ["Third"]}
        ]}
      ]

      result = Parser.find_child_list(children, "success-criteria", "criterion")
      assert result == ["First", "Second", "Third"]
    end

    test "returns empty list when parent not found" do
      children = [{"other", [], []}]
      assert Parser.find_child_list(children, "success-criteria", "criterion") == []
    end

    test "returns empty list when parent has no matching items" do
      children = [{"success-criteria", [], [{"other", [], ["Nope"]}]}]
      assert Parser.find_child_list(children, "success-criteria", "criterion") == []
    end

    test "returns empty list for empty children" do
      assert Parser.find_child_list([], "parent", "item") == []
    end
  end

  describe "find_child_map_list/3" do
    test "returns list of attribute maps from repeated child elements" do
      children = [
        {"transition-history", [], [
          {"transition", [{"from", "resting"}, {"to", "executing"}, {"at", "2026-01-01T00:00:00Z"}], []},
          {"transition", [{"from", "executing"}, {"to", "improving"}, {"at", "2026-01-01T00:30:00Z"}], []}
        ]}
      ]

      result = Parser.find_child_map_list(children, "transition-history", "transition")

      assert length(result) == 2
      [first, second] = result
      assert first["from"] == "resting"
      assert first["to"] == "executing"
      assert second["from"] == "executing"
      assert second["to"] == "improving"
    end

    test "returns empty list when parent not found" do
      assert Parser.find_child_map_list([], "transitions", "transition") == []
    end
  end

  describe "kebab_to_snake_atom/1" do
    test "converts kebab-case to snake_case atom" do
      assert Parser.kebab_to_snake_atom("scan-result") == :scan_result
      assert Parser.kebab_to_snake_atom("fsm-snapshot") == :fsm_snapshot
    end

    test "passes through non-hyphenated strings" do
      assert Parser.kebab_to_snake_atom("goal") == :goal
    end
  end

  describe "snake_to_kebab/1" do
    test "converts snake_case to kebab-case" do
      assert Parser.snake_to_kebab("scan_result") == "scan-result"
      assert Parser.snake_to_kebab("fsm_snapshot") == "fsm-snapshot"
    end

    test "passes through non-underscored strings" do
      assert Parser.snake_to_kebab("goal") == "goal"
    end
  end
end
