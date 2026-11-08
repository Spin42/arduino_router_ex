defmodule ArduinoRouterEx do
  @moduledoc """
  The Arduino Router in Elixir: the Linux side of the Bridge between an Arduino
  sketch and the applications on the board, as on the Arduino UNO Q and
  VENTUNO Q.

  A sketch built with Arduino's `Arduino_RouterBridge` library exposes
  functions with `Bridge.provide/2`, calls Linux with `Bridge.call/2` and
  writes to its `Monitor`. Add the router to your supervision tree:

      children = [{ArduinoRouterEx, port: "/dev/ttyACM0"}]

  then call the sketch and serve it from Elixir:

      ArduinoRouterEx.call("matrix_draw", [frame])
      ArduinoRouterEx.provide("linux_time", fn [] -> {:ok, System.os_time(:second)} end)

  See `ArduinoRouterEx.Router` for the protocol.
  """

  use Supervisor

  alias ArduinoRouterEx.{Router, Serial}

  @router ArduinoRouterEx.Router

  @type option :: {:port, String.t()} | {:speed, pos_integer()}

  @doc """
  Starts the router and its serial connection to the sketch.

    * `:port` - the sketch's serial port, `"/dev/ttyACM0"` by default
    * `:speed` - the baud rate, `115_200` by default
  """
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(opts) do
    children = [
      {Router, name: @router},
      {Serial, Keyword.put(opts, :router, @router)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Calls `method` on the sketch, or on whoever registered it. See `ArduinoRouterEx.Router.call/4`."
  @spec call(String.t(), list(), timeout()) :: {:ok, term()} | {:error, term()}
  def call(method, params \\ [], timeout \\ 5_000),
    do: Router.call(@router, method, params, timeout)

  @doc "Sends `method` as a notification."
  @spec notify(String.t(), list()) :: :ok
  def notify(method, params \\ []), do: Router.notify(@router, method, params)

  @doc "Serves `method` from Elixir. See `ArduinoRouterEx.Router.provide/3`."
  @spec provide(String.t(), Router.handler()) :: :ok | {:error, term()}
  def provide(method, handler), do: Router.provide(@router, method, handler)

  @doc "Stops serving `method` from Elixir."
  @spec unprovide(String.t()) :: :ok
  def unprovide(method), do: Router.unprovide(@router, method)

  @doc """
  Waits until the sketch has registered `methods`. See
  `ArduinoRouterEx.Router.await_routes/3`.
  """
  @spec await_routes([String.t()], timeout()) :: :ok | {:error, :timeout}
  def await_routes(methods, timeout \\ 10_000), do: Router.await_routes(@router, methods, timeout)

  @doc "Lists the registered methods and who serves them."
  @spec routes() :: %{String.t() => :elixir | pid()}
  def routes, do: Router.routes(@router)

  @doc """
  Subscribes the caller to the sketch's monitor output, received as
  `{:arduino_router_ex_monitor, data}`.
  """
  @spec monitor_subscribe() :: :ok
  def monitor_subscribe, do: Router.monitor_subscribe(@router)

  @doc "Sends `data` to the sketch's monitor input."
  @spec monitor_write(iodata()) :: :ok
  def monitor_write(data), do: Router.monitor_write(@router, data)
end
