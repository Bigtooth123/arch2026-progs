#!/usr/bin/env bash

# Locate and validate the GNU toolchain for the RV32I-only bare-metal build.
#
#   toolchain.sh --detect      print the tool prefix and exit
#   toolchain.sh [prefix]      validate the toolchain and report versions
#
# Validation compiles, assembles and links a probe with the exact flags of the
# build, then reads the ELF attributes back: the compiler must accept
# -march=rv32i_zicsr, the probe must carry no M, F or C extension, and '*' must
# lower to a __mulsi3 call rather than a mul instruction.

ARCH="-march=rv32i_zicsr -mabi=ilp32"
CANDIDATES="riscv-none-elf- riscv32-unknown-elf- riscv64-unknown-elf- riscv-none-embed- riscv64-linux-gnu- riscv32-unknown-linux-gnu-"

detect() {
  if [ -n "$CROSS_COMPILE" ]; then
    echo "$CROSS_COMPILE"
    return 0
  fi
  for p in $CANDIDATES; do
    if command -v "${p}gcc" >/dev/null 2>&1; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

if [ "$1" = "--detect" ]; then
  detect
  exit $?
fi

here=$(cd "$(dirname "$0")" && pwd)
. "$here/common.sh"
set_colors

fail() {
  printf "${RED}[ FAIL ]${NC} %s\n" "$1" >&2
  [ -n "$2" ] && printf "         %s\n" "$2" >&2
  exit 1
}
ok() { printf "${GREEN}[  OK  ]${NC} %s\n" "$1"; }

PREFIX="${1:-$(detect)}" ||
  fail "No RISC-V GNU toolchain found" \
       "Install one (for example xPack riscv-none-elf-gcc) and put it in PATH, or set CROSS_COMPILE=<prefix>."

for tool in gcc as ld objdump objcopy nm size readelf; do
  command -v "${PREFIX}${tool}" >/dev/null 2>&1 ||
    fail "${PREFIX}${tool} is missing" "A complete binutils set is required: gcc as ld objdump objcopy nm size readelf."
done
ok "tools present: ${PREFIX}{gcc,as,ld,objdump,objcopy,nm,size,readelf}"

gcc_ver=$("${PREFIX}gcc" -dumpfullversion 2>/dev/null || "${PREFIX}gcc" -dumpversion)
gcc_major=${gcc_ver%%.*}
[ "$gcc_major" -ge 12 ] 2>/dev/null ||
  fail "GCC $gcc_ver is too old" "GCC 12 or later is needed for the -march=rv32i_zicsr spelling."
ok "GCC $gcc_ver"

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/probe.c" <<'EOF'
int mul(int a, int b) { return a * b; }
int main(void) { return mul(3, 5) != 15; }
EOF
cat > "$tmp/boot.S" <<'EOF'
    .section .text._start
    .globl _start
_start:
    li a7, 93
    csrr a0, cycle
    ecall
EOF
printf 'ENTRY(_start)\nSECTIONS { . = 0x10000; .text : { *(.text._start) *(.text .text.*) } }\n' > "$tmp/l.ld"

"${PREFIX}gcc" $ARCH -ffreestanding -O2 -S -o "$tmp/probe.asm" "$tmp/probe.c" 2> "$tmp/err" ||
  fail "The compiler rejects: $ARCH" "$(head -3 "$tmp/err")"
if grep -Eq '^[[:space:]]+(mul|mulh|mulhu|mulhsu|div|divu|rem|remu)[[:space:]]' "$tmp/probe.asm"; then
  fail "The compiler emitted an M-extension instruction under $ARCH"
fi
grep -q '__mulsi3' "$tmp/probe.asm" ||
  fail "'*' did not lower to a __mulsi3 call" "Check that $ARCH really selects RV32I."
ok "'*' lowers to a __mulsi3 call, no M instruction"

"${PREFIX}gcc" $ARCH -ffreestanding -O2 -c -o "$tmp/probe.o" "$tmp/probe.c" &&
"${PREFIX}as" $ARCH -o "$tmp/boot.o" "$tmp/boot.S" &&
"${PREFIX}ld" -m elf32lriscv -T "$tmp/l.ld" --no-warn-rwx-segments -o "$tmp/probe.elf" "$tmp/boot.o" 2> "$tmp/err" ||
  fail "Compile, assemble or link of the probe failed" "$(head -3 "$tmp/err")"
ok "compile, assemble and link"

attr=$("${PREFIX}readelf" -A "$tmp/probe.o" | sed -n 's/.*Tag_RISCV_arch: "\(.*\)"/\1/p')
[ -n "$attr" ] || fail "No Tag_RISCV_arch in the probe" "The compiler did not record the ISA string."
case "$attr" in
  rv32i*) ;;
  *) fail "Probe ISA is '$attr'" "Expected a 32-bit RV32I string." ;;
esac
extra=$(echo "$attr" | tr '_' '\n' | tail -n +2 | grep -Ev '^(zicsr|zicntr)' || true)
[ -z "$extra" ] || fail "Probe ISA '$attr' carries extensions beyond Zicsr" "$extra"
case "${attr%%_*}" in
  rv32i[0-9]*p[0-9]*) ;;
  *) fail "Probe base ISA '${attr%%_*}' is not plain RV32I" ;;
esac
ok "ISA string: $attr"

printf "\nbinutils: %s\n" "$("${PREFIX}ld" --version | head -1)"
printf "prefix:   %s\n" "$PREFIX"
