#include "ARTrackerNative.h"
#include <stdlib.h>
#include <stdatomic.h>
#include <pthread.h>
#include <unistd.h>
#include <mach/mach.h>

#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#define ARTN_STRIP(p) ((uintptr_t)ptrauth_strip((void *)(p), ptrauth_key_return_address))
#else
#define ARTN_STRIP(p) ((uintptr_t)(p))
#endif

struct artn_sampler {
    thread_t target;
    artn_sampler_config cfg;
    uintptr_t stack_low;
    uintptr_t stack_high;
    pthread_t sampling_thread;
    _Atomic bool stop_requested;
    _Atomic bool thread_started;
    uint32_t count;
    uint64_t *times;
    uint32_t *depths;
    uintptr_t *frames;
    uint32_t final_interval_us;
    uint64_t total_cost_ns;
};

// Runs ONLY while `s->target` is suspended. Must not call malloc/free, take locks, log, or touch ObjC/Swift.
// Reads stay inside [low_bound, stack_high) (stack_low computed in create, sp checked here), so no read can fault.
static uint32_t walk_suspended(const artn_sampler *s, uintptr_t *out, uint32_t max_depth) {
    uintptr_t pc, lr = 0, fp, sp;
#if defined(__arm64__)
    arm_thread_state64_t st;
    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(s->target, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) != KERN_SUCCESS) return 0;
    pc = ARTN_STRIP(arm_thread_state64_get_pc(st));
    lr = ARTN_STRIP(arm_thread_state64_get_lr(st));
    fp = (uintptr_t)arm_thread_state64_get_fp(st);
    sp = (uintptr_t)arm_thread_state64_get_sp(st);
#elif defined(__x86_64__)
    x86_thread_state64_t st;
    mach_msg_type_number_t cnt = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(s->target, x86_THREAD_STATE64, (thread_state_t)&st, &cnt) != KERN_SUCCESS) return 0;
    pc = (uintptr_t)st.__rip;
    fp = (uintptr_t)st.__rbp;
    sp = (uintptr_t)st.__rsp;
#else
    return 0;
#endif
    uintptr_t low_bound = (sp >= s->stack_low && sp < s->stack_high) ? sp : s->stack_low;
    uint32_t n = 0;
    if (pc == 0) return 0;
    out[n++] = pc;
    if (lr != 0 && n < max_depth) out[n++] = lr;      // arm64: caller of a leaf that has not pushed a frame
    bool first = true;
    while (n < max_depth) {
        if (fp < low_bound || fp > s->stack_high - 2 * sizeof(uintptr_t) || (fp & (sizeof(uintptr_t) - 1))) break;
        uintptr_t next_fp = ((const uintptr_t *)fp)[0];
        uintptr_t ret = ARTN_STRIP(((const uintptr_t *)fp)[1]);
        if (ret == 0) break;
        if (!(first && ret == lr)) out[n++] = ret;     // the leaf's saved LR equals `lr`: do not record it twice
        first = false;
        if (next_fp <= fp) break;                       // frames must move toward the stack top; stops cycles
        fp = next_fp;
    }
    return n;   // stopping at max_depth keeps the leaf-most frames and drops the root ones (spec §5.2)
}

static void *sampler_thread_main(void *arg) {
    artn_sampler *s = (artn_sampler *)arg;
    uint64_t start_ns = artn_now_ns();
    uint64_t max_duration_ns = (uint64_t)s->cfg.max_duration_ms * 1000000ULL;
    uint32_t interval_us = s->cfg.interval_us;

    while (!atomic_load_explicit(&s->stop_requested, memory_order_relaxed)) {
        if (s->count >= s->cfg.max_samples) break;
        uint64_t now_ns = artn_now_ns();
        if (now_ns - start_ns >= max_duration_ns) break;

        usleep(interval_us);
        if (atomic_load_explicit(&s->stop_requested, memory_order_relaxed)) break;

        uint64_t t0 = artn_now_ns();
        if (thread_suspend(s->target) != KERN_SUCCESS) {
            break;
        }
        uintptr_t *out_frames = &s->frames[(size_t)s->count * s->cfg.max_depth];
        uint32_t depth = walk_suspended(s, out_frames, s->cfg.max_depth);
        thread_resume(s->target);

        uint64_t t1 = artn_now_ns();
        uint64_t sample_cost = t1 - t0;
        s->total_cost_ns += sample_cost;

        s->times[s->count] = t0;
        s->depths[s->count] = depth;
        s->count++;

        uint64_t mean_cost = s->total_cost_ns / s->count;
        interval_us = artn_next_interval_us(interval_us, mean_cost, s->count);
        s->final_interval_us = interval_us;
    }
    s->final_interval_us = interval_us;
    return NULL;
}

