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
//   pulse/set(pin, offset_us, width_us, level) -> bool  (VENTUNO Q only, see below)
//   pulse/start(period_us)            -> bool
//   pulse/stop()                      -> bool
//
// A watched pin is sampled every millisecond; each change is sent to Linux as
// the notification io/changed(pin, value).
//
// On the VENTUNO Q, TIM3 counts in 1 us ticks and pulses D3 (PB1, channel 4)
// and D5 (PB5, channel 2) with the same period and phase: pulse/set gives a
// pin a pulse width_us long, offset_us into each period, at level 0 (low) or
// 1 (high); pulse/start starts every pin set since the last pulse/stop, which
// returns them to inputs and gives TIM3 back to PWM as it was before the
// train. In combined PWM mode 2, a pulse starts on its channel's compare value
// and ends on its pair's (channel 3 for D3, channel 1 for D5).

#include <Arduino_RouterBridge.h>
#include <Arduino_LED_Matrix.h>
#include <Wire.h>

#if defined(CONFIG_BOARD_ARDUINO_VENTUNO_Q)
#include <soc.h>
#endif

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

#if defined(CONFIG_BOARD_ARDUINO_VENTUNO_Q)
static const uint32_t TICK_HZ = 1000000;
static const uint32_t MAX_PERIOD_US = 65536;
// OCxM values: PWM mode 1 and combined PWM mode 2.
static const uint32_t OCM_PWM1 = 0b0110;
static const uint32_t OCM_COMBINED_PWM2 = 0b1101;

struct Pulse {
    int pin;
    uint32_t gpio;       // PBx
    bool set;
    int offset_us;
    int width_us;
    int level;
};

// D3 and D5, in the order of the TIM3 channel pairs (3, 4) and (1, 2).
static Pulse pulses[] = {{3, 1, false, 0, 0, 0}, {5, 5, false, 0, 0, 0}};
static bool pulsing = false;

// TIM3 as Zephyr's PWM driver set it up, restored when the train stops so that
// PWM on D3 and D5 works again.
struct Tim3State {
    uint32_t cr1, psc, arr, ccmr1, ccmr2, ccer, ccr1, ccr2, ccr3, ccr4;
};
static Tim3State pwm_state;

// Encodes a 4-bit OCxM value for the low (channel 1 or 3) or high (2 or 4)
// half of a CCMR register, with its preload enabled.
static uint32_t ccmr_output(uint32_t ocm, bool high_half) {
    uint32_t value = ((ocm & 0b0111) << 4) | ((ocm >> 3) << 16) | (1u << 3);
    return high_half ? value << 8 : value;
}

static void pulse_halt() {
    RCC->APB1LENR |= RCC_APB1LENR_TIM3EN;
    RCC->AHB2ENR |= RCC_AHB2ENR_GPIOBEN;
    TIM3->CR1 &= ~TIM_CR1_CEN;
    TIM3->CCER &= ~(TIM_CCER_CC1E | TIM_CCER_CC1P | TIM_CCER_CC2E | TIM_CCER_CC2P |
                    TIM_CCER_CC3E | TIM_CCER_CC3P | TIM_CCER_CC4E | TIM_CCER_CC4P);
}

bool pulse_set(int pin, int offset_us, int width_us, int level) {
    if (offset_us < 0 || width_us < 1 || (level != 0 && level != 1)) {
        return false;
    }
    for (Pulse &pulse : pulses) {
        if (pulse.pin == pin) {
            pulse = {pin, pulse.gpio, true, offset_us, width_us, level};
            return true;
        }
    }
    return false;
}

