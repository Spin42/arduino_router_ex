defmodule ArduinoRouterEx.Sketch do
  @moduledoc """
  Installs and restarts the sketch on the board's microcontroller with the
  board's commands, which the library runs but does not implement.

  The loader the sketch runs on, and links against, belongs to the board's
  system: build the sketch with the Arduino core version the system ships the
  loader of. The `:loader` option flashes another loader, for a board whose
  system does not ship one.

  The commands default to the VENTUNO Q system's `ventuno-q-mcu`; set others
  with the `:command` option or in the application environment:

      config :arduino_router_ex,
        flash_command: ["ventuno-q-mcu", "flash"],
        restart_command: ["ventuno-q-mcu", "start"]

  `install/2` remembers what it flashed in a state file, `:state_file` or
  `config :arduino_router_ex, :sketch_state_file`, so that installing the same
  files again does nothing.
  """

  @default_command ["ventuno-q-mcu", "flash"]
  @default_restart_command ["ventuno-q-mcu", "start"]
  @default_state_file "/data/arduino_router_ex/sketch.sha256"

  @type option ::
          {:loader, Path.t()}
          | {:command, [String.t()]}
          | {:state_file, Path.t()}

  @doc """
  Flashes `sketch` unless the state file says the same files are installed,
  and returns `{:ok, :flashed}` or `{:ok, :unchanged}`.

    * `:loader` - a loader to flash with the sketch, instead of the system's
    * `:command` - the flash command and its leading arguments
    * `:state_file` - where to remember the installed files
  """
  @spec install(Path.t(), [option()]) :: {:ok, :flashed | :unchanged} | {:error, term()}
  def install(sketch, opts \\ []) do
    state_file = Keyword.get(opts, :state_file, state_file())

    with {:ok, digest} <- digest(sketch, opts[:loader]) do
      if File.read(state_file) == {:ok, digest} do
        {:ok, :unchanged}
      else
        with :ok <- flash(sketch, opts),
             :ok <- File.mkdir_p(Path.dirname(state_file)),
             :ok <- File.write(state_file, digest) do
          {:ok, :flashed}
        end
      end
    end
  end

  @doc """
  Flashes `sketch`, and the `:loader` when given, with the flash command.
  """
  @spec flash(Path.t(), [option()]) :: :ok | {:error, term()}
  def flash(sketch, opts \\ []) do
    [command | args] = Keyword.get(opts, :command, command())
    args = args ++ [sketch | List.wrap(opts[:loader])]

    run(command, args)
  end

  defp run(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:command_failed, status, output}}
    end
  rescue
    error in ErlangError -> {:error, {:command_failed, error.original}}
  end

  @doc """
  Restarts the sketch, which then registers its functions with the router
  again. `:command` replaces the restart command.
  """
  @spec restart([{:command, [String.t()]}]) :: :ok | {:error, term()}
  def restart(opts \\ []) do
    [command | args] =
      Keyword.get_lazy(opts, :command, fn ->
        Application.get_env(:arduino_router_ex, :restart_command, @default_restart_command)
      end)

    run(command, args)
  end

  defp digest(sketch, loader) do
    [sketch | List.wrap(loader)]
    |> Enum.reduce_while({:ok, :crypto.hash_init(:sha256)}, fn path, {:ok, hash} ->
      case File.read(path) do
        {:ok, data} -> {:cont, {:ok, :crypto.hash_update(hash, data)}}
        {:error, reason} -> {:halt, {:error, {reason, path}}}
      end
    end)
    |> case do
      {:ok, hash} -> {:ok, Base.encode16(:crypto.hash_final(hash), case: :lower)}
      error -> error
    end
  end

  defp command, do: Application.get_env(:arduino_router_ex, :flash_command, @default_command)

  defp state_file,
    do: Application.get_env(:arduino_router_ex, :sketch_state_file, @default_state_file)
end
