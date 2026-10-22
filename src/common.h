#ifndef TSVC_COMMON_HDR
#define TSVC_COMMON_HDR

/* LVX: overridable, because the right values differ by two orders of
 * magnitude between a wall-clock host run and a cycle-accurate ISS.
 *
 * Upstream's 100000 iterations exist to make the elapsed time measurable on a
 * real machine. Under a DETERMINISTIC simulator that repetition buys nothing:
 * one pass gives the exact cycle count, with no averaging and no warm-up
 * ritual. So TSVC_ITERATIONS=1 is the correct setting here rather than a
 * concession -- the same argument that makes lvx-polybench and lvx-ssw
 * measure under the ISS instead of wall-clock.
 *
 * Note it CHANGES THE CHECKSUMS: most loops accumulate across the nl loop
 * (s1221's `b[i] = b[i-4] + a[i]' repeated 100000 times is not the same
 * computation as once), so a checksum from one setting cannot be compared
 * against another, nor against upstream's published values. The reference the
 * harness gates on is generated natively at the SAME settings. */
#ifndef iterations
#define iterations 100000
#endif
#ifndef LEN_1D
#define LEN_1D 32000
#endif
#ifndef LEN_2D
#define LEN_2D 256
#endif

#include <sys/time.h>

struct args_t {
    struct timeval t1;
    struct timeval t2;
    void * __restrict__ arg_info;
};

/* LVX: selected by -DTSVC_DOUBLE rather than by editing an #if 0, so the TYPE
 * axis can be swept from the harness the way lvx-polybench sweeps float and
 * double. The FP latency difference changes RecMII directly, which is the
 * whole point of having the axis. */
#if defined(TSVC_DOUBLE)
typedef double real_t;
#define ABS fabs
#else
typedef float real_t;
#define ABS fabsf
#endif

int dummy(real_t[LEN_1D], real_t[LEN_1D], real_t[LEN_1D], real_t[LEN_1D], real_t[LEN_1D], real_t[LEN_2D][LEN_2D], real_t[LEN_2D][LEN_2D], real_t[LEN_2D][LEN_2D], real_t);

void init(int** ip, real_t* s1, real_t* s2);

int initialise_arrays(const char* name);
real_t calc_checksum(const char * name);

/* LVX: the name of the loop currently running. time_function receives only a
 * function pointer, so without this a row cannot be labelled -- and the
 * handoff is explicit that untagged loop identifiers have already caused two
 * false findings in the CMS work. initialise_arrays sets it. */
extern const char *tsvc_loop_name;

#endif
