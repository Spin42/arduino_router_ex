defmodule ArduinoRouterEx.SketchTest do
  use ExUnit.Case, async: true

  alias ArduinoRouterEx.Sketch

  @moduletag :tmp_dir

  # A flash command that records its arguments, or fails.
  defp fake_command(dir, status) do
    path = Path.join(dir, "flash")
    File.write!(path, "#!/bin/sh\necho \"$@\" >> #{dir}/calls\nexit #{status}\n")
    File.chmod!(path, 0o755)
    [path]
  end

  defp calls(dir) do
    case File.read(Path.join(dir, "calls")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  setup %{tmp_dir: dir} do
    sketch = Path.join(dir, "sketch.bin")
    loader = Path.join(dir, "loader.bin")
    File.write!(sketch, "sketch v1")
    File.write!(loader, "loader")
    %{sketch: sketch, loader: loader, state_file: Path.join(dir, "state/sketch.sha256")}
  end

  test "flashes once, then skips the same files", %{tmp_dir: dir} = ctx do
    opts = [loader: ctx.loader, command: fake_command(dir, 0), state_file: ctx.state_file]

    assert Sketch.install(ctx.sketch, opts) == {:ok, :flashed}
    assert Sketch.install(ctx.sketch, opts) == {:ok, :unchanged}
    assert calls(dir) == ["#{ctx.sketch} #{ctx.loader}"]
  end

  test "flashes again when the sketch changes", %{tmp_dir: dir} = ctx do
    opts = [command: fake_command(dir, 0), state_file: ctx.state_file]

    assert Sketch.install(ctx.sketch, opts) == {:ok, :flashed}
    File.write!(ctx.sketch, "sketch v2")
    assert Sketch.install(ctx.sketch, opts) == {:ok, :flashed}
    assert length(calls(dir)) == 2
  end

  test "a failed flash is an error and is not remembered", %{tmp_dir: dir} = ctx do
    opts = [command: fake_command(dir, 1), state_file: ctx.state_file]

    assert {:error, {:command_failed, 1, _}} = Sketch.install(ctx.sketch, opts)
    refute File.exists?(ctx.state_file)
  end

  test "a missing sketch is an error", %{tmp_dir: dir} = ctx do
    opts = [command: fake_command(dir, 0), state_file: ctx.state_file]

    assert {:error, {:enoent, _}} = Sketch.install(Path.join(dir, "missing.bin"), opts)
    assert calls(dir) == []
  end

  test "restart runs the restart command", %{tmp_dir: dir} do
    assert Sketch.restart(command: fake_command(dir, 0) ++ ["start"]) == :ok
    assert calls(dir) == ["start"]
    assert {:error, {:command_failed, 1, _}} = Sketch.restart(command: fake_command(dir, 1))
  end
end
