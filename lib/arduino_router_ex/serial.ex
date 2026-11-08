defmodule ArduinoRouterEx.Serial do
  @moduledoc """
  A connection to an Arduino sketch over a serial port, attached to an
  `ArduinoRouterEx.Router`.

  The port is opened by the `arduino_router_ex_tty` helper, which does not flush
  it: a sketch's Bridge sends its first request as soon as the port is opened,
  and a flush would drop it, leaving the sketch waiting for its answer.

  It waits until the port exists, so it can start before the board's
  microcontroller has enumerated, and exits when the port goes away, which
  takes the sketch's routes and pending calls with it.
  """

  use GenServer

  alias ArduinoRouterEx.{Protocol, Router}

  require Logger

  @retry_ms 100

  @type option ::
          {:router, GenServer.server()}
          | {:port, String.t()}
          | {:speed, pos_integer()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    state = %{
      router: Keyword.fetch!(opts, :router),
      port: Keyword.get(opts, :port, "/dev/ttyACM0"),
      speed: Keyword.get(opts, :speed, 115_200),
      tty: nil,
      buffer: <<>>
    }

    {:ok, state, {:continue, :open}}
  end

  @impl GenServer
  def handle_continue(:open, state), do: {:noreply, open(state)}

  @impl GenServer
  def handle_info(:open, state), do: {:noreply, open(state)}

  def handle_info({tty, {:data, data}}, %{tty: tty} = state) do
    {messages, buffer, skipped} = Protocol.decode(state.buffer <> data)

    if skipped != <<>> do
      Logger.warning(
        "arduino_router_ex: skipped #{byte_size(skipped)} bytes: #{inspect(skipped, limit: 64)}"
      )
    end

    Enum.each(messages, &Router.deliver(state.router, self(), &1))
    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({tty, {:exit_status, status}}, %{tty: tty} = state) do
    Logger.info("arduino_router_ex: #{state.port} closed (#{status})")
    {:stop, {:shutdown, {:serial_closed, status}}, state}
  end

  def handle_info({:arduino_router_ex_send, iodata}, %{tty: tty} = state) when is_port(tty) do
    Port.command(tty, iodata)
    {:noreply, state}
  end

  def handle_info({:arduino_router_ex_send, _iodata}, state), do: {:noreply, state}

  defp open(state) do
    if File.exists?(state.port) do
      tty =
        Port.open({:spawn_executable, helper()}, [
          :binary,
          :stream,
          :exit_status,
          args: [state.port, Integer.to_string(state.speed)]
        ])

      :ok = Router.attach(state.router)
      Logger.info("arduino_router_ex: connected to #{state.port}")
      %{state | tty: tty}
    else
      Process.send_after(self(), :open, @retry_ms)
      state
    end
  end

  defp helper, do: Application.app_dir(:arduino_router_ex, "priv/arduino_router_ex_tty")
end
