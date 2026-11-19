#include "ARTrackerNative.h"
#include <time.h>
#include <sys/time.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <pthread.h>

extern pthread_t pthread_main_thread_np(void);

static uint64_t s_constructor_uptime_ns = 0;
static int64_t  s_constructor_wall_us = 0;

__attribute__((constructor))
static void artn_ctor(void) {
    s_constructor_uptime_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    struct timeval tv;
    if (gettimeofday(&tv, NULL) == 0) {
        s_constructor_wall_us = (int64_t)tv.tv_sec * 1000000LL + (int64_t)tv.tv_usec;
    }
}

uint64_t artn_now_ns(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

uint64_t artn_constructor_uptime_ns(void) {
    return s_constructor_uptime_ns;
}

int64_t artn_constructor_wall_us(void) {
    return s_constructor_wall_us;
}

bool artn_process_start_wall_us(int64_t *out) {
    if (!out) return false;
    struct kinfo_proc kp;
    size_t size = sizeof(kp);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    if (sysctl(mib, 4, &kp, &size, NULL, 0) != 0) {
        return false;
    }
    struct timeval start = kp.kp_proc.p_starttime;
    if (start.tv_sec == 0 && start.tv_usec == 0) {
        return false;
    }
    *out = (int64_t)start.tv_sec * 1000000LL + (int64_t)start.tv_usec;
    return true;
}

thread_t artn_main_mach_thread(void) {
    return pthread_mach_thread_np(pthread_main_thread_np());
}
