# rubik_solve_asm: meet-in-the-middle 2x2x2 Rubik solver, RV32I only.
#
# int rubik_solve_asm(const char *state, char *out, size_t cap)
#   a0 = state, a1 = out, a2 = cap
#   return: number of moves, -1 invalid/unsolved, -2 output buffer too small
#
# This is an assembly translation of the optimized C implementation that uses
# a distance <= 5 near table and a distance-11 far table.

    .equ    CUBIES,               7
    .equ    MOVES,                9
    .equ    MAX_SOLUTION_LENGTH, 11
    .equ    NEAR_DISTANCE,        5
    .equ    SEARCH_FRAME_SIZE,    6


# Generated from the C headers by tools/gen_rubik_asm_tables.py.
# Defines RUBIK_NEAR_COUNT/RUBIK_FAR_COUNT and all large table labels.
    .include "src/rubik/rubik_tables.inc"

    .text
    .align  2

# -----------------------------------------------------------------------------
# count_smaller_after
#   a0 = pointer to 7 permutation bytes
#   a1 = position [0, 5]
#   a0 = number of later entries smaller than p[position]
# -----------------------------------------------------------------------------
.Lcount_smaller_after:
    mv      t4, a0
    add     t0, t4, a1
    lbu     t1, 0(t0)
    addi    t2, a1, 1
    li      t3, CUBIES
    li      a0, 0
.Lcount_loop:
    bgeu    t2, t3, .Lcount_done
    add     t0, t4, t2
    lbu     t5, 0(t0)
    sltu    t6, t5, t1
    add     a0, a0, t6
    addi    t2, t2, 1
    j       .Lcount_loop
.Lcount_done:
    ret

# -----------------------------------------------------------------------------
# parse_and_rank
#   a0 = input string
#   success: a0 = permutation rank, a1 = orientation rank
#   failure: a0 = -1
#
# Local stack [0..6] stores the parsed permutation.
# A bit mask validates uniqueness while parsing.
# -----------------------------------------------------------------------------
.Lparse_and_rank:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s0, 24(sp)
    sw      s1, 20(sp)
    mv      s0, a0

    li      t0, 0                  # seen permutation mask
    li      t1, 0                  # i
.Lparse_perm_loop:
    li      t2, CUBIES
    bgeu    t1, t2, .Lparse_ori_start
    add     t2, s0, t1
    lbu     t3, 0(t2)
    addi    t3, t3, -49            # '1' -> 0
    li      t4, 7
    bgeu    t3, t4, .Lparse_invalid

    li      t4, 1
    sll     t4, t4, t3
    and     t5, t0, t4
    bnez    t5, .Lparse_invalid
    or      t0, t0, t4

    add     t5, sp, t1
    sb      t3, 0(t5)
    addi    t1, t1, 1
    j       .Lparse_perm_loop

.Lparse_ori_start:
    li      t0, 0                  # orientation sum
    li      t1, 0                  # i
    li      s1, 0                  # base-3 rank of first 6 orientations
.Lparse_ori_loop:
    li      t2, CUBIES
    bgeu    t1, t2, .Lparse_tail_check
    addi    t2, t1, 7
    add     t2, s0, t2
    lbu     t3, 0(t2)
    addi    t3, t3, -49            # '1' -> 0
    li      t4, 3
    bgeu    t3, t4, .Lparse_invalid
    add     t0, t0, t3

    li      t4, 6
    bgeu    t1, t4, .Lparse_ori_next
    slli    t4, s1, 1
    add     s1, t4, s1             # rank *= 3
    add     s1, s1, t3
.Lparse_ori_next:
    addi    t1, t1, 1
    j       .Lparse_ori_loop

.Lparse_tail_check:
    lbu     t1, 14(s0)
    bnez    t1, .Lparse_invalid

    # sum must be one of 0, 3, 6, 9, 12.
    beqz    t0, .Lparse_rank_perm
    li      t1, 3
    beq     t0, t1, .Lparse_rank_perm
    li      t1, 6
    beq     t0, t1, .Lparse_rank_perm
    li      t1, 9
    beq     t0, t1, .Lparse_rank_perm
    li      t1, 12
    bne     t0, t1, .Lparse_invalid

