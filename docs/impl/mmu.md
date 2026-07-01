# MMU — Sv32 Implementation

Implementation notes for `rtl/kv32_mmu.sv`. For the architectural specification
(page table format, `satp`, translation algorithm, TLB semantics) see
[../spec/07-mmu-sv32.md](../spec/07-mmu-sv32.md).

## Module structure

`kv32_mmu` implements the Sv32 two-level page-table walker together with
separate instruction and data TLBs. It is instantiated once inside
`kv32_core.sv` and receives:

- CSR inputs from `kv32_csr` (`satp_asid`, `satp_ppn`, `mstatus_sum`, `mstatus_mxr`, `mstatus_mprv`, `mstatus_mpp`, `priv_mode`).
- Independent lookup ports `i_vpn`/`d_vpn` for FETCH-time and MEM-time translation.
- A dedicated PTW bus (`ptw_req`/`ptw_gnt`/`ptw_ack`/`ptw_rdata`/`ptw_err`) that
  the core muxes onto `dmem_*` while the walker is active.
- `sfence_vma` invalidation pulses with VA and ASID selectors.

## TLB layout

Two 16-entry direct-mapped TLBs (ITLB and DTLB), each tagged by `{ASID, VPN}`
with associated PPN, permission bits, and page-size flag. On lookup:

- Hit (`i_tlb_hit` / `d_tlb_hit`): returns `phys_ppn` combinationally in the
  same cycle as the VPN input.
- Miss: the core drives `ptw_start` with `walk_vpn` and `walk_access_type`
  (0=exec / 1=load / 2=store), and holds FSM state until `ptw_done` or
  `ptw_fault` pulses.

`sfence.vma` invalidates matching entries in both TLBs. The invalidation
selectors follow the spec: `x0` in `rs1` invalidates all VAs; `x0` in `rs2`
invalidates all ASIDs.

## Page-table walker

The walker is a small FSM issuing one PTE read per level. It shares the data
memory bus with the core's normal `dmem_*` traffic — the core mux gates the
external `dmem_*` signals to the PTW while `ptw_busy` is asserted, then hands
the bus back for the actual load/store beat.

Key implementation points to keep in mind when editing:

- **Access-type propagation** into `ptw_fault_cause` — 12 for exec, 13 for
  load, 15 for store — must match RISC-V Privileged spec §4.3.
- **A/D bit update** is hardware-managed. Loads set A on a leaf hit; stores
  set A and D. The walker performs a read-modify-write of the PTE via the same
  PTW bus.
- **Superpage alignment**: for a 4 MiB leaf at level 1, `PPN[0]` must be zero
  or a page fault is raised (Sv32 alignment rule).
- **PTW bus above-4 GiB check**: outstanding review item — currently the PTW
  bus mux does not reject `dmem_addr` values above 4 GiB. See
  [../project/code_review.md](../project/code_review.md).

## Related files

- `rtl/kv32_mmu.sv` — this module.
- `rtl/kv32_core.sv` — instantiates the MMU, muxes the PTW bus onto `dmem_*`,
  and consumes `i_page_fault`/`d_page_fault` for trap generation.
- `tb/tb_mmu.sv` — unit testbench covering TLB fill, page faults, `sfence.vma`,
  and the A/D update path. See [../verification/unit-tests.md](../verification/unit-tests.md).
