# hello_world constraints: one differential clock in, one LED out.
# Pin locations and standards copied from the real board file (b210.xdc), so the
# design targets the same physical package. No -name on create_clock: nextpnr
# ignores that option (see .context/19-build-alignment-audit.md, F3).

create_clock -period 25.000 [get_ports codec_main_clk_p]

set_property LOC AA17 [get_ports codec_main_clk_p]
set_property IOSTANDARD LVDS [get_ports codec_main_clk_p]
set_property LOC AA18 [get_ports codec_main_clk_n]
set_property IOSTANDARD LVDS [get_ports codec_main_clk_n]

set_property LOC B11 [get_ports led]
set_property IOSTANDARD LVCMOS33 [get_ports led]
