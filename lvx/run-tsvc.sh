#!/usr/bin/env bash
# Part of the LVX project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#
# TSVC_2 on LVX: build and run the 151 loops, one row each.
#
#   ./lvx/run-tsvc.sh                  lvx-2, -O2, float, vectorized
#   VEC=novec ./lvx/run-tsvc.sh        the same loops with the vectorizer off
#   FPMODE=fast ./lvx/run-tsvc.sh      -ffast-math (see the ICE note below)
#   ARCH=lvx-1 ./lvx/run-tsvc.sh       the scalar core
#   TYPE=double ./lvx/run-tsvc.sh
#   ITER=4 ./lvx/run-tsvc.sh           more passes per loop
#   VECREPORT=1 ./lvx/run-tsvc.sh      -fopt-info-vec-all to a file
#   STATIC_ONLY=1 ./lvx/run-tsvc.sh    build + static metrics, no ISS
#   ./lvx/run-tsvc.sh --native         the x86 reference, same source
#   ./lvx/run-tsvc.sh --csw /path/to/lvx-csw
#
# VEC IS THE AXIS THIS SUITE EXISTS FOR. TSVC is the Test Suite for Vectorizing
# Compilers: upstream builds vectorized AND non-vectorized executables, and the
# per-loop RATIO between them is the measurement -- did the vectorizer fire,
# and did firing help. A vec-only run reports absolute cycles and answers
# neither question. So this mirrors upstream's pair rather than inventing a
# metric: VEC=vec passes -ftree-vectorize, VEC=novec passes
# -fno-tree-vectorize, and harness/run.sh runs both and divides.
#
# Use -fopt-info-vec-all (VECREPORT=1) rather than counting SIMD instructions
# to decide whether a given loop vectorized -- the same guidance lvx-polybench
# records, for the same reason: a SIMD instruction count conflates the loop
# under test with everything else in the image.
#
# FPMODE follows upstream's three variants, with one of them currently blocked:
#   default   no FP flags. The default here.
#   fast      -ffast-math, as upstream's `relaxed'.
#   precise   gcc has no precise flag -- upstream's Makefile.gcc warns
#             "No 'precise' math flags for gcc!" -- so this is identical to
#             default and exists only to keep the names aligned with upstream.
#
# FPMODE=fast ICEs lvx-gcc on lvx-2 with float: a vectorized float reciprocal
# becomes UNSPEC_FMUL with a const_vector operand and dies unrecognized at RTL
# pass vregs. One line reproduces it -- `a[i] = 1.0f / b[i]' -- at every float
# vector width, while double and lvx-1 are clean. Reported to the lvx-csw
# session 2026-10-22. Until it is fixed, FPMODE=fast works on lvx-1 and on
# lvx-2 with TYPE=double, which is why the default avoids the flag rather than
# the suite waiting for it.
#
# HOSTED LINK, like lvx-polybench's and unlike lvx-ssw's. These loops need
# newlib: strcmp (270 calls in calc_checksum), memalign, sinf and cosf (one
# each), printf on the error paths. -T lvx-sim.ld supplies sbrk's heap bounds,
# without which malloc has no heap.
#
# ITERATIONS DEFAULTS TO 1, which is correct here rather than a shortcut.
# Upstream's 100000 exists to make the elapsed time measurable on real
# hardware; a deterministic ISS gives the exact cycle count in one pass, with
# no averaging. It does CHANGE THE CHECKSUMS -- most loops accumulate across
# the nl loop -- so the harness gates against a reference generated at the same
# settings, and these values are not comparable with upstream's published ones.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARCH=${ARCH:-lvx-2}
OPT=${OPT:-O2}
TYPE=${TYPE:-float}
VEC=${VEC:-vec}
FPMODE=${FPMODE:-default}
ITER=${ITER:-1}
LEN1D=${LEN1D:-32000}
LEN2D=${LEN2D:-256}

