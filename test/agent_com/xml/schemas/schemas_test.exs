defmodule AgentCom.XML.Schemas.SchemasTest do
  use ExUnit.Case, async: true

  alias AgentCom.XML
  alias AgentCom.XML.Schemas.{Goal, ScanResult, FsmSnapshot, Improvement, Proposal}

  describe "schema_types/0 lists all 5 types" do
    test "contains exactly the 5 expected types" do
      types = XML.schema_types()
      assert Enum.sort(types) == Enum.sort([:goal, :scan_result, :fsm_snapshot, :improvement, :proposal])
    end
  end

  describe "all schema types encode and decode" do
    @schemas [
      {:goal, %Goal{id: "g-all", title: "All schemas test", priority: "normal"}},
      {:scan_result, %ScanResult{id: "sr-all", repo: "Test", description: "All schemas", severity: "medium"}},
      {:fsm_snapshot, %FsmSnapshot{state: "resting", since: "2026-01-01T00:00:00Z", snapshot_at: "2026-01-01T01:00:00Z"}},
      {:improvement, %Improvement{id: "imp-all", repo: "Test", description: "All schemas", status: "identified"}},
      {:proposal, %Proposal{id: "prop-all", title: "All schemas", description: "Test all"}}
    ]

    for {type, struct} <- @schemas do
      test "#{type} encodes and decodes without error" do
        struct = unquote(Macro.escape(struct))
        type = unquote(type)

        assert {:ok, xml} = XML.encode(struct)
        assert is_binary(xml)
        assert {:ok, decoded} = XML.decode(xml, type)
        assert decoded.__struct__ == struct.__struct__
      end
    end
  end

  describe "new/1 exists on all schema modules" do
    test "Goal.new/1 exists and returns ok/error tuple" do
      assert {:ok, _} = Goal.new(%{id: "g-1", title: "T"})
      assert {:error, _} = Goal.new(%{})
    end

    test "ScanResult.new/1 exists and returns ok/error tuple" do
      assert {:ok, _} = ScanResult.new(%{id: "sr-1", repo: "R", description: "D"})
      assert {:error, _} = ScanResult.new(%{})
    end

    test "FsmSnapshot.new/1 exists and returns ok/error tuple" do
      assert {:ok, _} = FsmSnapshot.new(%{state: "resting", since: "2026-01-01T00:00:00Z", snapshot_at: "2026-01-01T01:00:00Z"})
      assert {:error, _} = FsmSnapshot.new(%{})
    end

    test "Improvement.new/1 exists and returns ok/error tuple" do
      assert {:ok, _} = Improvement.new(%{id: "imp-1", repo: "R", description: "D"})
      assert {:error, _} = Improvement.new(%{})
    end

    test "Proposal.new/1 exists and returns ok/error tuple" do
      assert {:ok, _} = Proposal.new(%{id: "prop-1", title: "T", description: "D"})
      assert {:error, _} = Proposal.new(%{})
    end
  end

  describe "Saxy.Builder protocol implemented for all types" do
    test "all schema structs implement Saxy.Builder" do
      structs = [
        %Goal{id: "g-proto", title: "T"},
        %ScanResult{id: "sr-proto", repo: "R", description: "D"},
        %FsmSnapshot{state: "resting", since: "now", snapshot_at: "now"},
        %Improvement{id: "imp-proto", repo: "R", description: "D"},
        %Proposal{id: "prop-proto", title: "T", description: "D"}
      ]

      for struct <- structs do
        simple_form = Saxy.Builder.build(struct)
        assert is_tuple(simple_form), "#{inspect(struct.__struct__)} should build to a tuple"
      end
    end
  end
end
