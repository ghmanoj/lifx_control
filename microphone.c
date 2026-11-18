#include "microphone.h"
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct envelope {
    double calibration[20], gate, smoothed;
    int count, attack, quiet;
    bool active;
};

static int compare_db(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

// Each update represents 100 ms. A negative result means calibration is in progress.
static int update(struct envelope *env, double rms)
{
    double db = 20 * log10(fmax(rms, 0.000001));
    if (env->count < 20) {
        env->calibration[env->count++] = db;
        if (env->count == 20) {
            qsort(env->calibration, 20, sizeof(double), compare_db);
            env->gate = fmax(-42, env->calibration[15] + 18);
        }
        return -1;
    }
    if (!env->active) {
        env->attack = db > env->gate ? env->attack + 1 : 0;
        if (env->attack >= 4) {
            env->active = true;
            env->quiet = 0;
        }
    } else {
        env->quiet = db < env->gate - 4 ? env->quiet + 1 : 0;
        if (env->quiet >= 3) {
            env->active = false;
            env->attack = 0;
        }
    }
    double normalized = env->active ? fmin(1, fmax(0, (db - (env->gate - 4)) / 20)) : 0;
    double level = normalized * normalized;
    double delta = (level > env->smoothed ? 0.40 : 0.25) * (level - env->smoothed);
    env->smoothed += fmin(0.06, fmax(-0.04, delta));
    if (!env->active && env->smoothed < 0.005)
        env->smoothed = 0;
    return (int)lround((0.02 + 0.98 * env->smoothed) * 65535);
}

static int at_db(struct envelope *env, double db)
{
    return update(env, pow(10, db / 20));
}

static bool self_test(void)
{
    struct envelope env = {0}, noisy = {0};
    int idle = (int)lround(0.02 * 65535);
    for (int i = 0; i < 20; i++)
        if (at_db(&env, -55) != -1 || at_db(&noisy, -38) != -1)
            return false;
    double noise[] = {-57, -53, -51, -49, -54, -52, -45, -40, -39, -20, -55};
    for (size_t i = 0; i < sizeof noise / sizeof noise[0]; i++)
        if (at_db(&env, noise[i]) != idle)
            return false;
    int previous = idle;
    for (int i = 0; i < 160; i++) {
        int value = at_db(&env, i < 60 ? -20 : -55);
        if (abs(value - previous) > 3854 || (i == 59 && (!env.active || env.smoothed <= 0.9)))
            return false;
        previous = value;
    }
    if (env.active || at_db(&env, -55) != idle)
        return false;
    for (int i = 0; i < 60; i++)
        at_db(&env, -34);
    if (at_db(&env, -34) >= 0.20 * 65535)
        return false;
    for (int i = 0; i < 60; i++)
        at_db(&env, -20);
    double noisy_room[] = {-39, -35, -33, -37};
    for (size_t i = 0; i < sizeof noisy_room / sizeof noisy_room[0]; i++)
        if (at_db(&noisy, noisy_room[i]) != idle)
            return false;
    return at_db(&env, -20) > 0.90 * 65535;
}

double microphone_rms(const int16_t *samples, size_t count)
{
    double sum = 0;
    for (size_t i = 0; i < count; i++) {
        double sample = samples[i] / 32768.0;
        sum += sample * sample;
    }
    return count ? sqrt(sum / count) : 0;
}

bool emit_microphone_level(double rms)
{
    static struct envelope env;
    int level = update(&env, rms);
    if (level < 0) {
        if (env.count == 20)
            fprintf(stderr, "Ready. Play music now (noise gate: %.1f dBFS).\n", env.gate);
        return true;
    }
    uint8_t bytes[] = { (uint8_t)level, (uint8_t)(level >> 8) };
    return write(STDOUT_FILENO, bytes, sizeof bytes) == sizeof bytes;
}

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--self-test")) {
            if (!self_test()) {
                fputs("Noise gate tests failed\n", stderr);
                return 1;
            }
            puts("Noise gate tests passed");
            return 0;
        }
    }
    fputs("Calibrating room noise for two seconds. Keep music paused until ready.\n", stderr);
    return capture_microphone();
}