CSW_ARG=; args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --csw)   CSW_ARG=${2:?--csw needs a path}; shift 2 ;;
        --csw=*) CSW_ARG=${1#--csw=}; shift ;;
        *)       args+=("$1"); shift ;;
    esac
done
set -- ${args[@]+"${args[@]}"}
case "$TYPE" in float|double) ;; *) echo "TYPE must be float or double" >&2; exit 2 ;; esac
case "$VEC" in vec) vecflag="-ftree-vectorize" ;; novec) vecflag="-fno-tree-vectorize" ;;
    *) echo "VEC must be vec or novec" >&2; exit 2 ;; esac
case "$FPMODE" in
    default|precise) fpflag="" ;;
    fast)            fpflag="-ffast-math" ;;
    *) echo "FPMODE must be default, precise or fast" >&2; exit 2 ;;
esac
if [ "$FPMODE" = fast ] && [ "$ARCH" = lvx-2 ] && [ "$TYPE" = float ]; then
    echo "warning: FPMODE=fast on lvx-2 with float ICEs lvx-gcc (vectorized" >&2
    echo "         float reciprocal -> UNSPEC_FMUL with a const_vector," >&2
    echo "         unrecognized at RTL pass vregs; reported 2026-10-22)." >&2
    echo "         Expect BUILD FAIL. double and lvx-1 are unaffected." >&2
fi

resolve_csw() {
    [ -n "$CSW_ARG" ] && { printf '%s\n' "$CSW_ARG"; return 0; }
    [ -n "${LVX_CSW:-}" ] && { printf '%s\n' "$LVX_CSW"; return 0; }
    local super c
    super=$(git -C "$HERE" rev-parse --show-superproject-working-tree 2>/dev/null) || super=
    [ -n "$super" ] && [ -x "$super/bin/lvx-csw-path" ] && "$super/bin/lvx-csw-path" 2>/dev/null && return 0
    for c in ${super:+"$super/../lvx-csw"} "$HERE/../lvx-csw" "$HOME/lvx-csw"; do
        [ -d "$c/lvx-mds" ] || [ -d "$c/validation" ] || continue
        (cd "$c" && pwd); return 0
    done
    return 1
}

tmacro=""; [ "$TYPE" = double ] && tmacro="-DTSVC_DOUBLE"
DEFS="-Diterations=$ITER -DLEN_1D=$LEN1D -DLEN_2D=$LEN2D $tmacro"
SRCS="$HERE/src/tsvc.c $HERE/src/common.c $HERE/src/dummy.c $HERE/lvx/tsvc-report.c"

if [ "${1:-}" = "--native" ]; then
    # No tsvc-time.c natively: the host's real gettimeofday is wanted, and
    # overriding it would replace microseconds with an x86 cycle counter the
    # reference is not expressed in.
    # shellcheck disable=SC2086
    cc -$OPT $vecflag $fpflag $DEFS -I"$HERE/src" -w \
       -o /tmp/tsvc-native-$TYPE-$VEC-$FPMODE $SRCS -lm || exit 1
    exec /tmp/tsvc-native-$TYPE-$VEC-$FPMODE
fi

CSW=$(resolve_csw) || {
    echo "error: cannot find lvx-csw. It holds the toolchain and the ISS." >&2
    echo "       Pass --csw <path>, set \$LVX_CSW, or keep the checkouts as" >&2
    echo "       siblings; lvx-perf's bin/lvx-csw-path owns the chain." >&2
    exit 2; }
BIN=$CSW/lvx-toolchain/bin
[ -x "$BIN/lvx-mbr-gcc" ] || {
    echo "error: $CSW has no built cross-toolchain" >&2
    echo "       build it:  make -C '$CSW' install-minimal-toolchain" >&2; exit 2; }
LDSCRIPTS=$CSW/lvx-newlib/libgloss/lvx-mbr/linker_scripts
[ -d "$LDSCRIPTS" ] || { echo "error: no linker scripts at $LDSCRIPTS" >&2; exit 2; }

