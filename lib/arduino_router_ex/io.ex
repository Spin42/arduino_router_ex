defmodule ArduinoRouterEx.IO do
  @moduledoc """
  The microcontroller's pins, ADC, PWM and I2C buses, through the `io` sketch
  in `sketches/io`.

  `install_sketch/1` installs that sketch, prebuilt for the board, and its
  functions answer these calls. Pins are the sketch's pin numbers; `pin/1` resolves the board's names
  (`"D13"`, `"A0"`, `"LED_BUILTIN"`, `"LED1_R"`). `ArduinoRouterEx.GPIO` and
  `ArduinoRouterEx.I2C` put the same pins and buses behind Circuits.

  Pin changes come as `{:arduino_router_ex_io, pin, value}` to the processes
  that `subscribe/2`.
  """

  alias ArduinoRouterEx.IO.Events

  @modes %{
    input: 0,
    output: 1,
    input_pullup: 2,
    input_pulldown: 3,
    output_open_drain: 4
  }

  # Prebuilt io sketches by board, built against the Arduino core version whose
  # loader the board's system ships.
  @sketches %{ventunoq: "io-arduino_zephyr-1.1.0-ventunoq.zsk.bin"}

  @type pin :: non_neg_integer()
  @type mode :: :input | :output | :input_pullup | :input_pulldown | :output_open_drain
  @type edges :: :rising | :falling | :both

  @doc """
  Installs the prebuilt io sketch for `board` (`:ventunoq`, built against
  `arduino:zephyr` 1.1.0) with `ArduinoRouterEx.Sketch.install/2`, then waits
  for it to register its functions.
  """
  @spec install_sketch(atom(), timeout()) :: {:ok, :flashed | :unchanged} | {:error, term()}
  def install_sketch(board \\ :ventunoq, timeout \\ 30_000) do
    with {:ok, file} <- Map.fetch(@sketches, board),
         sketch = Application.app_dir(:arduino_router_ex, Path.join("priv/sketches", file)),
         {:ok, status} <- ArduinoRouterEx.Sketch.install(sketch),
         :ok <- ArduinoRouterEx.await_routes(["io/pin", "io/watch", "matrix/draw"], timeout) do
      {:ok, status}
    else
      :error -> {:error, :unknown_board}
      error -> error
    end
  end

  @doc "Returns the pin number of a board pin name, such as `\"D13\"` or `\"A0\"`."
  @spec pin(String.t()) :: {:ok, pin()} | {:error, term()}
  def pin(name) when is_binary(name) do
    case ArduinoRouterEx.call("io/pin", [name]) do
      {:ok, -1} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Sets a pin's mode."
  @spec mode(pin(), mode()) :: :ok | {:error, term()}
  def mode(pin, mode), do: ok(ArduinoRouterEx.call("io/mode", [pin, Map.fetch!(@modes, mode)]))

  @doc "Drives an output pin low (0) or high (1)."
  @spec write(pin(), 0 | 1) :: :ok | {:error, term()}
  def write(pin, value) when value in [0, 1],
    do: ok(ArduinoRouterEx.call("io/write", [pin, value]))

  @doc "Reads a pin's level."
  @spec read(pin()) :: {:ok, 0 | 1} | {:error, term()}
  def read(pin) do
    case ArduinoRouterEx.call("io/read", [pin]) do
      {:ok, -1} -> {:error, :invalid_pin}
      other -> other
    end
  end

  @doc "Reads an analog pin, at the resolution set by `analog_resolution/1`."
  @spec analog_read(pin()) :: {:ok, non_neg_integer()} | {:error, term()}
  def analog_read(pin), do: ArduinoRouterEx.call("io/analog_read", [pin])

  @doc "Sets the ADC resolution in bits."
  @spec analog_resolution(pos_integer()) :: :ok | {:error, term()}
  def analog_resolution(bits), do: ok(ArduinoRouterEx.call("io/analog_resolution", [bits]))

  @doc "Sets a PWM pin's duty cycle, at the resolution set by `pwm_resolution/1`."
  @spec pwm(pin(), non_neg_integer()) :: :ok | {:error, term()}
  def pwm(pin, value), do: ok(ArduinoRouterEx.call("io/pwm", [pin, value]))

  @doc "Sets the PWM resolution in bits."
  @spec pwm_resolution(pos_integer()) :: :ok | {:error, term()}
  def pwm_resolution(bits), do: ok(ArduinoRouterEx.call("io/pwm_resolution", [bits]))

  @doc "Sets an I2C bus's clock in hertz."
  @spec i2c_clock(non_neg_integer(), pos_integer()) :: :ok | {:error, term()}
  def i2c_clock(bus, hz), do: ok(ArduinoRouterEx.call("io/i2c_clock", [bus, hz]))

  @doc """
  Writes `data` to an I2C device, then reads `count` bytes, in one
  transaction. An empty `data` only reads; a zero `count` only writes.
  """
  @spec i2c_transfer(non_neg_integer(), 0..127, iodata(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def i2c_transfer(bus, address, data, count) do
    data = Msgpax.Bin.new(IO.iodata_to_binary(data))

    case ArduinoRouterEx.call("io/i2c", [bus, address, data, count]) do
      {:ok, [0, read]} -> {:ok, read}
      {:ok, [-1, _]} -> {:error, :bus_not_found}
      {:ok, [-2, _]} -> {:error, :short_read}
      {:ok, [status, _]} -> {:error, {:i2c, status}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Sends the caller `{:arduino_router_ex_io, pin, value}` when `pin` changes on
  `edges`, until `unsubscribe/1` or the caller exits. The sketch samples the
  pin every millisecond.
  """
  @spec subscribe(pin(), edges()) :: {:ok, reference()} | {:error, term()}
  def subscribe(pin, edges \\ :both), do: Events.subscribe(pin, edges, self(), :raw)

  @doc "Stops a subscription."
  @spec unsubscribe(reference()) :: :ok
  def unsubscribe(ref), do: Events.unsubscribe(ref)

  defp ok({:ok, true}), do: :ok
  defp ok({:ok, false}), do: {:error, :invalid_argument}
  defp ok({:error, _} = error), do: error
end
