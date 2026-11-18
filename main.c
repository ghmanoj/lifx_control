#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#if WITH_MICROPHONE
#include "platform/executable_path.h"
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;
#endif

#if WITH_MICROPHONE
#define MUSIC_USAGE "lifx-control <IP> music [--levels-stdin]"
#else
#define MUSIC_USAGE "lifx-control <IP> music --levels-stdin"
#endif

static const char help_text[] =
    "lifx-control - Control a LIFX Mini W bulb on your local network\n"
    "\n"
    "USAGE\n"
    "  lifx-control <IP> <BRIGHTNESS>\n"
    "  lifx-control <IP> poweroff\n"
    "  lifx-control <IP> get\n"
    "  " MUSIC_USAGE "\n"
    "  lifx-control -h | --help\n"
    "\n"
    "ARGUMENTS AND COMMANDS\n"
    "  <IP>          Bulb's IPv4 address, such as 192.168.1.50.\n"
    "  <BRIGHTNESS>  Percentage from 0 to 100; decimals such as 12.5 are allowed.\n"
    "                Positive values set brightness and turn the bulb on.\n"
    "                0 turns it off, preserving its stored brightness.\n"
    "  poweroff      Turn off without changing the stored brightness.\n"
    "  get           Print stored brightness and power state without changes.\n"
    "                An off bulb may still report nonzero stored brightness.\n"
#if WITH_MICROPHONE
    "  music         Follow the volume of the default microphone.\n"
#else
    "  music         Follow brightness samples from stdin.\n"
#endif
    "\n"
    "OPTIONS\n"
    "  -h, --help      Show this help and exit.\n"
    "  --levels-stdin  For music only: read binary brightness samples from stdin\n"
    "                  at about 10 Hz. Each sample is a two-byte\n"
    "                  little-endian integer from 0 to 65535.\n"
    "                  Closing stdin stops the loop and restores the bulb.\n"
    "\n"
    "MUSIC MODE\n"
#if WITH_MICROPHONE
    "  Keep music paused for the two-second room-noise calibration. Play it\n"
    "  through speakers when \"Ready\" appears. Volume drives brightness from\n"
    "  2% to 100%. Keep lifx-microphone beside this executable.\n"
#endif
    "  Press Ctrl+C to stop and restore the original brightness and power.\n"
    "  Restoration is attempted after errors but requires a reachable bulb.\n"
    "\n"
    "EXAMPLES\n"
    "  lifx-control 192.168.1.50 75       Set brightness to 75% and turn on\n"
    "  lifx-control 192.168.1.50 12.5     Set brightness to 12.5% and turn on\n"
    "  lifx-control 192.168.1.50 poweroff Turn off, retaining brightness\n"
    "  lifx-control 192.168.1.50 get      Read brightness and power state\n"
#if WITH_MICROPHONE
    "  lifx-control 192.168.1.50 music    Start microphone music mode\n"
#endif
    "\n"
    "NETWORK\n"
    "  The bulb must be powered at the wall and reachable over UDP port 56700.\n"
    "  No cloud account or API token is needed. White/color settings are kept.\n"
    "  If requests time out, check the IP, firewall, and Wi-Fi client isolation.\n"
    "\n"
    "EXIT STATUS\n"
    "  0  Success or help displayed\n"
    "  1  Network, protocol, microphone, or runtime failure (including invalid IP)\n"
    "  2  Invalid command-line arguments";

struct bulb {
    int fd;
    uint32_t source;
    uint8_t target[8];
    uint8_t color[8];
    uint16_t power;
};

static uint16_t get16(const uint8_t *p)
{
    return (uint16_t)(p[0] | ((uint16_t)p[1] << 8));
}

static void put16(uint8_t *p, uint16_t value)
{
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
}

static void put32(uint8_t *p, uint32_t value)
{
    put16(p, (uint16_t)value);
    put16(p + 2, (uint16_t)(value >> 16));
}

