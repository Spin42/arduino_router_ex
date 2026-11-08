// Exposes the microcontroller's pins, ADC, PWM, I2C buses and LED matrix over
// the Bridge, for ArduinoRouterEx.IO and its Circuits backends.
//
//   io/version()                      -> string
//   io/pin(name)                      -> pin number, or -1
//   io/mode(pin, mode)                -> bool  (see MODES)
//   io/write(pin, value)              -> bool
//   io/read(pin)                      -> 0 | 1
//   io/watch(pin, edge)               -> bool  (0 none, 1 rising, 2 falling, 3 both)
//   io/analog_read(pin)               -> int
//   io/analog_resolution(bits)        -> bool
//   io/pwm(pin, value)                -> bool
//   io/pwm_resolution(bits)           -> bool
//   io/i2c_clock(bus, hz)             -> bool
//   io/i2c(bus, address, data, count) -> [status, bytes read]
//   matrix/draw(pixels)               -> bool  (8 rows of 13 pixels, one byte each)
//
// A watched pin is sampled every millisecond; each change is sent to Linux as
// the notification io/changed(pin, value).

#include <Arduino_RouterBridge.h>
#include <Arduino_LED_Matrix.h>
#include <Wire.h>

static const char *VERSION = "arduino_router_ex io 1";
static const size_t MATRIX_PIXELS = 104;
static const int MODES[] = {INPUT, OUTPUT, INPUT_PULLUP, INPUT_PULLDOWN, OUTPUT_OPENDRAIN};

struct NamedPin {
    const char *name;
    int pin;
};

static const NamedPin NAMED_PINS[] = {
    {"A0", A0},         {"A1", A1},         {"A2", A2},         {"A3", A3},
    {"A4", A4},         {"A5", A5},         {"LED_BUILTIN", LED_BUILTIN},
    {"LED1_R", LED1_R}, {"LED1_G", LED1_G}, {"LED1_B", LED1_B},
    {"LED2_R", LED2_R}, {"LED2_G", LED2_G}, {"LED2_B", LED2_B},
    {"LED3_R", LED3_R}, {"LED3_G", LED3_G}, {"LED3_B", LED3_B},
    {"LED4_R", LED4_R}, {"LED4_G", LED4_G}, {"LED4_B", LED4_B},
};

static TwoWire *const BUSES[] = {&Wire, &Wire1, &Wire2};
static const int BUS_COUNT = sizeof(BUSES) / sizeof(BUSES[0]);

// 0 when the pin is not watched, else the edge mask: 1 rising, 2 falling.
static uint8_t watched_edges[NUM_OF_DIGITAL_PINS];
static int8_t last_values[NUM_OF_DIGITAL_PINS];
static bool bus_started[BUS_COUNT];

Arduino_LED_Matrix matrix;

static bool valid_pin(int pin) {
    return pin >= 0 && pin < NUM_OF_DIGITAL_PINS;
}

String io_version() {
    return String(VERSION);
}

int io_pin(String name) {
    if (name.length() > 1 && name[0] == 'D') {
        int pin = name.substring(1).toInt();
        if (String(pin) == name.substring(1) && valid_pin(pin)) {
            return pin;
        }
    }
    for (const NamedPin &named : NAMED_PINS) {
        if (name == named.name) {
            return named.pin;
        }
    }
    return -1;
}

bool io_mode(int pin, int mode) {
    if (!valid_pin(pin) || mode < 0 || mode >= (int)(sizeof(MODES) / sizeof(MODES[0]))) {
        return false;
    }
    pinMode(pin, MODES[mode]);
    return true;
}

bool io_write(int pin, int value) {
    if (!valid_pin(pin)) {
        return false;
    }
    digitalWrite(pin, value ? HIGH : LOW);
    return true;
}

int io_read(int pin) {
    return valid_pin(pin) ? digitalRead(pin) : -1;
}

bool io_watch(int pin, int edges) {
    if (!valid_pin(pin) || edges < 0 || edges > 3) {
        return false;
    }
    last_values[pin] = digitalRead(pin);
    watched_edges[pin] = edges;
    return true;
}

int io_analog_read(int pin) {
    return analogRead(pin);
}

bool io_analog_resolution(int bits) {
    analogReadResolution(bits);
    return true;
}

bool io_pwm(int pin, int value) {
    if (!valid_pin(pin)) {
        return false;
    }
    analogWrite(pin, value);
    return true;
}

bool io_pwm_resolution(int bits) {
    analogWriteResolution(bits);
    return true;
}

static TwoWire *bus(int index) {
    if (index < 0 || index >= BUS_COUNT) {
        return nullptr;
    }
    if (!bus_started[index]) {
        BUSES[index]->begin();
        bus_started[index] = true;
    }
    return BUSES[index];
}

bool io_i2c_clock(int index, int hz) {
    TwoWire *wire = bus(index);
    if (wire == nullptr) {
        return false;
    }
    wire->setClock(hz);
    return true;
}

// Writes data, then reads count bytes, as one transaction. The status is 0,
// the Wire error code of the write, -1 for a bad bus or -2 for a short read.
std::tuple<int, MsgPack::bin_t<uint8_t>> io_i2c(int index, int address,
                                                MsgPack::bin_t<uint8_t> data, int count) {
    MsgPack::bin_t<uint8_t> out;
    TwoWire *wire = bus(index);
    if (wire == nullptr) {
        return std::make_tuple(-1, out);
    }
    if (!data.empty()) {
        wire->beginTransmission(address);
        wire->write(data.data(), data.size());
        uint8_t status = wire->endTransmission(count == 0);
        if (status != 0) {
            return std::make_tuple((int)status, out);
        }
    }
    if (count > 0) {
        wire->requestFrom(address, count);
        while (wire->available()) {
            out.push_back(wire->read());
        }
    }
    return std::make_tuple((int)out.size() == count ? 0 : -2, out);
}

bool matrix_draw(MsgPack::bin_t<uint8_t> pixels) {
    if (pixels.size() != MATRIX_PIXELS) {
        return false;
    }
    matrix.draw(pixels.data());
    return true;
}

void setup() {
    matrix.begin();
    matrix.setGrayscaleBits(8);

    Bridge.begin();

    Bridge.provide("io/version", io_version);
    Bridge.provide("io/pin", io_pin);
    Bridge.provide_safe("io/mode", io_mode);
    Bridge.provide_safe("io/write", io_write);
    Bridge.provide_safe("io/read", io_read);
    Bridge.provide_safe("io/watch", io_watch);
    Bridge.provide_safe("io/analog_read", io_analog_read);
    Bridge.provide_safe("io/analog_resolution", io_analog_resolution);
    Bridge.provide_safe("io/pwm", io_pwm);
    Bridge.provide_safe("io/pwm_resolution", io_pwm_resolution);
    Bridge.provide_safe("io/i2c_clock", io_i2c_clock);
    Bridge.provide_safe("io/i2c", io_i2c);
    Bridge.provide("matrix/draw", matrix_draw);
}

void loop() {
    for (int pin = 0; pin < NUM_OF_DIGITAL_PINS; pin++) {
        if (watched_edges[pin] == 0) {
            continue;
        }
        int value = digitalRead(pin);
        if (value == last_values[pin]) {
            continue;
        }
        last_values[pin] = value;
        if ((value && (watched_edges[pin] & 1)) || (!value && (watched_edges[pin] & 2))) {
            Bridge.notify("io/changed", pin, value);
        }
    }
    delay(1);
}
