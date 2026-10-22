// Part of the LVX project, under the Apache License v2.0 with LLVM Exceptions.
// See LICENSE.TXT in the root of the lvx-perf repository for license
// information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

/* gettimeofday reading LVX's free-running cycle counter.
 *
 * The 151 loops each bracket their work with two gettimeofday calls -- 302
 * call sites. Overriding the function is therefore the whole of the timing
 * port: not one of those sites changes, and the suite keeps working unmodified
 * on the host.
 *
 * newlib DOES provide a gettimeofday for lvx-mbr, which is why this file
 * matters: its bare-metal stub has no clock behind it, so without an override
 * every interval would come back identical and the suite would report
 * plausible-looking zero times. The linker prefers a definition in an object
 * over one in an archive, so listing this before -lc is enough.
 *
 * THE PACKING IS CHOSEN SO UPSTREAM'S ARITHMETIC STAYS EXACT. tsvc.c
 * reconstructs the interval as tv_sec * 1000000 + tv_usec in integers, so
 * splitting the cycle count at a million puts the whole value back together
 * with no rounding -- where storing it as seconds-and-fraction would quantise
 * a cycle figure into uselessness. The reconstructed number is therefore
 * CYCLES on the target and microseconds natively, and the harness records
 * which rather than leaving the column name to imply one.
 */
#include <sys/time.h>

int gettimeofday (struct timeval *tv, void *tz)
{
	unsigned long long c;

	(void) tz;
	if (!tv)
		return 0;

	__asm__ __volatile__ ("get %0 = $frcc\n\t;;" : "=r"(c) : : "memory");

	tv->tv_sec  = (long) (c / 1000000ull);
	tv->tv_usec = (long) (c % 1000000ull);
	return 0;
}
