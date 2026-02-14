defmodule AgentCom.WebhookHistoryTest do
  @moduledoc """
  Unit tests for WebhookHistory ETS-backed event storage.

  Covers record/list, ordering, limit, cap at 100, and clear.

  async: false -- shared ETS table.
  """

  use ExUnit.Case, async: false

  alias AgentCom.WebhookHistory

  setup do
    WebhookHistory.init_table()
    WebhookHistory.clear()

    on_exit(fn ->
      WebhookHistory.clear()
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "record and list" do
    test "records an event and lists it back with expected fields" do
      :ok = WebhookHistory.record(%{
        event_type: "push",
        repo: "owner/repo",
        ref: "refs/heads/main",
        delivery_id: "test-delivery-1",
        action: "accepted"
      })

      events = WebhookHistory.list()
      assert length(events) == 1

      event = hd(events)
      assert event.event_type == "push"
      assert event.repo == "owner/repo"
      assert event.ref == "refs/heads/main"
      assert event.delivery_id == "test-delivery-1"
      assert event.action == "accepted"
      assert is_integer(event.timestamp)
    end
  end

  describe "ordering" do
    test "returns events in newest-first order" do
      :ok = WebhookHistory.record(%{event_type: "push", seq: 1})
      Process.sleep(2)
      :ok = WebhookHistory.record(%{event_type: "push", seq: 2})
      Process.sleep(2)
      :ok = WebhookHistory.record(%{event_type: "push", seq: 3})

      events = WebhookHistory.list()
      assert length(events) == 3

      sequences = Enum.map(events, & &1.seq)
      assert sequences == [3, 2, 1]
    end
  end

  describe "limit" do
    test "respects limit parameter" do
      for i <- 1..5 do
        :ok = WebhookHistory.record(%{event_type: "push", seq: i})
        Process.sleep(2)
      end

      events = WebhookHistory.list(limit: 2)
      assert length(events) == 2
    end
  end

  describe "cap at 100" do
    test "trims entries beyond 100" do
      for i <- 1..105 do
        :ok = WebhookHistory.record(%{event_type: "push", seq: i})
      end

      events = WebhookHistory.list(limit: 200)
      assert length(events) == 100
    end
  end

  describe "clear" do
    test "removes all events" do
      :ok = WebhookHistory.record(%{event_type: "push"})
      :ok = WebhookHistory.record(%{event_type: "push"})
      assert length(WebhookHistory.list()) == 2

      :ok = WebhookHistory.clear()
      assert WebhookHistory.list() == []
    end
  end
end
