#ifndef ARTRACKERNATIVE_H
#define ARTRACKERNATIVE_H

#include <stdint.h>
#include <stdbool.h>
#include <mach/mach.h>

#ifdef __cplusplus
extern "C" {
#endif

uint64_t artn_now_ns(void);                         // clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
uint64_t artn_constructor_uptime_ns(void);          // set by __attribute__((constructor))
int64_t  artn_constructor_wall_us(void);            // gettimeofday() in the same constructor
bool     artn_process_start_wall_us(int64_t *out);  // sysctl KERN_PROC_PID p_starttime, µs since epoch
thread_t artn_main_mach_thread(void);               // pthread_mach_thread_np(pthread_main_thread_np())

typedef struct { uint32_t max_samples, max_depth, interval_us, max_duration_ms; } artn_sampler_config;
typedef struct artn_sampler artn_sampler;
artn_sampler *artn_sampler_create(thread_t target, artn_sampler_config cfg); // allocates ALL buffers; NULL on failure
bool      artn_sampler_start(artn_sampler *s);        // spawns the sampling pthread (QOS_CLASS_USER_INTERACTIVE)
void      artn_sampler_request_stop(artn_sampler *s); // non-blocking, safe on the main thread
void      artn_sampler_join(artn_sampler *s);         // blocks until the thread exits; never call on main
uint32_t  artn_sampler_count(const artn_sampler *s);
uint64_t  artn_sampler_time_ns(const artn_sampler *s, uint32_t i);
uint32_t  artn_sampler_depth(const artn_sampler *s, uint32_t i);
const uintptr_t *artn_sampler_frames(const artn_sampler *s, uint32_t i); // leaf first
uint32_t  artn_sampler_final_interval_us(const artn_sampler *s);
uint64_t  artn_sampler_mean_cost_ns(const artn_sampler *s);
void      artn_sampler_destroy(artn_sampler *s);
uint32_t  artn_next_interval_us(uint32_t current_us, uint64_t mean_cost_ns, uint32_t samples_taken);

typedef struct { uintptr_t load, text_start, text_end; uint8_t uuid[16]; bool has_uuid; const char *path; } artn_image;
uint32_t artn_copy_images(artn_image *out, uint32_t cap);   // returns count written

#ifdef __cplusplus
}
#endif

#endif /* ARTRACKERNATIVE_H */
