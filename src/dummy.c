
/* LVX: these were spelled `float', which only compiles while real_t IS
   float -- common.h declares dummy with real_t, so -DTSVC_DOUBLE made the two
   conflict. An upstream bug that the TYPE axis exposes the moment it is used,
   not anything about this target. */
#include "common.h"

int dummy(real_t a[LEN_1D], real_t b[LEN_1D], real_t c[LEN_1D], real_t d[LEN_1D], real_t e[LEN_1D], real_t aa[LEN_2D][LEN_2D], real_t bb[LEN_2D][LEN_2D], real_t cc[LEN_2D][LEN_2D], real_t s){
    (void)a; (void)b; (void)c; (void)d; (void)e; (void)aa; (void)bb; (void)cc; (void)s;
    // --  called in each loop to make all computations appear required
    return 0;
}

