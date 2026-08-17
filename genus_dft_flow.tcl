##############################################################################
#  Cadence Genus Synthesis Solution  21.19-s055_1
#  Design : IITB_RISC_Top  (6-stage pipelined IITB-RISC processor)
#  Flow   : plain RTL -> DFT-aware synthesis -> scan insertion -> ATPG handoff
#  PDK    : SkyWater sky130, TT corner
#
#  Produces the same output set as the 4-bit ALU project:
#     <TOP>_scan_netlist.v      scan-inserted gate-level netlist
#     <TOP>_scan.sdc            post-synthesis constraints
#     <TOP>_scan.scandef        scan chain physical description (for Innovus)
#     <TOP>.test_netlist.v      \
#     <TOP>.FULLSCAN.pinassign   > Modus ATPG package (from write_dft_atpg)
#     runmodus.atpg.tcl         /
#
#  Run:  genus -batch -files scripts/genus_dft_flow.tcl -log genus_dft
##############################################################################

puts "\n============================================================"
puts "   GENUS DFT SYNTHESIS - IITB_RISC_Top"
puts "============================================================\n"


##############################################################################
# 1. DESIGN VARIABLES
##############################################################################

set TOP             IITB_RISC_Top

set RTL_DIR         "./rtl"
set CONSTRAINT_DIR  "./constraints"
set REPORT_DIR      "./reports_scan"
set OUTPUT_DIR      "./outputs_scan"

# ---- Scan architecture choice (see notes at bottom of this file) ----
#  774 flops / 8 chains  ~=  97 flops per chain
set NUM_SCAN_CHAINS 8

file mkdir $REPORT_DIR
file mkdir $OUTPUT_DIR

set_db max_cpus_per_server 4
set_db information_level   7


##############################################################################
# 2. TECHNOLOGY LIBRARY
##############################################################################
#  EDIT THESE TWO PATHS to match the sky130 install on vlsi31.

set LIB_SEARCH_PATH "/path/to/sky130/lib"
set TARGET_LIB      "sky130_tt_1.8_25_nldm.lib"

set_db init_lib_search_path $LIB_SEARCH_PATH
set_db library              [list $TARGET_LIB]


##############################################################################
# 3. READ RTL
##############################################################################
#  NOTE: Data_Memory.v here must be the BLACK-BOX stub, not the behavioural
#  version. Read order is leaf-first, top last.

puts "\n---- Reading RTL ----"

set RTL_FILES [list \
    "$RTL_DIR/ALU.v"                    \
    "$RTL_DIR/CCR.v"                    \
    "$RTL_DIR/Condition_Evaluator.v"    \
    "$RTL_DIR/Forwarding_Unit.v"        \
    "$RTL_DIR/Hazard_Detection_Unit.v"  \
    "$RTL_DIR/Instruction_Memory.v"     \
    "$RTL_DIR/Main_Control.v"           \
    "$RTL_DIR/PC_Adder.v"               \
    "$RTL_DIR/PC_Register.v"            \
    "$RTL_DIR/Register_File.v"          \
    "$RTL_DIR/Sign_Extension.v"         \
    "$RTL_DIR/Target_Adder.v"           \
    "$RTL_DIR/branch_predictor.v"       \
    "$RTL_DIR/IF_ID_Register.v"         \
    "$RTL_DIR/ID_RR_Register.v"         \
    "$RTL_DIR/RR_EX_Register.v"         \
    "$RTL_DIR/EX_MEM_Register.v"        \
    "$RTL_DIR/MEM_WB_Register.v"        \
    "$RTL_DIR/Data_Memory.v"            \
    "$RTL_DIR/IITB_RISC_Top.v"          \
]

foreach f $RTL_FILES {
    if {![file exists $f]} {
        puts "ERROR: missing RTL file: $f"
        exit 1
    }
    puts "  $f"
}

# Data_Memory is an intentional black box (hard SRAM macro in a real ASIC,
# covered by Memory BIST, not flop scan). Allow it through elaboration.
set_db hdl_error_on_blackbox false

read_hdl $RTL_FILES


##############################################################################
# 4. ELABORATE
##############################################################################

puts "\n---- Elaborating $TOP ----"

elaborate $TOP
current_design $TOP

# Expect exactly ONE unresolved module: Data_Memory. Anything else is a bug.
check_design -unresolved > "$REPORT_DIR/check_design_unresolved.rpt"
puts "  >> Check check_design_unresolved.rpt: Data_Memory should be the ONLY"
puts "  >> unresolved reference."


##############################################################################
# 5. TIMING CONSTRAINTS
##############################################################################

puts "\n---- Reading SDC ----"

read_sdc "$CONSTRAINT_DIR/design.sdc"

report_timing -lint > "$REPORT_DIR/timing_lint.rpt"


##############################################################################
# 6. DFT SETUP  (must come BEFORE syn_generic)
##############################################################################

puts "\n---- DFT setup ----"

# Scan style. NOTE: root-level attribute (set on "/"), value is "muxed_scan"
# (NOT "mux_scan", and NOT settable on the design object) -- this exact
# mistake cost time on the ALU project.
set_db / .dft_scan_style muxed_scan

# Let Genus find clk / reset as top-level test clocks and test signals.
set_db / .dft_identify_top_level_test_clocks true
set_db / .dft_identify_test_signals           true

# Scan enable. Created as a new primary input port.
define_shift_enable -name scan_enable -active high -create_port scan_enable

