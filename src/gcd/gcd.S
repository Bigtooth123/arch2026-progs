# gcd_u32_asm: binary GCD, hand-written RV32I.
#
# uint32_t gcd_u32_asm(uint32_t a, uint32_t b)   a in a0, b in a1, result in a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tgcd.c.

# ----------------------------------------------------------------
# ctz32_nonzero
# ----------------------------------------------------------------

    .macro  CTZ32
    mv      t0, a0          # t0 = working x
    li      t1, 0           # t1 = count

    slli    t2, t0, 16
    bne     t2, zero, .Lctz_check8_\@

    srli    t0, t0, 16
    addi    t1, t1, 16

.Lctz_check8_\@:
    # Check low 8 bits.
    andi    t2, t0, 255
    bne     t2, zero, .Lctz_check4_\@

    srli    t0, t0, 8
    addi    t1, t1, 8

.Lctz_check4_\@:
    # Check low 4 bits.
    andi    t2, t0, 15
    bne     t2, zero, .Lctz_check2_\@

    srli    t0, t0, 4
    addi    t1, t1, 4

.Lctz_check2_\@:
    # Check low 2 bits.
    andi    t2, t0, 3
    bne     t2, zero, .Lctz_check1_\@

    srli    t0, t0, 2
    addi    t1, t1, 2

.Lctz_check1_\@:
    # If bit 0 is zero, there is one more trailing zero.
    andi    t2, t0, 1
    bne     t2, zero, .Lctz_done_\@

    addi    t1, t1, 1

.Lctz_done_\@:
    mv      a0, t1
    .endm

    .text

    .globl  gcd_u32_asm
    .type   gcd_u32_asm, @function
    .align  2


gcd_u32_asm:
    # gcd(0, b) = b
    beq     a0, zero, .Lreturn_b

    # gcd(a, 0) = a
    beq     a1, zero, .Lreturn_a

    # Keep the working values in a2 and a1.
    mv      a2, a0

    # ------------------------------------------------------------
    # common_shift = ctz(a | b)
    # a4 = shift
    # ------------------------------------------------------------
    or      a0, a2, a1
    CTZ32
    mv      a4, a0

    # ------------------------------------------------------------
    # a >>= ctz(a)
    #
    # After this, a is odd.
    # ------------------------------------------------------------
    mv      a0, a2
    CTZ32
    srl     a2, a2, a0

.Lgcd_loop:
    # ------------------------------------------------------------
    # b >>= ctz(b)
    #
    # b is guaranteed nonzero when we enter the loop.
    # After this, b is odd.
    # ------------------------------------------------------------
    mv      a0, a1
    CTZ32
    srl     a1, a1, a0

    bgeu    a1, a2, .Lno_swap

    # swap(a, b)
    mv      t1, a2
    mv      a2, a1
    mv      a1, t1

.Lno_swap:
    # Both a and b are odd here.
    #
    # gcd(a, b) = gcd(a, b - a)
    #
    # Since odd - odd is even, the next iteration can remove
    # all factors of two from b.
    sub     a1, a1, a2

    # Continue until b becomes zero.
    bne     a1, zero, .Lgcd_loop

    # gcd = a * 2^common_shift
    sll     a0, a2, a4

    ret

.Lreturn_b:
    mv      a0, a1
    ret

.Lreturn_a:
    # a0 already contains a.
    ret

    .size   gcd_u32_asm, .-gcd_u32_asm
