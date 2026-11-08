defmodule ArduinoRouterEx.ProtocolTest do
  use ExUnit.Case, async: true

  alias ArduinoRouterEx.Protocol

  test "round-trips the three message types" do
    messages = [
      {:request, 7, "matrix_draw", [1, "two", [3]]},
      {:response, 7, nil, true},
      {:notification, "$/setMaxMsgSize", [1024]}
    ]

    buffer = messages |> Enum.map(&Protocol.encode/1) |> IO.iodata_to_binary()

    assert Protocol.decode(buffer) == {messages, <<>>, <<>>}
  end

  test "keeps an incomplete message for the next chunk" do
    full = IO.iodata_to_binary(Protocol.encode({:request, 1, "$/reset", []}))
    {head, tail} = String.split_at(full, 3)

    assert Protocol.decode(head) == {[], head, <<>>}
    assert Protocol.decode(head <> tail) == {[{:request, 1, "$/reset", []}], <<>>, <<>>}
  end

  test "keeps MessagePack bin values as Msgpax.Bin" do
    buffer =
      IO.iodata_to_binary(Protocol.encode({:request, 1, "mon/write", [Msgpax.Bin.new("hi")]}))

    assert {[{:request, 1, "mon/write", [%Msgpax.Bin{data: "hi"}]}], <<>>, <<>>} =
             Protocol.decode(buffer)
  end

  test "skips values that are not RPC messages" do
    buffer =
      IO.iodata_to_binary([Msgpax.pack!([9, 9, 9]), Protocol.encode({:notification, "x", []})])

    assert {[{:notification, "x", []}], <<>>, skipped} = Protocol.decode(buffer)
    assert skipped != <<>>
  end

  test "skips text and invalid bytes before a message" do
    reset = IO.iodata_to_binary(Protocol.encode({:request, 1, "$/reset", []}))
    buffer = "MCU starting\r\n" <> <<0xC1>> <> reset

    assert Protocol.decode(buffer) ==
             {[{:request, 1, "$/reset", []}], <<>>, "MCU starting\r\n" <> <<0xC1>>}
  end

  test "plain/1 unwraps bin values at any depth" do
    assert Protocol.plain([%Msgpax.Bin{data: "a"}, %{"k" => %Msgpax.Bin{data: "b"}}]) == [
             "a",
             %{"k" => "b"}
           ]
  end
end
