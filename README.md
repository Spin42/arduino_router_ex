# ArduinoRouterEx

The Linux side of the Arduino Bridge, in Elixir: a reimplementation of
Arduino's [arduino-router](https://github.com/arduino/arduino-router) for
boards that pair a Linux SoC with a microcontroller running an Arduino sketch,
such as the Arduino VENTUNO Q and UNO Q.

A sketch built with Arduino's
[Arduino_RouterBridge](https://github.com/arduino-libraries/Arduino_RouterBridge)
library talks MessagePack-RPC over a serial port: it exposes functions with
`Bridge.provide`, calls Linux with `Bridge.call`, sends notifications with
`Bridge.notify` and writes to its `Monitor`. This library is the other end.

## Usage

Add the router to your supervision tree with the sketch's serial port:

```elixir
children = [{ArduinoRouterEx, port: "/dev/ttyACM0"}]
```

Call the functions the sketch provides:

```elixir
{:ok, "pong"} = ArduinoRouterEx.call("ping")
{:ok, true} = ArduinoRouterEx.call("matrix_draw", [Msgpax.Bin.new(frame)])
```

Serve functions the sketch calls, and its notifications:

```elixir
ArduinoRouterEx.provide("linux_time", fn [] -> {:ok, System.os_time(:second)} end)
```

Read and write the sketch's `Monitor`:

```elixir
ArduinoRouterEx.monitor_subscribe()
ArduinoRouterEx.monitor_write("hello\n")
# receive {:arduino_router_ex_monitor, data}
```

Binaries go to the sketch as MessagePack strings; wrap them in `Msgpax.Bin`
for a sketch parameter of type `MsgPack::bin_t<uint8_t>`.

## The io sketch: pins, ADC, PWM, I2C and the LED matrix

The library ships `io`, a sketch that exposes the microcontroller's pins, ADC,
PWM, I2C buses and LED matrix over the Bridge (source in `sketches/io`,
prebuilt for the VENTUNO Q against `arduino:zephyr` 1.1.0). Install it once
the router runs; it is skipped when already installed:

```elixir
{:ok, _} = ArduinoRouterEx.IO.install_sketch()
```

Each call is a USB round trip of about a millisecond, and the sketch samples
watched pins every millisecond: fine for LEDs, buttons, sensors and slow PWM.
Anything that needs tighter timing belongs in a sketch of its own.

### Pins

Functions take the sketch's pin numbers; `pin/1` resolves the board's names:
`"D0"` to the last digital pin, `"A0"` to `"A5"`, `"LED_BUILTIN"` and the RGB
LEDs `"LED1_R"` to `"LED4_B"`.

```elixir
alias ArduinoRouterEx.IO

{:ok, d13} = IO.pin("D13")
{:ok, red} = IO.pin("LED1_R")

# Modes: :input, :output, :input_pullup, :input_pulldown, :output_open_drain
:ok = IO.mode(d13, :output)
:ok = IO.write(d13, 1)

:ok = IO.mode(d13, :input_pullup)
{:ok, level} = IO.read(d13)
```

### Edges

`subscribe/2` sends the caller a message on each change of a pin, on
`:rising`, `:falling` or `:both` edges, until `unsubscribe/1` or the caller
exits:

```elixir
{:ok, d2} = IO.pin("D2")
:ok = IO.mode(d2, :input_pullup)
{:ok, ref} = IO.subscribe(d2, :falling)

receive do
  {:arduino_router_ex_io, ^d2, 0} -> :pressed
end

:ok = IO.unsubscribe(ref)
```

### Analog inputs and PWM

```elixir
:ok = IO.analog_resolution(12)
{:ok, a0} = IO.pin("A0")
{:ok, value} = IO.analog_read(a0)        # 0..4095

:ok = IO.pwm_resolution(8)
{:ok, d6} = IO.pin("D6")
:ok = IO.pwm(d6, 128)                     # 50 % duty cycle
```

### I2C

The buses are `Wire`, `Wire1` and `Wire2` of the Arduino core, numbered 0 to
2; bus 0 is on SDA (D21) and SCL (D20). `i2c_transfer/4` writes, then reads,
in one transaction:

```elixir
:ok = IO.i2c_clock(0, 400_000)

# Read 2 bytes from register 0x00 of the device at 0x48.
{:ok, <<raw::16>>} = IO.i2c_transfer(0, 0x48, <<0x00>>, 2)

# Write only, read only.
{:ok, <<>>} = IO.i2c_transfer(0, 0x48, <<0x01, 0x60, 0xA0>>, 0)
{:ok, <<_byte>>} = IO.i2c_transfer(0, 0x48, <<>>, 1)

# A device that does not answer:
{:error, {:i2c, 2}} = IO.i2c_transfer(0, 0x50, <<0x00>>, 1)
```

### LED matrix

A frame is 8 rows of 13 brightness values, 0 to 255, as a list of rows or a
104-byte binary:

```elixir
alias ArduinoRouterEx.Matrix

frame = for row <- 0..7, do: for(col <- 0..12, do: if(row == col, do: 255, else: 0))
:ok = Matrix.draw(frame)
:ok = Matrix.clear()
```

### Pulse trains

`ArduinoRouterEx.PulseTrain` pulses several pins from one microcontroller
timer, with the same period and phase, in 1 µs steps. On the VENTUNO Q, D3
and D5 can pulse; each pulse has a width, an offset into the period and a
level, and the pins are inputs again after `stop/0`. The timer also drives
PWM on D3 and D5, which pauses during a train and resumes after it:

```elixir
alias ArduinoRouterEx.PulseTrain

# 30 Hz: D3 low for the first 5 ms, D5 high from 20 ms to the end of the period.
:ok =
  PulseTrain.start(33_333, [
    {"D3", width_us: 5_000},
    {"D5", offset_us: 20_000, width_us: 13_333, level: :high}
  ])

:ok = PulseTrain.stop()
```

### Through Circuits

`ArduinoRouterEx.GPIO` and `ArduinoRouterEx.I2C` put the microcontroller's
pins and buses behind Circuits, as the `"mcu"` controller and the
`"mcu-i2c0"` to `"mcu-i2c2"` buses, and hand everything else to Linux, so the
SoC's GPIOs and buses keep working. Set them in `config/runtime.exs`:
Circuits builds its Linux backends only when they are the default at build
time.

```elixir
config :circuits_gpio, default_backend: {ArduinoRouterEx.GPIO, fallback: Circuits.GPIO.CDev}
config :circuits_i2c, default_backend: {ArduinoRouterEx.I2C, fallback: Circuits.I2C.I2CDev}
```

```elixir
{:ok, led} = Circuits.GPIO.open({"mcu", "LED1_R"}, :output)
:ok = Circuits.GPIO.write(led, 1)

{:ok, button} = Circuits.GPIO.open({"mcu", "D2"}, :input, pull_mode: :pullup)
:ok = Circuits.GPIO.set_interrupts(button, :falling)
# receive {:circuits_gpio, {"mcu", "D2"}, _timestamp, 0}

{:ok, bus} = Circuits.I2C.open("mcu-i2c0")
{:ok, <<raw::16>>} = Circuits.I2C.write_read(bus, 0x48, <<0x00>>, 2)

# A SoC GPIO still goes to Linux.
{:ok, gpio} = Circuits.GPIO.open({"gpiochip4", 3}, :output)
```

### The sketch's methods

Other Bridge clients can call the sketch directly with `ArduinoRouterEx.call/2`:

| Method                                      | Returns                                         |
| ------------------------------------------- | ----------------------------------------------- |
| `io/version()`                              | the sketch's version string                     |
| `io/pin(name)`                              | the pin number, or -1                           |
| `io/mode(pin, mode)`                        | `true` (modes 0 to 4, in the order above)       |
| `io/write(pin, value)`, `io/read(pin)`      | `true`, the level                               |
| `io/watch(pin, edges)`                      | `true` (0 none, 1 rising, 2 falling, 3 both); changes come as the notification `io/changed(pin, value)` |
| `io/analog_read(pin)`                       | the reading                                     |
| `io/analog_resolution(bits)`                | `true`                                          |
| `io/pwm(pin, value)`, `io/pwm_resolution(bits)` | `true`                                      |
| `io/i2c_clock(bus, hz)`                     | `true`                                          |
| `io/i2c(bus, address, data, count)`         | `[status, bytes read]`                          |
| `matrix/draw(pixels)`                       | `true` for 104 bytes                            |
| `pulse/set(pin, offset_us, width_us, level)`, `pulse/start(period_us)`, `pulse/stop()` | `true`; VENTUNO Q only |

## Installing a sketch

For a sketch of your own, `ArduinoRouterEx.Sketch.install/2` flashes it with the board's flash
command, and skips it when the same sketch is already installed;
`ArduinoRouterEx.await_routes/2` then waits for the sketch to register its
functions:

```elixir
{:ok, _} = ArduinoRouterEx.Sketch.install("/usr/share/my_app/sketch.elf-zsk.bin")
:ok = ArduinoRouterEx.await_routes(["ping", "matrix_draw"])
```

The commands default to the
[VENTUNO Q Nerves system](https://github.com/Spin42/nerves_system_arduino_ventuno_q)'s
`ventuno-q-mcu`, which flashes over the board's SWD port. The system ships the
loader the sketch runs on and links against, so build the sketch with the same
`arduino:zephyr` core version as the system:

```sh
arduino-cli compile --fqbn arduino:zephyr:ventunoq --output-dir build .
```

and ship `build/<sketch>.ino.elf-zsk.bin` in your firmware.
`sketches/bridge_test` is a sketch that exercises the router.

## The sketch's lifecycle

A sketch registers its functions when it starts, after its serial port opens.
Restart the sketch when the router starts, as Arduino's service and the
VENTUNO Q system do, so that it registers them with this router;
`ArduinoRouterEx.Sketch.restart/1` runs the board's restart command.

The serial port is opened by a small C helper rather than Circuits.UART, which
flushes the port after opening it: opening the port raises DTR, the sketch
sends its first request within milliseconds, and a flush would drop it.

## Compared with arduino-router

Implemented: `$/register`, `$/unregister`, `$/reset`, `$/setMaxMsgSize`,
`$/version`, the monitor methods (`mon/connected`, `mon/read`, `mon/write`,
`mon/reset`) and routing between the sketch, Elixir and other connections.

Not implemented: the Unix and TCP sockets other Linux programs join the
router through, the TCP monitor port, and `$/serial/open` and `$/serial/close`.
