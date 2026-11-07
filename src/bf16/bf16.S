# BFloat16 routines: hand-written RV32I.
#
# uint16_t bf16_from_f32_asm(uint32_t f32bits)   a0 -> a0
# uint16_t bf16_mul_asm(uint16_t a, uint16_t b)  a0, a1 -> a0
# uint16_t bf16_sqrt_asm(uint16_t a)             a0 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tbf16.c.

    .text

    .globl  bf16_from_f32_asm
    .type   bf16_from_f32_asm, @function
    .align  2
bf16_from_f32_asm:
    srli    t0, a0, 23
    andi    t0, t0, 255
    li      t1, 255
    beq     t0, t1, .Lf32_special

    srli    t0, a0, 16
    andi    t0, t0, 1
    lui     t1, 8
    addi    t1, t1, -1
    add     a0, a0, t1
    add     a0, a0, t0

.Lf32_special:
    srli    a0, a0, 16
    ret
    .size   bf16_from_f32_asm, .-bf16_from_f32_asm

    .globl  bf16_mul_asm
    .type   bf16_mul_asm, @function
    .align  2
bf16_mul_asm:
    # a2 = product sign; a3/a4 = magnitudes.
    xor     a2, a0, a1
    lui     t2, 0xffff8
    and     a2, a2, t2
    lui     t2, 8
    addi    t2, t2, -1
    and     a3, a0, t2
    and     a4, a1, t2

    # a5/a6 = exponents; t0/t1 = fractions, then significands.
    srli    a5, a0, 7
    andi    a5, a5, 255
    srli    a6, a1, 7
    andi    a6, a6, 255
    andi    t0, a0, 127
    andi    t1, a1, 127

    # Classify a before b, as required for NaN precedence.
    li      t2, 255
    bne     a5, t2, .Lmul_check_b
    bne     t0, zero, .Lmul_return
    beq     a4, zero, .Lmul_nan
    j       .Lmul_inf

.Lmul_check_b:
    bne     a6, t2, .Lmul_finite
    bne     t1, zero, .Lmul_return_b
    beq     a3, zero, .Lmul_nan

.Lmul_inf:
    lui     t2, 8
    addi    t2, t2, -128
    or      a0, a2, t2
    ret

.Lmul_nan:
    lui     a0, 8
    addi    a0, a0, -64
    ret

.Lmul_return_b:
    mv      a0, a1
.Lmul_return:
    ret

.Lmul_finite:
    beq     a3, zero, .Lmul_zero
    beq     a4, zero, .Lmul_zero

    # Normalize a denormal significand and adjust its exponent.
    bne     a5, zero, .Lmul_a_normal
    li      a5, 1
    li      t2, 128
.Lmul_norm_a:
    slli    t0, t0, 1
    addi    a5, a5, -1
    bltu    t0, t2, .Lmul_norm_a
    j       .Lmul_a_ready
.Lmul_a_normal:
    ori     t0, t0, 128
.Lmul_a_ready:

    # Normalize b in the same way.
    bne     a6, zero, .Lmul_b_normal
    li      a6, 1
    li      t2, 128
.Lmul_norm_b:
    slli    t1, t1, 1
    addi    a6, a6, -1
    bltu    t1, t2, .Lmul_norm_b
    j       .Lmul_b_ready
.Lmul_b_normal:
    ori     t1, t1, 128
.Lmul_b_ready:

    # t3 = t0 * t1, using RV32I shift and add.
    li      t3, 0
    mv      t4, t0
    mv      t5, t1
.Lmul_product_loop:
    andi    t6, t5, 1
    beq     t6, zero, .Lmul_product_skip
    add     t3, t3, t4
.Lmul_product_skip:
    slli    t4, t4, 1
    srli    t5, t5, 1
    bne     t5, zero, .Lmul_product_loop

    add     a5, a5, a6
    addi    a5, a5, -127
    slli    t2, t3, 16
    bge     t2, zero, .Lmul_product_low
    srli    t3, t3, 8
    addi    a5, a5, 1
    j       .Lmul_range
