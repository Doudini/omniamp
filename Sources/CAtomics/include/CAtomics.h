#pragma once
#include <stdint.h>

// Lock-free 64-bit counters shared between the audio render thread and the file reader (FileRenderer).
// Swift 5.10 on macOS 14 has no atomics of its own, and the render thread must never take a lock.

static inline int64_t oa_load(const int64_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void oa_store(int64_t *p, int64_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
static inline int64_t oa_add(int64_t *p, int64_t v) { return __atomic_add_fetch(p, v, __ATOMIC_ACQ_REL); }
