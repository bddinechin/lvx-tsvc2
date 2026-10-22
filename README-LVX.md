# lvx-tsvc2 — TSVC_2 as an LVX vectorization and modulo-scheduling benchmark

Upstream: https://github.com/UoB-HPC/TSVC_2 (forked at `911fc63`, 2026-10-14).
This branch, `lvx-tsvc2`, carries the LVX port; `main` tracks upstream.

**Why this one.** TSVC is the Test Suite for Vectorizing Compilers: 151 loops
written to probe what a vectorizer can and cannot do. Two things in `lvx-perf`
wanted it.

It is the **vectorization** instrument. `lvx-polybench` measures dense FP loop
nests and `lvx-ssw` measures hand-written SIMD; neither asks *did the
vectorizer fire on this shape, and did firing help*. That question needs a
vectorized and a non-vectorized build of the same loop, which is what upstream
provides and what the harness here measures as a ratio.

And it is the **modulo-scheduling** instrument, which is why it was requested.
`lvx-csw/docs/handoff-lvx-perf-tsvc.md` wanted loop shapes PolyBench does not
have: symbolic distances (`s162` `a[i] = a[i+k]`, `s175`, `s431`) where the
compiler must be conservative; Σω > 1 circuits; coupled recurrences and
wrap-around *scalars* (`s254`, `s255`, `s291`, `s292`), which
`-mcms-inductive-relaxation` had never been tested against; and single-basic-block
loops with simple trip counts, where SMS should accept far more than the 17 of
84 PolyBench loop instances it managed.

## What it measures, and the axes

Four axes. Three of them are *pairs*, because a pair is a measurement where a
single value is only a setting.

| axis | values | the pair measures |
|---|---|---|
| `VEC` | `vec` / `novec` | **what TSVC exists for**: did the vectorizer fire, and did it help |
| `TYPE` | `float` / `double` | how much of the 128-bit lane it got — four floats or two doubles |
| `FPMODE` | `default` / `fast` / `precise` | upstream's three variants |
| `ARCH` | `lvx-1` / `lvx-2` | the scalar core against the vector one |

```bash
./harness/run.sh                   # both types x both vec settings, lvx-2 -O2
./harness/run.sh --csw /path/to/lvx-csw
VEC=vec TYPE=float ./harness/run.sh
STATIC_ONLY=1 ./harness/run.sh     # build + static metrics, seconds, no ISS
VECREPORT=1 ./lvx/run-tsvc.sh      # -fopt-info-vec-all, per-loop vectorizer notes
./harness/make-reference.sh        # regenerate the native correctness oracle
./harness/cms-probe.sh             # the compile-only dependence-graph probe
./harness/compare.sh results/A.tsv results/B.tsv
```

The vec/novec ratio is reported **per loop**. An aggregate would average a loop
the vectorizer transformed with one it refused and describe neither. Use
`VECREPORT=1` (`-fopt-info-vec-all`) rather than counting SIMD instructions to
decide whether a given loop vectorized — the same guidance `lvx-polybench`
records, because an instruction count conflates the loop under test with
everything else in the image.

`FPMODE=precise` is **identical to `default`** and exists only to keep the names
aligned with upstream: GCC has no precise-math flag, and upstream's own
`makefiles/Makefile.gcc` warns `"No 'precise' math flags for gcc!"`.

## Correctness: the suite's own checksums, against a native oracle

Every loop returns a checksum, so the oracle comes free — but two things about
it matter.

It is compared as a **raw bit pattern**, not through `%f`. A decimal rendering
of a float is a lossy comparison, and this value is the gate: it has to be
exact or it is not a gate. `lvx/tsvc-report.c` emits the bits and an
approximate decimal beside them, the latter marked and never compared.

And the reference is **generated natively** by `harness/make-reference.sh`,
because a reference taken from the target could only perpetuate a target
miscompile, never detect one — `lvx-polybench`'s `reference-output/` is built
the same way for the same reason.

**The reference is settings-specific, and this is particular to TSVC.** Most
loops accumulate across the `nl` loop, so a checksum is a function of
`iterations` as well as of the code: `s1221`'s `b[i] = b[i-4] + a[i]` run once
is not the computation it is run 100000 times. The reference filename therefore
carries `(iterations, LEN_1D, LEN_2D, type)`, and a run with no matching
reference reports `noref` rather than comparing against the wrong one. It also
means **these checksums do not match upstream TSVC's published figures.**

`iterations` defaults to **1**, which is correct rather than a shortcut:
upstream's 100000 exists to make the elapsed time measurable on real hardware,
and a deterministic ISS gives the exact cycle count in one pass with no
averaging.

## The port: six changes, two of them upstream bugs

| change | why |
|---|---|
| `iterations`, `LEN_1D`, `LEN_2D` → `#ifndef`-guarded | the right values differ by orders of magnitude between a host run and an ISS |
| `real_t` by `-DTSVC_DOUBLE`, not an `#if 0` | makes the TYPE axis sweepable |
| **`src/dummy.c`: 9× `float` → `real_t`** | **upstream bug** — the signature was spelled `float` while `common.h` declares it `real_t`, so `-DTSVC_DOUBLE` does not compile upstream at all |
| `posix_memalign` → `memalign` | newlib ships `memalign` and `aligned_alloc` but not `posix_memalign`; `lvx-polybench/utilities/polybench.c:557` needed the identical substitution |
| `tsvc_loop_name`, and integer timing in `time_function` | upstream reconstructs the interval in `double` seconds, which would quantise a cycle count away; and `time_function` receives only a function pointer, so without the name a row cannot be labelled |
| removed `common.c`'s `printf("%5s\t", name)` | it printed the loop name mid-stream, landing on the previous row's line |

