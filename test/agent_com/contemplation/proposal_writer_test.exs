defmodule AgentCom.Contemplation.ProposalWriterTest do
  use ExUnit.Case, async: true

  alias AgentCom.Contemplation.ProposalWriter
  alias AgentCom.XML.Schemas.Proposal

  setup do
    # Use System.tmp_dir with unique suffix for test isolation
    dir = Path.join([System.tmp_dir!(), "proposal_writer_test_#{System.unique_integer([:positive])}"])
    on_cleanup = fn -> File.rm_rf!(dir) end

    on_exit(on_cleanup)
    {:ok, dir: dir}
  end

  defp make_proposal(id, title) do
    {:ok, p} = Proposal.new(%{
      id: id,
      title: title,
      description: "Test description for #{title}",
      problem: "Test problem",
      solution: "Test solution",
      impact: "medium",
      effort: "small"
    })
    p
  end

  describe "write_proposals/2" do
    test "writes proposals as XML files", %{dir: dir} do
      proposals = [make_proposal("p1", "First"), make_proposal("p2", "Second")]
      assert {:ok, paths} = ProposalWriter.write_proposals(proposals, dir: dir)
      assert length(paths) == 2
      Enum.each(paths, fn path ->
        assert File.exists?(path)
        content = File.read!(path)
        assert content =~ "<proposal"
        assert content =~ "</proposal>"
      end)
    end

    test "enforces max 3 proposals per cycle", %{dir: dir} do
      proposals = for i <- 1..5, do: make_proposal("p#{i}", "Proposal #{i}")
      assert {:ok, paths} = ProposalWriter.write_proposals(proposals, dir: dir)
      assert length(paths) == 3
    end

    test "creates directory if it does not exist", %{dir: dir} do
      nested = Path.join(dir, "nested/deep")
      proposals = [make_proposal("p1", "One")]
      assert {:ok, [path]} = ProposalWriter.write_proposals(proposals, dir: nested)
      assert File.exists?(path)
    end

    test "empty list writes zero files", %{dir: dir} do
      assert {:ok, []} = ProposalWriter.write_proposals([], dir: dir)
    end
  end

  describe "max_per_cycle/0" do
    test "returns 3" do
      assert ProposalWriter.max_per_cycle() == 3
    end
  end
end