artn_sampler *artn_sampler_create(thread_t target, artn_sampler_config cfg) {
    if (cfg.max_samples == 0 || cfg.max_depth == 0 || cfg.interval_us == 0) {
        return NULL;
    }
    pthread_t p = pthread_from_mach_thread_np(target);
    if (!p) return NULL;

    uintptr_t stack_high = (uintptr_t)pthread_get_stackaddr_np(p);
    size_t stack_size = pthread_get_stacksize_np(p);
    if (stack_high == 0 || stack_size == 0) return NULL;
    uintptr_t stack_low = stack_high - stack_size;

    artn_sampler *s = (artn_sampler *)calloc(1, sizeof(artn_sampler));
    if (!s) return NULL;

    s->target = target;
    s->cfg = cfg;
    s->stack_low = stack_low;
    s->stack_high = stack_high;
    s->final_interval_us = cfg.interval_us;
    atomic_init(&s->stop_requested, false);
    atomic_init(&s->thread_started, false);

    s->times = (uint64_t *)calloc(cfg.max_samples, sizeof(uint64_t));
    s->depths = (uint32_t *)calloc(cfg.max_samples, sizeof(uint32_t));
    s->frames = (uintptr_t *)calloc((size_t)cfg.max_samples * cfg.max_depth, sizeof(uintptr_t));

    if (!s->times || !s->depths || !s->frames) {
        artn_sampler_destroy(s);
        return NULL;
    }

    return s;
}

bool artn_sampler_start(artn_sampler *s) {
    if (!s) return false;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&s->thread_started, &expected, true)) {
        return false;
    }
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    struct sched_param sp;
    sp.sched_priority = sched_get_priority_max(SCHED_RR);
    pthread_attr_setschedparam(&attr, &sp);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);

    int rc = pthread_create(&s->sampling_thread, &attr, sampler_thread_main, s);
    pthread_attr_destroy(&attr);
    return (rc == 0);
}

void artn_sampler_request_stop(artn_sampler *s) {
    if (!s) return;
    atomic_store_explicit(&s->stop_requested, true, memory_order_relaxed);
}

void artn_sampler_join(artn_sampler *s) {
    if (!s) return;
    if (atomic_load_explicit(&s->thread_started, memory_order_relaxed)) {
        pthread_join(s->sampling_thread, NULL);
    }
}

uint32_t artn_sampler_count(const artn_sampler *s) {
    return s ? s->count : 0;
}

uint64_t artn_sampler_time_ns(const artn_sampler *s, uint32_t i) {
    if (!s || i >= s->count) return 0;
    return s->times[i];
}

uint32_t artn_sampler_depth(const artn_sampler *s, uint32_t i) {
    if (!s || i >= s->count) return 0;
    return s->depths[i];
}

const uintptr_t *artn_sampler_frames(const artn_sampler *s, uint32_t i) {
    if (!s || i >= s->count) return NULL;
    return &s->frames[(size_t)i * s->cfg.max_depth];
}

uint32_t artn_sampler_final_interval_us(const artn_sampler *s) {
    return s ? s->final_interval_us : 0;
}

uint64_t artn_sampler_mean_cost_ns(const artn_sampler *s) {
    if (!s || s->count == 0) return 0;
    return s->total_cost_ns / s->count;
}

void artn_sampler_destroy(artn_sampler *s) {
    if (!s) return;
    free(s->times);
    free(s->depths);
    free(s->frames);
    free(s);
}

uint32_t artn_next_interval_us(uint32_t current_us, uint64_t mean_cost_ns, uint32_t samples_taken) {
    if (samples_taken >= 10 && (samples_taken % 10 == 0) && mean_cost_ns > 1000000ULL) {
        uint32_t doubled = current_us * 2;
        return doubled > 40000 ? 40000 : doubled;
    }
    return current_us;
}
