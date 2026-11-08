defmodule ArduinoRouterEx.Protocol do
  @moduledoc """
  MessagePack-RPC messages as the Arduino Router exchanges them: a stream of
  MessagePack arrays with no other framing.

    * request: `[0, id, method, params]`
    * response: `[1, id, error, result]`
    * notification: `[2, method, params]`

  Binaries decode to Elixir binaries, except MessagePack `bin` values, which
  decode to `Msgpax.Bin` structs so that forwarding them keeps their type.
  """

  @type id :: non_neg_integer()
  @type message ::
          {:request, id(), String.t(), list()}
          | {:response, id(), term(), term()}
          | {:notification, String.t(), list()}

  @doc "Encodes a message."
  @spec encode(message()) :: iodata()
  def encode({:request, id, method, params}), do: Msgpax.pack!([0, id, method, params])
  def encode({:response, id, error, result}), do: Msgpax.pack!([1, id, error, result])
  def encode({:notification, method, params}), do: Msgpax.pack!([2, method, params])

  @doc """
  Decodes the complete messages at the start of `buffer` and returns them with
  the bytes left over and the bytes skipped.

  Every message is a MessagePack array of three or four elements, so decoding
  starts only at a fixarray header of that size: other bytes, such as text a
  sketch writes before starting its Bridge, are skipped one at a time, and so
  are values that are not RPC messages.
  """
  @spec decode(binary()) :: {[message()], binary(), binary()}
  def decode(buffer), do: decode(buffer, [], <<>>)

  defp decode(<<header, _::binary>> = buffer, acc, skipped) when header in [0x93, 0x94] do
    case Msgpax.unpack_slice(buffer, binary: true) do
      {:ok, term, rest} ->
        case message(term) do
          {:ok, message} -> decode(rest, [message | acc], skipped)
          :error -> skip(buffer, acc, skipped)
        end

      {:error, %Msgpax.UnpackError{reason: {:incomplete, _}}} ->
        {Enum.reverse(acc), buffer, skipped}

      {:error, %Msgpax.UnpackError{reason: :incomplete}} ->
        {Enum.reverse(acc), buffer, skipped}

      {:error, _} ->
        skip(buffer, acc, skipped)
    end
  end

  defp decode(<<>>, acc, skipped), do: {Enum.reverse(acc), <<>>, skipped}
  defp decode(buffer, acc, skipped), do: skip(buffer, acc, skipped)

  defp skip(<<byte, rest::binary>>, acc, skipped),
    do: decode(rest, acc, <<skipped::binary, byte>>)

  defp message([0, id, method, params]) when is_integer(id) and is_list(params) do
    with {:ok, method} <- text(method), do: {:ok, {:request, id, method, params}}
  end

  defp message([1, id, error, result]) when is_integer(id),
    do: {:ok, {:response, id, error, result}}

  defp message([2, method, params]) when is_list(params) do
    with {:ok, method} <- text(method), do: {:ok, {:notification, method, params}}
  end

  defp message(_), do: :error

  defp text(value) when is_binary(value), do: {:ok, value}
  defp text(%Msgpax.Bin{data: data}), do: {:ok, data}
  defp text(_), do: :error

  @doc "Replaces `Msgpax.Bin` structs with their binaries, at any depth."
  @spec plain(term()) :: term()
  def plain(%Msgpax.Bin{data: data}), do: data
  def plain(list) when is_list(list), do: Enum.map(list, &plain/1)

  def plain(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {plain(k), plain(v)} end)

  def plain(value), do: value
end
