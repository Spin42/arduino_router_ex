defmodule ArduinoRouterEx.GPIO do
  @moduledoc """
  A `Circuits.GPIO` backend for the microcontroller's pins, through the `io`
  sketch, that hands every other GPIO to a fallback backend.

  Circuits.GPIO has one backend per application, so this one serves the
  `"mcu"` controller and passes the rest on, by default to the Linux GPIO
  character device backend:

      config :circuits_gpio,
        default_backend: {ArduinoRouterEx.GPIO, fallback: Circuits.GPIO.CDev}

  Microcontroller pins are `{"mcu", name}`, with the board's pin names, or
  `{"mcu", number}`:

      {:ok, led} = Circuits.GPIO.open({"mcu", "LED1_R"}, :output)
      Circuits.GPIO.write(led, 1)

  Groups of microcontroller pins are not supported. Interrupts come from the
  sketch sampling the pin every millisecond, and their timestamps are taken
  when Elixir receives them.
  """

  @behaviour Circuits.GPIO.Backend

  alias ArduinoRouterEx.GPIO.Handle
  alias ArduinoRouterEx.IO

  @controller "mcu"

  @impl Circuits.GPIO.Backend
  def enumerate(options), do: fallback(options).enumerate(options)

  @impl Circuits.GPIO.Backend
  def identifiers({@controller, _} = spec, _options) do
    with {:ok, pin} <- resolve(spec) do
      {:ok, %{location: {@controller, pin}, controller: @controller, label: label(spec, pin)}}
    end
  end

  def identifiers(spec, options), do: fallback(options).identifiers(spec, options)

  @impl Circuits.GPIO.Backend
  def status({@controller, _}, _options), do: {:error, :not_supported}
  def status(spec, options), do: fallback(options).status(spec, options)

  @impl Circuits.GPIO.Backend
  def open({@controller, _} = spec, direction, options) do
    with {:ok, pin} <- resolve(spec) do
      handle = %Handle{spec: spec, pin: pin, ref: make_ref()}

      with :ok <- configure(handle, direction, options) do
        {:ok, handle}
      end
    end
  end

  def open(spec, direction, options) do
    if is_list(spec) and Enum.any?(spec, &match?({@controller, _}, &1)),
      do: {:error, :not_supported},
      else: fallback(options).open(spec, direction, options)
  end

  @impl Circuits.GPIO.Backend
  def force_close({@controller, _}, _options), do: :ok
  def force_close(spec, options), do: fallback(options).force_close(spec, options)

  @impl Circuits.GPIO.Backend
  def backend_info, do: %{name: __MODULE__, controller: @controller}

  @doc false
  @spec configure(Handle.t(), Circuits.GPIO.direction(), keyword()) :: :ok | {:error, term()}
  def configure(handle, :output, options) do
    mode =
      if Keyword.get(options, :drive_mode) == :open_drain, do: :output_open_drain, else: :output

    with :ok <- IO.mode(handle.pin, mode) do
      IO.write(handle.pin, Keyword.get(options, :initial_value, 0))
    end
  end

  def configure(handle, :input, options) do
    IO.mode(handle.pin, input_mode(Keyword.get(options, :pull_mode, :not_set)))
  end

  @doc false
  @spec input_mode(Circuits.GPIO.pull_mode()) :: IO.mode()
  def input_mode(:pullup), do: :input_pullup
  def input_mode(:pulldown), do: :input_pulldown
  def input_mode(_), do: :input

  defp resolve({@controller, pin}) when is_integer(pin) and pin >= 0, do: {:ok, pin}
  defp resolve({@controller, name}) when is_binary(name), do: IO.pin(name)
  defp resolve(_), do: {:error, :not_found}

  defp label({@controller, name}, _pin) when is_binary(name), do: name
  defp label(_spec, pin), do: "D#{pin}"

  defp fallback(options), do: Keyword.get(options, :fallback, Circuits.GPIO.CDev)
end
