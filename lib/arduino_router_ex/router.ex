defmodule ArduinoRouterEx.Router do
  @moduledoc """
  Routes MessagePack-RPC calls between connections and Elixir, as the Arduino
  Router does.

  A connection, such as `ArduinoRouterEx.Serial`, attaches itself, hands every
  message it decodes to `deliver/3` and sends whatever it receives as
  `{:arduino_router_ex_send, iodata}`. A connection registers the methods it
  serves with `$/register`; Elixir registers its own with `provide/3`. A call
  goes to whichever side registered the method.

  The router also answers:

    * `$/register`, `$/unregister`, `$/reset`, `$/setMaxMsgSize` and
      `$/version`;
    * `mon/connected`, `mon/read`, `mon/write` and `mon/reset`, the monitor
      that an Arduino sketch's `Monitor` (its serial console) uses, served to
      the processes that call `monitor_subscribe/1`.

  Errors follow the Arduino Router's `[code, message]` form.
  """

  use GenServer

  alias ArduinoRouterEx.Protocol

  require Logger

  @invalid_params 1
  @method_not_available 2
  @failed_to_send 3
  @generic_error 4
  @route_already_exists 5

  @typedoc "A method's handler: called with the call's params."
  @type handler :: ([term()] -> {:ok, term()} | {:error, term()})

  @type option :: {:name, GenServer.name()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))
  end

  @doc "Attaches the calling process as a connection."
  @spec attach(GenServer.server()) :: :ok
  def attach(router), do: GenServer.call(router, :attach)

  @doc "Hands a decoded message from `connection` to the router."
  @spec deliver(GenServer.server(), pid(), Protocol.message()) :: :ok
  def deliver(router, connection, message),
    do: GenServer.cast(router, {:deliver, connection, message})

  @doc """
  Calls `method` on whichever side registered it and returns its result, or
  `{:error, error}` with the error it returned.
  """
  @spec call(GenServer.server(), String.t(), list(), timeout()) ::
          {:ok, term()} | {:error, term()}
  def call(router, method, params \\ [], timeout \\ 5_000) do
    GenServer.call(router, {:call, method, params}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc "Sends `method` as a notification, without waiting for anything."
  @spec notify(GenServer.server(), String.t(), list()) :: :ok
  def notify(router, method, params \\ []), do: GenServer.cast(router, {:notify, method, params})

  @doc """
  Serves `method` from Elixir. The handler runs in its own process, gets the
  params with MessagePack `bin` values as plain binaries and returns
  `{:ok, result}` or `{:error, error}`.
  """
  @spec provide(GenServer.server(), String.t(), handler()) :: :ok | {:error, term()}
  def provide(router, method, handler) when is_function(handler, 1) do
    GenServer.call(router, {:provide, method, handler})
  end

  @doc "Stops serving `method` from Elixir."
  @spec unprovide(GenServer.server(), String.t()) :: :ok
  def unprovide(router, method), do: GenServer.call(router, {:unprovide, method})

  @doc """
  Subscribes the caller to what the sketch writes to its monitor, received as
  `{:arduino_router_ex_monitor, data}`. The sketch sees the monitor as connected
  while it has a subscriber.
  """
  @spec monitor_subscribe(GenServer.server()) :: :ok
  def monitor_subscribe(router), do: GenServer.call(router, :monitor_subscribe)

  @doc "Queues `data` for the sketch to read from its monitor."
  @spec monitor_write(GenServer.server(), iodata()) :: :ok
  def monitor_write(router, data),
    do: GenServer.cast(router, {:monitor_write, IO.iodata_to_binary(data)})

  @doc "Lists the registered methods and who serves them."
  @spec routes(GenServer.server()) :: %{String.t() => :elixir | pid()}
  def routes(router), do: GenServer.call(router, :routes)

  @doc """
  Waits until `methods` are all registered, as a sketch does when it starts,
  and returns `:ok`, or `{:error, :timeout}` after `timeout` milliseconds.
  """
  @spec await_routes(GenServer.server(), [String.t()], timeout()) :: :ok | {:error, :timeout}
  def await_routes(router, methods, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_routes_until(router, methods, deadline)
  end

  defp await_routes_until(router, methods, deadline) do
    routes = routes(router)

    cond do
      Enum.all?(methods, &Map.has_key?(routes, &1)) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(50)
        await_routes_until(router, methods, deadline)
    end
  end

  @impl GenServer
  def init(:ok) do
    {:ok,
     %{
       # method => {:connection, pid} | {:elixir, handler}
       routes: %{},
       # connection pid => next outgoing message id
       connections: %{},
       # {connection, outgoing id} => {:connection, pid, id} | {:elixir, from}
       pending: %{},
       subscribers: MapSet.new(),
       monitor_input: <<>>
     }}
  end

  @impl GenServer
  def handle_call(:attach, {pid, _}, state) do
    Process.monitor(pid)
    {:reply, :ok, put_in(state.connections[pid], 0)}
  end

  def handle_call({:call, method, params}, from, state) do
    case Map.get(state.routes, method) do
      {:connection, connection} ->
        {:noreply, forward(state, connection, method, params, {:elixir, from})}

      {:elixir, handler} ->
        Task.start(fn -> GenServer.reply(from, run(handler, params)) end)
        {:noreply, state}

      nil ->
        {:reply, {:error, not_available(method)}, state}
    end
  end

  def handle_call({:provide, method, handler}, _from, state) do
    if Map.has_key?(state.routes, method) do
      {:reply, {:error, already_exists(method)}, state}
    else
      {:reply, :ok, put_in(state.routes[method], {:elixir, handler})}
    end
  end

  def handle_call({:unprovide, method}, _from, state) do
    routes =
      case state.routes do
        %{^method => {:elixir, _}} -> Map.delete(state.routes, method)
        routes -> routes
      end

    {:reply, :ok, %{state | routes: routes}}
  end

  def handle_call(:monitor_subscribe, {pid, _}, state) do
    Process.monitor(pid)
    {:reply, :ok, update_in(state.subscribers, &MapSet.put(&1, pid))}
  end

  def handle_call(:routes, _from, state) do
    routes =
      Map.new(state.routes, fn
        {method, {:connection, pid}} -> {method, pid}
        {method, {:elixir, _}} -> {method, :elixir}
      end)

    {:reply, routes, state}
  end

  @impl GenServer
  def handle_cast({:deliver, connection, message}, state) do
    {:noreply, handle_message(state, connection, message)}
  end

  def handle_cast({:notify, method, params}, state) do
    case Map.get(state.routes, method) do
      {:connection, connection} -> transmit(connection, {:notification, method, params})
      {:elixir, handler} -> Task.start(fn -> run(handler, params) end)
      nil -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:monitor_write, data}, state) do
    {:noreply, %{state | monitor_input: state.monitor_input <> data}}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    cond do
      Map.has_key?(state.connections, pid) ->
        {:noreply, detach(state, pid)}

      MapSet.member?(state.subscribers, pid) ->
        {:noreply, update_in(state.subscribers, &MapSet.delete(&1, pid))}

      true ->
        {:noreply, state}
    end
  end

  defp handle_message(state, connection, {:request, id, method, params}) do
    case builtin(state, connection, method, params) do
      {:reply, state, result, error} ->
        transmit(connection, {:response, id, error, result})
        state

      :route ->
        route_request(state, connection, id, method, params)
    end
  end

  defp handle_message(state, connection, {:response, id, error, result}) do
    case Map.pop(state.pending, {connection, id}) do
      {nil, _} ->
        Logger.warning("arduino_router_ex: response to unknown request #{id}")
        state

      {origin, pending} ->
        answer(origin, error, result)
        %{state | pending: pending}
    end
  end

  # The router's own methods also come as notifications: a sketch talking to
  # a router that answers $/version sends mon/write that way.
  defp handle_message(state, connection, {:notification, method, params}) do
    case builtin(state, connection, method, params) do
      {:reply, state, _result, _error} ->
        state

      :route ->
        case Map.get(state.routes, method) do
          {:connection, ^connection} -> :ok
          {:connection, other} -> transmit(other, {:notification, method, params})
          {:elixir, handler} -> Task.start(fn -> run(handler, params) end)
          nil -> :ok
        end

        state
    end
  end

  defp route_request(state, connection, id, method, params) do
    case Map.get(state.routes, method) do
      {:connection, target} ->
        forward(state, target, method, params, {:connection, connection, id})

      {:elixir, handler} ->
        Task.start(fn ->
          case run(handler, params) do
            {:ok, result} -> transmit(connection, {:response, id, nil, result})
            {:error, error} -> transmit(connection, {:response, id, error, nil})
          end
        end)

        state

      nil ->
        transmit(connection, {:response, id, not_available(method), nil})
        state
    end
  end

  defp builtin(state, connection, "$/register", [method]) do
    case text(method) do
      {:ok, method} ->
        if Map.has_key?(state.routes, method) do
          {:reply, state, nil, already_exists(method)}
        else
          Logger.debug("arduino_router_ex: #{inspect(connection)} registered #{method}")
          {:reply, put_in(state.routes[method], {:connection, connection}), true, nil}
        end

      :error ->
        {:reply, state, nil, [@invalid_params, "invalid params: expected a method name"]}
    end
  end

  defp builtin(state, connection, "$/unregister", [method]) do
    method = with {:ok, text} <- text(method), do: text

    case Map.get(state.routes, method) do
      {:connection, ^connection} ->
        {:reply, %{state | routes: Map.delete(state.routes, method)}, true, nil}

      _ ->
        {:reply, state, nil,
         [@generic_error, "route not registered by this client: #{inspect(method)}"]}
    end
  end

  defp builtin(state, connection, "$/reset", []) do
    Logger.info("arduino_router_ex: #{inspect(connection)} reset its routes")
    {:reply, drop_routes(state, connection), true, nil}
  end

  defp builtin(state, _connection, "$/setMaxMsgSize", [_size]), do: {:reply, state, true, nil}

  defp builtin(state, _connection, "$/version", []) do
    {:reply, state, "arduino_router_ex #{Application.spec(:arduino_router_ex, :vsn)}", nil}
  end

  defp builtin(state, _connection, "mon/connected", []) do
    {:reply, state, MapSet.size(state.subscribers) > 0, nil}
  end

  defp builtin(state, _connection, "mon/read", [max]) when is_integer(max) and max >= 0 do
    take = min(max, byte_size(state.monitor_input))
    <<data::binary-size(^take), rest::binary>> = state.monitor_input
    {:reply, %{state | monitor_input: rest}, Msgpax.Bin.new(data), nil}
  end

  defp builtin(state, _connection, "mon/write", [data]) do
    data = Protocol.plain(data)

    if is_binary(data) do
      Enum.each(state.subscribers, &send(&1, {:arduino_router_ex_monitor, data}))
      {:reply, state, byte_size(data), nil}
    else
      {:reply, state, nil, [@invalid_params, "invalid params: expected data to write"]}
    end
  end

  defp builtin(state, _connection, "mon/reset", []) do
    {:reply, %{state | monitor_input: <<>>}, true, nil}
  end

  defp builtin(state, _connection, method, _params)
       when method in ~w($/register $/unregister $/reset $/setMaxMsgSize $/version
                         mon/connected mon/read mon/write mon/reset) do
    {:reply, state, nil, [@invalid_params, "invalid params for #{method}"]}
  end

  defp builtin(_state, _connection, _method, _params), do: :route

  defp forward(state, target, method, params, origin) do
    id = Map.fetch!(state.connections, target)
    transmit(target, {:request, id, method, params})

    %{
      state
      | connections: Map.put(state.connections, target, rem(id + 1, 0x1_0000_0000)),
        pending: Map.put(state.pending, {target, id}, origin)
    }
  end

  defp answer({:elixir, from}, nil, result),
    do: GenServer.reply(from, {:ok, Protocol.plain(result)})

  defp answer({:elixir, from}, error, _result),
    do: GenServer.reply(from, {:error, Protocol.plain(error)})

  defp answer({:connection, connection, id}, error, result) do
    transmit(connection, {:response, id, error, result})
  end

  defp detach(state, connection) do
    {lost, pending} =
      Map.split_with(state.pending, fn {{target, _}, _} -> target == connection end)

    Enum.each(lost, fn {_, origin} ->
      answer(origin, [@failed_to_send, "connection closed"], nil)
    end)

    state = %{state | pending: pending, connections: Map.delete(state.connections, connection)}
    drop_routes(state, connection)
  end

  defp drop_routes(state, connection) do
    routes = Map.reject(state.routes, fn {_, route} -> route == {:connection, connection} end)
    %{state | routes: routes}
  end

  defp run(handler, params) do
    case handler.(Protocol.plain(params)) do
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      other -> {:error, [@generic_error, "handler returned #{inspect(other)}"]}
    end
  rescue
    exception -> {:error, [@generic_error, Exception.message(exception)]}
  end

  defp transmit(connection, message),
    do: send(connection, {:arduino_router_ex_send, Protocol.encode(message)})

  defp text(value) when is_binary(value), do: {:ok, value}
  defp text(%Msgpax.Bin{data: data}), do: {:ok, data}
  defp text(_), do: :error

  defp not_available(method), do: [@method_not_available, "method #{method} not available"]
  defp already_exists(method), do: [@route_already_exists, "route already exists: #{method}"]
end
