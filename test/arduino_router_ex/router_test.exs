defmodule ArduinoRouterEx.RouterTest do
  use ExUnit.Case, async: true

  alias ArduinoRouterEx.{Protocol, Router}

  # A connection standing in for a sketch: it attaches itself, delivers what
  # the test asks for and forwards what the router sends back to the test.
  defp connect(router) do
    test = self()

    pid =
      spawn_link(fn ->
        :ok = Router.attach(router)
        send(test, :attached)
        loop(router, test)
      end)

    assert_receive :attached
    pid
  end

  defp loop(router, test) do
    receive do
      {:deliver, message} ->
        Router.deliver(router, self(), message)

      {:arduino_router_ex_send, iodata} ->
        {messages, <<>>, <<>>} = Protocol.decode(IO.iodata_to_binary(iodata))
        Enum.each(messages, &send(test, {:sent, self(), &1}))
    end

    loop(router, test)
  end

  defp request(connection, id, method, params) do
    send(connection, {:deliver, {:request, id, method, params}})
    assert_receive {:sent, ^connection, {:response, ^id, error, result}}
    {error, result}
  end

  setup do
    {:ok, router} = Router.start_link()
    %{router: router}
  end

  test "a sketch resets, registers a method and Elixir calls it", %{router: router} do
    sketch = connect(router)

    assert request(sketch, 1, "$/reset", []) == {nil, true}
    assert request(sketch, 2, "$/register", ["matrix_draw"]) == {nil, true}
    assert Router.routes(router) == %{"matrix_draw" => sketch}

    call = Task.async(fn -> Router.call(router, "matrix_draw", [[1, 2]]) end)
    assert_receive {:sent, ^sketch, {:request, id, "matrix_draw", [[1, 2]]}}
    send(sketch, {:deliver, {:response, id, nil, true}})

    assert Task.await(call) == {:ok, true}
  end

  test "a sketch calls a method Elixir provides", %{router: router} do
    sketch = connect(router)
    :ok = Router.provide(router, "add", fn [a, b] -> {:ok, a + b} end)

    assert request(sketch, 1, "add", [2, 3]) == {nil, 5}
  end

  test "a sketch calls a method another connection registered", %{router: router} do
    sketch = connect(router)
    app = connect(router)
    assert request(app, 1, "$/register", ["ping"]) == {nil, true}

    send(sketch, {:deliver, {:request, 9, "ping", ["x"]}})
    assert_receive {:sent, ^app, {:request, out_id, "ping", ["x"]}}
    send(app, {:deliver, {:response, out_id, nil, "pong"}})

    assert_receive {:sent, ^sketch, {:response, 9, nil, "pong"}}
  end

  test "await_routes waits for a sketch's registrations", %{router: router} do
    sketch = connect(router)
    waiter = Task.async(fn -> Router.await_routes(router, ["a", "b"], 2_000) end)

    assert request(sketch, 1, "$/register", ["a"]) == {nil, true}
    assert request(sketch, 2, "$/register", ["b"]) == {nil, true}

    assert Task.await(waiter) == :ok
    assert Router.await_routes(router, ["c"], 100) == {:error, :timeout}
  end

  test "unknown methods and duplicate routes are errors", %{router: router} do
    sketch = connect(router)

    assert request(sketch, 1, "nope", []) == {[2, "method nope not available"], nil}
    assert request(sketch, 2, "$/register", ["m"]) == {nil, true}
    assert request(sketch, 3, "$/register", ["m"]) == {[5, "route already exists: m"], nil}
    assert Router.call(router, "nope") == {:error, [2, "method nope not available"]}
  end

  test "routes and pending calls go away with their connection", %{router: router} do
    sketch = connect(router)
    assert request(sketch, 1, "$/register", ["slow"]) == {nil, true}

    call = Task.async(fn -> Router.call(router, "slow") end)
    assert_receive {:sent, ^sketch, {:request, _, "slow", []}}

    Process.unlink(sketch)
    Process.exit(sketch, :kill)

    assert Task.await(call) == {:error, [3, "connection closed"]}
    assert Router.routes(router) == %{}
  end

  test "the monitor carries the sketch's console both ways", %{router: router} do
    sketch = connect(router)

    assert request(sketch, 1, "mon/connected", []) == {nil, false}
    :ok = Router.monitor_subscribe(router)
    assert request(sketch, 2, "mon/connected", []) == {nil, true}

    assert request(sketch, 3, "mon/write", [Msgpax.Bin.new("hello")]) == {nil, 5}
    assert_receive {:arduino_router_ex_monitor, "hello"}

    send(sketch, {:deliver, {:notification, "mon/write", ["notified"]}})
    assert_receive {:arduino_router_ex_monitor, "notified"}

    Router.monitor_write(router, "MATRIX\n")
    assert request(sketch, 4, "mon/read", [3]) == {nil, %Msgpax.Bin{data: "MAT"}}
    assert request(sketch, 5, "mon/read", [64]) == {nil, %Msgpax.Bin{data: "RIX\n"}}
  end
end
