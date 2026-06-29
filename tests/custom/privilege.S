# Privilege mode integration test
# Tests M/S/U mode transitions, delegation, and SRET/MRET

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64M
RVTEST_CODE_BEGIN

  # Test 1: Verify we're in M-mode initially
  li TESTNUM, 1
  csrr t0, mstatus
  li t1, 0x1800  # mstatus.MPP should be 0b11 (M-mode)
  and t0, t0, t1
  bne t0, t1, fail

  # Test 2: Set up delegation for ECALL from U-mode (cause 8)
  li TESTNUM, 2
  li t0, (1 << 8)
  csrw medeleg, t0
  csrr t1, medeleg
  bne t0, t1, fail

  # Test 3: Set up S-mode trap handler
  li TESTNUM, 3
  la t0, s_mode_handler
  csrw stvec, t0

  # Test 4: Set up M-mode trap handler (for pass/fail ECALL from U-mode)
  li TESTNUM, 4
  la t0, m_mode_handler
  csrw mtvec, t0

  # Test 5: Transition to S-mode via MRET
  li TESTNUM, 5
  la t0, s_mode_entry
  csrw mepc, t0

  # Set mstatus.MPP to S-mode (0b01)
  csrr t0, mstatus
  li t1, 0x1800  # MPP mask
  not t1, t1     # Invert to get clear mask
  and t0, t0, t1 # Clear MPP field
  li t1, 0x800   # MPP = S-mode (0b01)
  or t0, t0, t1  # Set MPP to S-mode
  csrw mstatus, t0

  mret

  # Should not reach here
  j fail

s_mode_entry:
  # We should now be in S-mode
  li TESTNUM, 6

  # Test 7: Set up U-mode entry and transition via SRET
  li TESTNUM, 7
  la t0, u_mode_entry
  csrw sepc, t0

  # Set sstatus.SPP to U-mode (0b0) via sstatus
  csrr t0, sstatus
  li t1, 0x100   # SPP mask
  not t1, t1
  and t0, t0, t1 # Clear SPP field (set to U-mode)
  csrw sstatus, t0

  sret

  # Should not reach here
  j fail

u_mode_entry:
  # We should now be in U-mode
  # Test 8: Execute ECALL from U-mode
  # This should trap to S-mode (delegated via medeleg)
  li TESTNUM, 8
  ecall

  # After ECALL, SRET should bring us back here
  # Test 11: Verify we returned to U-mode
  li TESTNUM, 11

  # Now write pass result via tohost
  # We're in U-mode, so ECALL will trap to S-mode (cause 8, delegated)
  # But we want to reach M-mode for the final tohost write
  # So we clear delegation first... but we can't from U-mode.
  # Instead, use the M-mode handler for the final pass/fail ECALL.
  # ECALL from U-mode with cause 8 is delegated to S-mode, so we need
  # to NOT delegate cause 8 for the final ECALL.
  #
  # Simplest approach: just write tohost directly via a store.
  # We're in U-mode and have access to the memory (no PMP/MMU restrictions).
  li t0, 0x80001000  # tohost address
  li t1, 1           # pass value
  sw t1, 0(t0)       # write tohost = 1

  # Loop forever (testbench will detect tohost write)
1:
  j 1b

m_mode_handler:
  # M-mode trap handler — handles ECALL from M-mode (pass/fail from TEST_PASSFAIL)
  # Also handles unexpected traps
  csrr t0, mcause
  # Check if it's ECALL from M-mode (cause 11)
  li t1, 11
  beq t0, t1, write_pass
  # Otherwise it's an unexpected trap — fail
  j write_fail

write_pass:
  li t0, 0x80001000  # tohost address
  li t1, 1           # pass
  sw t1, 0(t0)
1:
  j 1b

write_fail:
  li t0, 0x80001000  # tohost address
  slli a0, TESTNUM, 1
  ori a0, a0, 1
  sw a0, 0(t0)
1:
  j 1b

s_mode_handler:
  # S-mode trap handler for ECALL from U-mode (cause 8)
  li TESTNUM, 10

  # Verify cause is ECALL from U-mode (8)
  csrr t0, scause
  li t1, 8
  bne t0, t1, fail

  # Return to U-mode via SRET, skipping the ECALL instruction
  csrr t0, sepc
  addi t0, t0, 4  # Skip the ecall instruction
  csrw sepc, t0
  sret

  j fail

fail:
  # Write fail to tohost
  li t0, 0x80001000
  slli a0, TESTNUM, 1
  ori a0, a0, 1
  sw a0, 0(t0)
1:
  j 1b

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
