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

## The microcontroller's pins, I2C buses and LED matrix

The library ships `io`, a sketch that exposes the microcontroller's pins, ADC,
PWM, I2C buses and LED matrix over the Bridge (source in `sketches/io`,
prebuilt for the VENTUNO Q against `arduino:zephyr` 1.1.0). Install it, then
use the pins from Elixir:

```elixir
{:ok, _} = ArduinoRouterEx.IO.install_sketch()

{:ok, a0} = ArduinoRouterEx.IO.pin("A0")
{:ok, level} = ArduinoRouterEx.IO.analog_read(a0)

ArduinoRouterEx.Matrix.draw(frame)   # 8 rows of 13 brightness values
```

`ArduinoRouterEx.GPIO` and `ArduinoRouterEx.I2C` put the microcontroller's
pins and buses behind Circuits, as the `"mcu"` controller and the
`"mcu-i2c0"` to `"mcu-i2c2"` buses, and hand everything else to Linux, so the
SoC's GPIOs and buses keep working:

```elixir
{:ok, led} = Circuits.GPIO.open({"mcu", "LED1_R"}, :output)
Circuits.GPIO.write(led, 1)

{:ok, bus} = Circuits.I2C.open("mcu-i2c0")
Circuits.I2C.write_read(bus, 0x48, <<0x00>>, 2)
```

Set them in `config/runtime.exs`: Circuits builds its Linux backends only
when they are the default at build time.

```elixir
config :circuits_gpio, default_backend: {ArduinoRouterEx.GPIO, fallback: Circuits.GPIO.CDev}
config :circuits_i2c, default_backend: {ArduinoRouterEx.I2C, fallback: Circuits.I2C.I2CDev}
```

`ArduinoRouterEx.PulseTrain` pulses several pins from one microcontroller
timer, with the same period and phase, in 1 µs steps. On the VENTUNO Q, D3
and D5 can pulse:

```elixir
# 30 Hz: D3 low for the first 5 ms, D5 low for the last 13.3 ms.
ArduinoRouterEx.PulseTrain.start(33_333, [
  {"D3", width_us: 5_000},
  {"D5", offset_us: 20_000, width_us: 13_333}
])
```

Each call is a USB round trip of about a millisecond, and the sketch samples
watched pins every millisecond: fine for LEDs, buttons, sensors and slow PWM.
Anything that needs tighter timing belongs in a sketch of its own.

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
