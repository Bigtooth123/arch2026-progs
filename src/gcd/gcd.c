#include "gcd.h"

static unsigned ctz32(uint32_t x)
{
    unsigned n = 0;

    /* x must be nonzero. */
    if ((x & 0x0000FFFFu) == 0) {
        n += 16;
        x >>= 16;
    }

    if ((x & 0x000000FFu) == 0) {
        n += 8;
        x >>= 8;
    }

    if ((x & 0x0000000Fu) == 0) {
        n += 4;
        x >>= 4;
    }

    if ((x & 0x00000003u) == 0) {
        n += 2;
        x >>= 2;
    }

    if ((x & 0x00000001u) == 0)
        n += 1;

    return n;
}

/* Dummy: returns 0 for every input. Replace with the binary GCD. */
uint32_t gcd_u32(uint32_t a, uint32_t b)
{
    if (a == 0)
        return b;
    if (b == 0)
        return a;

    /*
     * gcd(a, b) contains 2^min(ctz(a), ctz(b)).
     * ctz(a | b) gives exactly that minimum.
     */
    unsigned shift = ctz32(a | b);

    /* Keep a odd throughout the main loop. */
    a >>= ctz32(a);

    do {
        /* Remove all factors of two from b at once. */
        b >>= ctz32(b);

        /* Keep a <= b. */
        if (a > b) {
            uint32_t temp = a;
            a = b;
            b = temp;
        }

        /*
         * Both a and b are odd here.
         * Therefore b - a is even (or zero).
         */
        b -= a;

    } while (b != 0);

    return a << shift;
}