.Lparse_rank_perm:
    mv      a0, sp
    li      a1, 0
    call    .Lcount_smaller_after
    mv      s0, a0

    mv      a0, sp
    li      a1, 1
    call    .Lcount_smaller_after
    slli    t0, s0, 2
    slli    t1, s0, 1
    add     s0, t0, t1             # * 6
    add     s0, s0, a0

    mv      a0, sp
    li      a1, 2
    call    .Lcount_smaller_after
    slli    t0, s0, 2
    add     s0, t0, s0             # * 5
    add     s0, s0, a0

    mv      a0, sp
    li      a1, 3
    call    .Lcount_smaller_after
    slli    s0, s0, 2              # * 4
    add     s0, s0, a0

    mv      a0, sp
    li      a1, 4
    call    .Lcount_smaller_after
    slli    t0, s0, 1
    add     s0, t0, s0             # * 3
    add     s0, s0, a0

    mv      a0, sp
    li      a1, 5
    call    .Lcount_smaller_after
    slli    s0, s0, 1              # * 2
    add     s0, s0, a0

    mv      a0, s0
    mv      a1, s1
    j       .Lparse_return

.Lparse_invalid:
    li      a0, -1
.Lparse_return:
    lw      s1, 20(sp)
    lw      s0, 24(sp)
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret

# -----------------------------------------------------------------------------
# apply_search_move
#   a0 = permutation rank
#   a1 = orientation rank
#   a2 = face [0, 2]
#   a3 = quarter turns [1, 3]
# returns updated a0/a1 and deliberately preserves a2/a3.
#
# The caller decodes move -> face/turns once.  The previous version decoded the
# same move inside this helper and then the DFS decoded the face again after
# return, which was expensive in the hottest path.
# -----------------------------------------------------------------------------
.Lapply_search_move:
    slli    t3, a2, 2
    la      t4, .Lpermutation_face
    add     t4, t4, t3
    lw      t4, 0(t4)
    la      t5, .Lorientation_face
    add     t5, t5, t3
    lw      t5, 0(t5)
    mv      t2, a3

.Lapply_turn_loop:
    slli    t6, a0, 1
    add     t6, t4, t6
    lhu     a0, 0(t6)

    slli    t6, a1, 1
    add     t6, t5, t6
    lhu     a1, 0(t6)

    addi    t2, t2, -1
    bnez    t2, .Lapply_turn_loop
    ret

# -----------------------------------------------------------------------------
# search_state_key
#   a0 = p, a1 = o
#   a0 = p * 729 + o
# 729 = 1024 - 256 - 32 - 8 + 1
# -----------------------------------------------------------------------------
.Lsearch_state_key:
    slli    t0, a0, 10
    slli    t1, a0, 8
    sub     t0, t0, t1
    slli    t1, a0, 5
    sub     t0, t0, t1
    slli    t1, a0, 3
    sub     t0, t0, t1
    add     t0, t0, a0
    add     a0, t0, a1
    ret

# -----------------------------------------------------------------------------
# lookup_key
#   a0 = sorted uint32_t key array
#   a1 = count
#   a2 = target key
#   a0 = matching index, or -1
# -----------------------------------------------------------------------------
.Llookup_key:
    li      t0, 0                    # low
    mv      t1, a1                   # high
.Llookup_loop:
    bgeu    t0, t1, .Llookup_finish
    sub     t2, t1, t0
    srli    t2, t2, 1
    add     t2, t2, t0               # mid
    slli    t3, t2, 2
    add     t3, a0, t3
    lw      t4, 0(t3)
    bltu    t4, a2, .Llookup_less
    mv      t1, t2
    j       .Llookup_loop
.Llookup_less:
    addi    t0, t2, 1
    j       .Llookup_loop
.Llookup_finish:
    bgeu    t0, a1, .Llookup_not_found
    slli    t2, t0, 2
    add     t2, a0, t2
    lw      t3, 0(t2)
    bne     t3, a2, .Llookup_not_found
    mv      a0, t0
    ret
