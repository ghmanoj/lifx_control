#define _POSIX_C_SOURCE 200809L
#include "microphone.h"
#include <alsa/asoundlib.h>
#include <stdio.h>

int capture_microphone(void)
{
    snd_pcm_t *pcm;
    int status = snd_pcm_open(&pcm, "default", SND_PCM_STREAM_CAPTURE, 0);
    if (status < 0) {
        fprintf(stderr, "Could not open the default ALSA input: %s\n", snd_strerror(status));
        return 1;
    }

    enum { sample_rate = 44100, frames_per_update = sample_rate / 10 };
    status = snd_pcm_set_params(pcm, SND_PCM_FORMAT_S16, SND_PCM_ACCESS_RW_INTERLEAVED,
                                1, sample_rate, 1, 200000);
    int16_t samples[frames_per_update];
    size_t used = 0;
    while (status >= 0) {
        snd_pcm_sframes_t n = snd_pcm_readi(pcm, samples + used, frames_per_update - used);
        if (n < 0) {
            status = snd_pcm_recover(pcm, (int)n, 1);
            used = 0;
            continue;
        }
        used += (size_t)n;
        if (used == frames_per_update) {
            if (!emit_microphone_level(microphone_rms(samples, used)))
                break;
            used = 0;
        }
    }
    if (status < 0)
        fprintf(stderr, "ALSA microphone capture failed: %s\n", snd_strerror(status));
    snd_pcm_close(pcm);
    return 1;
}