.Lmul_product_low:
    srli    t3, t3, 7

.Lmul_range:
    li      t2, 255
    bge     a5, t2, .Lmul_inf
    bge     zero, a5, .Lmul_denormal

    andi    t3, t3, 127
    slli    a5, a5, 7
    or      a0, a2, a5
    or      a0, a0, t3
    ret

.Lmul_denormal:
    li      t2, -6
    blt     a5, t2, .Lmul_zero
    andi    t3, t3, 127
    li      t2, 1
    sub     t2, t2, a5
    srl     t3, t3, t2
    or      a0, a2, t3
    ret

.Lmul_zero:
    mv      a0, a2
    ret
    .size   bf16_mul_asm, .-bf16_mul_asm

    .globl  bf16_sqrt_asm
    .type   bf16_sqrt_asm, @function
    .align  2
bf16_sqrt_asm:
    srli    t0, a0, 7
    andi    t0, t0, 255
    andi    t1, a0, 127
    slli    t2, a0, 17
    srli    t2, t2, 17

    # NaNs are unchanged; +Inf is unchanged; -Inf is a quiet NaN.
    li      t3, 255
    bne     t0, t3, .Lsqrt_finite
    bne     t1, zero, .Lsqrt_return
    slli    t2, a0, 16
    blt     t2, zero, .Lsqrt_nan
    ret

.Lsqrt_finite:
    beq     t2, zero, .Lsqrt_zero
    slli    t2, a0, 16
    blt     t2, zero, .Lsqrt_nan
    beq     t0, zero, .Lsqrt_zero

    # Make the unbiased exponent even, doubling the significand if needed.
    addi    t3, t0, -127
    ori     t1, t1, 128
    andi    t2, t3, 1
    beq     t2, zero, .Lsqrt_search_init
    slli    t1, t1, 1
    addi    t3, t3, -1

    # Find the largest mid in [90, 256] with (mid * mid) / 128 <= m.
.Lsqrt_search_init:
    li      a1, 90
    li      a2, 256
    li      a3, 90
.Lsqrt_search:
    bltu    a2, a1, .Lsqrt_search_done
    add     a4, a1, a2
    srli    a4, a4, 1

    li      a5, 0
    mv      a6, a4
    mv      a7, a4
.Lsqrt_square_loop:
    andi    t4, a7, 1
    beq     t4, zero, .Lsqrt_square_skip
    add     a5, a5, a6
.Lsqrt_square_skip:
    slli    a6, a6, 1
    srli    a7, a7, 1
    bne     a7, zero, .Lsqrt_square_loop

    srli    a5, a5, 7
    bltu    t1, a5, .Lsqrt_too_large
    mv      a3, a4
    addi    a1, a4, 1
    j       .Lsqrt_search
.Lsqrt_too_large:
    addi    a2, a4, -1
    j       .Lsqrt_search

.Lsqrt_search_done:
    srai    t3, t3, 1
    addi    t3, t3, 127
    li      t2, 256
    bltu    a3, t2, .Lsqrt_range
    srli    a3, a3, 1
    addi    t3, t3, 1

.Lsqrt_range:
    li      t2, 255
    bge     t3, t2, .Lsqrt_inf
    bge     zero, t3, .Lsqrt_zero
    slli    t3, t3, 7
    andi    a3, a3, 127
    or      a0, t3, a3
.Lsqrt_return:
    ret

.Lsqrt_inf:
    lui     a0, 8
    addi    a0, a0, -128
    ret
.Lsqrt_nan:
    lui     a0, 8
    addi    a0, a0, -64
    ret
.Lsqrt_zero:
    li      a0, 0
    ret
    .size   bf16_sqrt_asm, .-bf16_sqrt_asm