.Llookup_not_found:
    li      a0, -1
    ret

# -----------------------------------------------------------------------------
# near_index
#   a0 = p, a1 = o
#   a0 = index in rubik_near_key, or -1
#
# Hot-path helper used at every DFS leaf.  It deliberately has no stack frame:
# state-key construction and binary search are fused so a miss costs no
# save/restore traffic.
# -----------------------------------------------------------------------------
.Lnear_index:
    # a2 = p * 729 + o, 729 = 1024 - 256 - 32 - 8 + 1
    slli    t0, a0, 10
    slli    t1, a0, 8
    sub     t0, t0, t1
    slli    t1, a0, 5
    sub     t0, t0, t1
    slli    t1, a0, 3
    sub     t0, t0, t1
    add     t0, t0, a0
    add     a2, t0, a1              # target key

    la      t3, .Lrubik_near_key     # base
    li      t4, RUBIK_NEAR_COUNT     # count
    li      t0, 0                    # low
    mv      t1, t4                   # high
.Lnear_lookup_loop:
    bgeu    t0, t1, .Lnear_lookup_finish
    sub     t2, t1, t0
    srli    t2, t2, 1
    add     t2, t2, t0              # mid
    slli    t5, t2, 2
    add     t5, t3, t5
    lw      t6, 0(t5)
    bltu    t6, a2, .Lnear_lookup_less
    mv      t1, t2
    j       .Lnear_lookup_loop
.Lnear_lookup_less:
    addi    t0, t2, 1
    j       .Lnear_lookup_loop
.Lnear_lookup_finish:
    bgeu    t0, t4, .Lnear_lookup_not_found
    slli    t2, t0, 2
    add     t2, t3, t2
    lw      t2, 0(t2)
    bne     t2, a2, .Lnear_lookup_not_found
    mv      a0, t0
    ret
.Lnear_lookup_not_found:
    li      a0, -1
    ret

# -----------------------------------------------------------------------------
# append_near_found
#   a0 = p, a1 = o, a2 = solution, a3 = &solution_length, a4 = known index
#   a0 = 1 on success, 0 if a later table link is unexpectedly absent
#
# Unlike the old append_near_solution, this is called only after membership was
# already established.  Failed DFS probes therefore never pay this stack-frame
# cost.
# -----------------------------------------------------------------------------
.Lappend_near_found:
    addi    sp, sp, -48
    sw      ra, 44(sp)
    sw      s0, 40(sp)
    sw      s1, 36(sp)
    sw      s2, 32(sp)
    sw      s3, 28(sp)
    sw      s4, 24(sp)
    sw      s5, 20(sp)
    sw      s6, 16(sp)
    sw      s7, 12(sp)

    mv      s0, a0                   # p
    mv      s1, a1                   # o
    mv      s2, a2                   # solution
    mv      s3, a3                   # length pointer

    la      t0, .Lrubik_near_info
    add     t0, t0, a4
    lbu     s4, 0(t0)                # current info
    srli    s5, s4, 4                # original distance
    li      s6, 0                    # i

.Lappend_found_loop:
    bgeu    s6, s5, .Lappend_found_success
    andi    s7, s4, 0x0f             # move
    add     t0, s2, s6
    sb      s7, 0(t0)

    la      t0, .Lmove_meta
    add     t0, t0, s7
    lbu     t1, 0(t0)
    srli    a2, t1, 2               # face
    andi    a3, t1, 3               # turns
    mv      a0, s0
    mv      a1, s1
    call    .Lapply_search_move
    mv      s0, a0
    mv      s1, a1

    addi    s6, s6, 1
    bgeu    s6, s5, .Lappend_found_success

    mv      a0, s0
    mv      a1, s1
    call    .Lnear_index
    bltz    a0, .Lappend_found_fail

    la      t0, .Lrubik_near_info
    add     t0, t0, a0
    lbu     s4, 0(t0)
    j       .Lappend_found_loop

.Lappend_found_success:
    sb      s5, 0(s3)
    li      a0, 1
    j       .Lappend_found_return
