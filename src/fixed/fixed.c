#include "fixed.h"

uint32_t op1(uint32_t a, uint32_t b, int *n)
{
    int passes = 0;

    while (b != 0) {
        uint32_t carry = (a & b) << 1;
        a ^= b;
        b = carry;
        passes++;
    }
    *n = passes;
    return a;
}

uint32_t op2(uint32_t a, uint32_t b)
{
    return a - b;
}

uint32_t op3(uint32_t a, uint32_t b)
{
    return (a & b) + ((a ^ b) >> 1);
}

int32_t q_mul(int32_t a, int32_t b)
{
    uint32_t mag_a = a < 0 ? 0u - (uint32_t) a : (uint32_t) a;
    uint32_t mag_b = b < 0 ? 0u - (uint32_t) b : (uint32_t) b;
    uint32_t al = mag_a & 0xFFFFu, ah = mag_a >> 16;
    uint32_t bl = mag_b & 0xFFFFu, bh = mag_b >> 16;
    uint64_t magnitude = (uint64_t) (al * bl) + ((uint64_t) (al * bh) << 16) +
                         ((uint64_t) (ah * bl) << 16) +
                         ((uint64_t) (ah * bh) << 32);
    uint64_t product = (a < 0) != (b < 0) ? 0u - magnitude : magnitude;

    product += (uint64_t) 1 << (Q - 1);
    return (int32_t) ((int64_t) product >> Q);
}
