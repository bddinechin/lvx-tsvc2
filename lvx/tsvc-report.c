// Part of the LVX project, under the Apache License v2.0 with LLVM Exceptions.
// See LICENSE.TXT in the root of the lvx-perf repository for license
// information. Upstream TSVC_2 is under the University of Illinois/NCSA Open
// Source License (license.txt), which is permissive, so an Apache-2.0 file
// sits alongside it without difficulty -- the arrangement lvx-ssw uses over
// MIT upstream. (lvx-turbopfor cannot: GPL-2.0 upstream, and Apache-2.0 does
// not combine into GPLv2.)
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

/* One machine-readable row per loop, for harness/run.sh.
 *
 * WHY NOT UPSTREAM'S printf, and the second reason is the one that matters.
 * Bare metal under gem5 has crt.S's write(2) and exit(2) and nothing else, so
 * printf is unavailable. And upstream renders the checksum through %f, which
 * is a LOSSY comparison of the value this suite uses as its correctness
 * oracle: a decimal float cannot be compared exactly, so the oracle would be
 * fuzzy precisely where it must not be.
 *
 * So the checksum goes out as its raw BIT PATTERN, unsigned. Two runs agree or
 * they do not, with no formatting in between. A human cannot read that, so an
 * approximate decimal goes out beside it, clearly marked and never compared.
 *
 * The number printers are LOCAL rather than taken from lvx-ssw's lvx-io.h,
 * even though the licences permit sharing: that file's putnum appends a
 * newline, which suits its one-value-per-line output and would break every row
 * here. Shareable is not the same as suitable.
 */
#include <stdint.h>
#include <string.h>
#include "../src/common.h"

/* write(2) on both platforms: this suite links hosted against newlib, as
   lvx-polybench does, so there is no need for crt.S's sys_write and no
   __lvx__ split here. printf is available too -- it is avoided only because
   its %f would make the checksum comparison inexact. */
#include <unistd.h>
static void emit (const char *b, unsigned long n) { (void)!write (1, b, n); }

static void put (const char *s)
{
	unsigned long n = 0;
	while (s[n]) n++;
	emit (s, n);
}

/* No trailing newline: these build one tab-separated row. */
static void putu (uint64_t v)
{
	char b[24];
	unsigned i = sizeof b;
	if (!v) b[--i] = '0';
	while (v) { b[--i] = (char) ('0' + v % 10); v /= 10; }
	emit (&b[i], sizeof b - i);
}

static void puti (long long v)
{
	if (v < 0) { put ("-"); putu ((uint64_t) -v); }
	else putu ((uint64_t) v);
}

void tsvc_report_header (void)
{
	/* Named columns: a reader should not have to count tabs, and the unit of
	   `elapsed' differs by build -- cycles from $frcc on the target,
	   microseconds from gettimeofday natively -- so the harness records which
	   rather than the column name implying one. */
	put ("# RESULT\tloop\telapsed\tchecksum_bits\tchecksum_approx\n");
}

void tsvc_report (const char *name, long long elapsed, real_t checksum)
{
	/* memcpy rather than a union or a pointer cast: exactness matters here and
	   type-punning through a pointer is an aliasing violation GCC may act on. */
	uint64_t bits = 0;
	if (sizeof (real_t) == 4) {
		uint32_t b32;
		memcpy (&b32, &checksum, sizeof b32);
		bits = b32;
	} else {
		memcpy (&bits, &checksum, sizeof bits);
	}

	put ("RESULT\t");   put (name);
	put ("\telapsed ");  puti (elapsed);
	/* Unsigned throughout: a float's sign bit is just bit 63 of the pattern,
	   and printing it as a negative number would make the oracle depend on
	   how the reader re-parses it. */
	put ("\tchecksum_bits "); putu (bits);

	/* Approximate, for human eyes only. Marked in the column name. */
	{
		long long whole = (long long) checksum;
		real_t frac = checksum - (real_t) whole;
		if (frac < 0) frac = -frac;
		put ("\tchecksum_approx "); puti (whole);
		put ("."); putu ((uint64_t) (frac * (real_t) 1000));
	}
	put ("\n");
}