# Optional but recommended: declare the functional clock explicitly rather
# than relying purely on auto-identification.
#   define_test_clock -name clk_test -domain domain1 -period 20 [get_ports clk]

# ---- Reset handling ----
# reset is a top-level PRIMARY INPUT, so ATPG can hold it inactive during
# shift directly -- no reset muxing or test-mode logic is required here.
# If check_dft_rules later complains about uncontrollable async set/reset
# pins, that is the point at which you would add:
#   define_test_mode -name TM -active high -create_port test_mode
# and mux the reset. Do not add it pre-emptively.

# Pre-synthesis DFT rule check: catches structural problems while they are
# still cheap to fix.
check_dft_rules > "$REPORT_DIR/dft_rules_pre_syn.rpt"

report_dft_setup > "$REPORT_DIR/dft_setup.rpt"


##############################################################################
# 7. GENERIC SYNTHESIS
##############################################################################

puts "\n---- syn_generic ----"

syn_generic


##############################################################################
# 8. TECHNOLOGY MAPPING
##############################################################################
#  This is where flops get mapped to SCAN-CELL library equivalents
#  (e.g. SDFFRX1) because dft_scan_style was set above.

puts "\n---- syn_map ----"

syn_map

# CRITICAL CHECKPOINT.
# Expect ~774 flops. If you see several thousand, the Data_Memory black box
# did NOT take effect and you are about to scan-stitch a 256x16 RAM.
report_gates -flop > "$REPORT_DIR/gates_flop_postmap.rpt"

puts "\n  >> CHECKPOINT: open $REPORT_DIR/gates_flop_postmap.rpt"
puts "  >> Flop count should be ~774. Several thousand => black box failed.\n"


##############################################################################
# 9. SCAN CHAIN DEFINITION AND STITCHING
##############################################################################

puts "\n---- Scan chain build ($NUM_SCAN_CHAINS chains) ----"

# Ask for 8 balanced chains. Genus distributes the flops and creates the
# scan_in/scan_out port pairs automatically.
set_db design:$TOP .dft_min_number_of_scan_chains $NUM_SCAN_CHAINS

# Alternative control (use INSTEAD of the line above if you prefer to cap
# length rather than fix chain count):
#   set_db design:$TOP .dft_max_length_of_scan_chains 100

# Auto-create and stitch.
connect_scan_chains -auto_create_chains

# ---- Alternative: explicit chains with controlled port names ----
# Use this block instead of -auto_create_chains if you want predictable
# port names (chain_in_0 .. chain_in_7 etc). Slightly more script, but the
# names show up in the Modus pinassign file and are easier to read.
#
#   for {set i 0} {$i < $NUM_SCAN_CHAINS} {incr i} {
#       define_scan_chain -name chain_$i \
#                         -sdi  scan_in_$i \
#                         -sdo  scan_out_$i \
#                         -create_ports
#   }
#   connect_scan_chains


##############################################################################
# 10. INCREMENTAL OPTIMIZATION
##############################################################################

puts "\n---- syn_opt -incr ----"

syn_opt -incr


##############################################################################
# 11. POST-SCAN VERIFICATION
##############################################################################

puts "\n---- Post-scan checks ----"

# Expect: 8 chains, ~97 flops each, balanced.
report_scan_chains  > "$REPORT_DIR/scan_chains.rpt"

# Structural DRC on the stitched design.
check_dft_rules     > "$REPORT_DIR/dft_rules_post_scan.rpt"

report_dft_registers > "$REPORT_DIR/dft_registers.rpt"

puts "\n  >> CHECKPOINT: $REPORT_DIR/scan_chains.rpt"
puts "  >> Expect $NUM_SCAN_CHAINS chains, lengths within +/-1 of each other.\n"


##############################################################################
# 12. QOR REPORTS
##############################################################################

puts "\n---- Reports ----"

report_area                    > "$REPORT_DIR/area.rpt"
report_gates                   > "$REPORT_DIR/gates.rpt"
report_timing -max_paths 20    > "$REPORT_DIR/timing.rpt"
report_qor                     > "$REPORT_DIR/qor.rpt"
report_power                   > "$REPORT_DIR/power.rpt"
check_design                   > "$REPORT_DIR/check_design_final.rpt"


##############################################################################
# 13. WRITE OUTPUTS
##############################################################################

puts "\n---- Writing outputs ----"

# Scan-inserted gate-level netlist
write_hdl > "$OUTPUT_DIR/${TOP}_scan_netlist.v"

# Post-synthesis constraints
write_sdc > "$OUTPUT_DIR/${TOP}_scan.sdc"

# SCANDEF for Innovus: lets placement physically REORDER the chain by cell
# proximity. Note this is a SEPARATE call -- write_dft_atpg does not
# produce it (issue #2 from the ALU project).
write_scandef > "$OUTPUT_DIR/${TOP}_scan.scandef"

# Modus ATPG handoff package: test netlist + pinassign + modedef +
# a template runmodus.atpg.tcl
write_dft_atpg -library $TARGET_LIB

# Full design database (Genus command is write_design, NOT write_db)
write_design -basename "$OUTPUT_DIR/${TOP}_scan"


##############################################################################
# 14. DONE
##############################################################################

puts "\n============================================================"
puts "   SCAN SYNTHESIS COMPLETE"
puts "   Netlist : $OUTPUT_DIR/${TOP}_scan_netlist.v"
puts "   Scandef : $OUTPUT_DIR/${TOP}_scan.scandef"
puts "   Reports : $REPORT_DIR/"
puts "============================================================\n"

# exit
