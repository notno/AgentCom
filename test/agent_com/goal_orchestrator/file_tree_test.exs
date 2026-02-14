defmodule AgentCom.GoalOrchestrator.FileTreeTest do
  use ExUnit.Case, async: true

  alias AgentCom.GoalOrchestrator.FileTree

  setup do
    # Path.expand normalizes separators on Windows, critical for Path.wildcard
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("file_tree_test_#{System.unique_integer([:positive])}")
      |> Path.expand()

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "gather/1" do
    test "returns relative paths for nested files", %{tmp_dir: tmp_dir} do
      create_file(tmp_dir, "lib/app/server.ex")
      create_file(tmp_dir, "lib/app/client.ex")
      create_file(tmp_dir, "test/app/server_test.exs")

      assert {:ok, files} = FileTree.gather(tmp_dir)

      assert files == [
               "lib/app/client.ex",
               "lib/app/server.ex",
               "test/app/server_test.exs"
             ]
    end

    test "excludes _build, .git, and deps directories", %{tmp_dir: tmp_dir} do
      create_file(tmp_dir, "lib/app.ex")
      create_file(tmp_dir, "_build/dev/app.beam")
      create_file(tmp_dir, ".git/HEAD")
      create_file(tmp_dir, "deps/jason/mix.exs")
      create_file(tmp_dir, "node_modules/pkg/index.js")
      create_file(tmp_dir, ".elixir_ls/build.log")

      assert {:ok, files} = FileTree.gather(tmp_dir)

      assert files == ["lib/app.ex"]
    end

    test "returns error for non-existent path" do
      path = Path.expand("/nonexistent/path/xyz_#{System.unique_integer()}")
      assert {:error, {:not_a_directory, ^path}} = FileTree.gather(path)
    end

    test "returns empty list for empty directory", %{tmp_dir: tmp_dir} do
      assert {:ok, []} = FileTree.gather(tmp_dir)
    end

    test "excludes hidden directories", %{tmp_dir: tmp_dir} do
      create_file(tmp_dir, "lib/app.ex")
      create_file(tmp_dir, ".hidden/secret.txt")

      assert {:ok, files} = FileTree.gather(tmp_dir)

      assert files == ["lib/app.ex"]
    end
  end

  describe "validate_references/2" do
    test "identifies missing files" do
      tasks = [
        %{description: "Update lib/app/server.ex to add endpoint"},
        %{description: "Fix test/app/missing_test.exs"}
      ]

      file_paths = ["lib/app/server.ex", "lib/app/client.ex"]

      {valid, invalid} = FileTree.validate_references(tasks, file_paths)

      assert length(valid) == 1
      assert length(invalid) == 1

      [{_task, missing}] = invalid
      assert "test/app/missing_test.exs" in missing
    end

    test "passes tasks with no file references" do
      tasks = [
        %{description: "Refactor the authentication logic"},
        %{description: "Add better error messages"}
      ]

      {valid, invalid} = FileTree.validate_references(tasks, [])

      assert length(valid) == 2
      assert invalid == []
    end

    test "handles mixed valid and invalid tasks" do
      tasks = [
        %{description: "Update lib/real.ex"},
        %{description: "No file refs here"},
        %{description: "Fix lib/fake.ex and test/fake_test.exs"}
      ]

      file_paths = ["lib/real.ex"]

      {valid, invalid} = FileTree.validate_references(tasks, file_paths)

      assert length(valid) == 2
      assert length(invalid) == 1

      [{task, missing}] = invalid
      assert task.description =~ "fake"
      assert "lib/fake.ex" in missing
      assert "test/fake_test.exs" in missing
    end

    test "all tasks valid when all references exist" do
      tasks = [
        %{description: "Update lib/app.ex and config/config.exs"}
      ]

      file_paths = ["lib/app.ex", "config/config.exs"]

      {valid, invalid} = FileTree.validate_references(tasks, file_paths)

      assert length(valid) == 1
      assert invalid == []
    end
  end

  defp create_file(base, relative_path) do
    full_path = Path.join(base, relative_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, "# placeholder")
  end
end