static void header(const struct bulb *bulb, uint8_t *packet, size_t size,
                   uint16_t type, uint8_t sequence, bool ack)
{
    memset(packet, 0, size);
    put16(packet, (uint16_t)size);
    put16(packet + 2, 0x1400);
    put32(packet + 4, bulb->source);
    memcpy(packet + 8, bulb->target, 8);
    packet[22] = ack ? 2 : 0;
    packet[23] = sequence;
    put16(packet + 32, type);
}

static const uint8_t empty_target[8];

static const char *exchange(const struct bulb *bulb, const uint8_t *request,
                            size_t size, uint16_t expected, uint8_t response[512])
{
    for (int attempt = 0; attempt < 3; attempt++) {
        if (send(bulb->fd, request, size, 0) != (ssize_t)size)
            return "SendFailed";
        // Limit time spent discarding unrelated responses as well as waiting.
        for (int i = 0; i < 10; i++) {
            struct pollfd pfd = { .fd = bulb->fd, .events = POLLIN };
            int ready = poll(&pfd, 1, 100);
            if (!ready || (ready < 0 && errno == EINTR))
                continue;
            if (ready < 0)
                return "PollFailed";
            ssize_t n = recv(bulb->fd, response, 512, 0);
            if (n < 0)
                return "ReceiveFailed";
            if (n < 36 || get16(response) != n ||
                (get16(response + 2) & 0x1fff) != 0x1400 ||
                memcmp(response + 4, request + 4, 4) ||
                response[23] != request[23] || get16(response + 32) != expected)
                continue;
            if (memcmp(request + 8, empty_target, 8) && memcmp(response + 8, request + 8, 8))
                continue;
            return NULL;
        }
    }
    return "BulbTimedOut";
}

static const char *query(struct bulb *bulb)
{
    uint8_t packet[36], response[512];
    header(bulb, packet, sizeof packet, 101, 1, false);
    const char *error = exchange(bulb, packet, sizeof packet, 107, response);
    if (error)
        return error;
    if (get16(response) < 88 || !memcmp(response + 8, empty_target, 8))
        return "InvalidLightState";
    memcpy(bulb->target, response + 8, 8);
    memcpy(bulb->color, response + 36, 8);
    bulb->power = get16(response + 46);
    return NULL;
}

static const char *set_brightness(const struct bulb *bulb, uint16_t level,
                                  uint32_t duration, uint8_t sequence)
{
    uint8_t packet[49], response[512];
    header(bulb, packet, sizeof packet, 102, sequence, true);
    memcpy(packet + 37, bulb->color, 8);
    put16(packet + 41, level);
    put32(packet + 45, duration);
    return exchange(bulb, packet, sizeof packet, 45, response);
}

static const char *set_power(const struct bulb *bulb, uint16_t power, uint8_t sequence)
{
    uint8_t packet[42], response[512];
    header(bulb, packet, sizeof packet, 117, sequence, true);
    put16(packet + 36, power);
    return exchange(bulb, packet, sizeof packet, 45, response);
}

#if WITH_MICROPHONE
static const char *start_microphone(int socket_fd, int *input, pid_t *child)
{
    char path[4096];
    if (!executable_path(path, sizeof path))
        return "ExecutablePathUnavailable";
    char *slash = strrchr(path, '/');
    if (!slash)
        return "HelperPathMissing";
    if (sizeof "/lifx-microphone" > sizeof path - (size_t)(slash - path))
        return "ExecutablePathTooLong";
    strcpy(slash, "/lifx-microphone");

    int pipes[2];
    if (pipe(pipes))
        return "PipeFailed";
    posix_spawn_file_actions_t actions;
    const char *error = "SpawnFailed";
    if (!posix_spawn_file_actions_init(&actions)) {
        if (!posix_spawn_file_actions_addclose(&actions, socket_fd) &&
            !posix_spawn_file_actions_addclose(&actions, pipes[0]) &&
            !posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO) &&
            !posix_spawn_file_actions_addclose(&actions, pipes[1])) {
            char *args[] = { path, NULL };
            error = posix_spawn(child, path, &actions, NULL, args, environ)
                        ? "MicrophoneHelperMissing" : NULL;
        }
        posix_spawn_file_actions_destroy(&actions);
    }
    close(pipes[1]);
    if (error)
        close(pipes[0]);
    else
        *input = pipes[0];
    return error;
}
#endif