The handoff is explicit that **untagged loop identifiers have already caused
two false findings** in the CMS work, which is why the name hook exists and why
`cms-probe.sh` tags every dump line with its source file.

### `lvx/tsvc-time.c` is the whole timing port

One `gettimeofday` override reading `$frcc`. It covers **302 call sites**
without touching one of them, and the suite keeps working unmodified on the
host.

It has to be an *override* rather than a new function: newlib **does** provide
`gettimeofday` for `lvx-mbr`, but its bare-metal stub has no clock behind it,
so without this every interval would come back identical and the suite would
report plausible-looking zeros. The linker prefers a definition in an object
over one in an archive, so listing it before `-lc` is enough.

The packing — `(cycles / 1000000, cycles % 1000000)` — is chosen so upstream's
own `tv_sec * 1000000 + tv_usec` reconstruction comes back **exact**. The
reconstructed figure is therefore cycles on the target and microseconds
natively, and the harness records which rather than letting a column name imply
one.

## Known blocker: an lvx-gcc ICE under FPMODE=fast

A vectorized float reciprocal ICEs the back end on lvx-2:

```c
void g (float *a, const float *b, int n)
{ for (int i = 0; i < n; i++) a[i] = 1.0f / b[i]; }     /* -O2 -march=lvx-2 -ffast-math */
```

`-ffast-math` turns the division into a reciprocal multiply, and the resulting
`UNSPEC_FMUL` carries a `const_vector` operand where the pattern wants a
register — unrecognized at RTL pass `vregs`, `extract_insn`, `recog.cc:2894`.
The same shape as the TImode-shift ICE this project fixed in `ddb027f279a`: an
insn built by a direct `gen_*` call that nothing validated.

Exactly **one of eight** combinations, and *not* width-dependent:

```
lvx-2 -ffast-math float     ICE        V4SF  (128-bit)  ICE
lvx-2 -ffast-math double    ok         V8SF  (256-bit)  ICE
lvx-2 no-ffast   float      ok         V16SF (512-bit)  ICE
lvx-1 (all four)            ok
```

Reported to the `lvx-csw` session on 2026-10-22. `FPMODE` therefore defaults to
`default` rather than the suite waiting for the fix; `fast` works today on
`lvx-1` and on `lvx-2` with `TYPE=double`.

**Why no existing suite caught it**, since it is not an exotic idiom:
`lvx-polybench` is the FP-heavy suite and its flags carry no `-ffast-math`; the
CMS probe flags do carry it but use `-march=lvx-1`, which has no packed FP.
TSVC is the first thing here to put the two together — and it failed in
`common.c:143`, an array-fill helper, not a kernel.

## The CMS/SMS probe, and what it settled

`harness/cms-probe.sh` is **compile-only**: the probe and the SMS dumps are
compile-time artefacts, so it needs no ISS, no execution and no oracle, and it
runs while the ISS is mid-rename. It emits the two invocations the handoff
specifies and tags every dump line with its source file.

Measured on lvx-1 `-O2` float, across all 151 loops — 5747 CMS arcs over 428
graphs:

| arc kind | ω | count |
|---|---|---|
| `reg-raw` | 1 | 2518 |
| `reg-raw` | 0 | 1804 |
| `mem-cross` | 1 | 520 |
| `ctrl-store` | 1 | 307 |
| `ctrl-liveout` | 1 | 272 |
| `mem-intra` | 0 | 190 |
| **any** | **> 1** | **0** |

**Not one arc of 5747 carries ω > 1**, and `reg-raw` is 75% of them. That
confirms the handoff's own correction at suite scale rather than from the two
loops it could test by hand: an arc's distance and a circuit's Σω are different
things, GCC absorbs small-distance array recurrences into register rotations,
and for large distances it uses two base pointers so the stride test cannot
relate the references.

So **do not read a missing ω > 1 here as a gap**, and do not add loops hoping
to reach `LVX_CMS_MAX_DELTA`, the arc-drop rule or `ncopy = delta + 4`. That
machinery is reached by `#pragma omp simd safelen(n)`, which TSVC does not
carry.

SMS for comparison: 620 loop instances, 141 graphs, 2461 arcs — accepting
roughly a third of what CMS probes here, against 17 of 84 on PolyBench. The
better acceptance rate the handoff expected looks real; it is not yet broken
down per loop.

One thing to expect rather than read as a fault: **one "holds a call" decline
per function.** `dummy()` sits in the outer `nl` loop, not the inner one, so
the inner loops are clean and the outer ones are correctly refused.

## Licensing

Upstream is the **University of Illinois/NCSA Open Source License**
(`license.txt`) — permissive, BSD-3-family. GitHub reports it as `NOASSERTION`
only because the file is lowercase.

That is permissive in both directions, so the LVX-specific files here carry the
LVX `Apache-2.0 WITH LLVM-exception` header and code may be shared with
`lvx-ssw` freely. `lvx-turbopfor` cannot do this — GPL-2.0 upstream, and
Apache-2.0 does not combine into GPLv2 — which is why that suite carries
deliberate duplicates and this one does not.

One judgement worth recording anyway: `lvx/tsvc-report.c` has its own small
number printers rather than using `lvx-ssw`'s `lvx-io.h`, which the licences
would have permitted. That file's `putnum` appends a newline, which suits its
one-value-per-line output and would break every row here. Shareable is not the
same as suitable.
