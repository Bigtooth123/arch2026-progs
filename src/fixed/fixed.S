# op1, op2, op3 and q_mul: hand-written RV32I.
#
# uint32_t op1_asm(uint32_t a, uint32_t b, int *n)   a0, a1, a2 -> a0
# uint32_t op2_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# uint32_t op3_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# int32_t  q_mul_asm(int32_t a, int32_t b)           a0, a1 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. q_mul forms a 64-bit product in a register pair. Tests:
# tests/tfixed.c.

    .text

    .globl  op1_asm
    .type   op1_asm, @function
    .align  2
op1_asm:
    beq     a1, zero, .Lop1_zero

    li      t0, 0

.Lop1_loop:
    and     t1, a0, a1
    xor     a0, a0, a1
    slli    a1, t1, 1
    addi    t0, t0, 1
    bne     a1, zero, .Lop1_loop

    sw      t0, 0(a2)
    ret

.Lop1_zero:
    sw      zero, 0(a2)
    ret
    .size   op1_asm, .-op1_asm

    .globl  op2_asm
    .type   op2_asm, @function
    .align  2
op2_asm:
    sub     a0, a0, a1
    ret
    .size   op2_asm, .-op2_asm

    .globl  op3_asm
    .type   op3_asm, @function
    .align  2
op3_asm:
    and     t0, a0, a1
    xor     t1, a0, a1
    srli    t1, t1, 1
    add     a0, t0, t1
    ret
    .size   op3_asm, .-op3_asm

    .globl  q_mul_asm
    .type   q_mul_asm, @function
    .align  2
q_mul_asm:
    # Multiply the unsigned magnitudes, then apply the product sign.
    xor     t0, a0, a1
    bge     a0, zero, .Lqmul_a_positive
    sub     a0, zero, a0
.Lqmul_a_positive:
    bge     a1, zero, .Lqmul_b_positive
    sub     a1, zero, a1
.Lqmul_b_positive:

    # t2:t1 is the shifted 64-bit multiplicand; t5:t4 is the product.
    mv      t1, a0
    li      t2, 0
    mv      t3, a1
    li      t4, 0
    li      t5, 0
    beq     t3, zero, .Lqmul_sign

.Lqmul_loop:
    andi    t6, t3, 1
    beq     t6, zero, .Lqmul_shift

    mv      a2, t4
    add     t4, t4, t1
    sltu    t6, t4, a2
    add     t5, t5, t2
    add     t5, t5, t6

.Lqmul_shift:
    srli    t6, t1, 31
    slli    t1, t1, 1
    slli    t2, t2, 1
    or      t2, t2, t6
    srli    t3, t3, 1
    bne     t3, zero, .Lqmul_loop

.Lqmul_sign:
    bge     t0, zero, .Lqmul_round

    # Two's-complement negate of the 64-bit t5:t4 pair.
    sub     t4, zero, t4
    sltu    t6, zero, t4
    sub     t5, zero, t5
    sub     t5, t5, t6

.Lqmul_round:
    # Add 2^19, carrying into the high word when the low word wraps.
    mv      t6, t4
    lui     t1, 0x80
    add     t4, t4, t1
    sltu    t6, t4, t6
    add     t5, t5, t6

    # Low 32 bits of an arithmetic right shift of t5:t4 by Q = 20.
    srli    a0, t4, 20
    slli    t5, t5, 12
    or      a0, a0, t5
    ret
    .size   q_mul_asm, .-q_mul_asm
