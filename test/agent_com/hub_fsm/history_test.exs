defmodule AgentCom.HubFSM.HistoryTest do
  @moduledoc """
  Unit tests for HubFSM.History ETS-backed transition history.

  Tests init, record, list, current_state, trim, and clear operations.

  NOT async: true -- ETS named table (:hub_fsm_history) is global.
  """

  use ExUnit.Case, async: false

  alias AgentCom.HubFSM.History

  setup do
    History.init_table()
    History.clear()
    on_exit(fn -> History.clear() end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # init_table/0
  # ---------------------------------------------------------------------------

  describe "init_table/0" do
    test "creates the ETS table" do
      # Table already created in setup; verify it exists
      assert :ets.whereis(:hub_fsm_history) != :undefined
    end

    test "is idempotent -- calling twice does not crash" do
      assert :ok = History.init_table()
      assert :ok = History.init_table()
    end
  end

  # ---------------------------------------------------------------------------
  # record/4
  # ---------------------------------------------------------------------------

  describe "record/4" do
    test "inserts an entry retrievable by list/0" do
      History.record(:resting, :executing, "goals available", 1)

      entries = History.list()
      assert length(entries) == 1

      [entry] = entries
      assert entry.from == :resting
      assert entry.to == :executing
      assert entry.reason == "goals available"
      assert entry.transition_number == 1
      assert is_integer(entry.timestamp)
    end
  end

  # ---------------------------------------------------------------------------
  # list/1
  # ---------------------------------------------------------------------------

  describe "list/1" do
    test "returns entries newest-first" do
      History.record(:resting, :executing, "reason 1", 1)
      Process.sleep(2)
      History.record(:executing, :resting, "reason 2", 2)
      Process.sleep(2)
      History.record(:resting, :executing, "reason 3", 3)

      entries = History.list()
      transition_numbers = Enum.map(entries, & &1.transition_number)

      # Newest first means highest transition number first
      assert transition_numbers == [3, 2, 1]
    end

    test "respects :limit option" do
      for i <- 1..10 do
        History.record(:resting, :executing, "reason #{i}", i)
        Process.sleep(2)
      end

      entries = History.list(limit: 3)
      assert length(entries) == 3

      # Should be the 3 newest
      transition_numbers = Enum.map(entries, & &1.transition_number)
      assert transition_numbers == [10, 9, 8]
    end
  end

  # ---------------------------------------------------------------------------
  # current_state/0
  # ---------------------------------------------------------------------------

  describe "current_state/0" do
    test "returns most recent to state" do
      History.record(:resting, :executing, "started", 1)
      Process.sleep(2)
      History.record(:executing, :resting, "done", 2)

      assert History.current_state() == :resting
    end

    test "returns nil when history is empty" do
      assert History.current_state() == nil
    end
  end

  # ---------------------------------------------------------------------------
  # trim
  # ---------------------------------------------------------------------------

  describe "trim" do
    test "caps history at 200 entries" do
      # Insert 210 entries
      for i <- 1..210 do
        History.record(:resting, :executing, "entry #{i}", i)
      end

      # Trim is called internally by record/4, so check size
      size = :ets.info(:hub_fsm_history, :size)
      assert size == 200
    end
  end

  # ---------------------------------------------------------------------------
  # clear/0
  # ---------------------------------------------------------------------------

  describe "clear/0" do
    test "removes all entries" do
      History.record(:resting, :executing, "test", 1)
      History.record(:executing, :resting, "test", 2)
      assert length(History.list()) == 2

      History.clear()
      assert History.list() == []
    end
  end
end
