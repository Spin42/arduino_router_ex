// Exercises arduino_router_ex: functions Linux calls, a call and a notification
// to Linux, and the monitor in both directions.

#include <Arduino_RouterBridge.h>
#include <Arduino_LED_Matrix.h>

// 8 rows of 13 pixels, one brightness byte (0-255) per pixel, row by row.
static const size_t MATRIX_PIXELS = 104;

Arduino_LED_Matrix matrix;

String ping() {
    return String("pong");
}

String version() {
    return String("bridge_test 2");
}

int add(int a, int b) {
    return a + b;
}

bool matrix_draw(MsgPack::bin_t<uint8_t> frame) {
    if (frame.size() != MATRIX_PIXELS) {
        return false;
    }
    matrix.draw(frame.data());
    return true;
}

bool matrix_clear() {
    uint8_t blank[MATRIX_PIXELS] = {0};
    matrix.draw(blank);
    return true;
}

void setup() {
    matrix.begin();
    matrix.setGrayscaleBits(8);

    Bridge.begin();
    Monitor.begin();

    Bridge.provide("ping", ping);
    Bridge.provide("version", version);
    Bridge.provide("add", add);
    Bridge.provide("matrix_draw", matrix_draw);
    Bridge.provide("matrix_clear", matrix_clear);
}

void loop() {
    static unsigned long last = 0;

    if (millis() - last >= 2000) {
        last = millis();
        Bridge.notify("bridge_test/tick", (int)(last / 1000));

        String time;
        if (Bridge.call("linux_time").result(time)) {
            Monitor.print("linux_time: ");
            Monitor.println(time);
        }
    }

    if (Monitor.available()) {
        String line = Monitor.readStringUntil('\n');
        Monitor.print("echo: ");
        Monitor.println(line);
    }

    delay(10);
}