.Lappend_found_fail:
    li      a0, 0
.Lappend_found_return:
    lw      s7, 12(sp)
    lw      s6, 16(sp)
    lw      s5, 20(sp)
    lw      s4, 24(sp)
    lw      s3, 28(sp)
    lw      s2, 32(sp)
    lw      s1, 36(sp)
    lw      s0, 40(sp)
    lw      ra, 44(sp)
    addi    sp, sp, 48
    ret

# -----------------------------------------------------------------------------
# search_to_near
#   a0 = start.p
#   a1 = start.o
#   a2 = previous_face (0..2 or 3 for none)
#   a3 = solution
#   a4 = &solution_length
#   a0 = success
#
# Stack frame layout for each DFS node (6 bytes):
#   +0 uint16_t p
#   +2 uint16_t o
#   +4 uint8_t  next_move
#   +5 uint8_t  last_face
# -----------------------------------------------------------------------------
.Lsearch_to_near:
    addi    sp, sp, -112
    sw      ra, 108(sp)
    sw      s0, 104(sp)
    sw      s1, 100(sp)
    sw      s2, 96(sp)
    sw      s3, 92(sp)
    sw      s4, 88(sp)
    sw      s5, 84(sp)
    sw      s6, 80(sp)
    sw      s7, 76(sp)
    sw      s8, 72(sp)

    mv      s0, a0                   # start p
    mv      s1, a1                   # start o
    mv      s2, a2                   # previous face
    mv      s3, a3                   # solution
    mv      s4, a4                   # result length ptr

    # suffix length byte lives at 44(sp); frames occupy 0..41.
    # Probe membership with the frameless hot-path helper first.
    mv      a0, s0
    mv      a1, s1
    call    .Lnear_index
    bltz    a0, .Lsearch_limit_start

    mv      a4, a0                  # known near-table index
    mv      a0, s0
    mv      a1, s1
    mv      a2, s3
    addi    a3, sp, 44
    call    .Lappend_near_found
    beqz    a0, .Lsearch_limit_start
    lbu     t0, 44(sp)
    sb      t0, 0(s4)
    li      a0, 1
    j       .Lsearch_to_near_return

.Lsearch_limit_start:
    li      s5, 1                    # limit
.Lsearch_new_limit:
    li      t0, NEAR_DISTANCE
    bltu    t0, s5, .Lsearch_not_found

    li      s6, 0                    # depth
    mv      s7, sp                   # frame = &stack[0]
    sh      s0, 0(s7)
    sh      s1, 2(s7)
    sb      zero, 4(s7)
    sb      s2, 5(s7)

.Lsearch_dfs_loop:
    beq     s6, s5, .Lsearch_leaf

    lbu     t0, 4(s7)                # frame->next_move
    li      t1, MOVES
    beq     t0, t1, .Lsearch_exhausted

    addi    t1, t0, 1
    sb      t1, 4(s7)                # next_move++
    mv      s8, t0                   # chosen move

    # One packed byte contains both values: (face << 2) | turns.
    la      t1, .Lmove_meta
    add     t1, t1, s8
    lbu     t1, 0(t1)
    srli    a2, t1, 2                # face
    andi    a3, t1, 3                # turns
    lbu     t3, 5(s7)                # last_face
    beq     a2, t3, .Lsearch_dfs_loop

    lhu     a0, 0(s7)
    lhu     a1, 2(s7)
    call    .Lapply_search_move

    add     t0, s3, s6
    sb      s8, 0(t0)

    addi    s7, s7, SEARCH_FRAME_SIZE
    sh      a0, 0(s7)
    sh      a1, 2(s7)
    sb      zero, 4(s7)
    sb      a2, 5(s7)                # helper preserves face in a2
    addi    s6, s6, 1
    j       .Lsearch_dfs_loop

