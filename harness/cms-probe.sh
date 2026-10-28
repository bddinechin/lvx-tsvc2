#!/usr/bin/env bash
# Part of the LVX project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#
# CMS and SMS dependence-graph probe over TSVC's 151 loops. COMPILE-ONLY.
#
#   ./harness/cms-probe.sh                  # lvx-1, float, both invocations
#   TYPE=double ./harness/cms-probe.sh
#   ARCH=lvx-2 ./harness/cms-probe.sh
#   ./harness/cms-probe.sh --csw /path/to/lvx-csw
#
# Writes results/cms-<arch>-<opt>-<type>.txt and a summary to stdout.
#
# NO EXECUTION, NO ISS, NO ORACLE. The CMS probe and the SMS dumps are
# compile-time artefacts, so this runs today and is unaffected by the ISS being
# mid-rename. The timed side of this suite lives in harness/run.sh and is a
# separate question from this one.
#
# WHY TSVC RATHER THAN MORE POLYBENCH, from lvx-csw/docs/handoff-lvx-perf-tsvc.md
# and worth repeating here because the first answer was wrong:
#
#   - Symbolic distances -- s162 (a[i] = a[i+k]), s175 (a[i] = a[i+inc]), s431.
#     The distance is unprovable so the compiler must be conservative, which is
#     exactly where ivdep or the stride test decides whether pipelining
#     happens. PolyBench has nothing of this shape.
#   - Sigma-omega > 1 circuits, which PolyBench never produced. b[i-6] gives
#     RecMII 2 from Sigma-theta 10: real amortisation of a recurrence across
#     iterations.
#   - Recurrence shapes seen once -- coupled through two arrays (s323), and
#     wrap-around SCALARS (s254, s255, s291, s292), which is what modulo
#     expansion and -mcms-inductive-relaxation have never been tested against.
#   - A much better SMS acceptance rate: single-basic-block loops with simple
#     trip counts, where SMS accepted only 17 of 84 PolyBench loop instances.
#
# What it is NOT for: the handoff's first version expected these loops to
# exercise LVX_CMS_MAX_DELTA and the arc-drop rule. They do not. An arc's
# distance and a circuit's Sigma-omega are different things, GCC turns
# small-distance array recurrences into register rotations, and for large
# distances it uses two base pointers so the stride test cannot relate the
# references. That machinery is reached by `#pragma omp simd safelen(n)`
# instead -- and that is now confirmed rather than conjectured: lvx-gcc
# 1e89883136c carries loop->safelen into late RTL, where it had been dying at
# pass_rtl_loop_done (whose properties_destroyed names PROP_loops), and a
# safelen(4) loop yields mem-cross at omega=4, delta=4, RecMII 2 against 7 for
# the same body unannotated. So the machinery IS exercised, by a pragma and
# never by an array distance. Do not read a missing delta > 1 here as a gap.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"

ARCH=${ARCH:-lvx-1}        # the handoff's flags are lvx-1: CMS work is on the scalar core
OPT=${OPT:-O2}
TYPE=${TYPE:-float}

CSW_ARG=
while [ $# -gt 0 ]; do
    case "$1" in
        --csw)   CSW_ARG=${2:?--csw needs a path}; shift 2 ;;
        --csw=*) CSW_ARG=${1#--csw=}; shift ;;
        -h|--help) sed -n '5,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$TYPE" in float|double) ;; *) echo "TYPE must be float or double" >&2; exit 2 ;; esac

# lvx-csw holds the toolchain; its location is a parameter. Delegated to
# lvx-perf's resolver by INVOCATION so there is one copy of that chain.
resolve_csw() {
    [ -n "$CSW_ARG" ] && { printf '%s\n' "$CSW_ARG"; return 0; }
    [ -n "${LVX_CSW:-}" ] && { printf '%s\n' "$LVX_CSW"; return 0; }
    local super c
    super=$(git -C "$repo" rev-parse --show-superproject-working-tree 2>/dev/null) || super=
    [ -n "$super" ] && [ -x "$super/bin/lvx-csw-path" ] && "$super/bin/lvx-csw-path" 2>/dev/null && return 0
    for c in ${super:+"$super/../lvx-csw"} "$repo/../lvx-csw" "$HOME/lvx-csw"; do
        [ -d "$c/lvx-mds" ] || [ -d "$c/validation" ] || continue
        (cd "$c" && pwd); return 0
    done
    return 1
}
CSW=$(resolve_csw) || { echo "cannot find lvx-csw; pass --csw or set LVX_CSW" >&2; exit 2; }
G=$CSW/lvx-toolchain/bin/lvx-mbr-gcc
[ -x "$G" ] || { echo "no cross compiler at $G -- is lvx-csw built?" >&2; exit 2; }

