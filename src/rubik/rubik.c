#include "rubik.h"

#include <stdint.h>

enum {
    CUBIES = 7,
    PERMUTATIONS = 5040,
    ORIENTATIONS = 729,
    FACES = 3,
    MOVES = 9,
    MAX_SOLUTION_LENGTH = 11,
    NEAR_DISTANCE = 5,
    SEARCH_STACK_DEPTH = MAX_SOLUTION_LENGTH - NEAR_DISTANCE + 1
};

typedef struct {
    uint8_t p[CUBIES];
    uint8_t o[CUBIES];
} state_t;

typedef struct {
    uint16_t p;
    uint16_t o;
} search_state_t;

typedef struct {
    uint16_t p;
    uint16_t o;
    uint8_t next_move;
    uint8_t last_face;
} search_frame_t;


/*
 * Generated in Assignment 1.
 *
 * Assignment 1 provides the quarter-turn transition tables:
 *
 * static const uint16_t permutation[3][5040];
 * static const uint16_t orientation[3][729];
 *
 * tools/generate_rubik_lookup.c derives the sorted distance-5 and distance-11
 * tables used by the meet-in-the-middle search.
 */
#include "lookup_tables.h"
#include "static_tables.h"


/* ------------------------------------------------------------
 * Move information
 * ------------------------------------------------------------ */

static const uint8_t move_face[MOVES] = {0, 0, 0, 1, 1, 1, 2, 2, 2};

static const uint8_t move_turns[MOVES] = {1, 2, 3, 1, 2, 3, 1, 2, 3};

/*
 * Use fixed-size arrays instead of an array of pointers.
 *
 * Each entry has room for:
 *   2 characters + '\0'
 */
static const char move_names[MOVES][3] = {"R",  "R2", "R'", "B", "B2",
                                          "B'", "D",  "D2", "D'"};

static const uint8_t move_name_len[MOVES] = {1, 2, 2, 1, 2, 2, 1, 2, 2};


static const uint16_t *const permutation_face[FACES] = {
    permutation[0], permutation[1], permutation[2]};

static const uint16_t *const orientation_face[FACES] = {
    orientation[0], orientation[1], orientation[2]};


/* ------------------------------------------------------------
 * Input parsing and validation
 * ------------------------------------------------------------ */

static int valid(const state_t *state)
{
    uint8_t sum = 0;

    for (uint8_t i = 0; i < CUBIES; ++i) {
        /*
         * Cubie index must be 0..6.
         * Orientation must be 0..2.
         */
        if (state->p[i] >= CUBIES || state->o[i] >= 3)
            return 0;

        /*
         * Every cubie must appear exactly once.
         */
        for (uint8_t j = 0; j < i; ++j) {
            if (state->p[j] == state->p[i])
                return 0;
        }

        sum = (uint8_t) (sum + state->o[i]);
    }

    /*
     * Orientation sum must be divisible by 3.
     *
     * Since each orientation is at most 2,
     * sum is only in [0, 14].
     *
     * Avoid % here.
     */
    return sum == 0 || sum == 3 || sum == 6 || sum == 9 || sum == 12;
}


static int parse_state(const char *input, state_t *state)
{
    /*
     * First 7 characters:
     *
     * permutation digits '1'..'7'
     */
    for (uint8_t i = 0; i < CUBIES; ++i) {
        char c = input[i];

        if (c < '1' || c > '7')
            return 0;

        state->p[i] = (uint8_t) (c - '1');
    }

    /*
     * Next 7 characters:
     *
     * orientation digits '1'..'3'
     */
    for (uint8_t i = 0; i < CUBIES; ++i) {
        char c = input[CUBIES + i];

        if (c < '1' || c > '3')
            return 0;

        state->o[i] = (uint8_t) (c - '1');
    }

    /*
     * State must contain exactly 14 characters.
     */
    if (input[RUBIK_STATE_LEN] != '\0')
        return 0;

    return valid(state);
}


/* ------------------------------------------------------------
 * State ranking
 * ------------------------------------------------------------ */

static uint8_t count_smaller_after(const state_t *state, uint8_t position)
{
    uint8_t smaller = 0;

    for (uint8_t i = (uint8_t) (position + 1U); i < CUBIES; ++i) {
        if (state->p[i] < state->p[position])
            ++smaller;
    }

    return smaller;
}