.Lsearch_leaf:
    # Most leaves miss the near table.  Probe without entering the heavy
    # reconstruction helper; only a hit pays its save/restore cost.
    lhu     a0, 0(s7)
    lhu     a1, 2(s7)
    call    .Lnear_index
    bltz    a0, .Lsearch_leaf_backtrack

    mv      a4, a0                  # known near-table index
    lhu     a0, 0(s7)
    lhu     a1, 2(s7)
    add     a2, s3, s6
    addi    a3, sp, 44
    call    .Lappend_near_found
    beqz    a0, .Lsearch_leaf_backtrack

    lbu     t0, 44(sp)
    add     t0, t0, s6
    sb      t0, 0(s4)
    li      a0, 1
    j       .Lsearch_to_near_return

.Lsearch_leaf_backtrack:
    addi    s6, s6, -1
    addi    s7, s7, -SEARCH_FRAME_SIZE
    j       .Lsearch_dfs_loop

.Lsearch_exhausted:
    beqz    s6, .Lsearch_next_limit
    addi    s6, s6, -1
    addi    s7, s7, -SEARCH_FRAME_SIZE
    j       .Lsearch_dfs_loop

.Lsearch_next_limit:
    addi    s5, s5, 1
    j       .Lsearch_new_limit

.Lsearch_not_found:
    li      a0, 0
.Lsearch_to_near_return:
    lw      s8, 72(sp)
    lw      s7, 76(sp)
    lw      s6, 80(sp)
    lw      s5, 84(sp)
    lw      s4, 88(sp)
    lw      s3, 92(sp)
    lw      s2, 96(sp)
    lw      s1, 100(sp)
    lw      s0, 104(sp)
    lw      ra, 108(sp)
    addi    sp, sp, 112
    ret

# -----------------------------------------------------------------------------
# solve_search
#   a0 = p, a1 = o, a2 = solution, a3 = &solution_length
#   a0 = success
# -----------------------------------------------------------------------------
.Lsolve_search:
    addi    sp, sp, -48
    sw      ra, 44(sp)
    sw      s0, 40(sp)
    sw      s1, 36(sp)
    sw      s2, 32(sp)
    sw      s3, 28(sp)
    sw      s4, 24(sp)
    sw      s5, 20(sp)
    sw      s6, 16(sp)

    mv      s0, a0                   # p
    mv      s1, a1                   # o
    mv      s2, a2                   # solution
    mv      s3, a3                   # solution length ptr
    li      s4, 0                    # prefix_length
    li      s5, 3                    # previous_face = FACES

    call    .Lsearch_state_key
    mv      a2, a0
    la      a0, .Lrubik_far_key
    li      a1, RUBIK_FAR_COUNT
    call    .Llookup_key
    bltz    a0, .Lsolve_after_far

    la      t0, .Lrubik_far_move
    add     t0, t0, a0
    lbu     s6, 0(t0)
    sb      s6, 0(s2)

    la      t0, .Lmove_meta
    add     t0, t0, s6
    lbu     t1, 0(t0)
    srli    a2, t1, 2               # face
    andi    a3, t1, 3               # turns
    mv      a0, s0
    mv      a1, s1
    call    .Lapply_search_move
    mv      s0, a0
    mv      s1, a1
    li      s4, 1
    mv      s5, a2                  # helper preserves face

.Lsolve_after_far:
    mv      a0, s0
    mv      a1, s1
    mv      a2, s5
    add     a3, s2, s4
    addi    a4, sp, 0                # remaining_length byte
    call    .Lsearch_to_near
    beqz    a0, .Lsolve_fail

    lbu     t0, 0(sp)
    add     t0, t0, s4
    sb      t0, 0(s3)
    li      a0, 1
    j       .Lsolve_return

.Lsolve_fail:
    li      a0, 0
.Lsolve_return:
    lw      s6, 16(sp)
    lw      s5, 20(sp)
    lw      s4, 24(sp)
    lw      s3, 28(sp)
    lw      s2, 32(sp)
    lw      s1, 36(sp)
    lw      s0, 40(sp)
    lw      ra, 44(sp)
    addi    sp, sp, 48
    ret

# -----------------------------------------------------------------------------
# Public entry point
# -----------------------------------------------------------------------------
    .globl  rubik_solve_asm
    .type   rubik_solve_asm, @function
    .align  2