tmacro=""; [ "$TYPE" = double ] && tmacro="-DTSVC_DOUBLE"
out="$repo/results/cms-$ARCH-$OPT-$TYPE.txt"
work=$(mktemp -d); trap 'rm -rf "$work"' 0 1 2 3 15

# The two invocations the handoff specifies.  SMS needs hardware loops on -- it
# requires the doloop.
#
# THE STANDING CONFIGURATION, 2026-10-28.  Three things changed under this
# script and two of them had removed the options it used:
#
#   -mcms-dump-arcs          DELETED (lvx-gcc 510aa0c2e64).  It existed for one
#                            offline join, which §7nonies completed; the arc
#                            kind x omega summary below went with it.
#   --param=sms-assume-ivdep REVERTED to upstream (578092468ae).  It was a hunk
#                            in generic ddg.cc affecting every target.  The
#                            sound replacement is in-tree: add_inter_loop_mem_dep
#                            drops the edge on loop->safelen > 1 and sms_schedule
#                            rejects when the stage count exceeds it, so a
#                            `#pragma omp simd safelen(n)' states the assumption
#                            soundly.  TSVC carries no pragma, so the SMS side
#                            now runs WITHOUT the relaxation and its K is
#                            correspondingly inflated -- stated rather than
#                            worked around, since the alternative is an unsound
#                            flag in a shared file.
#   -mcms-assume-ivdep       now REQUIRES -mcms-probe and is a hard error
#                            without it (4c25f72bcab, §7decies' correctness
#                            deadline).  Both invocations below pass the probe,
#                            so both are legal.
#
# And the configuration the author asks experiments to run in
# (docs/cms-foundations.md §7octovicies.2): ivdep forced, loop-variant-address
# loads given the uncached latency, and exact expansion degrees.
#   -mcms-assume-ivdep             pipelining only engages at all in this regime
#   -mcms-force-speculative-loads  makes those loads BE the .us form the
#                                  15-cycle default latency prices.  Its own
#                                  default is off, so forgetting it charges an
#                                  uncached latency to a cached load
#   -mcms-exact-degree             power-of-two rounding inflates `squeeze'
#                                  without touching pressure (§7octodecies.5)
CMS_FLAGS="-mcms-probe -mcms-assume-ivdep -mcms-force-speculative-loads"
CMS_FLAGS="$CMS_FLAGS -mcms-exact-degree -fdump-rtl-mach"
SMS_FLAGS="-fmodulo-sched -fmodulo-sched-allow-regmoves"
SMS_FLAGS="$SMS_FLAGS $CMS_FLAGS -fdump-rtl-sms"

