#ifndef WAVE_RT_H
#define WAVE_RT_H

#include <stdint.h>
#include <stdbool.h>

// Lock-free helpers for the real-time audio threads.
// Plain int64 storage accessed only through these functions (C11 __atomic builtins).

static inline int64_t wave_atomic_load_acquire(const int64_t *p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline void wave_atomic_store_release(int64_t *p, int64_t v) {
    __atomic_store_n(p, v, __ATOMIC_RELEASE);
}

static inline int64_t wave_atomic_fetch_add(int64_t *p, int64_t v) {
    return __atomic_fetch_add(p, v, __ATOMIC_ACQ_REL);
}

/// Installs SIGINT/SIGTERM handlers that only set a flag (async-signal-safe).
void wave_install_stop_signal_handlers(void);

/// True once SIGINT or SIGTERM has been received.
bool wave_stop_requested(void);

#endif
