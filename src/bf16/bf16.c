#include "bf16.h"

uint16_t bf16_from_f32(uint32_t f32bits)
{
    uint32_t exponent = (f32bits >> 23) & 0xFFu;

    if (exponent == 0xFFu)
        return (uint16_t) (f32bits >> 16);

    uint32_t tie = (f32bits >> 16) & 1u;
    return (uint16_t) ((f32bits + 0x7FFFu + tie) >> 16);
}

uint16_t bf16_mul(uint16_t a, uint16_t b)
{
    uint32_t sign = (a ^ b) & 0x8000u;
    uint32_t mag_a = a & 0x7FFFu, mag_b = b & 0x7FFFu;
    int exp_a = (a >> 7) & 0xFF, exp_b = (b >> 7) & 0xFF;
    uint32_t frac_a = a & 0x7Fu, frac_b = b & 0x7Fu;

    /* The operands are classified in order: a first, then b. */
    if (exp_a == 0xFF) {
        if (frac_a != 0)
            return a;
        if (mag_b == 0)
            return 0x7FC0u;
        return (uint16_t) (sign | 0x7F80u);
    }
    if (exp_b == 0xFF) {
        if (frac_b != 0)
            return b;
        if (mag_a == 0)
            return 0x7FC0u;
        return (uint16_t) (sign | 0x7F80u);
    }
    if (mag_a == 0 || mag_b == 0)
        return (uint16_t) sign;

    uint32_t sig_a = frac_a, sig_b = frac_b;
    if (exp_a == 0) {
        exp_a = 1;
        while (sig_a < 0x80u) {
            sig_a <<= 1;
            exp_a--;
        }
    } else {
        sig_a |= 0x80u;
    }
    if (exp_b == 0) {
        exp_b = 1;
        while (sig_b < 0x80u) {
            sig_b <<= 1;
            exp_b--;
        }
    } else {
        sig_b |= 0x80u;
    }

    uint32_t product = sig_a * sig_b;
    int exponent = exp_a + exp_b - 127;
    if (product & 0x8000u) {
        product >>= 8;
        exponent++;
    } else {
        product >>= 7;
    }

    if (exponent >= 0xFF)
        return (uint16_t) (sign | 0x7F80u);
    if (exponent <= 0) {
        if (exponent < -6)
            return (uint16_t) sign;
        product &= 0x7Fu;
        product >>= 1 - exponent;
        return (uint16_t) (sign | product);
    }

    return (uint16_t) (sign | ((uint32_t) exponent << 7) | (product & 0x7Fu));
}

uint16_t bf16_sqrt(uint16_t a)
{
    uint32_t magnitude = a & 0x7FFFu;
    uint32_t exponent = (a >> 7) & 0xFFu;
    uint32_t fraction = a & 0x7Fu;

    if (exponent == 0xFFu) {
        if (fraction != 0)
            return a;
        if (a & 0x8000u)
            return 0x7FC0u;
        return a;
    }
    if (magnitude == 0)
        return 0;
    if (a & 0x8000u)
        return 0x7FC0u;
    if (exponent == 0)
        return 0;

    int unbiased = (int) exponent - 127;
    uint32_t significand = 0x80u | fraction;
    if (unbiased & 1) {
        significand <<= 1;
        unbiased--;
    }

    uint32_t low = 90, high = 256, root = 90;
    while (low <= high) {
        uint32_t mid = (low + high) >> 1;
        uint32_t square = (mid * mid) >> 7;
        if (square <= significand) {
            root = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }

    int result_exp = unbiased / 2 + 127;
    if (root >= 0x100u) {
        root >>= 1;
        result_exp++;
    }
    if (result_exp >= 0xFF)
        return 0x7F80u;
    if (result_exp <= 0)
        return 0;
    return (uint16_t) (((uint32_t) result_exp << 7) | (root & 0x7Fu));
}
