defmodule ArduinoRouterEx.PulseTrain do
  @moduledoc """
  Periodic pulses on several pins at once, from one microcontroller timer
  through the `io` sketch: the pins share the period and phase, in 1 µs
  steps.

  On the VENTUNO Q, D3 and D5 can pulse. The timer is the one `IO.pwm/2` uses
  on D3, D5 and pin 80: their PWM pauses while a pulse train runs and resumes
  when it stops. Don't change their PWM during a train.
  """

  alias ArduinoRouterEx.IO

  @max_period_us 65_536
  @levels %{low: 0, high: 1}

  @type pulse_option ::
          {:width_us, pos_integer()}
          | {:offset_us, non_neg_integer()}
          | {:level, :low | :high}

  @doc """
  Pulses each pin every `period_us`, 2 to 65 536 µs, replacing any running
  pulse train.

  Each pulse is a pin, as a number or a name such as `"D3"`, with:

    * `:width_us` - required, the pulse's length, shorter than the period
    * `:offset_us` - when the pulse starts in each period, so that it ends
      within the period; defaults to 0
    * `:level` - `:low` (the default) or `:high`; the pin is driven to the
      other level between pulses

  Pins are inputs until the pulse train starts and again after `stop/0`.

      # 30 Hz: D3 low for the first 5 ms, D5 low for the last 13.3 ms.
      PulseTrain.start(33_333, [
        {"D3", width_us: 5_000},
        {"D5", offset_us: 20_000, width_us: 13_333}
      ])
  """
  @spec start(pos_integer(), [{IO.pin() | String.t(), [pulse_option()]}]) ::
          :ok | {:error, term()}
  def start(period_us, pulses) when is_integer(period_us) and is_list(pulses) do
    with :ok <- check_period(period_us),
         {:ok, pulses} <- check_pulses(pulses, period_us),
         :ok <- stop(),
         :ok <- set_pulses(pulses) do
      ok(ArduinoRouterEx.call("pulse/start", [period_us]))
    end
  end

  @doc "Stops the pulse train, returns its pins to inputs and resumes PWM on the timer's other pins."
  @spec stop() :: :ok | {:error, term()}
  def stop, do: ok(ArduinoRouterEx.call("pulse/stop", []))

  defp check_period(period_us) when period_us in 2..@max_period_us, do: :ok
  defp check_period(_period_us), do: {:error, :period_out_of_range}

  defp check_pulses([], _period_us), do: {:error, :no_pulses}

  defp check_pulses(pulses, period_us) do
    Enum.reduce_while(pulses, {:ok, []}, fn {pin, opts}, {:ok, acc} ->
      width = Keyword.fetch!(opts, :width_us)
      offset = Keyword.get(opts, :offset_us, 0)
      level = Map.fetch!(@levels, Keyword.get(opts, :level, :low))

      with :ok <- check_window(offset, width, period_us),
           {:ok, pin} <- resolve(pin) do
        {:cont, {:ok, [[pin, offset, width, level] | acc]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp check_window(offset, width, period_us)
       when is_integer(offset) and is_integer(width) and offset >= 0 and width >= 1 and
              width < period_us and offset + width <= period_us,
       do: :ok

  defp check_window(_offset, _width, _period_us), do: {:error, :pulse_out_of_range}

  defp resolve(pin) when is_integer(pin), do: {:ok, pin}
  defp resolve(name) when is_binary(name), do: IO.pin(name)

  defp set_pulses(pulses) do
    Enum.reduce_while(pulses, :ok, fn params, :ok ->
      case ArduinoRouterEx.call("pulse/set", params) do
        {:ok, true} -> {:cont, :ok}
        {:ok, false} -> {:halt, {:error, {:not_supported, hd(params)}}}
        error -> {:halt, error}
      end
    end)
  end

  defp ok({:ok, true}), do: :ok
  defp ok({:ok, false}), do: {:error, :invalid_argument}
  defp ok({:error, _} = error), do: error
end