case $ARCH in
    lvx-1) GEM5BIN=gem5-lvx-1.opt ;;
    lvx-2) GEM5BIN=gem5-lvx-2.opt ;;
    # Wrong-core runs are SILENT: lvx-2 code under the lvx-1 ISS does not
    # error, it returns wrong answers.
    *) echo "error: unknown ARCH='$ARCH' (lvx-1 or lvx-2)" >&2; exit 2 ;;
esac
[ "${STATIC_ONLY:-0}" = 1 ] || [ -x "$CSW/lvx-gem5/build/$GEM5BIN" ] || {
    echo "error: missing ISS for $ARCH: $CSW/lvx-gem5/build/$GEM5BIN" >&2
    echo "       lvx-gem5 renamed these from gem5-lvxN.opt on 2026-10-21;" >&2
    echo "       if the old name is present the ISS needs rebuilding." >&2; exit 2; }

WD=$(mktemp -d); trap 'rm -rf "$WD"' EXIT
echo "== $ARCH -$OPT $TYPE $VEC $FPMODE iter=$ITER =="

# tsvc-time.c FIRST so its gettimeofday wins over newlib's: the linker takes a
# definition from an object in preference to one in an archive, and newlib's
# bare-metal stub has no clock behind it.
t0=$SECONDS
# shellcheck disable=SC2086
vecreport=""
[ "${VECREPORT:-0}" = 1 ] && vecreport="-fopt-info-vec-all=$WD/vec.txt -fno-inline"
# shellcheck disable=SC2086
"$BIN/lvx-mbr-gcc" -$OPT -march="$ARCH" $vecflag $fpflag $vecreport $DEFS -I"$HERE/src" -w \
    -T lvx-sim.ld -L"$LDSCRIPTS" \
    -o "$WD/tsvc.elf" "$HERE/lvx/tsvc-time.c" $SRCS -lm \
    || { echo "BUILD FAIL"; exit 1; }
echo "compile_seconds $((SECONDS - t0))"
if [ "${VECREPORT:-0}" = 1 ] && [ -f "$WD/vec.txt" ]; then
    rep="$HERE/results/vecreport-$ARCH-$OPT-$TYPE-$VEC-$FPMODE.txt"
    mkdir -p "$HERE/results"; cp "$WD/vec.txt" "$rep"
    echo "vec_loops_vectorized $(grep -c 'loop vectorized' "$rep" || true)"
    echo "vec_report $rep"
fi

"$BIN/lvx-mbr-objdump" -d "$WD/tsvc.elf" > "$WD/dis.txt" 2>/dev/null
echo "text_bytes $("$BIN/lvx-mbr-size" -A "$WD/tsvc.elf" | awk '$1==".text"{print $2}')"
echo "insns_static $(grep -cE '^[[:space:]]+[0-9a-f]+:' "$WD/dis.txt")"
echo "bundles_static $(grep -c ';;' "$WD/dis.txt")"
echo "simd_insns $(grep -coE '\b[a-z]+(dp|wq|ho|bx)\b' "$WD/dis.txt" || true)"

[ "${STATIC_ONLY:-0}" = 1 ] && exit 0

# gem5's default model is `atomic', which is FUNCTIONAL: its cycles are not
# timing. Set `minor' explicitly and REPORT it -- leaving this to a default is
# how lvx-polybench and lvx-mibench both acquired functional-model series that
# nobody realised were functional, and a later model switch then read as a
# 60-240% regression.
LVX_CPU=${LVX_CPU:-minor}
echo "cpu_model $LVX_CPU"
LVX_CPU=$LVX_CPU timeout "${TMO:-7200}" \
    "$CSW/lvx-gem5/build/$GEM5BIN" --outdir="$WD/m5out" \
    "$CSW/lvx-gem5/tests/lvx/run_lvx.py" "$WD/tsvc.elf" 2>&1 |
    grep -E '^RESULT|^# RESULT|target exited'
