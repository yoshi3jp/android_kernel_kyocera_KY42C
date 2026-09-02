# This software is contributed or developed by KYOCERA Corporation.
# (C) 2022 KYOCERA Corporation
#

#obj-y += kdisp_com.o
#obj-y += kdisp_diag.o
#obj-y += kdisp_bl_ctrl.o
#obj-y += kdisp_connect_target.o
#obj-y += kdisp_debug.o
#obj-y += kdisp_panel.o

# ARM64 A0 compile-audit waivers for the KY subdisplay cluster.  The current
# AArch32 code contains numerous pointer-to-32-bit casts and 32-bit printf
# formats used only for diagnostic output (including size_t and dma_addr_t
# values).  Keep those diagnostics visible as warnings while allowing the
# first AArch64 compile to continue and expose later blockers.  These are not
# stabilized-port fixes; convert the affected logs to %p/%zu/appropriate DMA
# formatting and remove these waivers once the full compile surface is known.
ifeq ($(CONFIG_ARM64),y)
ccflags-y += -Wno-error=pointer-to-int-cast -Wno-error=format
endif

obj-y += disp_ext_sub.o
obj-y += disp_ext_sub_ctrl.o
obj-y += disp_ext_sub_panel.o
obj-y += disp_ext_sub_panel_st7571.o
obj-y += disp_ext_sub_panel_ld7032.o
obj-y += disp_ext_sub_dbg.o

#obj-$(CONFIG_DISP_EXT_SUB) += disp_ext_sub.o
#obj-$(CONFIG_DISP_EXT_SUB) += disp_ext_sub_ctrl.o
#obj-$(CONFIG_DISP_EXT_SUB) += disp_ext_sub_panel.o
#obj-$(CONFIG_DISP_EXT_SUB) += disp_ext_sub_dbg.o
#obj-$(CONFIG_DISP_EXT_SPI) += disp_ext_spi.o
#obj-$(CONFIG_DISP_EXT_SUB_ALWAYS_ON) += disp_ext_sub_mdm.o

