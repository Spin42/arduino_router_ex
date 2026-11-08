defmodule ArduinoRouterEx.FakeIOSketch do
  @moduledoc false
  # A connection standing in for the io sketch: it registers the io/* and
  # matrix/* methods, keeps pin levels, answers I2C transfers to a device at
  # 0x48 that echoes the register written, and notifies io/changed when a
  # watched pin changes.

  alias ArduinoRouterEx.{Protocol, Router}

  @methods ~w(io/pin io/mode io/write io/read io/watch io/analog_read io/i2c matrix/draw)
  @pins %{"D13" => 13, "A0" => 14, "LED1_R" => 61}

  def start(router) do
    test = self()

    pid =
      spawn_link(fn ->
        :ok = Router.attach(router)

        for {method, id} <- Enum.with_index(@methods) do
          Router.deliver(router, self(), {:request, id, "$/register", [method]})
        end

        send(test, :registered)
        loop(router, test, %{levels: %{}, watched: %{}, next_id: 1000})
      end)

    receive do
      :registered -> :ok
    end

    :ok = Router.await_routes(router, @methods, 1_000)
    pid
  end

  defp loop(router, test, state) do
    receive do
      {:arduino_router_ex_send, iodata} ->
        {messages, <<>>, <<>>} = Protocol.decode(IO.iodata_to_binary(iodata))
        state = Enum.reduce(messages, state, &handle(router, test, &1, &2))
        loop(router, test, state)

      {:set_level, pin, value} ->
        loop(router, test, set_level(router, state, pin, value))
    end
  end

  defp handle(router, test, {:request, id, method, params}, state) do
    send(test, {:sketch_called, method, Protocol.plain(params)})
    {result, state} = call(router, method, Protocol.plain(params), state)
    Router.deliver(router, self(), {:response, id, nil, result})
    state
  end

  defp handle(_router, _test, _message, state), do: state

  defp call(_router, "io/pin", [name], state), do: {Map.get(@pins, name, -1), state}
  defp call(_router, "io/mode", [_pin, _mode], state), do: {true, state}

  defp call(router, "io/write", [pin, value], state),
    do: {true, set_level(router, state, pin, value)}

  defp call(_router, "io/read", [pin], state), do: {Map.get(state.levels, pin, 0), state}

  defp call(_router, "io/watch", [pin, mask], state),
    do: {true, put_in(state.watched[pin], mask)}

  defp call(_router, "io/analog_read", [_pin], state), do: {512, state}

  defp call(_router, "io/i2c", [_bus, 0x48, register, count], state),
    do: {[0, Msgpax.Bin.new(String.duplicate(register, count))], state}

  defp call(_router, "io/i2c", [_bus, _address, _data, _count], state),
    do: {[2, Msgpax.Bin.new(<<>>)], state}

  defp call(_router, "matrix/draw", [pixels], state), do: {byte_size(pixels) == 104, state}

  defp set_level(router, state, pin, value) do
    previous = Map.get(state.levels, pin, 0)
    mask = Map.get(state.watched, pin, 0)
    edge = if value == 1, do: 1, else: 2

    if value != previous and Bitwise.band(mask, edge) != 0 do
      Router.deliver(router, self(), {:notification, "io/changed", [pin, value]})
    end

    put_in(state.levels[pin], value)
  end
end