probe() {   # $1 = tag (cms|sms), $2... = extra flags
    local tag=$1; shift
    local d="$work/$tag"; mkdir -p "$d"
    ( cd "$d" && for src in "$repo/src/tsvc.c" "$repo/src/common.c"; do
        "$G" -$OPT -march="$ARCH" -ffast-math $tmacro "$@" \
             -I"$repo/src" -c "$src" -o /dev/null 2>>"$d/stderr.txt" || true
      done )
    # TAG EVERY LINE WITH ITS SOURCE FILE.  Loop numbers are not unique across
    # translation units, and the handoff records that reading an untagged
    # `loop 8' already cost two false findings in this work.  One sed is enough
    # and it is not optional.
    #
    # NOR ARE THEY UNIQUE WITHIN ONE FILE, which the file tag alone does not
    # fix: a loop number is assigned inside one FUNCTION's loop tree, so two
    # functions in one translation unit can both have a `loop 3'.  That cost a
    # real loop out of every PolyBench sweep until 2026-10-28 and made the
    # corpus read as 162 loops instead of 163 (§7octovicies.1).  The probe now
    # prints `fn=<function>' on every line, so the key here is
    # (pass, source, fn, loop) -- all four parts, and the fn= part comes from
    # the compiler rather than from this script.
    for f in "$d"/*.mach "$d"/*.sms; do
        [ -f "$f" ] || continue
        local base; base=$(basename "$f")
        local srcname=${base%%.*}
        grep -hE '^;; lvx (cms|graph cms|arc cms)' "$f" 2>/dev/null \
          | sed "s|^|$tag\t$srcname\t|"
    done
}

{
    printf '# CMS/SMS probe over TSVC_2. arch=%s opt=-%s type=%s\n' "$ARCH" "$OPT" "$TYPE"
    printf '# toolchain: lvx-gcc %s\n' "$(git -C "$CSW/lvx-gcc/gcc" describe --always 2>/dev/null || echo unknown)"
    printf '# columns: pass<TAB>source<TAB>dump-line\n'
    probe cms $CMS_FLAGS
    probe sms $SMS_FLAGS
} > "$out"

# COUNTING.  Two things here were wrong and both were silent.
#
# The probe line is now `;; lvx cms: fn=<function> loop <n> ...' (lvx-gcc
# f9ca67c4aac), so a grep for "lvx cms: loop" matches nothing -- which reported
# 0 loop-instances over a file holding 984 scheduled loops.  Matched on `span='
# instead, which is the field a scheduled loop has and a declined one has not,
# so the two are counted apart rather than conflated.
#
# And `$(grep -c ... || echo 0)' emits TWO values when grep finds nothing:
# grep -c prints its own 0 and exits 1, so the `||' fires and appends another.
# The extra word shifted every later printf argument, which is why the broken
# run printed its counts one per line.  `|| true' is the fix; grep -c has
# already printed the number.
echo "arch=$ARCH opt=-$OPT type=$TYPE"
for tag in cms sms; do
    printf '  %-4s scheduled=%-5s declined=%-4s relaxed-arcs-dropped=%s\n' "$tag" \
      "$(grep -c "^$tag.*lvx cms: fn=.* span=" "$out" 2>/dev/null || true)" \
      "$(grep -c "^$tag.*lvx cms: fn=.*declined" "$out" 2>/dev/null || true)" \
      "$(awk -F'\t' -v t="$tag" '$1==t && $3 ~ /lvx cms: fn=/ {
            if (match($3, /[0-9]+ relaxed arcs dropped/))
              s += substr($3, RSTART, RLENGTH) + 0
          } END {print s+0}' "$out")"
done

# The arc kind x omega distribution is the whole point of the probe, so it is
# summarised rather than left in the file. Field positions in a tagged line:
#   $3 = ";; lvx arc cms <loop> <src> <dst> <kind> <theta> <omega>"
# so kind is word 8, theta 9, omega 10. Getting that wrong once produced a
# table of field offsets that looked like data.
# The arc kind x omega summary needed -mcms-dump-arcs, which is gone.  Left as
# a stub rather than deleted silently, because its finding is the one thing this
# script taught that the flags no longer let it re-derive: GCC absorbs
# small-distance array recurrences into register rotations and uses two base
# pointers for large ones, so every arc comes out at omega <= 1 and
# LVX_CMS_MAX_DELTA is reached only by `#pragma omp simd safelen(n)'.
echo "  arc kinds: UNAVAILABLE -- needed -mcms-dump-arcs, deleted 510aa0c2e64"
false && echo "  arc kinds (CMS), kind x omega:"
awk -F'\t' '$1=="cms" && $3 ~ /lvx arc cms/ {split($3,w," "); print w[8], "omega="w[10]}' "$out" \
  | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'

# omega > 1 is the question the handoff asked and then corrected itself on.
# Reported explicitly, including when the answer is none, because "no output"
# and "zero" are not the same claim.
# Same stub reason as the arc-kind table: the per-arc lines came from
# -mcms-dump-arcs.  The circuit lines the probe still prints carry sum-omega
# per CIRCUIT, which is a different quantity -- the distinction this script's
# own header had to correct itself on -- so it is not substituted here.
nw=$(awk -F'\t' '$3 ~ /lvx arc cms/ {split($3,w," "); if (w[10]+0 > 1) n++} END{print n+0}' "$out")
printf '  arcs with omega>1: %s (per-arc data unavailable without -mcms-dump-arcs)' "$nw"
if [ "$nw" = 0 ]; then
    echo "   <- expected. An arc's distance and a circuit's Sigma-omega differ:"
    echo "     GCC absorbs small-distance array recurrences into register"
    echo "     rotations (hence reg-raw dominating) and uses two base pointers"
    echo "     for large ones, so the arc is emitted conservatively at omega=1."
    echo "     LVX_CMS_MAX_DELTA and the drop rule are reached by"
    echo "     '#pragma omp simd safelen(n)', which TSVC does not carry."
else
    echo
fi
echo
echo "wrote $out"
