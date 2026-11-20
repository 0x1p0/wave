#include "WaveRT.h"
#include <signal.h>

static volatile sig_atomic_t wave_stop_flag = 0;

static void wave_stop_handler(int sig) {
    (void)sig;
    wave_stop_flag = 1;
}

void wave_install_stop_signal_handlers(void) {
    struct sigaction sa;
    sa.sa_handler = wave_stop_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

bool wave_stop_requested(void) {
    return wave_stop_flag != 0;
}
