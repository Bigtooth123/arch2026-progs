# GNU toolchain for the RV32I-only bare-metal build.
#
# CROSS_COMPILE=<prefix> selects a toolchain; otherwise scripts/toolchain.sh
# searches PATH for the usual prefixes. `make toolchain` validates the result.

ifeq ($(strip $(CROSS_COMPILE)),)
CROSS_COMPILE := $(shell scripts/toolchain.sh --detect)
endif

ifeq ($(strip $(CROSS_COMPILE)),)
$(warning No RISC-V GNU toolchain in PATH; set CROSS_COMPILE=<prefix>)
endif

RV_CC      := $(CROSS_COMPILE)gcc
RV_AS      := $(CROSS_COMPILE)as
RV_LD      := $(CROSS_COMPILE)ld -m elf32lriscv
RV_OBJDUMP := $(CROSS_COMPILE)objdump
RV_NM      := $(CROSS_COMPILE)nm
RV_SIZE    := $(CROSS_COMPILE)size

# RV32I plus Zicsr, which the cycle and instret reads need. No M, F or C.
RV_ARCH := -march=rv32i_zicsr -mabi=ilp32
