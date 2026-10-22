#!/usr/bin/env bash
# Part of the LVX project, under the Apache License v2.0 with LLVM Exceptions.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#
# TSVC_2 on LVX: vectorisation performance tracking, with a correctness gate.
#
#   ./harness/run.sh                       # lvx-2, -O2, float AND double,
#                                          #   vec AND novec -- all four
#   ARCH=lvx-1 ./harness/run.sh
#   TYPE=float ./harness/run.sh            # one width only
#   VEC=vec ./harness/run.sh               # skip the novec half
#   FPMODE=fast ./harness/run.sh           # see the ICE note in lvx/run-tsvc.sh
#   ITER=4 ./harness/run.sh
#   STATIC_ONLY=1 ./harness/run.sh         # build + static metrics, no ISS
#   ./harness/compare.sh results/A.tsv results/B.tsv
#   ./harness/cms-probe.sh                 # the compile-only dependence probe
#
# Writes results/<arch>-<opt>-<type>-i<iter>.tsv, one row per loop, and a human
# summary. Commit the results: the series is the point.
#
# BOTH FP WIDTHS AND BOTH VECTORIZER SETTINGS BY DEFAULT, because each pair is
# a measurement rather than a setting.
#
# The float/double ratio per loop shows how much of the lane the vectorizer
# got: a 128-bit lane holds four floats or two doubles. That is lvx-polybench's
# reasoning and it applies unchanged.
#
# The vec/novec ratio is what TSVC EXISTS FOR. It is the Test Suite for
# Vectorizing Compilers; a loop's absolute cycle count says nothing about
# whether the vectorizer fired or whether firing helped, and those are the two
# questions. Upstream builds both executables for the same reason, so this
# follows it rather than inventing a metric. The ratio is reported per loop --
# an aggregate would average a loop the vectorizer transformed with one it
# refused, and describe neither.
#
# CORRECTNESS IS GATED ON THE CHECKSUM BIT PATTERN against a reference
# generated NATIVELY by harness/make-reference.sh. A reference taken from the
# target could only perpetuate a target miscompile, never detect one. The
# comparison is on raw bits because a decimal rendering of a float is lossy,
# and this is the oracle.
#
# THE REFERENCE IS SETTINGS-SPECIFIC. Most loops accumulate across the nl loop,
# so the checksum is a function of `iterations' as well as of the code. The
# reference filename carries (iter, LEN_1D, LEN_2D, type) and a run with no
# matching reference reports `noref' rather than comparing against the wrong
# one. That is also why these checksums do not match upstream TSVC's published
# figures.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"

ARCH=${ARCH:-lvx-2}
OPT=${OPT:-O2}
ITER=${ITER:-1}
LEN1D=${LEN1D:-32000}
LEN2D=${LEN2D:-256}
STATIC_ONLY=${STATIC_ONLY:-0}
FPMODE=${FPMODE:-default}
TYPES=${TYPE:-"float double"}
VECS=${VEC:-"vec novec"}

csw_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --csw)   csw_args+=(--csw "${2:?--csw needs a path}"); shift 2 ;;
        --csw=*) csw_args+=("$1"); shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$ARCH" in lvx-1|lvx-2) ;; *) echo "ARCH must be lvx-1 or lvx-2" >&2; exit 2 ;; esac

outdir="$repo/results"; mkdir -p "$outdir"
work=$(mktemp -d); trap 'rm -rf "$work"' 0 1 2 3 15

HEADER='loop\tarch\topt\ttype\tvec\tfpmode\titerations\tcorrect\tcycles\tchecksum_bits\ttext_bytes\tinsns_static\tbundles_static\tsimd_insns\tcompile_seconds\tcpu_model'

