#-------------------------------------------------------------------------------
# Modus ATPG Script -- IITB_RISC_Top
# Corrected from the Genus 21.19-s055_1 auto-generated template.
#
# Changes vs. the generated template are marked  ### FIX / ### ADDED / ### NOTE
#
# Run:  modus -64bit -batch -files runmodus_atpg.tcl
#-------------------------------------------------------------------------------


#-------------------------------------------------------------------------------
# 0. PATHS  -- EDIT THESE THREE, everything else keys off them
#-------------------------------------------------------------------------------

### ADDED: pulled out as variables so the two techlib files can never drift apart.
set STDCELL_DIR  "/home/users/sanketp/work_sky130_cad/STD_CELLS"
set LIB_TIMING   "$STDCELL_DIR/lib/sky130_tt_1.8_25_nldm.lib"

### FIX (this is ALU Issue #3, and it WILL happen again):
#   The Genus template lists ONLY the Liberty file. Liberty carries timing but
#   not the internal structural detail Modus needs to resolve fault sites
#   inside a scan flop. Without the Verilog cell model you get:
#       ERROR (TEI-002): The 'cell SDFFRX1' was not found ...
#       ERROR (TEI-400): Build Model FAILED
#   Confirm the actual location of sky130_scl_9T.v on vlsi31 and fix this path.
set LIB_VERILOG  "$STDCELL_DIR/verilog/sky130_scl_9T.v"

### ADDED: the black-box stub for Data_Memory (empty module, real port list).
#   Supplying this means nothing is genuinely "missing", which lets us keep
#   -allowmissingmodules no as a safety net. See section 2.
set BBOX_STUB    "./rtl/Data_Memory.v"

set DESIGN       IITB_RISC_Top
set TESTMODE     FULLSCAN
set EXPERIMENT   ${DESIGN}_atpg


#-------------------------------------------------------------------------------
# 1. INITIALIZE
#-------------------------------------------------------------------------------
# set_db workdir must come first -- it defines where the test database lives.
#
### NOTE: this is a RELATIVE path. Modus resolves it against the directory you
#   launch from, NOT the script location. Launch from the project root or make
#   it absolute, or the .test_netlist.v / .pinassign lookups below will miss.

set_db workdir ./test_scripts
set WORKDIR [get_db workdir]

### FIX: template used "summary", which hides the build_model detail you need
#   on the FIRST run. Switch back to summary once the flow is proven.
set_option stdout full

set ::env(CDS_LIC_REPORT) yes

### NOTE: this line dies immediately if $Install_Dir is not exported in your
#   shell. Check with:   echo $Install_Dir
#   If unset, either export it or hardcode the Modus install path here.
if {![info exists ::env(Install_Dir)]} {
    puts "ERROR: environment variable Install_Dir is not set."
    puts "       export it, or replace the source line below with a hard path."
    exit 1
}
source $::env(Install_Dir)/bin/64bit/test_checks.tcl

set STOP_ON_MSG_SEV ERROR
set LOGDIR          $WORKDIR/testresults/logs

### NOTE: destructive. Archive coverage reports from a previous run BEFORE
#   re-running, or you lose them.
file delete -force $WORKDIR/tbdata
file delete -force $WORKDIR/testresults


#-------------------------------------------------------------------------------
# 2. BUILD THE LOGIC MODEL
#-------------------------------------------------------------------------------
### FIX 1: -techlib now takes BOTH the Liberty and the standard cell Verilog,
#          grouped in braces so Tcl passes them as one list argument.
#
### FIX 2: -allowmissingmodules changed yes -> no, with the Data_Memory stub
#          supplied via -designsource instead.
#
#   Why this matters: with "yes", a wrong LIB_VERILOG path does NOT error.
#   Modus silently black-boxes every scan flop, build_model "succeeds", and
#   you then chase confusing failures in verify_test_structures. With "no"
#   plus the stub, a bad path fails loudly and immediately at the right stage.
#
#   FALLBACK: if Modus rejects the empty stub module, revert to
#   -allowmissingmodules yes and drop $BBOX_STUB -- but then you MUST manually
#   grep the build_model log for SDFFRX1 resolution (see checkpoint below).

build_model \
    -cell                 $DESIGN \
    -techlib              [list $LIB_TIMING $LIB_VERILOG] \
    -designsource         [list $WORKDIR/${DESIGN}.test_netlist.v $BBOX_STUB] \
    -allowmissingmodules  no \
    -messagecounteach     100

check_log log_build_model

#  >>> CHECKPOINT 1 -- do not skip this one.
#  In $LOGDIR/log_build_model:
#    * NO TEI-002 for SDFFRX1 (or any scan cell). If present, LIB_VERILOG is wrong.
#    * Data_Memory should be the ONLY module reported as empty / undriven.
#    * Flop count should be ~774, matching report_gates -flop from Genus.