static volatile sig_atomic_t stopping;

static void stop_music(int signal_number)
{
    (void)signal_number;
    stopping = 1;
}

static const char *follow_levels(const struct bulb *bulb, int input, bool stdin_levels)
{
    int pending = -1, previous = -1;
    uint8_t sequence = 2;
    fputs("Music mode: listening to volume; press Ctrl+C to stop and restore the bulb.\n", stderr);
    while (!stopping) {
        struct pollfd pfd = { .fd = input, .events = POLLIN };
        int ready = poll(&pfd, 1, 100);
        if (stopping)
            break;
        if (!ready || (ready < 0 && errno == EINTR))
            continue;
        if (ready < 0)
            return "AudioPollFailed";
        uint8_t bytes[256];
        ssize_t n = read(input, bytes, sizeof bytes);
        if (n < 0 && errno == EINTR)
            continue;
        if (n < 0)
            return "AudioReadFailed";
        if (n == 0)
            return stdin_levels && pending < 0 ? NULL : "MicrophoneStopped";
        int latest = -1;
        for (ssize_t i = 0; i < n; i++) {
            if (pending < 0) {
                pending = bytes[i];
            } else {
                latest = pending | (bytes[i] << 8);
                pending = -1;
            }
        }
        if (latest < 0 || (previous >= 0 && abs(latest - previous) < 328))
            continue;
        const char *error = set_brightness(bulb, (uint16_t)latest, 150, sequence++);
        if (!error && previous < 0)
            error = set_power(bulb, UINT16_MAX, sequence++);
        if (error)
            return error;
        previous = latest;
    }
    return NULL;
}

static const char *music(const struct bulb *bulb, bool stdin_levels)
{
    int input = STDIN_FILENO;
#if WITH_MICROPHONE
    pid_t child = 0;
#endif
    struct sigaction action = { .sa_handler = stop_music }, old_int, old_term;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGINT, &action, &old_int))
        return "SignalSetupFailed";
    if (sigaction(SIGTERM, &action, &old_term)) {
        sigaction(SIGINT, &old_int, NULL);
        return "SignalSetupFailed";
    }

    const char *error = NULL;
#if WITH_MICROPHONE
    if (!stdin_levels)
        error = start_microphone(bulb->fd, &input, &child);
#endif
    if (!error) {
        error = follow_levels(bulb, input, stdin_levels);
#if WITH_MICROPHONE
        if (child > 0) {
            close(input);
            kill(child, SIGTERM);
            while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        }
#endif
        const char *restore = set_brightness(bulb, get16(bulb->color + 4), 150, 254);
        if (restore)
            fprintf(stderr, "Could not restore brightness: %s\n", restore);
        restore = set_power(bulb, bulb->power, 255);
        if (restore)
            fprintf(stderr, "Could not restore power: %s\n", restore);
    }
    sigaction(SIGTERM, &old_term, NULL);
    sigaction(SIGINT, &old_int, NULL);
    return error;
}

enum command { GET, BRIGHTNESS, POWEROFF, MUSIC };

static const char *control(const char *ip, enum command command, double percent, bool stdin_levels)
{
    struct sockaddr_in address = { .sin_family = AF_INET, .sin_port = htons(56700) };
    if (inet_pton(AF_INET, ip, &address.sin_addr) != 1 ||
        address.sin_addr.s_addr == INADDR_ANY || address.sin_addr.s_addr == INADDR_BROADCAST)
        return "InvalidIPv4Address";

    if (stdin_levels) {
        int flags = fcntl(STDIN_FILENO, F_GETFL);
        if (flags < 0 || (flags & O_ACCMODE) == O_WRONLY)
            return "StdinNotReadable";
    }

    struct bulb bulb = { .fd = socket(AF_INET, SOCK_DGRAM, 0),
                         .source = (uint32_t)getpid() | UINT32_C(0x80000000) };
    if (bulb.fd < 0)
        return "SocketFailed";
    const char *error = "ConnectFailed";
    if (!connect(bulb.fd, (struct sockaddr *)&address, sizeof address))
        error = query(&bulb);
    if (!error) {
        switch (command) {
        case GET:
            printf("Brightness: %.2f%%\nPower: %s\n", get16(bulb.color + 4) * 100.0 / 65535.0,
                   bulb.power ? "on" : "off");
            break;
        case MUSIC:
            error = music(&bulb, stdin_levels);
            break;
        case BRIGHTNESS:
        case POWEROFF:
            if (percent > 0)
                error = set_brightness(&bulb, (uint16_t)lround(percent * 65535.0 / 100.0), 0, 2);
            if (!error)
                error = set_power(&bulb, percent > 0 ? UINT16_MAX : 0, 3);
            break;
        }
    }
    close(bulb.fd);
    return error;
}

