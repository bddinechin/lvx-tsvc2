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
# instead. Do not read a missing delta > 1 here as a gap.
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

# The two invocations the handoff specifies. SMS needs hardware loops on -- it
# requires the doloop -- and both relaxations, so the graphs are comparable.
CMS_FLAGS="-mcms-probe -mcms-dump-arcs -fdump-rtl-mach"
SMS_FLAGS="-fmodulo-sched -fmodulo-sched-allow-regmoves --param=sms-assume-ivdep=1"
SMS_FLAGS="$SMS_FLAGS -mcms-probe -mcms-assume-ivdep -mcms-dump-arcs -fdump-rtl-sms -fdump-rtl-mach"

probe() {   # $1 = tag (cms|sms), $2... = extra flags
    local tag=$1; shift
    local d="$work/$tag"; mkdir -p "$d"
    ( cd "$d" && for src in "$repo/src/tsvc.c" "$repo/src/common.c"; do
        "$G" -$OPT -march="$ARCH" -ffast-math $tmacro "$@" \
             -I"$repo/src" -c "$src" -o /dev/null 2>>"$d/stderr.txt" || true
      done )
    # TAG EVERY LINE WITH ITS SOURCE FILE. Loop numbers are not unique across
    # translation units, and the handoff records that reading an untagged
    # `loop 8' already cost two false findings in this work. One sed is enough
    # and it is not optional.
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

echo "arch=$ARCH opt=-$OPT type=$TYPE"
for tag in cms sms; do
    printf '  %-4s loop-instances=%-6s graphs=%-5s arcs=%-6s relaxed-arcs-dropped=%s\n' "$tag" \
      "$(grep -c "^$tag.*lvx cms: loop" "$out" 2>/dev/null || echo 0)" \
      "$(grep -c "^$tag.*lvx graph cms" "$out" 2>/dev/null || echo 0)" \
      "$(grep -c "^$tag.*lvx arc cms" "$out" 2>/dev/null || echo 0)" \
      "$(awk -F'\t' -v t="$tag" '$1==t && $3 ~ /lvx cms: loop/ {
            if (match($3, /[0-9]+ relaxed arcs dropped/))
              s += substr($3, RSTART, RLENGTH) + 0
          } END {print s+0}' "$out")"
done

# The arc kind x omega distribution is the whole point of the probe, so it is
# summarised rather than left in the file. Field positions in a tagged line:
#   $3 = ";; lvx arc cms <loop> <src> <dst> <kind> <theta> <omega>"
# so kind is word 8, theta 9, omega 10. Getting that wrong once produced a
# table of field offsets that looked like data.
echo "  arc kinds (CMS), kind x omega:"
awk -F'\t' '$1=="cms" && $3 ~ /lvx arc cms/ {split($3,w," "); print w[8], "omega="w[10]}' "$out" \
  | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'

# omega > 1 is the question the handoff asked and then corrected itself on.
# Reported explicitly, including when the answer is none, because "no output"
# and "zero" are not the same claim.
nw=$(awk -F'\t' '$3 ~ /lvx arc cms/ {split($3,w," "); if (w[10]+0 > 1) n++} END{print n+0}' "$out")
printf '  arcs with omega>1: %s' "$nw"
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