#-------------------------------------------------------------------------------
# 3. BUILD THE TEST MODE
#-------------------------------------------------------------------------------

build_testmode \
    -testmode   $TESTMODE \
    -assignfile $WORKDIR/${DESIGN}.${TESTMODE}.pinassign \
    -modedef    $TESTMODE

check_log log_build_testmode_$TESTMODE


#-------------------------------------------------------------------------------
# 4. REPORT THE TEST STRUCTURES
#-------------------------------------------------------------------------------

report_test_structures \
    -testmode        $TESTMODE \
    -reportscanchain all

check_log log_report_test_structures_$TESTMODE

#  >>> CHECKPOINT 2
#  Expect 8 scan chains, ~97 flops each, lengths within +/-1.
#  This MUST match what Genus reported in scan_chains.rpt. A mismatch means
#  the pinassign file and the netlist disagree -- fix it here, not after ATPG.


#-------------------------------------------------------------------------------
# 5. VERIFY THE TEST STRUCTURES (scan DRC)
#-------------------------------------------------------------------------------
### NOTE: this is the real DRC gate. Scan chain trace failures, uncontrollable
#   clocks, and uncontrollable async set/reset all surface HERE.
#   reset is a primary input on this design, so it should be controllable --
#   if TSV flags it anyway, that is when you go back to Genus and add reset
#   muxing via define_test_mode.

verify_test_structures \
    -messagecount TSV-016=10,TSV-024=10,TSV-315=10,TSV-027=10 \
    -testmode     $TESTMODE

check_log log_verify_test_structures_$TESTMODE


#-------------------------------------------------------------------------------
# 6. BUILD THE FAULT MODEL
#-------------------------------------------------------------------------------
# -includedynamic no  => static (stuck-at) faults only. Correct for run 1.
# For a transition-fault pass later, see section 11.

build_faultmodel \
    -includedynamic no

check_log log_build_faultmodel

#  >>> CHECKPOINT 3
#  Note the total static fault count. The ALU had 332; expect a substantially
#  larger number here. Record it -- you need it to interpret coverage.


#-------------------------------------------------------------------------------
# 7. ATPG - TEST GENERATION
#-------------------------------------------------------------------------------
### NOTE: this will take real wall-clock time, unlike the ALU's 3.78 s.

create_logic_tests \
    -experiment $EXPERIMENT \
    -testmode   $TESTMODE

check_log log_create_logic_tests_${TESTMODE}_${EXPERIMENT}

#  >>> CHECKPOINT 4
#  The %TCov / %ATCov summary table printed by this command IS your coverage
#  result -- same place the ALU's 100.00% came from. Expect BELOW 100% here.


#-------------------------------------------------------------------------------
# 8. SWITCHING ACTIVITY REPORT
#-------------------------------------------------------------------------------
# Shift/capture toggle activity -- relevant to test power. Harmless to keep.

write_toggle_gram \
    -experiment $EXPERIMENT \
    -testmode   $TESTMODE


#-------------------------------------------------------------------------------
# 9. WRITE VERILOG VECTORS (parallel scan format)
#-------------------------------------------------------------------------------
# Produces TWO vector files plus a mainsim wrapper:
#    ...data.scan.ex1.ts1.verilog    scan chain integrity test
#    ...data.logic.ex1.ts2.verilog   stuck-at logic patterns

write_vectors \
    -inexperiment $EXPERIMENT \
    -testmode     $TESTMODE \
    -language     verilog \
    -scanformat   parallel

check_log log_write_vectors_${TESTMODE}_${EXPERIMENT}


#-------------------------------------------------------------------------------
# 10. COMMIT TO MASTER DATABASE
#-------------------------------------------------------------------------------

commit_tests \
    -inexperiment $EXPERIMENT \
    -testmode     $TESTMODE

check_log log_commit_tests_${TESTMODE}_${EXPERIMENT}


#-------------------------------------------------------------------------------
# 11. OPTIONAL SECOND PASS -- TRANSITION FAULTS
#-------------------------------------------------------------------------------
# Only after the stuck-at flow is clean end-to-end. Transition (delay) faults
# need at-speed launch/capture, so the pinassign must support it and your SDC
# needs a meaningful clock. Treat as a separate project milestone, not a
# bolt-on to this run.
#
#   build_faultmodel -includedynamic yes
#   create_logic_tests -experiment ${DESIGN}_atpg_trans -testmode $TESTMODE \
#                      -faulttype delay


#-------------------------------------------------------------------------------
# 12. DONE
#-------------------------------------------------------------------------------
### NOTE: commented out deliberately. On the first run you want the shell to
#   stay open so you can poke at the database interactively. Re-enable once
#   the flow is proven and you are running it in batch.

# exit