static bool is_help(const char *arg)
{
    return !strcmp(arg, "-h") || !strcmp(arg, "--help");
}

// Zig accepted underscores between digits, including in hexadecimal mantissas.
static bool parse_percent(char *text, double *percent)
{
    const char *digits = text + (*text == '+' || *text == '-');
    bool hex = digits[0] == '0' && (digits[1] == 'x' || digits[1] == 'X');
    char *out = text;
    for (char *p = text; *p; p++) {
        if (*p == 'p' || *p == 'P')
            hex = false;
        if (*p != '_') {
            *out++ = *p;
            continue;
        }
        if (p == text)
            return false;
        unsigned char prev = (unsigned char)p[-1], next = (unsigned char)p[1];
        if (!(hex ? isxdigit(prev) && isxdigit(next) : isdigit(prev) && isdigit(next)))
            return false;
    }
    *out = 0;
    char *end;
    *percent = strtod(text, &end);
    return end != text && !*end && !isspace((unsigned char)*text) &&
           isfinite(*percent) && *percent >= 0 && *percent <= 100;
}

int main(int argc, char **argv)
{
    if ((argc == 2 && is_help(argv[1])) || (argc == 3 && is_help(argv[2])) ||
        (argc == 4 && !strcmp(argv[2], "music") && is_help(argv[3]))) {
        puts(help_text);
        return 0;
    }
    enum command command;
    double percent = 0;
    bool stdin_levels = false;
    if (argc >= 3 && !strcmp(argv[2], "music")) {
        command = MUSIC;
        stdin_levels = argc == 4 && !strcmp(argv[3], "--levels-stdin");
#if !WITH_MICROPHONE
        if (argc == 3) {
            fputs("Use music --levels-stdin or rebuild with make WITH_MICROPHONE=1.\n", stderr);
            return 2;
        }
#endif
        if (argc != 3 && !stdin_levels) {
            fputs("Usage: " MUSIC_USAGE "\n"
                  "Try 'lifx-control --help' for details.\n", stderr);
            return 2;
        }
    } else if (argc != 3) {
        fputs("Usage: lifx-control <IPv4 address> <brightness 0-100|poweroff|get|music>\n"
              "Try 'lifx-control --help' for details.\n", stderr);
        return 2;
    } else if (!strcmp(argv[2], "get")) {
        command = GET;
    } else if (!strcmp(argv[2], "poweroff")) {
        command = POWEROFF;
    } else {
        command = BRIGHTNESS;
        if (!parse_percent(argv[2], &percent)) {
            fputs("Brightness must be a number from 0 to 100.\n", stderr);
            return 2;
        }
    }
    const char *error = control(argv[1], command, percent, stdin_levels);
    if (error) {
        if (command == MUSIC)
            fprintf(stderr, "Music mode failed: %s.\n", error);
        else
            fprintf(stderr, "Failed: %s. Check the IP, bulb power, and local network access.\n", error);
        return 1;
    }
    if (command == POWEROFF)
        fprintf(stderr, "Bulb %s acknowledged power off.\n", argv[1]);
    if (command == BRIGHTNESS)
        fprintf(stderr, "Bulb %s acknowledged brightness %s%%.\n", argv[1], argv[2]);
    return 0;
}
