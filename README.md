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

## Installing a sketch

`ArduinoRouterEx.Sketch.install/2` flashes a sketch with the board's flash
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