bool pulse_start(int period_us) {
    if (period_us < 2 || (uint32_t)period_us > MAX_PERIOD_US) {
        return false;
    }
    bool any = false;
    for (const Pulse &pulse : pulses) {
        if (pulse.set && (pulse.width_us >= period_us || pulse.offset_us + pulse.width_us > period_us)) {
            return false;
        }
        any = any || pulse.set;
    }
    if (!any) {
        return false;
    }
    RCC->APB1LENR |= RCC_APB1LENR_TIM3EN;
    if (!pulsing) {
        pwm_state = {TIM3->CR1,   TIM3->PSC,  TIM3->ARR,  TIM3->CCMR1, TIM3->CCMR2,
                     TIM3->CCER,  TIM3->CCR1, TIM3->CCR2, TIM3->CCR3,  TIM3->CCR4};
    }
    pulse_halt();

    TIM3->PSC = CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC / TICK_HZ - 1;
    TIM3->ARR = period_us - 1;
    TIM3->CCR4 = pulses[0].offset_us;
    TIM3->CCR3 = pulses[0].offset_us + pulses[0].width_us;
    TIM3->CCR2 = pulses[1].offset_us;
    TIM3->CCR1 = pulses[1].offset_us + pulses[1].width_us;
    TIM3->CCMR2 = ccmr_output(OCM_PWM1, false) | ccmr_output(OCM_COMBINED_PWM2, true);
    TIM3->CCMR1 = ccmr_output(OCM_PWM1, false) | ccmr_output(OCM_COMBINED_PWM2, true);

    uint32_t ccer = 0;
    if (pulses[0].set) {
        ccer |= TIM_CCER_CC4E | (pulses[0].level ? 0 : TIM_CCER_CC4P);
    }
    if (pulses[1].set) {
        ccer |= TIM_CCER_CC2E | (pulses[1].level ? 0 : TIM_CCER_CC2P);
    }
    TIM3->CCER |= ccer;

    TIM3->CR1 |= TIM_CR1_ARPE;
    TIM3->CNT = 0;
    TIM3->EGR = TIM_EGR_UG;
    TIM3->CR1 |= TIM_CR1_CEN;

    // Alternate function 2: TIM3_CH4 on PB1, TIM3_CH2 on PB5.
    for (const Pulse &pulse : pulses) {
        if (pulse.set) {
            uint32_t afr = 4 * pulse.gpio, moder = 2 * pulse.gpio;
            GPIOB->AFR[0] = (GPIOB->AFR[0] & ~(0xFu << afr)) | (2u << afr);
            GPIOB->MODER = (GPIOB->MODER & ~(0b11u << moder)) | (0b10u << moder);
        }
    }
    pulsing = true;
    return true;
}

bool pulse_stop() {
    if (pulsing) {
        pulse_halt();
        uint32_t ccer = pwm_state.ccer;
        for (const Pulse &pulse : pulses) {
            if (pulse.set) {
                GPIOB->MODER &= ~(0b11u << (2 * pulse.gpio));
                ccer &= pulse.pin == 3 ? ~(TIM_CCER_CC4E | TIM_CCER_CC4P) : ~(TIM_CCER_CC2E | TIM_CCER_CC2P);
            }
        }
        TIM3->PSC = pwm_state.psc;
        TIM3->ARR = pwm_state.arr;
        TIM3->CCR1 = pwm_state.ccr1;
        TIM3->CCR2 = pwm_state.ccr2;
        TIM3->CCR3 = pwm_state.ccr3;
        TIM3->CCR4 = pwm_state.ccr4;
        TIM3->CCMR1 = pwm_state.ccmr1;
        TIM3->CCMR2 = pwm_state.ccmr2;
        // Loads the preloaded prescaler and period.
        TIM3->EGR = TIM_EGR_UG;
        TIM3->CCER = ccer;
        TIM3->CR1 = pwm_state.cr1;
    }
    for (Pulse &pulse : pulses) {
        pulse.set = false;
    }
    pulsing = false;
    return true;
}
#endif

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
#if defined(CONFIG_BOARD_ARDUINO_VENTUNO_Q)
    Bridge.provide("pulse/set", pulse_set);
    Bridge.provide("pulse/start", pulse_start);
    Bridge.provide("pulse/stop", pulse_stop);
#endif
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