/*
 * Lehmer-code permutation ranking.
 *
 * Avoid general multiplication by using shifts/additions for
 * multiplication by 6, 5, 4, 3, and 2.
 */
static uint16_t rank_permutation(const state_t *state)
{
    uint16_t p;

    p = count_smaller_after(state, 0);

    /* p = p * 6 + digit */
    p = (uint16_t) ((p << 2U) + (p << 1U) + count_smaller_after(state, 1));

    /* p = p * 5 + digit */
    p = (uint16_t) ((p << 2U) + p + count_smaller_after(state, 2));

    /* p = p * 4 + digit */
    p = (uint16_t) ((p << 2U) + count_smaller_after(state, 3));

    /* p = p * 3 + digit */
    p = (uint16_t) ((p << 1U) + p + count_smaller_after(state, 4));

    /* p = p * 2 + digit */
    p = (uint16_t) ((p << 1U) + count_smaller_after(state, 5));

    return p;
}


/*
 * Orientation is a base-3 number.
 *
 * Only the first six orientations are necessary because the
 * seventh is determined by the orientation constraint.
 */
static uint16_t rank_orientation(const state_t *state)
{
    uint16_t o = 0;

    for (uint8_t i = 0; i < 6; ++i) {
        /* o = o * 3 + state->o[i] */
        o = (uint16_t) ((o << 1U) + o + state->o[i]);
    }

    return o;
}


static search_state_t encode_search_state(const state_t *state)
{
    search_state_t result;

    result.p = rank_permutation(state);
    result.o = rank_orientation(state);

    return result;
}


/* ------------------------------------------------------------
 * Move operation
 * ------------------------------------------------------------ */

static search_state_t apply_search_move(search_state_t state, uint8_t move)
{
    uint8_t face = move_face[move];
    uint8_t turns = move_turns[move];

    const uint16_t *p_table = permutation_face[face];
    const uint16_t *o_table = orientation_face[face];

    /*
     * R  : one quarter turn
     * R2 : two quarter turns
     * R' : three quarter turns
     *
     * Same for B and D.
     */
    do {
        state.p = p_table[state.p];
        state.o = o_table[state.o];
    } while (--turns != 0);

    return state;
}


/* ------------------------------------------------------------
 * Compact lookup tables
 * ------------------------------------------------------------ */

static uint32_t search_state_key(search_state_t state)
{
    uint32_t p = state.p;

    /* p * 729 + o, without requiring a multiplication instruction. */
    return (p << 10U) - (p << 8U) - (p << 5U) - (p << 3U) + p + state.o;
}


static int lookup_key(const uint32_t *keys, uint32_t count, uint32_t key)
{
    uint32_t low = 0;
    uint32_t high = count;

    while (low < high) {
        uint32_t mid = low + ((high - low) >> 1U);
        uint32_t value = keys[mid];

        if (value < key)
            low = mid + 1U;
        else
            high = mid;
    }

    if (low < count && keys[low] == key)
        return (int) low;
    return -1;
}


static int append_near_solution(search_state_t state,
                                uint8_t *solution,
                                uint8_t *solution_length)
{
    int index =
        lookup_key(rubik_near_key, RUBIK_NEAR_COUNT, search_state_key(state));
    if (index < 0)
        return 0;

    uint8_t info = rubik_near_info[index];
    uint8_t distance = info >> 4U;

    for (uint8_t i = 0; i < distance; ++i) {
        uint8_t move = info & 0x0FU;
        solution[i] = move;
        state = apply_search_move(state, move);

        if (i + 1U < distance) {
            index = lookup_key(rubik_near_key, RUBIK_NEAR_COUNT,
                               search_state_key(state));
            if (index < 0)
                return 0;
            info = rubik_near_info[index];
        }
    }

    *solution_length = distance;
    return 1;
}


/* ------------------------------------------------------------
 * Meet-in-the-middle search
 * ------------------------------------------------------------ */

