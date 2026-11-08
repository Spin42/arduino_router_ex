defmodule ArduinoRouterEx.IOTest do
  # The IO modules use the router started under its default name.
  use ExUnit.Case, async: false

  alias ArduinoRouterEx.{FakeIOSketch, GPIO, I2C, IO, Matrix, Router}

  setup do
    start_supervised!({Router, name: ArduinoRouterEx.Router})
    start_supervised!({ArduinoRouterEx.IO.Events, router: ArduinoRouterEx.Router})
    %{sketch: FakeIOSketch.start(ArduinoRouterEx.Router)}
  end

  test "resolves pin names" do
    assert IO.pin("D13") == {:ok, 13}
    assert IO.pin("nope") == {:error, :not_found}
  end

  test "writes and reads a pin" do
    assert IO.mode(13, :output) == :ok
    assert IO.write(13, 1) == :ok
    assert IO.read(13) == {:ok, 1}
  end

  test "transfers over I2C and reports a missing device" do
    assert IO.i2c_transfer(0, 0x48, <<0xAB>>, 2) == {:ok, <<0xAB, 0xAB>>}
    assert IO.i2c_transfer(0, 0x50, <<0x00>>, 1) == {:error, {:i2c, 2}}
  end

  test "subscribers get the edges they asked for", %{sketch: sketch} do
    {:ok, _ref} = IO.subscribe(13, :rising)

    send(sketch, {:set_level, 13, 1})
    assert_receive {:arduino_router_ex_io, 13, 1}

    send(sketch, {:set_level, 13, 0})
    refute_receive {:arduino_router_ex_io, 13, 0}, 100
  end

  test "unsubscribing stops the sketch watching the pin" do
    {:ok, ref} = IO.subscribe(13, :both)
    assert_receive {:sketch_called, "io/watch", [13, 3]}

    :ok = IO.unsubscribe(ref)
    assert_receive {:sketch_called, "io/watch", [13, 0]}
  end

  test "draws the matrix" do
    assert Matrix.draw(List.duplicate(List.duplicate(255, 13), 8)) == :ok
    assert Matrix.clear() == :ok
    assert Matrix.draw([[1, 2]]) == {:error, :invalid_frame}
  end

  describe "GPIO backend" do
    test "opens microcontroller pins by name and number" do
      {:ok, led} = GPIO.open({"mcu", "LED1_R"}, :output, initial_value: 1)
      assert_receive {:sketch_called, "io/write", [61, 1]}
      assert Circuits.GPIO.Handle.read(led) == 1

      {:ok, pin} = GPIO.open({"mcu", 13}, :input, pull_mode: :pullup)
      assert_receive {:sketch_called, "io/mode", [13, 2]}
      assert Circuits.GPIO.Handle.write(pin, 0) == :ok
    end

    test "reports unknown pins and refuses groups" do
      assert GPIO.open({"mcu", "nope"}, :input, []) == {:error, :not_found}
      assert GPIO.open([{"mcu", 13}, {"mcu", 14}], :input, []) == {:error, :not_supported}
    end

    test "sends Circuits interrupt and subscription messages", %{sketch: sketch} do
      {:ok, pin} = GPIO.open({"mcu", "D13"}, :input, [])

      :ok = Circuits.GPIO.Handle.set_interrupts(pin, :both, [])
      {:ok, _} = Circuits.GPIO.Handle.subscribe(pin, tag: :button)

      send(sketch, {:set_level, 13, 1})
      assert_receive {:circuits_gpio, {"mcu", "D13"}, _timestamp, 1}
      assert_receive {:circuits_gpio, %{ref: :button, value: 1, previous_value: 0}}

      :ok = Circuits.GPIO.Handle.close(pin)
      send(sketch, {:set_level, 13, 0})
      refute_receive {:circuits_gpio, _, _, _}, 100
    end

    test "hands other GPIOs to the fallback" do
      assert GPIO.open({"gpiochip9", 1}, :input, fallback: Circuits.GPIO.NilBackend) ==
               Circuits.GPIO.NilBackend.open({"gpiochip9", 1}, :input, [])
    end
  end

  describe "I2C backend" do
    test "opens microcontroller buses and reads a register" do
      {:ok, bus} = I2C.open("mcu-i2c1", [])
      assert Circuits.I2C.Bus.write_read(bus, 0x48, <<0x07>>, 1, []) == {:ok, <<0x07>>}
      assert Circuits.I2C.Bus.write(bus, 0x50, <<0x00>>, []) == {:error, {:i2c, 2}}
    end

    test "lists its buses after the fallback's" do
      assert I2C.bus_names(fallback: Circuits.I2C.NilBackend) ==
               ["mcu-i2c0", "mcu-i2c1", "mcu-i2c2"]
    end
  end
end