rc=0
for type in $TYPES; do
  case "$type" in float|double) ;; *) echo "unknown TYPE '$type'" >&2; exit 2 ;; esac
  tsv="$outdir/$ARCH-$OPT-$type-$FPMODE-i$ITER.tsv"
  ref="$here/reference-$ITER-$LEN1D-$LEN2D-$type.tsv"
  printf "$HEADER\n" > "$tsv"
  for vec in $VECS; do
    case "$vec" in vec|novec) ;; *) echo "unknown VEC '$vec'" >&2; exit 2 ;; esac
    log="$work/$type-$vec.log"

    echo "=== $type $vec ==="
    if ARCH="$ARCH" OPT="$OPT" TYPE="$type" VEC="$vec" FPMODE="$FPMODE" ITER="$ITER" \
       LEN1D="$LEN1D" LEN2D="$LEN2D" STATIC_ONLY="$STATIC_ONLY" \
       "$repo/lvx/run-tsvc.sh" "${csw_args[@]+"${csw_args[@]}"}" > "$log" 2>&1
    then run_ok=1; else run_ok=0; fi

    field() { sed -n "s/^$1 \(.*\)$/\1/p" "$log" | tail -1; }
    text=$(field text_bytes); insns=$(field insns_static)
    bund=$(field bundles_static); simd=$(field simd_insns)
    csec=$(field compile_seconds); cpu=$(field cpu_model)

    if grep -qE '^(BUILD FAIL|error:)' "$log"; then
        echo "  BUILD FAIL"; sed -n '1,8p' "$log" | sed 's/^/  | /'; rc=1; continue
    fi
    if [ "$STATIC_ONLY" = 1 ]; then
        printf '  static: text=%s insns=%s bundles=%s simd=%s compile=%ss\n' \
               "${text:--}" "${insns:--}" "${bund:--}" "${simd:--}" "${csec:--}"
        continue
    fi

    nres=$(grep -c '^RESULT' "$log" || true)
    if [ "$run_ok" != 1 ] || [ "${nres:-0}" -eq 0 ]; then
        echo "  RUN FAIL (no rows)"; sed -n '1,10p' "$log" | sed 's/^/  | /'; rc=1; continue
    fi

    have_ref=0; [ -f "$ref" ] && have_ref=1
    [ "$have_ref" = 1 ] || echo "  note: no reference at $(basename "$ref") -- rows will read noref" >&2

    rows="$work/rows-$type.tsv"; : > "$rows"
    ok=0; bad=0; noref=0
    while IFS= read -r line; do
        loop=$(printf '%s' "$line" | awk -F'\t' '{print $2}')
        bits=$(printf '%s' "$line" | sed -n 's/.*\tchecksum_bits \([0-9]*\).*/\1/p')
        cyc=$(printf '%s' "$line"  | sed -n 's/.*\telapsed \(-\?[0-9]*\).*/\1/p')
        if [ "$have_ref" = 1 ]; then
            want=$(awk -F'\t' -v l="$loop" '$1==l{print $2}' "$ref")
            if   [ -z "$want" ];        then correct=NOTINREF; bad=$((bad+1))
            elif [ "$want" = "$bits" ]; then correct=ok;       ok=$((ok+1))
            else correct=MISMATCH; bad=$((bad+1)); fi
        else correct=noref; noref=$((noref+1)); fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
               "$loop" "$ARCH" "$OPT" "$type" "$vec" "$FPMODE" "$ITER" "$correct" \
               "${cyc:-}" "${bits:-}" "${text:-}" "${insns:-}" "${bund:-}" "${simd:-}" \
               "${csec:-}" "${cpu:-}" >> "$rows"
    done < <(grep '^RESULT' "$log")

    cat "$rows" >> "$tsv"
    printf '  %s rows: ok=%s MISMATCH/NOTINREF=%s noref=%s\n' "$(wc -l < "$rows")" "$ok" "$bad" "$noref"
    if [ "$bad" -gt 0 ]; then
        echo "  the failing loops (a cycle count from these is not a result):"
        awk -F'\t' '$8!="ok" && $8!="noref" {printf "    %-10s %s\n", $1, $8}' "$rows" | head -12
        rc=1
    fi
  done

  # The vec/novec ratio per loop: the number this suite exists to produce.
  # Only computed when both halves ran, and only from rows that passed the
  # correctness gate -- a speedup over a wrong answer is not a speedup.
  if [ "$STATIC_ONLY" != 1 ] && [ -f "$tsv" ]; then
    echo "  vectorization speedup (novec/vec cycles, correct rows only):"
    awk -F'\t' 'NR>1 && $8=="ok" {
            if ($5=="vec")   v[$1]=$9;
            if ($5=="novec") n[$1]=$9;
        }
        END {
            c=0; faster=0; slower=0
            for (l in v) if (l in n && v[l]+0 > 0) {
                r = n[l] / v[l]; c++
                if (r > 1.02) faster++; else if (r < 0.98) slower++
                if (r > best)  { best = r;  bl = l }
                if (worst == 0 || r < worst) { worst = r; wl = l }
            }
            if (c == 0) { print "    (needs both vec and novec rows)"; exit }
            printf "    %d loops paired: %d faster, %d slower, %d within 2%%\n", c, faster, slower, c-faster-slower
            printf "    best  %-10s %.2fx\n", bl, best
            printf "    worst %-10s %.2fx\n", wl, worst
        }' "$tsv"
  fi
  echo "  wrote $tsv"
done
[ "$rc" = 0 ] || echo "NOT ALL ROWS ARE PERFORMANCE RESULTS -- see the correct column" >&2
exit $rc
