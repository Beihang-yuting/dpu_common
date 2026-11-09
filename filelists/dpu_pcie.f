// 可选集成入口；调用方先编译 dpu_resource_pkg 和 pcie_tl_pkg，不能重复编译核心包。
+incdir+$DPU_COMMON_ROOT/integration/pcie
$DPU_COMMON_ROOT/integration/pcie/dpu_pcie_pkg.sv