static int search_to_near(search_state_t start,
                          uint8_t previous_face,
                          uint8_t *solution,
                          uint8_t *solution_length)
{
    uint8_t suffix_length;
    if (append_near_solution(start, solution, &suffix_length)) {
        *solution_length = suffix_length;
        return 1;
    }

    search_frame_t stack[SEARCH_STACK_DEPTH];

    for (uint8_t limit = 1; limit <= NEAR_DISTANCE; ++limit) {
        uint8_t depth = 0;
        search_frame_t *frame = &stack[0];

        frame->p = start.p;
        frame->o = start.o;
        frame->next_move = 0;
        frame->last_face = previous_face;

        for (;;) {
            if (depth == limit) {
                search_state_t leaf = {frame->p, frame->o};

                if (append_near_solution(leaf, solution + depth,
                                         &suffix_length)) {
                    *solution_length = (uint8_t) (depth + suffix_length);
                    return 1;
                }

                --depth;
                --frame;
                continue;
            }

            if (frame->next_move == MOVES) {
                if (depth == 0)
                    break;

                --depth;
                --frame;
                continue;
            }

            uint8_t move = frame->next_move++;
            uint8_t face = move_face[move];

            /*
             * Consecutive turns of one face are never part of a shortest path.
             */
            if (face == frame->last_face)
                continue;

            search_state_t next = {frame->p, frame->o};
            next = apply_search_move(next, move);
            solution[depth] = move;

            ++frame;
            frame->p = next.p;
            frame->o = next.o;
            frame->next_move = 0;
            frame->last_face = face;
            ++depth;
        }
    }

    return 0;
}


static int solve_search(search_state_t start,
                        uint8_t *solution,
                        uint8_t *solution_length)
{
    uint8_t prefix_length = 0;
    uint8_t previous_face = FACES;
    int index =
        lookup_key(rubik_far_key, RUBIK_FAR_COUNT, search_state_key(start));

    /* Every distance-11 state stores one move toward distance 10. */
    if (index >= 0) {
        uint8_t move = rubik_far_move[index];
        solution[0] = move;
        start = apply_search_move(start, move);
        prefix_length = 1;
        previous_face = move_face[move];
    }

    uint8_t remaining_length;
    if (!search_to_near(start, previous_face, solution + prefix_length,
                        &remaining_length))
        return 0;

    *solution_length = (uint8_t) (prefix_length + remaining_length);
    return 1;
}


/* ------------------------------------------------------------
 * Output formatting
 * ------------------------------------------------------------ */

static size_t solution_output_size(const uint8_t *solution, uint8_t length)
{
    /*
     * Include the final '\0'.
     */
    size_t size = 1;

    for (uint8_t i = 0; i < length; ++i) {
        if (i != 0)
            ++size; /* space */

        size += move_name_len[solution[i]];
    }

    return size;
}


static void write_solution(const uint8_t *solution, uint8_t length, char *out)
{
    size_t pos = 0;

    for (uint8_t i = 0; i < length; ++i) {
        uint8_t move = solution[i];

        if (i != 0)
            out[pos++] = ' ';

        for (uint8_t j = 0; j < move_name_len[move]; ++j)
            out[pos++] = move_names[move][j];
    }

    out[pos] = '\0';
}


/* ------------------------------------------------------------
 * Public interface
 * ------------------------------------------------------------ */

int rubik_solve(const char *input, char *out, size_t cap)
{
    state_t state;

    /*
     * Contract:
     * invalid input -> -1
     * out must remain untouched.
     */
    if (!parse_state(input, &state))
        return -1;

    search_state_t start = encode_search_state(&state);

    uint8_t solution[MAX_SOLUTION_LENGTH];
    uint8_t solution_length;

    /*
     * Every valid 2x2x2 state in this representation should be
     * solvable within 11 moves.
     */
    if (!solve_search(start, solution, &solution_length))
        return -1;

    /*
     * Required bytes include spaces and terminating NUL.
     */
    size_t required = solution_output_size(solution, solution_length);

    /*
     * Contract:
     *
     * buffer too small -> -2
     *
     * If cap >= 1, out must become an empty string.
     */
    if (cap < required) {
        if (cap >= 1)
            out[0] = '\0';

        return -2;
    }

    write_solution(solution, solution_length, out);

    /*
     * Return number of moves, not number of output characters.
     */
    return (int) solution_length;
}
