defmodule AgentCom.MailboxTest do
  use ExUnit.Case, async: false

  alias AgentCom.{Mailbox, Message}
  alias AgentCom.TestHelpers.DetsHelpers

  setup do
    tmp_dir = DetsHelpers.full_test_setup()
    # Stop Scheduler to prevent interference
    Supervisor.terminate_child(AgentCom.Supervisor, AgentCom.Scheduler)
    on_exit(fn ->
      Supervisor.restart_child(AgentCom.Supervisor, AgentCom.Scheduler)
      DetsHelpers.full_test_teardown(tmp_dir)
    end)
    {:ok, tmp_dir: tmp_dir}
  end

  defp make_msg(from, to) do
    Message.new(%{from: from, to: to, type: "chat", payload: %{"text" => "hello"}})
  end

  describe "enqueue/2" do
    test "stores a message for an agent and returns {:ok, seq}" do
      msg = make_msg("sender", "mailbox-agent")
      assert {:ok, seq} = Mailbox.enqueue("mailbox-agent", msg)
      assert is_integer(seq) and seq > 0
    end
  end

  describe "poll/2" do
    test "returns stored messages with sequence numbers" do
      msg1 = make_msg("sender", "poll-agent")
      msg2 = make_msg("sender2", "poll-agent")
      {:ok, _} = Mailbox.enqueue("poll-agent", msg1)
      {:ok, _} = Mailbox.enqueue("poll-agent", msg2)

      {messages, last_seq} = Mailbox.poll("poll-agent", 0)
      assert length(messages) == 2
      assert is_integer(last_seq) and last_seq > 0

      # Messages should have seq fields and be ordered
      seqs = Enum.map(messages, & &1.seq)
      assert seqs == Enum.sort(seqs)
    end

    test "empty mailbox returns empty list" do
      {messages, seq} = Mailbox.poll("empty-agent", 0)
      assert messages == []
      assert seq == 0
    end
  end

  describe "ack/2" do
    test "removes acknowledged messages" do
      msg1 = make_msg("sender", "ack-agent")
      msg2 = make_msg("sender", "ack-agent")
      {:ok, seq1} = Mailbox.enqueue("ack-agent", msg1)
      {:ok, seq2} = Mailbox.enqueue("ack-agent", msg2)

      # Ack up to first message
      Mailbox.ack("ack-agent", seq1)
      # ack is a cast, give it a moment
      Process.sleep(50)

      {messages, _} = Mailbox.poll("ack-agent", 0)
      remaining_seqs = Enum.map(messages, & &1.seq)
      refute seq1 in remaining_seqs
      assert seq2 in remaining_seqs
    end

    test "poll after ack returns only unacknowledged messages" do
      msg1 = make_msg("a", "ack-poll-agent")
      msg2 = make_msg("b", "ack-poll-agent")
      msg3 = make_msg("c", "ack-poll-agent")
      {:ok, seq1} = Mailbox.enqueue("ack-poll-agent", msg1)
      {:ok, _seq2} = Mailbox.enqueue("ack-poll-agent", msg2)
      {:ok, _seq3} = Mailbox.enqueue("ack-poll-agent", msg3)

      # Ack the first message
      Mailbox.ack("ack-poll-agent", seq1)
      Process.sleep(50)

      {messages, _} = Mailbox.poll("ack-poll-agent", 0)
      assert length(messages) == 2
    end
  end
end
