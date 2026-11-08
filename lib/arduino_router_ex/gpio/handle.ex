defmodule ArduinoRouterEx.GPIO.Handle do
  @moduledoc false
  # A microcontroller pin opened through ArduinoRouterEx.GPIO.

  defstruct [:spec, :pin, ref: nil]

  @type t :: %__MODULE__{spec: Circuits.GPIO.gpio_spec(), pin: non_neg_integer(), ref: term()}
end

defimpl Circuits.GPIO.Handle, for: ArduinoRouterEx.GPIO.Handle do
  alias ArduinoRouterEx.{GPIO, IO}
  alias ArduinoRouterEx.IO.Events

  def read(handle) do
    {:ok, value} = IO.read(handle.pin)
    value
  end

  def status(_handle), do: {:error, :not_supported}

  def write(handle, value), do: IO.write(handle.pin, value)

  def set_direction(handle, direction), do: GPIO.configure(handle, direction, [])

  def set_pull_mode(handle, mode), do: IO.mode(handle.pin, GPIO.input_mode(mode))

  def set_drive_mode(handle, :open_drain), do: IO.mode(handle.pin, :output_open_drain)
  def set_drive_mode(handle, :push_pull), do: IO.mode(handle.pin, :output)
  def set_drive_mode(_handle, _mode), do: {:error, :not_supported}

  def close(handle), do: Events.unsubscribe_owner(handle.ref, :all)

  def set_interrupts(handle, :none, _options), do: Events.unsubscribe_owner(handle.ref, :legacy)

  def set_interrupts(handle, trigger, options) do
    receiver = Keyword.get(options, :receiver, self())
    :ok = Events.unsubscribe_owner(handle.ref, :legacy)

    with {:ok, _ref} <-
           Events.subscribe(handle.pin, trigger, receiver, {:legacy, handle.spec}, handle.ref) do
      :ok
    end
  end

  def subscribe(handle, options) do
    receiver = Keyword.get(options, :receiver, self())
    trigger = Keyword.get(options, :trigger, :both)
    tag = Keyword.get(options, :tag)
    Events.subscribe(handle.pin, trigger, receiver, {:map, tag}, handle.ref)
  end

  def unsubscribe(handle), do: Events.unsubscribe_owner(handle.ref, :map)
end
