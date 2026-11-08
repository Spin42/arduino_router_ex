// SPDX-License-Identifier: Apache-2.0
//
// Relays bytes between a serial port and an Erlang port (stdin/stdout).
//
//   arduino_router_ex_tty DEVICE SPEED
//
// Opening the tty raises DTR, which a sketch's Bridge waits for before it
// sends its first request; unlike Circuits.UART, this does not flush the tty
// after opening it, so that request is not lost. Exits 2 when the device
// cannot be opened, 3 when it fails or goes away, and 0 when stdin closes.

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

static speed_t to_speed(long baud)
{
    switch (baud) {
    case 9600: return B9600;
    case 19200: return B19200;
    case 38400: return B38400;
    case 57600: return B57600;
    case 115200: return B115200;
    case 230400: return B230400;
    case 460800: return B460800;
    case 921600: return B921600;
    default: return B115200;
    }
}

static int write_all(int fd, const unsigned char *buf, ssize_t len)
{
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN)
                continue;
            return -1;
        }
        buf += n;
        len -= n;
    }
    return 0;
}

int main(int argc, char *argv[])
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s DEVICE SPEED\n", argv[0]);
        return 1;
    }

    int tty = open(argv[1], O_RDWR | O_NOCTTY);
    if (tty < 0)
        return 2;

    struct termios tio;
    if (tcgetattr(tty, &tio) < 0)
        return 2;
    cfmakeraw(&tio);
    tio.c_cflag |= CLOCAL | CREAD;
    tio.c_cc[VMIN] = 1;
    tio.c_cc[VTIME] = 0;
    cfsetspeed(&tio, to_speed(strtol(argv[2], NULL, 10)));
    if (tcsetattr(tty, TCSANOW, &tio) < 0)
        return 2;

    unsigned char buf[4096];
    struct pollfd fds[2] = {
        {.fd = STDIN_FILENO, .events = POLLIN},
        {.fd = tty, .events = POLLIN},
    };

    for (;;) {
        if (poll(fds, 2, -1) < 0) {
            if (errno == EINTR)
                continue;
            return 3;
        }

        if (fds[1].revents & (POLLERR | POLLHUP | POLLNVAL))
            return 3;
        if (fds[1].revents & POLLIN) {
            ssize_t n = read(tty, buf, sizeof(buf));
            if (n <= 0 || write_all(STDOUT_FILENO, buf, n) < 0)
                return 3;
        }

        if (fds[0].revents & POLLIN) {
            ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
            if (n <= 0)
                return 0;
            if (write_all(tty, buf, n) < 0)
                return 3;
        } else if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) {
            return 0;
        }
    }
}
