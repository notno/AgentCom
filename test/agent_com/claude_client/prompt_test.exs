defmodule AgentCom.ClaudeClient.PromptTest do
  @moduledoc """
  Unit tests for Prompt.build/2 template output.

  Verifies that each prompt type produces correct XML instruction tags,
  handles missing map keys gracefully, and supports both atom and string keys.

  Stateless -- async: true.
  """

  use ExUnit.Case, async: true

  alias AgentCom.ClaudeClient.Prompt

  # ---------------------------------------------------------------------------
  # :decompose prompts
  # ---------------------------------------------------------------------------

  describe "build(:decompose, params)" do
    test "produces prompt containing <goal> XML tag" do
      prompt =
        Prompt.build(:decompose, %{
          goal: %{title: "Add user model", description: "Create User schema"},
          context: %{repo: "my_app"}
        })

      assert prompt =~ "<goal>"
      assert prompt =~ "</goal>"
    end

    test "contains <tasks> instruction and 'Respond ONLY with the XML'" do
      prompt =
        Prompt.build(:decompose, %{
          goal: %{title: "Test goal"},
          context: %{}
        })

      assert prompt =~ "<tasks>"
      assert prompt =~ "Respond ONLY with the XML"
    end

    test "embeds goal title and description in XML" do
      prompt =
        Prompt.build(:decompose, %{
          goal: %{title: "My Title", description: "My Description"},
          context: %{}
        })

      assert prompt =~ "My Title"
      assert prompt =~ "My Description"
    end

    test "embeds context repo name" do
      prompt =
        Prompt.build(:decompose, %{
          goal: %{title: "Test"},
          context: %{repo: "agent_com", files: ["lib/foo.ex"]}
        })

      assert prompt =~ "agent_com"
      assert prompt =~ "lib/foo.ex"
    end

    test "handles string keys in goal map" do
      prompt =
        Prompt.build(:decompose, %{
          goal: %{"title" => "String Key Goal", "description" => "desc"},
          context: %{}
        })

      assert prompt =~ "String Key Goal"
    end

    test "escapes XML special characters in goal content" do
      prompt =
        Prompt.build(:decompose, %{
          goal: %{title: "Fix <broken> & \"stuff\"", description: "a < b > c"},
          context: %{}
        })

      assert prompt =~ "&lt;broken&gt;"
      assert prompt =~ "&amp;"
      assert prompt =~ "&quot;stuff&quot;"
    end

    test "handles success_criteria as a list" do
      prompt =
        Prompt.build(:decompose, %{
          goal: %{title: "Test", success_criteria: ["crit1", "crit2"]},
          context: %{}
        })

      assert prompt =~ "crit1"
      assert prompt =~ "crit2"
    end
  end

  # ---------------------------------------------------------------------------
  # :verify prompts
  # ---------------------------------------------------------------------------

  describe "build(:verify, params)" do
    test "produces prompt containing <goal> and <verification> instruction" do
      prompt =
        Prompt.build(:verify, %{
          goal: %{title: "Complete feature"},
          results: %{summary: "All tests pass"}
        })

      assert prompt =~ "<goal>"
      assert prompt =~ "<verification>"
      assert prompt =~ "Respond ONLY with the XML"
    end

    test "embeds results summary" do
      prompt =
        Prompt.build(:verify, %{
          goal: %{title: "Test"},
          results: %{summary: "Summary of results", files_modified: ["a.ex", "b.ex"]}
        })

      assert prompt =~ "Summary of results"
      assert prompt =~ "a.ex"
    end

    test "contains verdict instruction (pass/fail)" do
      prompt =
        Prompt.build(:verify, %{
          goal: %{title: "Test"},
          results: %{}
        })

      assert prompt =~ "<verdict>"
      assert prompt =~ "pass"
      assert prompt =~ "fail"
    end
  end

  # ---------------------------------------------------------------------------
  # :identify_improvements prompts
  # ---------------------------------------------------------------------------

  describe "build(:identify_improvements, params)" do
    test "produces prompt containing <repo> and <improvements> instruction" do
      prompt =
        Prompt.build(:identify_improvements, %{
          repo: %{name: "agent_com", description: "Hub app"},
          diff: "diff --git a/lib/foo.ex"
        })

      assert prompt =~ "<repo>"
      assert prompt =~ "<improvements>"
      assert prompt =~ "Respond ONLY with the XML"
    end

    test "embeds diff content" do
      prompt =
        Prompt.build(:identify_improvements, %{
          repo: "my_repo",
          diff: "+  def new_function, do: :ok"
        })

      assert prompt =~ "new_function"
    end

    test "handles repo as a string" do
      prompt =
        Prompt.build(:identify_improvements, %{
          repo: "simple_repo_name",
          diff: "some diff"
        })

      assert prompt =~ "simple_repo_name"
    end

    test "handles repo as a map with name/description/tech_stack" do
      prompt =
        Prompt.build(:identify_improvements, %{
          repo: %{name: "my_app", description: "An app", tech_stack: "Elixir, Phoenix"},
          diff: "diff"
        })

      assert prompt =~ "my_app"
      assert prompt =~ "An app"
      assert prompt =~ "Elixir, Phoenix"
    end
  end

  # ---------------------------------------------------------------------------
  # Graceful handling of missing keys
  # ---------------------------------------------------------------------------

  describe "graceful handling of missing/empty keys" do
    test "decompose with empty goal map does not crash" do
      prompt = Prompt.build(:decompose, %{goal: %{}, context: %{}})
      assert is_binary(prompt)
      assert prompt =~ "<goal>"
    end

    test "verify with empty results map does not crash" do
      prompt = Prompt.build(:verify, %{goal: %{}, results: %{}})
      assert is_binary(prompt)
    end

    test "identify_improvements with nil diff does not crash" do
      prompt = Prompt.build(:identify_improvements, %{repo: %{}, diff: nil})
      assert is_binary(prompt)
    end

    test "decompose with non-map goal does not crash" do
      prompt = Prompt.build(:decompose, %{goal: "just a string", context: nil})
      assert is_binary(prompt)
    end
  end
end