rubik_solve_asm:
    addi    sp, sp, -64
    sw      ra, 60(sp)
    sw      s0, 56(sp)
    sw      s1, 52(sp)
    sw      s2, 48(sp)
    sw      s3, 44(sp)

    mv      s0, a1                   # out
    mv      s1, a2                   # cap

    # Parse and encode. Invalid input must leave out untouched.
    call    .Lparse_and_rank
    bltz    a0, .Lpublic_invalid

    # solution[0..10] starts at 0(sp), solution_length at 12(sp).
    addi    a2, sp, 0
    addi    a3, sp, 12
    call    .Lsolve_search
    beqz    a0, .Lpublic_invalid

    lbu     s2, 12(sp)               # number of moves

    # Compute required output bytes, including terminating NUL.
    li      t0, 1                    # required
    li      t1, 0                    # i
    la      t2, .Lmove_name_len
.Lrequired_loop:
    bgeu    t1, s2, .Lrequired_done
    beqz    t1, .Lrequired_no_space
    addi    t0, t0, 1
.Lrequired_no_space:
    add     t3, sp, t1
    lbu     t4, 0(t3)
    add     t5, t2, t4
    lbu     t5, 0(t5)
    add     t0, t0, t5
    addi    t1, t1, 1
    j       .Lrequired_loop
.Lrequired_done:
    bltu    s1, t0, .Lpublic_small_buffer

    # Write solution text.
    mv      t0, s0                   # current output pointer
    li      t1, 0                    # i
    la      t2, .Lmove_name_len
    la      t3, .Lmove_names
.Lwrite_loop:
    bgeu    t1, s2, .Lwrite_done
    beqz    t1, .Lwrite_no_space
    li      t4, 32                   # ' '
    sb      t4, 0(t0)
    addi    t0, t0, 1
.Lwrite_no_space:
    add     t4, sp, t1
    lbu     t4, 0(t4)                # move
    add     t5, t2, t4
    lbu     t5, 0(t5)                # length

    slli    t6, t4, 1
    add     t6, t6, t4               # move * 3
    add     t6, t3, t6
    lbu     a3, 0(t6)
    sb      a3, 0(t0)
    addi    t0, t0, 1
    li      a3, 2
    bne     t5, a3, .Lwrite_next
    lbu     a3, 1(t6)
    sb      a3, 0(t0)
    addi    t0, t0, 1
.Lwrite_next:
    addi    t1, t1, 1
    j       .Lwrite_loop
.Lwrite_done:
    sb      zero, 0(t0)
    mv      a0, s2
    j       .Lpublic_return

.Lpublic_small_buffer:
    beqz    s1, .Lpublic_small_no_write
    sb      zero, 0(s0)
.Lpublic_small_no_write:
    li      a0, -2
    j       .Lpublic_return

.Lpublic_invalid:
    li      a0, -1
.Lpublic_return:
    lw      s3, 44(sp)
    lw      s2, 48(sp)
    lw      s1, 52(sp)
    lw      s0, 56(sp)
    lw      ra, 60(sp)
    addi    sp, sp, 64
    ret
    .size   rubik_solve_asm, .-rubik_solve_asm

# -----------------------------------------------------------------------------
# Small read-only tables.
# -----------------------------------------------------------------------------
    .section .rodata
    .balign 4
.Lmove_meta:
    # (face << 2) | turns
    .byte   1, 2, 3, 5, 6, 7, 9, 10, 11
.Lmove_name_len:
    .byte   1, 2, 2, 1, 2, 2, 1, 2, 2
.Lmove_names:
    .byte   'R', 0, 0, 'R', '2', 0, 'R', 39, 0
    .byte   'B', 0, 0, 'B', '2', 0, 'B', 39, 0
    .byte   'D', 0, 0, 'D', '2', 0, 'D', 39, 0

    .balign 4
.Lpermutation_face:
    .word   .Lrubik_permutation
    .word   .Lrubik_permutation + 10080
    .word   .Lrubik_permutation + 20160
.Lorientation_face:
    .word   .Lrubik_orientation
    .word   .Lrubik_orientation + 1458
    .word   .Lrubik_orientation + 2916
