# CA 2

## Binary GCD

### Algorithm

The GCD program uses the binary GCD algorithm (Stein's algorithm), which replaces division and remainder with shifts, subtraction, and bitwise operations.

The main identities are

$$
\gcd(a,0)=a
$$

$$
\gcd(2a,2b)=2\gcd(a,b)
$$

and, for odd $a \le b$,

$$
\gcd(a,b)=\gcd(a,b-a)
$$

This makes the algorithm suitable for RV32I, which does not provide `div` or `rem`.

---

### CTZ Optimization

The initial version removed one factor of two per iteration. This was optimized using a software count-trailing-zeros (CTZ) operation.

RV32I has no native `ctz`, so the implementation checks groups of

$$
16,\ 8,\ 4,\ 2,\ 1
$$

bits.

The common power of two is obtained from

$$
ctz(a|b)=\min(ctz(a),ctz(b))
$$

The optimized loop is conceptually:

```c id="fp9f0m"
shift = ctz32(a | b);
a >>= ctz32(a);

do {
    b >>= ctz32(b);

    if (a > b)
        swap(a, b);

    b -= a;
} while (b != 0);

return a << shift;
```

This removes several powers of two with one variable shift instead of repeatedly shifting by one bit.

---

### RV32I and Macro Optimization

The assembly version keeps the operands in registers and uses only RV32I instructions. 
```
a0 = first operand
a1 = second operand
a0 = return value
```

Unsigned comparison uses `sltu`, subtraction uses `sub`, and the saved power of two is restored using `sll`.

An additional optimization is to implement the CTZ sequence as an assembler macro rather than a separate function.

A function-based implementation would repeatedly execute:

```asm id="2z6sps"
jal     ra, ctz32
...
ret
```

and may require extra register moves to pass arguments and preserve the return address.

Using `.macro` expands the CTZ instructions directly at each use site:

```asm id="waya6e"
.macro CTZ ...
    # 16, 8, 4, 2, 1 checks
.endm
```

This eliminates function-call and return overhead from the GCD loop. The trade-off is increased code size because the CTZ sequence is duplicated at each expansion site.

Therefore, the macro optimization favors fewer executed instructions at the cost of a larger `.text` section.

---

### Verification

The test suite checks boundary cases, all 65,536 pairs below 256, powers of two, random operands, and Fibonacci cases.

The C and assembly implementations are cross-checked against an independent reference. Since GCD is an exact integer operation, the numerical error is zero.

---

### Performance

Measurements were collected with `riscv64-unknown-elf-gcc 13.2.0` and rv32emu `ffb041b`.

rv32emu has no timing model, so the reported cycles are equivalent to executed instruction counts.

| Implementation | Instructions / call | `.text` |
|---|---:|---:|
| C `-O1` | 165.4 | 240 B |
| C `-O2` | 155.0 | 352 B |
| C `-O3` | **150.8** | 372 B |
| C `-Os` | 176.2 | **240 B** |
| Assembly | **149.9** | 344 B |

The hand-written assembly is about

$$
\frac{150.8-149.9}{150.8}\times100\%
\approx 0.6\%
$$

faster than the best compiler-generated version (`-O3`).

The assembly satisfies the 1500-instruction budget, while the C version remains below its 4000-instruction budget.

The macro-expanded CTZ helps reduce executed instructions by avoiding repeated call/return overhead. However, the duplicated instruction sequence also contributes to the 344-byte assembly footprint, which is larger than the 240-byte `-Os` version.

---

### Discussion

Binary GCD maps naturally to RV32I because its core operations are shifts, bitwise operations, subtraction, comparison, and branches.

The main optimizations are:

1. replacing division-based GCD with binary GCD;
2. removing multiple powers of two using CTZ;
3. implementing CTZ with a 16-8-4-2-1 binary search;
4. using assembler macros to remove CTZ function-call overhead;
5. keeping the working state in registers.

The result shows a clear speed-versus-size trade-off. The hand-written assembly slightly reduces the instruction count compared with GCC `-O3`, while macro expansion makes it larger than the smallest compiler-generated version.

## BFloat16

### Representation

BFloat16 stores a floating-point value in 16 bits:

```
15          14              7 6               0
+--------------+--------------+----------------+
| sign (1 bit) | exponent (8) | fraction (7)   |
+--------------+--------------+----------------+
```

It has the same 8-bit exponent and bias 127 as binary32, but keeps only 7
fraction bits. For a normal value,

$$
x=(-1)^s\times 2^{E-127}\times\left(1+\frac{F}{128}\right).
$$

An exponent of zero represents zero or a denormal, while an exponent of
`0xFF` represents infinity or NaN. The implementation manipulates only the
integer bit patterns and does not use floating-point instructions.

---

### Conversion from Binary32

`bf16_from_f32` narrows a 32-bit binary32 pattern to BFloat16. Simply taking
the upper 16 bits would truncate the value, so the discarded lower half must
be considered for round-to-nearest, ties-to-even.

For finite values, the conversion is

```c
tie = (f32bits >> 16) & 1;
result = (f32bits + 0x7FFF + tie) >> 16;
```

`0x7FFF` rounds values above the halfway point upward. At an exact halfway
point, `tie` is the least significant retained bit, so an odd retained value
is rounded up and an even one is kept. This is the ties-to-even rule.

Infinity and NaN have exponent `0xFF`. They bypass the addition and return the
upper 16 bits unchanged, preventing a special value from being altered by the
rounding increment.

---

### Multiplication

`bf16_mul` first separates each operand into its sign, exponent, and fraction.
The result sign is

$$
s=s_a\oplus s_b.
$$

Special values must be handled before ordinary multiplication. Operand `a` is
classified first: its NaN is returned unchanged, while its infinity produces
`0x7FC0` when `b` is zero and signed infinity otherwise. Only when `a` is
finite is `b` classified in the same way. Finally, zero multiplied by a finite
value produces zero with the product sign. This required order makes the result
deterministic even when both operands are special values.

For finite nonzero values, a normal significand receives its implicit leading
one:

```c
sig = 0x80 | fraction;
```

A denormal has no implicit one, so its significand is shifted left until bit 7
becomes one, decreasing its effective exponent after each shift. The two
8-bit significands are then multiplied and the product is normalized. If bit
15 is set, the product is shifted by 8 and the exponent is incremented;
otherwise it is shifted by 7. The discarded product bits are truncated as
required by the function contract.

Exponent overflow produces infinity. A nonpositive exponent produces a
denormal by an additional right shift, or signed zero when the value is too
small.

---

### Square Root

For a positive normal BFloat16 value,

$$
\sqrt{2^e m}=2^{e/2}\sqrt{m}.
$$

If the unbiased exponent is odd, the significand is doubled and the exponent
is reduced by one. The exponent is therefore even before it is divided by two.

The significand square root is found with a binary search over integer values
from 90 through 256. The search keeps the largest `mid` satisfying

$$
\frac{mid^2}{128}\le m.
$$

The root and exponent are normalized again before the BFloat16 fields are
packed. This is a deliberately approximate integer algorithm rather than a
correctly rounded IEEE square root; its specified worst relative error over
positive normal inputs is 0.3884%.

The special cases are:

- NaN is returned unchanged;
- positive infinity is returned unchanged;
- negative infinity and negative nonzero values produce `0x7FC0`;
- both signed zeros and all denormals produce positive zero.

---

### RV32I Implementation

The assembly routines follow the standard integer calling convention:

```
a0      = first operand and return value
a1      = second operand, when present
t0-t6   = temporary caller-saved registers
a2-a7   = additional caller-saved working registers
```

All three routines are leaf functions, so they do not need a stack frame or
save `ra`. They use only RV32I shifts, masks, branches, addition, and
subtraction. In particular, the M and F extensions are unavailable.

Both `bf16_mul_asm` and `bf16_sqrt_asm` need integer multiplication. It is
implemented with shift-and-add instead of `mul`:

```asm
.Lproduct_loop:
    andi    t6, multiplier, 1
    beq     t6, zero, .Lproduct_skip
    add     product, product, multiplicand
.Lproduct_skip:
    slli    multiplicand, multiplicand, 1
    srli    multiplier, multiplier, 1
    bne     multiplier, zero, .Lproduct_loop
```

The multiplication routine applies this to the two significands. The square
root routine applies it to `mid * mid` during each binary-search iteration.
This avoids `mul`, `div`, `rem`, floating-point instructions, and calls to a
runtime multiplication helper.

---

### Verification

The conversion tests cover directed boundary cases and every important
rounding relation: below a tie, at a tie, above a tie, and carry into the
exponent. Multiplication is checked using directed cases, a 256 by 256 grid,
all 65,536 operands against eight constants, algebraic laws, and golden hashes.

Square root is checked over all 65,536 input patterns, including special
values, monotonicity, and the allowed numerical-error bound. The C and assembly
versions are also cross-checked directly.

---

### Performance

The same compiler and rv32emu revision as the GCD measurements were used.
These are average executed instructions per call after loop overhead is
removed:

| Function | C `-O1` | C `-O2` | C `-O3` | C `-Os` | Assembly | Best C / ASM |
|---|---:|---:|---:|---:|---:|---:|
| `from_f32` | **11.1** | 11.3 | 13.1 | 12.2 | 12.2 | 0.90x |
| `mul` | 86.1 | **82.4** | 83.8 | 83.9 | **68.9** | 1.20x |
| `sqrt` | 280.6 | **278.4** | 279.7 | 283.2 | **251.3** | 1.11x |

The ratio is the best C instruction count divided by the assembly count, so a
value above `1.00x` means that assembly is faster. `from_f32` reports `0.90x`
because assembly needs about 1.1 more instructions per call than the best C
build. It still passes because the grading rule permits assembly to take up to
the best C result plus 2 instructions per call.

The worst tested assembly calls retire 15 instructions for conversion, 130 for
multiplication, and 493 for square root. These are below their respective
budgets of 60, 400, and 1500 instructions.

| Variant | `.text` |
|---|---:|
| C `-O1` | 832 B |
| C `-O2` | 872 B |
| C `-O3` | 904 B |
| C `-Os` | 716 B |
| Assembly | **636 B** |

---

### Discussion

The conversion routine is already very small, leaving little opportunity for
hand-written assembly to outperform the compiler. Multiplication and square
root benefit more from explicit register allocation and compact shift-and-add
loops.

The main implementation points are:

1. operate on bit patterns rather than floating-point values;
2. preserve the exact special-value precedence required by the contract;
3. distinguish ties-to-even conversion from truncating multiplication;
4. normalize denormals explicitly;
5. replace integer multiplication with RV32I shift-and-add loops.

The final assembly is faster for the two expensive operations and also has a
smaller `.text` section than every compiled C variant.

## Fixed-Point and Logic Arithmetic

### Q11.20 Representation

The fixed-point routines use signed Q11.20 values stored in 32-bit integers.
A stored integer $A$ represents

$$
x=\frac{A}{2^{20}}.
$$

Therefore, `0x00100000` represents 1.0 and `0x00080000` represents 0.5. The
format has a resolution of $2^{-20}$ and uses two's complement for negative
values.

The file also contains three integer operations that demonstrate how addition,
subtraction, and an overflow-safe average relate to bitwise logic.

---

### `op1`: Bitwise Addition

For each bit position, XOR computes a sum without its carry, while AND finds
where a carry is generated. Shifting the carry left moves it to the next bit:

```c
while (b != 0) {
    carry = (a & b) << 1;
    a ^= b;
    b = carry;
    passes++;
}
```

When the carry becomes zero, `a` contains $a+b$ modulo $2^{32}$. The function
also stores the exact loop count through `*n`, so the loop cannot be replaced
with a normal `+` operation. For example, adding one to `0xFFFF` propagates a
carry through 16 one-bits and takes 17 passes.

In assembly, the arguments are

```
a0 = a and return value
a1 = b
a2 = pointer to n
```

The loop count is kept in `t0` and written with `sw t0, 0(a2)` before return.

---

### `op2`: Subtraction

Subtraction modulo $2^{32}$ can be expressed through two's-complement addition:

$$
a-b=a+(\sim b+1).
$$

However, the performance contract asks for the direct RV32I instruction, so
the assembly implementation is simply:

```asm
sub     a0, a0, a1
ret
```

The result naturally wraps modulo $2^{32}$.

---

### `op3`: Overflow-Safe Average

Computing `(a + b) >> 1` directly can lose the carry when the 32-bit addition
overflows. The identity

$$
a+b=2(a\mathbin{\&}b)+(a\mathbin{\oplus}b)
$$

gives

$$
\left\lfloor\frac{a+b}{2}\right\rfloor
=(a\mathbin{\&}b)+\left((a\mathbin{\oplus}b)\mathbin{\gg}1\right).
$$

This form never constructs the potentially overflowing full sum. The assembly
maps directly to `and`, `xor`, `srli`, and `add`.

---

### `q_mul`: Q11.20 Multiplication

Multiplying two stored Q11.20 integers introduces 40 fractional bits:

$$
\frac{A}{2^{20}}\times\frac{B}{2^{20}}
=\frac{AB}{2^{40}}.
$$

To return to 20 fractional bits, the integer product must be shifted right by
20. The required rounded result is

$$
R=\left(AB+2^{19}\right)\mathbin{\gg}_{arith}20.
$$

Adding half of one output unit before the arithmetic shift makes exact ties
round toward positive infinity. For example,
`q_mul(3, 524288) = 2`, whereas `q_mul(-3, 524288) = -1`.

The intermediate product must be 64 bits. The C implementation divides each
unsigned magnitude into high and low 16-bit halves:

$$
A=A_h2^{16}+A_l,\qquad B=B_h2^{16}+B_l,
$$

and combines four partial products:

$$
AB=A_lB_l+(A_lB_h+A_hB_l)2^{16}+A_hB_h2^{32}.
$$

This avoids losing the upper half of a 32-bit product. The sign is applied to
the 64-bit magnitude before rounding and shifting. Only the low 32 bits of the
result are returned, so out-of-range products wrap rather than saturate.

---

### RV32I 64-Bit Multiplication

RV32I has 32-bit registers and this project forbids `mul`, so `q_mul_asm`
represents each 64-bit value with a register pair:

```
t2:t1 = 64-bit multiplicand, high word first
t5:t4 = 64-bit accumulated product
t3    = 32-bit multiplier
```

For every set bit in the multiplier, the multiplicand is added to the product.
`sltu` detects a carry from the low-word addition and adds it to the high word.
The multiplicand is then shifted left across the register boundary while the
multiplier is shifted right.

If the result is negative, the register pair is negated with 64-bit two's
complement. Rounding adds $2^{19}$ to the low word and propagates a possible
carry. Finally, the low 32 bits of the arithmetic 64-bit right shift by 20 are
assembled as

```asm
srli    a0, t4, 20
slli    t5, t5, 12
or      a0, a0, t5
```

The upper 12 bits come from the signed high word. Because a left shift keeps
the same low 12 bits for either signed or unsigned interpretation, `slli` is
sufficient here.

Addition and subtraction are not globally forbidden in these assembly
routines. The restriction is specific to the purpose of each function:
`op1` must construct its sum through bitwise carry propagation, while `op2`,
`op3`, and `q_mul` may use `sub` or `add` where required.

---

### Verification

`op1` is checked with directed cases, a 64 by 64 grid, 1,024 random pairs,
algebraic laws, and the exact number of carry-propagation passes. `op2` and
`op3` are compared with independent arithmetic references, including values
near `0x00000000` and `0xFFFFFFFF`.

`q_mul` is checked with directed cases, a 64 by 64 grid, random pairs, identity
and commutativity laws, negative values, wrap-around, and exact halfway cases.
Every assembly function is also compared directly with its C implementation.

---

### Performance

Average executed instructions per call are:

| Function | C `-O1` | C `-O2` | C `-O3` | C `-Os` | Assembly | Best C / ASM |
|---|---:|---:|---:|---:|---:|---:|
| `op1` | 24.7 | **24.6** | 26.8 | **24.6** | 24.8 | 0.99x |
| `op2` | **4.0** | **4.0** | 5.9 | **4.0** | **4.0** | 1.00x |
| `op3` | **7.0** | **7.0** | 8.9 | **7.0** | **7.0** | 1.00x |
| `q_mul` | 278.7 | **276.2** | 278.1 | **276.2** | **228.4** | 1.21x |

The simple operations compile to nearly the same instructions as the manual
assembly. `q_mul_asm` is about

$$
\frac{276.2-228.4}{276.2}\times100\%\approx17.3\%
$$

faster than the best C build.

The worst tested C/assembly instruction counts are 201/201 for `op1`, 6/6 for
`op2`, 9/9 for `op3`, and 465/431 for `q_mul`. All are below the assembly
budgets of 600, 40, 40, and 1200 instructions.

| Variant | `.text` |
|---|---:|
| C `-O1` | 396 B |
| C `-O2` | 376 B |
| C `-O3` | 376 B |
| C `-Os` | 372 B |
| Assembly | **220 B** |

---

### Discussion

The four routines demonstrate different mappings from arithmetic to RV32I:

1. `op1` exposes the carry-propagation process using XOR, AND, and shifts;
2. `op2` uses the ISA's direct modulo-$2^{32}$ subtraction;
3. `op3` rearranges an average to prevent intermediate overflow;
4. `q_mul` preserves precision with a 64-bit register pair and explicit
   rounding.

The compiler already produces optimal or nearly optimal code for the three
small operations. The largest improvement comes from `q_mul`, where controlling
the 64-bit shift-and-add product directly reduces both executed instructions
and code size. The complete assembly implementation is 220 bytes, substantially
smaller than the 372-byte `-Os` C version.

## Rubik Solver

### C Implementation

The Rubik solver uses a **meet-in-the-middle search** to reduce the runtime search depth.

The cube state is represented by two compact indices:

- `p`: permutation rank, ranging from `0` to `5039`
- `o`: orientation rank, ranging from `0` to `728`

These two values are combined into a unique state key:

$$
key = p \times 729 + o
$$

where `p` is the permutation index and `o` is the orientation index. The multiplication by 729 is implemented using shifts and additions/subtractions to avoid multiplication instructions on RV32I.

Two precomputed lookup tables are used:

- `rubik_near_key` / `rubik_near_info`: store states within 5 moves of the solved state and the next move toward the solution.
- `rubik_far_key` / `rubik_far_move`: store distance-11 states and one move that reduces them to distance 10.

The key arrays are sorted and searched using binary search.

For the near table, `rubik_near_info` stores both the remaining distance and the next move in a single byte. The upper 4 bits represent the distance to the solved state, while the lower 4 bits represent the next move.

For example:

```text
0x51
```

represents:

```text
distance = 5
move     = 1
```

After applying the stored move, the new state is encoded again and another near-table lookup is performed until the solved state is reached.

For states at distance 6–10, the solver performs an iterative search for at most 5 moves until it reaches a state contained in the near table.

A distance-11 state cannot directly be covered by a 5-step search plus a distance-5 table. Therefore, `rubik_far_key` is used to detect distance-11 states, and `rubik_far_move` provides one move that reduces the state to distance 10.

The overall search structure becomes:

```text
Distance <= 5
    |
    v
Near lookup table
    |
    v
Solved

Distance 6-10
    |
    v
Search at most 5 moves
    |
    v
Near lookup table
    |
    v
Solved

Distance 11
    |
    v
Far lookup table
    |
    v
Apply one move
    |
    v
Distance 10
    |
    v
Search at most 5 moves
    |
    v
Near lookup table
    |
    v
Solved
```

Therefore, the worst-case runtime search is reduced from searching up to 11 levels to searching at most 5 levels.

The search also skips consecutive moves on the same face because they cannot appear in a shortest solution. This reduces the effective branching factor of the search tree.

---

### RV32I Assembly Implementation

The assembly version follows the same meet-in-the-middle algorithm as the C implementation and uses only RV32I instructions.

Several optimizations are applied:

- The permutation validation uses a bit mask instead of repeatedly checking duplicate cubies.
- The state key `p * 729 + o` is computed using shifts and subtraction instead of `mul`.
- Binary search is implemented directly in assembly for the sorted lookup tables.
- The DFS search stack uses a compact 6-byte frame containing permutation, orientation, next move, and previous face.
- Consecutive moves on the same face are skipped because they cannot appear in a shortest solution.
- Move information is compactly encoded so the face and number of quarter turns can be decoded with simple shifts and masks.

The state key calculation is equivalent to:

$$
729p = 1024p - 256p - 32p - 8p + p
$$

which can be implemented using only shift, add, and subtract instructions.

The transition tables generated by the C implementation are also reused in assembly. Instead of reconstructing a cube state for every move, the solver directly uses the permutation and orientation indices to perform table lookups.

One important optimization is the handling of near-table lookup during DFS.

In the initial assembly version, every leaf state called the complete near-solution routine. Even when the state was not present in the near table, the function still required register saving, function calls, binary search, and register restoration.

Since most searched leaf states do not match a near-table entry, this introduced significant overhead in the hottest part of the search.

The optimized version separates the process into two stages:

```text
DFS leaf
    |
    v
Lightweight near-table lookup
    |
    +---- not found ----> backtrack
    |
    v
Found
    |
    v
Reconstruct remaining solution
```

The expensive solution-reconstruction path is therefore executed only when a matching state is found.

Move decoding is also optimized. Instead of repeatedly looking up the face and number of quarter turns in separate locations, both values are encoded together and decoded using bit operations.

The iterative search keeps its state in a compact stack frame:

```text
permutation : 16 bits
orientation : 16 bits
next_move   : 8 bits
last_face   : 8 bits
```

giving a total of 6 bytes per search frame.

Since the runtime search depth is limited to 5 levels, the total stack usage remains small.

---

### Performance Result

The final implementation passes all Rubik tests:

```text
toolchain     PASS
emulator      PASS
rubik         PASS
disassembly   PASS
cycles        PASS
footprint     PASS
hygiene       PASS

TOTAL: 55.0/55
```

The final cycle comparison is:

```text
rubik.solve: assembly matches the best C build (1.00x)
```

The initial assembly implementation was slower than the optimized C version because of excessive function-call and register save/restore overhead inside the DFS hot path.

After optimizing the near-table lookup and reducing repeated move decoding, the final RV32I implementation reaches approximately the same performance as the best compiler-generated C implementation.

The optimized RV32I assembly therefore satisfies the correctness, instruction-set, performance, and footprint requirements while preserving the same meet-in-the-middle search strategy used by the C implementation.