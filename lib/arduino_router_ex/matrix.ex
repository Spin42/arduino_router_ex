defmodule ArduinoRouterEx.Matrix do
  @moduledoc """
  The board's 8 × 13 LED matrix, through the `io` sketch.

  A frame is 8 rows of 13 brightness values from 0 to 255, either as a list
  of rows or as a 104-byte binary, row by row.
  """

  @rows 8
  @columns 13

  @type frame :: binary() | [[0..255]]

  @doc "Draws a frame."
  @spec draw(frame()) :: :ok | {:error, term()}
  def draw(rows) when is_list(rows) do
    if length(rows) == @rows and Enum.all?(rows, &(length(&1) == @columns)) do
      rows |> List.flatten() |> :erlang.list_to_binary() |> draw()
    else
      {:error, :invalid_frame}
    end
  end

  def draw(<<_::binary-size(@rows * @columns)>> = pixels) do
    case ArduinoRouterEx.call("matrix/draw", [Msgpax.Bin.new(pixels)]) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :invalid_frame}
      {:error, _} = error -> error
    end
  end

  def draw(_pixels), do: {:error, :invalid_frame}

  @doc "Turns every LED off."
  @spec clear() :: :ok | {:error, term()}
  def clear, do: draw(:binary.copy(<<0>>, @rows * @columns))
end
