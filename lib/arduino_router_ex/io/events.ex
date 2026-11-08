defmodule ArduinoRouterEx.IO.Events do
  @moduledoc false
  # Serves io/changed, the io sketch's pin change notifications, and keeps the
  # sketch watching the union of the subscribed edges of each pin.

  use GenServer

  alias ArduinoRouterEx.Router

  @edges %{rising: 1, falling: 2, both: 3}

  @type format :: :raw | {:legacy, term()} | {:map, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :router), name: __MODULE__)
  end

  @doc false
  @spec subscribe(non_neg_integer(), atom(), pid(), format(), term()) ::
          {:ok, reference()} | {:error, term()}
  def subscribe(pin, edges, receiver, format, owner \\ nil)

  def subscribe(pin, edges, receiver, format, owner) when is_map_key(@edges, edges) do
    GenServer.call(
      __MODULE__,
      {:subscribe, pin, Map.fetch!(@edges, edges), receiver, format, owner}
    )
  end

  def subscribe(_pin, _edges, _receiver, _format, _owner), do: {:error, :invalid_edges}

  @doc false
  @spec unsubscribe(reference()) :: :ok
  def unsubscribe(ref), do: GenServer.call(__MODULE__, {:unsubscribe, ref})

  @doc false
  # Drops an owner's subscriptions of one format kind (:legacy or :map), or all.
  @spec unsubscribe_owner(term(), :legacy | :map | :all) :: :ok
  def unsubscribe_owner(owner, kind),
    do: GenServer.call(__MODULE__, {:unsubscribe_owner, owner, kind})

  @impl GenServer
  def init(router) do
    events = self()
    # A restart replaces the handler of the previous instance.
    :ok = Router.unprovide(router, "io/changed")
    :ok = Router.provide(router, "io/changed", fn [pin, value] -> notify(events, pin, value) end)
    {:ok, %{subscriptions: %{}, last: %{}}}
  end

  defp notify(events, pin, value) do
    send(events, {:changed, pin, value})
    {:ok, nil}
  end

  @impl GenServer
  def handle_call({:subscribe, pin, mask, receiver, format, owner}, _from, state) do
    ref = make_ref()
    monitor = Process.monitor(receiver)

    subscription = %{
      pin: pin,
      mask: mask,
      receiver: receiver,
      format: format,
      owner: owner,
      monitor: monitor
    }

    state = put_in(state.subscriptions[ref], subscription)

    case watch(state, pin) do
      :ok ->
        {:reply, {:ok, ref}, state}

      error ->
        Process.demonitor(monitor, [:flush])
        {:reply, error, update_in(state.subscriptions, &Map.delete(&1, ref))}
    end
  end

  def handle_call({:unsubscribe, ref}, _from, state), do: {:reply, :ok, drop(state, ref)}

  def handle_call({:unsubscribe_owner, owner, kind}, _from, state) do
    refs =
      for {ref, %{owner: ^owner} = sub} <- state.subscriptions,
          kind == :all or elem(sub.format, 0) == kind,
          do: ref

    {:reply, :ok, Enum.reduce(refs, state, &drop(&2, &1))}
  end

  @impl GenServer
  def handle_info({:changed, pin, value}, state) do
    previous = Map.get(state.last, pin, 1 - value)
    timestamp = System.monotonic_time(:nanosecond)
    edge = if value == 1, do: 1, else: 2

    for {ref, %{pin: ^pin} = sub} <- state.subscriptions, Bitwise.band(sub.mask, edge) != 0 do
      send(sub.receiver, message(sub.format, ref, pin, value, previous, timestamp))
    end

    {:noreply, put_in(state.last[pin], value)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.subscriptions, fn {_, sub} -> sub.monitor == monitor end) do
      {ref, _} -> {:noreply, drop(state, ref)}
      nil -> {:noreply, state}
    end
  end

  defp message(:raw, _ref, pin, value, _previous, _timestamp),
    do: {:arduino_router_ex_io, pin, value}

  defp message({:legacy, spec}, _ref, _pin, value, _previous, timestamp),
    do: {:circuits_gpio, spec, timestamp, value}

  defp message({:map, tag}, ref, _pin, value, previous, timestamp) do
    {:circuits_gpio,
     %{ref: tag || ref, timestamp: timestamp, value: value, previous_value: previous}}
  end

  defp drop(state, ref) do
    case Map.pop(state.subscriptions, ref) do
      {nil, _} ->
        state

      {sub, subscriptions} ->
        Process.demonitor(sub.monitor, [:flush])
        state = %{state | subscriptions: subscriptions}
        _ = watch(state, sub.pin)
        state
    end
  end

  # Asks the sketch to watch the union of the pin's subscribed edges.
  defp watch(state, pin) do
    mask =
      state.subscriptions
      |> Enum.filter(fn {_, sub} -> sub.pin == pin end)
      |> Enum.reduce(0, fn {_, sub}, acc -> Bitwise.bor(acc, sub.mask) end)

    case ArduinoRouterEx.call("io/watch", [pin, mask]) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :invalid_pin}
      {:error, _} = error -> error
    end
  end
end
