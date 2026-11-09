// integration/pcie：可选 DPU/PCIe 配置入口；DPU 核心与 PCIe TL 之后编译。
// 不包含 VIO 或参考 project，不创建运行期对象；原生 PCIe TL 不反向依赖 DPU。
package dpu_pcie_pkg;
	timeunit 1ns;
	timeprecision 1ps;

	import uvm_pkg::*;
	import dpu_resource_pkg::*;
	import pcie_tl_pkg::*;
	`include "uvm_macros.svh"
	`include "dpu_pcie_bar_map.sv"
	`include "dpu_cfg_seq.sv"
	`include "dpu_bar_reg_seq.sv"
endpackage
