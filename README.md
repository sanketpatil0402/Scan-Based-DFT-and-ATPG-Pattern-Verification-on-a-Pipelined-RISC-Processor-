# Scan-Based DFT and ATPG on a 6-Stage Pipelined RISC Processor


**Status:** Complete and verified — 98.80% stuck-at test coverage across 30,224 faults, with all 299 ATPG patterns independently confirmed by gate-level simulation (262,462 compares, 0 miscompares).

---

## Table of Contents

1. [Overview](#overview)
2. [Results](#results)
3. [Tools and Environment](#tools-and-environment)
4. [Repository Structure](#repository-structure)
5. [Design Under Test](#design-under-test)
6. [VHDL to Verilog Conversion](#vhdl-to-verilog-conversion)
7. [The Data_Memory Black Box](#the-data_memory-black-box)
8. [Scan Architecture: Choosing the Chain Count](#scan-architecture-choosing-the-chain-count)
9. [Stage 1: DFT-Aware Synthesis in Genus](#stage-1-dft-aware-synthesis-in-genus)
10. [Stage 2: ATPG in Modus](#stage-2-atpg-in-modus)
11. [Stage 3: Gate-Level Verification](#stage-3-gate-level-verification)
12. [Issues Encountered and Resolutions](#issues-encountered-and-resolutions)
13. [Interpreting the Coverage Result](#interpreting-the-coverage-result)
14. [Key Concepts Demonstrated](#key-concepts-demonstrated)
15. [Reproducing This Flow](#reproducing-this-flow)
16. [References](#references)

---

## Overview

This project runs a complete industrial DFT flow — scan insertion, ATPG, and pattern verification — on a non-trivial design under test: a 6-stage pipelined RISC processor with hazard detection, operand forwarding, and a branch predictor.

It is a deliberate scale-up from an earlier flow on a 4-bit ALU (6 flip-flops, 332 faults, single scan chain). Moving to a 774-flop processor changes the problem qualitatively, not just quantitatively:

- **Scan chain architecture becomes a design decision.** One chain of 774 flops is legal and useless; the pin-count-versus-test-time tradeoff has to be reasoned about.
- **Memory has to be modelled, not synthesized.** A behavioural RAM array would have added ~4,096 flops to the scan chain and drowned the logic under test.
- **100% coverage is no longer reachable, and that is the more informative outcome.** The residual faults have identifiable structural causes worth explaining.

The design under test was originally written in VHDL as an academic processor implementation; the full RTL was ported to Verilog-2001 as the first stage of this project.

---

## Results

### Coverage (Cadence Modus, `create_logic_tests`, testmode FULLSCAN)

| Metric | Value |
|---|---|
| Scan chains | 8 |
| Flip-flops in chains | 774 (~97 per chain) |
| Total static faults | 30,224 |
| Faults tested | 29,862 |
| Possibly tested | 19 |
| Redundant | 14 |
| Untested | 329 |
| **Test coverage (%TCov)** | **98.80%** |
| **Adjusted test coverage (%ATCov)** | **98.85%** |
| Total test patterns | 299 (1 scan + 298 logic) |
| ATPG runtime | 2 min 18 s elapsed / 4.25 s CPU |
| Peak memory | ~16.5 MB |

`%TCov = #Tested / #Faults`. `%ATCov = #Tested / (#Faults − #Redundant)`, which excludes provably-redundant faults from the denominator and is the fairer measure of ATPG effectiveness.

### Coverage progression by ATPG pass

Modus generates patterns in distinct passes, each targeting a different fault class:

| Pass | Patterns | Cumulative %ATCov |
|---|---|---|
| Scan Test generation | 1 | 18.04% |
| Reset/Set Test generation | 2 | 18.55% |
| Static Logic Test generation | 296 | **98.85%** |

The **Scan Test** pass verifies the scan chain's own structural integrity before any functional-logic fault is targeted — a single pattern covering 5,453 faults (18%), which reflects how much of the design's fault population lives in the scan cells themselves. The **Reset/Set** pass exercises faults on the flops' asynchronous reset pins. The **Static Logic** pass closes the remaining 80%, with a characteristic long tail: 83.29% after 16 patterns, but 200+ further patterns to climb the last 15 points.

### Gate-level verification (Cadence Xcelium)

| Vector file | Purpose | Tests | Cycles | Compares | Miscompares |
|---|---|---|---|---|---|
| `data.scan.ex1.ts1` | Scan chain structural integrity | 1 | 6 | 752 | 0 |
| `data.logic.ex1.ts2` | Stuck-at ATPG patterns | 298 | 951 | 261,710 | 0 |
| **Cumulative** | | **299** | **957** | **262,462** | **0** |

**299/299 tests passed, 262,462/262,462 compares matched, zero miscompares.** Every response Modus predicted was reproduced by simulating the actual scan-inserted gate-level netlist. This is the evidence that 98.80% is a verified figure rather than a tool claim.

Two consistency checks worth noting, since they confirm the scan architecture is behaving as intended:

- **~878 compares per pattern.** With 774 scan flops plus 115 top-level output bits (889 observable points), this indicates essentially the full scan state is being observed each pattern, as expected for a full-scan design.
- **957 cycles for 299 patterns.** Serial shifting would need roughly 97 cycles per pattern (~29,000 total). The low figure is a direct consequence of `-scanformat parallel`, which deposits scan state directly rather than shifting it in serially. See [Stage 3](#stage-3-gate-level-verification) for why this matters and what it does *not* verify.

---

## Tools and Environment

| Component | Detail |
|---|---|
| Synthesis / scan insertion | Cadence Genus Synthesis Solution 21.19-s055_1 |
| ATPG | Cadence Modus DFT Software Solution 21.11-s005_1 |
| Gate-level simulation | Cadence Xcelium (`xrun`) |
| RTL simulation (conversion checking) | Icarus Verilog |
| RTL synthesis check (conversion checking) | Yosys |
| PDK | SkyWater sky130 (open source), TT corner |
| Liberty timing library | `sky130_tt_1.8_25_nldm.lib` |
| Standard cell Verilog model | `sky130_scl_9T.v` |
| Host | IIT Bombay VLSI lab server, Linux x86_64 |

---

## Repository Structure

```
.
├── README.md
├── rtl/                          # Synthesizable RTL (fed to Genus)
│   ├── IITB_RISC_Top.v           #   top level, 6-stage pipeline
│   ├── PC_Adder.v                #   IF: PC + 2
│   ├── PC_Register.v             #   IF: program counter (async reset)
│   ├── Instruction_Memory.v      #   IF: combinational ROM
│   ├── branch_predictor.v        #   IF: BTB + 2-bit saturating BTP
│   ├── IF_ID_Register.v          #   pipeline register
│   ├── Main_Control.v            #   ID: opcode decode
│   ├── Sign_Extension.v          #   ID: imm6/imm9 extension
│   ├── ID_RR_Register.v          #   pipeline register
│   ├── Register_File.v           #   RR: 8 x 16-bit, R0 = PC
│   ├── Hazard_Detection_Unit.v   #   RR: load-use stall, control flush
│   ├── RR_EX_Register.v          #   pipeline register
│   ├── ALU.v                     #   EX: add / NAND, 17-bit carry path
│   ├── CCR.v                     #   EX: condition code register
│   ├── Condition_Evaluator.v     #   EX: predication check
│   ├── Forwarding_Unit.v         #   EX: EX/MEM and MEM/WB bypass
│   ├── Target_Adder.v            #   (unused; see conversion notes)
│   ├── EX_MEM_Register.v         #   pipeline register
│   ├── Data_Memory.v             #   MEM: BLACK-BOX STUB (see below)
│   └── MEM_WB_Register.v         #   pipeline register
├── sim/                          # Simulation-only — NOT for synthesis
│   ├── Data_Memory_behav.v       #   behavioural RAM (same module name)
│   └── tb_smoke.v                #   24-cycle pipeline smoke test
├── constraints/
│   └── design.sdc                # timing constraints
├── scripts/
│   ├── genus_dft_flow.tcl        # synthesis + scan insertion
│   └── runmodus_atpg.tcl         # ATPG + vector export
├── docs/
│   └── CONVERSION_NOTES.md       # VHDL to Verilog port details
└── results/                      # (logs and reports from your run)
```

> **`rtl/Data_Memory.v` and `sim/Data_Memory_behav.v` declare the same module name.** They are in separate directories for exactly this reason. Never compile both in one run: `rtl/` for synthesis, `sim/` substituted in for functional simulation.

---

## Design Under Test

A 6-stage pipelined implementation of a custom 16-bit teaching ISA (IITB-RISC), not RISC-V. Pipeline stages:

```
IF  →  ID  →  RR  →  EX  →  MEM  →  WB
```

**Architectural features that matter for DFT:**

| Feature | DFT relevance |
|---|---|
| 5 pipeline registers | ~380 flops, the bulk of the scan chain |
| Register file, 8 × 16-bit | 128 flops; combinational read → wide mux cone |
| Branch predictor: 4-entry BTB + 64-entry 2-bit BTP | ~262 flops with reset-fixed and unreachable states |
| Forwarding unit | Combinational, feeds ALU input muxes |
| Hazard detection unit | Load-use stall and control-flow flush |
| Condition code register + predication | 2 flops gating writeback |
| Single clock domain, all `posedge clk` | **No lockup latches needed between chain segments** |

That last row is what makes the scan architecture straightforward. Mixed clock edges or multiple domains would require splitting chains per domain and inserting lockup latches at the boundaries; here, all 774 flops can be freely distributed across chains.

**ISA summary** (opcode = `instruction[15:12]`):

| Opcode | Instruction | Notes |
|---|---|---|
| `0000` | ADI | add immediate |
| `0001` | ADD family | ADA/ADC/ADZ/AWC, predicated on CZ bits |
| `0010` | NAND family | NDU/NDC/NDZ and complement variants |
| `0011` | LLI | load lower immediate (zero-extended) |
| `0100` | LW | load word |
| `0101` | SW | store word |
| `0110`/`0111` | LM / SM | multi-register load/store (decode only) |
| `1000` | BEQ | branch if equal |
| `1001` | BLT | branch if less than |
| `1010` | BLE | branch if less or equal |
| `1100` | JAL | jump and link |
| `1101` | JLR | jump and link register |
| `1111` | JRI | jump register + immediate |

Opcodes `1011` and `1110` are unused — relevant later, since the decoder logic for them is structurally unreachable and therefore contributes untestable faults.

---



## The Data_Memory Black Box

The original `Data_Memory` inferred a 256 × 16 clocked array. With no memory compiler in the flow, synthesis maps that literally to **~4,096 flip-flops** — which `connect_scan_chains` would then stitch into the scan chain.

The consequence would be a scan chain that is ~84% RAM bits, ATPG runtime dominated by memory faults, and a coverage number that says nothing about the processor.

More importantly, it would be **wrong as modelling**. In a real ASIC this block is a hard SRAM macro from a memory compiler. Hard macros are not flop-scan tested; they are covered by **Memory BIST**, an entirely separate DFT flow with its own controller and algorithms (March tests). Black-boxing the memory is therefore the industrially correct choice, not a shortcut taken for convenience.

`rtl/Data_Memory.v` keeps an identical port list with an empty body, so the top level needs no edits. Genus reports it as an unresolved boundary (expected) and routes the scan chain around it.

**Verified effect:** 774 flops post-synthesis rather than ~4,870.

The one downside, honestly stated: `Mem_Data_out` is undriven, so ATPG sees X there. Faults in the logic cone fed by it — principally the writeback result mux — become untestable and contribute to the residual discussed [below](#interpreting-the-coverage-result).

---

## Scan Architecture: Choosing the Chain Count

The chain count is a real engineering decision, not a formality. The governing relationship:

> **shift cycles per pattern ≈ length of the longest chain**
> **total test time ≈ patterns × longest chain length**

Each chain costs one input pin and one output pin. At 774 flops:

| Chains | Flops/chain | Shift cycles/pattern | Extra pins |
|---|---|---|---|
| 1 | 774 | 774 | 2 |
| 4 | ~194 | 194 | 8 |
| **8 (chosen)** | **~97** | **97** | **16** |
| 16 | ~49 | 49 | 32 |

**8 chains** was chosen: an 8× test-time reduction over a single chain, chain length just under 100 (production designs typically balance in the 100–500 range), at a cost of 16 ports that is negligible in this context. Sixteen chains would halve shift time again but double pin cost for diminishing return.

**Balance matters more than count.** Shift time is set by the *longest* chain, so eight chains of 97 is good while seven of 50 plus one of 424 would not be. Genus balances automatically; `report_scan_chains` is the confirmation step.

**Why production does this differently.** No real chip exposes 8 scan pin-pairs. Production uses **test compression**: a decompressor fans a few input channels out to a large number of short internal chains, and a compactor squeezes responses back down. Internal chain count rises sharply, pin count stays low, and pattern volume falls. The pin-limited tradeoff in the table above is precisely the problem compression exists to solve.

---

## Stage 1: DFT-Aware Synthesis in Genus

Plain RTL is read in with no manual scan ports or hand-coded scan muxes. The tool maps flops to scan-cell library equivalents and stitches the chains.

Script: [`scripts/genus_dft_flow.tcl`](scripts/genus_dft_flow.tcl)

```tcl
# --- DFT setup: MUST precede syn_generic ---
# dft_scan_style is a ROOT-level attribute (set on "/"), not per-design,
# and the value is "muxed_scan" -- not "mux_scan".
set_db / .dft_scan_style muxed_scan
set_db / .dft_identify_top_level_test_clocks true
set_db / .dft_identify_test_signals           true

define_shift_enable -name scan_enable -active high -create_port scan_enable
check_dft_rules

# --- Synthesis: syn_map is where flops become scan cells ---
syn_generic
syn_map
report_gates -flop        # CHECKPOINT: expect ~774, not ~4,870

# --- Chain build and stitch ---
set_db design:IITB_RISC_Top .dft_min_number_of_scan_chains 8
connect_scan_chains -auto_create_chains
syn_opt -incr

report_scan_chains        # CHECKPOINT: 8 chains, lengths within +/-1
check_dft_rules

# --- Outputs ---
write_hdl      > outputs_scan/IITB_RISC_Top_scan_netlist.v
write_sdc      > outputs_scan/IITB_RISC_Top_scan.sdc
write_scandef  > outputs_scan/IITB_RISC_Top_scan.scandef   # separate call!
write_dft_atpg -library sky130_tt_1.8_25_nldm.lib
```

**Reset handling.** `reset` is a top-level primary input, so ATPG can hold it inactive during shift with no additional test logic. Reset muxing via `define_test_mode` is only required when the reset is internally generated (from a reset synchronizer, PLL lock, or soft-reset register). Adding it pre-emptively would be wasted area.

**On the SDC:** `scan_enable` is deliberately **not** false-pathed. Shift mode is a hold-time problem — adjacent scan cells form a launch/capture pair with almost no combinational delay between them, and hold violations in the shift path are a classic DFT failure. False-pathing `scan_enable` hides exactly the thing worth seeing.

---

## Stage 2: ATPG in Modus

Script: [`scripts/runmodus_atpg.tcl`](scripts/runmodus_atpg.tcl)

```tcl
# 1. Build the logic model.
#    -techlib needs BOTH the Liberty file AND the standard cell Verilog model.
build_model \
    -cell                 IITB_RISC_Top \
    -techlib              {sky130_tt_1.8_25_nldm.lib  sky130_scl_9T.v} \
    -designsource         {IITB_RISC_Top.test_netlist.v  Data_Memory.v} \
    -allowmissingmodules  no

# 2. Declare the scan test mode
build_testmode -testmode FULLSCAN \
               -assignfile IITB_RISC_Top.FULLSCAN.pinassign \
               -modedef FULLSCAN

# 3. Report and DRC the scan structures as Modus sees them
report_test_structures -testmode FULLSCAN -reportscanchain all
verify_test_structures -testmode FULLSCAN

# 4. Build the stuck-at fault list
build_faultmodel -includedynamic no

# 5. Generate patterns
create_logic_tests -experiment IITB_RISC_Top_atpg -testmode FULLSCAN

# 6. Export as a self-contained Verilog testbench
write_vectors -inexperiment IITB_RISC_Top_atpg -testmode FULLSCAN \
              -language verilog -scanformat parallel

# 7. Commit to the master test database
commit_tests -inexperiment IITB_RISC_Top_atpg -testmode FULLSCAN
```

**`report_test_structures` must show 8 chains**, matching the Genus report. A mismatch means the pinassign file and the netlist disagree — cheaper to fix there than after ATPG runtime is spent.

**`verify_test_structures` is the real DRC gate**, not `build_model`. Scan chain trace failures, uncontrollable clocks, and uncontrollable async set/reset all surface at this step.

---

## Stage 3: Gate-Level Verification

The exported vectors were not trusted on the tool's word. They were re-simulated against the actual scan-inserted gate-level netlist:

```bash
xrun \
    sky130_scl_9T.v \
    outputs_scan/IITB_RISC_Top_scan_netlist.v \
    VER.FULLSCAN.IITB_RISC_Top_atpg.mainsim.v \
    +TESTFILE1=VER.FULLSCAN.IITB_RISC_Top_atpg.data.scan.ex1.ts1.verilog \
    +TESTFILE2=VER.FULLSCAN.IITB_RISC_Top_atpg.data.logic.ex1.ts2.verilog
```

Modus exports two vector files serving different purposes. The **scan** file verifies the chain's own shift path works at all — if that fails, every logic pattern result is meaningless. The **logic** file applies the stuck-at patterns to functional logic.

Result: **299/299 tests passed, 262,462 compares, 0 miscompares.**

**What `-scanformat parallel` does and does not verify.** Parallel format deposits scan state directly into the flops rather than shifting it in serially, which is why the run completes in 957 cycles instead of the ~29,000 serial shifting would require. This is the standard choice for verifying *pattern correctness* quickly. It does **not** exercise the serial shift path cycle by cycle — that requires `-scanformat serial`, which is far slower and typically reserved for validating the chain itself or for debugging a chain-integrity failure. Both formats verify the same ATPG patterns; they differ in how scan state is applied.

---

## Issues Encountered and Resolutions

Documented deliberately — diagnosing these was a larger and more representative part of the work than the commands that worked first time.

### Issue 1 — Genus rejects `dft_scan_style`

```
Error : Unrecognized attribute. [TUI-183] [set_db]
      : 'dft_scan_style' is not a recognized attribute for object 'design'.
```

**Cause:** the attribute is root-level, not per-design, and the value is `muxed_scan`, not `mux_scan`.

**Fix:** `set_db / .dft_scan_style muxed_scan`

### Issue 2 — `.scandef` never generated

**Cause:** `write_dft_atpg` produces the ATPG handoff package but does *not* write the scandef.

**Fix:** it needs its own explicit call — `write_scandef > <file>`.

### Issue 3 — Modus `build_model` cannot resolve the scan cell

```
ERROR (TEI-002): The 'cell SDFFRX1' was not found in the design source file(s) specified.
ERROR (TEI-400): Build Model FAILED
```

**Cause:** the Liberty file provides timing but not the internal structural detail Modus needs to resolve fault sites *inside* a scan flip-flop's mux. This is a known gap in open-source PDK Liberty files, which were not authored with commercial ATPG tool metadata in mind.

**Fix:** pass both the Liberty file and the standard cell Verilog model to `-techlib` as a Tcl list. At an interactive prompt the paths must be grouped in `{ }`, or Tcl splits them into separate tokens and Modus misreads the second path as an invalid flag.

```tcl
build_model -techlib {sky130_tt_1.8_25_nldm.lib  sky130_scl_9T.v} ...
```

Genus's auto-generated ATPG template always emits `-techlib` with the Liberty file alone, so this fix must be reapplied every time the template is regenerated.

### Issue 4 — `-allowmissingmodules yes` masks a wrong library path

The Genus template sets this to `yes` because `Data_Memory` is unresolved, which is correct reasoning in isolation. But it also means a wrong path to the standard cell Verilog does **not** error. Modus silently black-boxes every scan flop, `build_model` reports success, and the failure surfaces later at `verify_test_structures` — three stages away from the actual cause.

**Fix:** supply the empty `Data_Memory.v` stub as an additional `-designsource` and set `-allowmissingmodules no`. An empty module is a legal definition, so nothing is genuinely missing, and a real unresolved cell still fails loudly at the right stage.

### Issue 5 — script aborts on an unset environment variable

The generated template sources `$::env(Install_Dir)/bin/64bit/test_checks.tcl`. If `Install_Dir` is not exported, the script throws before any command runs. The provided script guards this with an explicit check and a readable error message.

---

## Interpreting the Coverage Result

**98.80% test coverage is a complete, defensible result — not a shortfall.** The residual breaks down as 14 redundant + 329 untested + 19 possibly-tested, out of 30,224.

Reaching 100% on the earlier 4-bit ALU was a consequence of that design's triviality — 6 flops, no deep sequential logic, no unreachable state. Once a design contains real control logic, a nonzero untestable population is expected, and sign-off criteria are built around *documenting and justifying* it rather than eliminating it.

The residual on this design is attributable to identifiable structural causes:

| Category | Why untestable |
|---|---|
| Branch predictor reset state | All 64 BTP entries reset to `01`; certain counter states are unreachable from reset |
| BTB state space | Not all valid/tag/target combinations are reachable through the update logic |
| Memory output cone | `Mem_Data_out` is X to ATPG, leaving the writeback result mux partly unobservable |
| Unused opcode decode | Opcodes `1011` and `1110` are never asserted, making that decoder logic structurally redundant |

> **Verify before citing.** The categories above follow from the design structure, but the precise attribution of the 329 untested faults should be confirmed against the actual fault list rather than asserted. Pull it with `report_faults` on the committed testmode and classify by hierarchical instance path.

**On the 19 "possibly tested" faults:** these are faults where the good-machine response resolved to X (typically through reconvergent fanout), so ATPG cannot certify detection even though a pattern exists that may detect them. A small count is normal and not a defect in the test program.

**Why coverage is a probabilistic proxy, not a guarantee.** The Williams & Brown defect level model:

```
DL = 1 - Y^(1-T)
```

where `Y` is process yield and `T` is test coverage. Coverage relates to shipped-defect risk statistically. Production flows manage residual risk through *layered* fault models — stuck-at plus transition plus IDDQ — rather than by forcing a single model's number toward 100%.

---

## Key Concepts Demonstrated

- **Scan flip-flop structure** — the internal 2:1 mux, and why `scan_enable` / `scan_in` / `scan_out` exist.
- **Shift / capture / shift-out cycle** — the three-phase structure underlying every ATPG pattern.
- **Scan chain architecture as a tradeoff** — chain count versus pin count versus test time, chain balancing, and why test compression exists.
- **Black-boxing hard macros** — why memories are covered by MBIST rather than flop scan, and the effect on the surrounding logic's testability.
- **Fault coverage versus test coverage** — why they differ and which is the fairer measure.
- **Redundant, untestable, and possibly-tested faults** — distinct categories with distinct causes.
- **DFT–PD coupling** — chain order out of synthesis is logical and arbitrary; placement physically reorders by cell proximity via the scandef (`reorderScan` in Innovus). Shift mode is a hold-time problem, which is why `scan_enable` is not false-pathed.
- **Parallel versus serial scan format** — what each verifies and the runtime difference.
- **Verifying the tool's own claim** — re-simulating exported patterns against the gate-level netlist rather than trusting a reported number.

---

## Reproducing This Flow

**Prerequisites:** Cadence Genus, Modus, and Xcelium; the sky130 PDK with *both* the Liberty file and the standard cell Verilog model.

**1. Check the RTL conversion (optional, no license needed)**

```bash
iverilog -g2005 -o sim.out -s tb_smoke sim/tb_smoke.v sim/Data_Memory_behav.v \
    $(ls rtl/*.v | grep -v 'rtl/Data_Memory.v$')
vvp sim.out
```

**2. Edit paths**

- `scripts/genus_dft_flow.tcl` → `LIB_SEARCH_PATH`, `TARGET_LIB`
- `scripts/runmodus_atpg.tcl` → `STDCELL_DIR`, `LIB_VERILOG`
- Confirm `Install_Dir` is exported in your shell

**3. Synthesis and scan insertion**

```bash
genus -batch -files scripts/genus_dft_flow.tcl -log genus_dft
```

Checkpoints: `Data_Memory` is the only unresolved module; `report_gates -flop` shows ~774; `report_scan_chains` shows 8 balanced chains.

**4. ATPG**

```bash
modus -64bit -batch -files scripts/runmodus_atpg.tcl
```

Checkpoints: no TEI-002 in the `build_model` log; `report_test_structures` shows 8 chains matching Genus.

**5. Gate-level verification**

Run the `xrun` command from [Stage 3](#stage-3-gate-level-verification) against the exported vector files. Confirm zero miscompares.

---

## References

**Source design**
The RTL under test derives from an academic 6-stage pipelined IITB-RISC processor implementation (originally VHDL), ported to Verilog-2001 for this project. Conversion details and the complete list of translation decisions are in [`docs/CONVERSION_NOTES.md`](docs/CONVERSION_NOTES.md).

**Textbooks**

- M.L. Bushnell and V.D. Agrawal, *Essentials of Electronic Testing for Digital, Memory, and Mixed-Signal VLSI Circuits*, Springer. The standard DFT reference — fault models, ATPG algorithms (D-algorithm, PODEM), scan design, BIST, and defect-level mathematics.
- M. Abramovici, M.A. Breuer, and A.D. Friedman, *Digital Systems Testing and Testable Design*, IEEE Press. Deeper treatment of ATPG algorithm internals (D-algorithm, PODEM, FAN).
- N.H.E. Weste and D.M. Harris, *CMOS VLSI Design: A Circuits and Systems Perspective*, Addison-Wesley. Clocking and timing chapters, relevant to the physical-design side of DFT–PD interaction.

**Papers**

- T.W. Williams and N.C. Brown, "Defect Level as a Function of Fault Coverage," *IEEE Transactions on Computers*, vol. C-30, no. 12, pp. 987–988, 1981. Original derivation of the defect level model cited above.

**Tool documentation**

- Cadence Genus Synthesis Solution — DFT flow and command reference.
- Cadence Modus DFT Software Solution — ATPG user guide and command reference. Available via `support.cadence.com` with institutional access. Use `msgHelp <message-id>` at the Modus prompt for any message code encountered.
- Synopsys TestMAX / TetraMAX documentation — useful for recognizing the vendor-neutral equivalent flow; the underlying concepts are identical.

**PDK**

- SkyWater sky130 open-source process design kit. Note that its Liberty files were not authored with commercial ATPG metadata in mind, which is the direct cause of [Issue 3](#issue-3--modus-build_model-cannot-resolve-the-scan-cell).

**Related work**

An earlier application of this same flow to a 4-bit ALU (6 flops, single scan chain, 332 faults, 100% coverage) served as the methodology baseline. The comparison between the two — particularly why one reaches 100% and the other does not — is the more instructive result.

