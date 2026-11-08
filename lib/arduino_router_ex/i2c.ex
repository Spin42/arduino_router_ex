defmodule ArduinoRouterEx.I2C do
  @moduledoc """
  A `Circuits.I2C` backend for the microcontroller's I2C buses, through the
  `io` sketch, that hands every other bus to a fallback backend:

      config :circuits_i2c,
        default_backend: {ArduinoRouterEx.I2C, fallback: Circuits.I2C.I2CDev}

  The sketch's `Wire`, `Wire1` and `Wire2` are `"mcu-i2c0"` to `"mcu-i2c2"`:

      {:ok, bus} = Circuits.I2C.open("mcu-i2c0")
      Circuits.I2C.write_read(bus, 0x48, <<0x00>>, 2)
  """

  @behaviour Circuits.I2C.Backend

  @prefix "mcu-i2c"
  @buses 0..2

  defstruct [:index]

  @type t :: %__MODULE__{index: non_neg_integer()}

  @impl Circuits.I2C.Backend
  def bus_names(options) do
    fallback(options).bus_names(options) ++ Enum.map(@buses, &"#{@prefix}#{&1}")
  end

  @impl Circuits.I2C.Backend
  def open(@prefix <> index = name, options) do
    case Integer.parse(index) do
      {index, ""} when index in @buses -> {:ok, %__MODULE__{index: index}}
      _ -> fallback(options).open(name, options)
    end
  end

  def open(name, options), do: fallback(options).open(name, options)

  @impl Circuits.I2C.Backend
  def info, do: %{name: __MODULE__}

  defp fallback(options), do: Keyword.get(options, :fallback, Circuits.I2C.I2CDev)
end

defimpl Circuits.I2C.Bus, for: ArduinoRouterEx.I2C do
  alias ArduinoRouterEx.IO

  def flags(_bus), do: []

  def read(bus, address, count, _options), do: IO.i2c_transfer(bus.index, address, <<>>, count)

  def write(bus, address, data, _options) do
    with {:ok, _} <- IO.i2c_transfer(bus.index, address, data, 0), do: :ok
  end

  def write_read(bus, address, data, count, _options),
    do: IO.i2c_transfer(bus.index, address, data, count)

  def close(_bus), do: :ok
end
