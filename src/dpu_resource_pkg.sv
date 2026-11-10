/*
 * 所属层次：src/ 资源包编译入口层。
 * 文件职责：按依赖顺序包含资源枚举、值类型、authoring 配置、快照、解析器和管理器实现。
 * 主要依赖：本包内 include 文件、UVM。
 * 所有权与生命周期：package 只提供编译期命名空间，不创建运行时对象；include 顺序决定类型可见性。
 */
// =============================================================================
// DPU Fabric shared resource package
// =============================================================================

`ifndef DPU_RESOURCE_PKG_SV
`define DPU_RESOURCE_PKG_SV

// 设计原因：用单一 package 边界承载跨模块共享类型，保证 include 顺序和命名空间一致。
// 职责与所有权：package 只提供类型、常量和实现可见性，不拥有任何运行时对象。
// 生命周期/失败边界：包含文件必须按声明依赖顺序编译；运行时错误由其中的对象接口报告。
package dpu_resource_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // AIP 是可选依赖：未加载时不读取命令行，组合 cfg 仍按默认值构造资源输入。
  // 不在这里 include AIP，避免同一类型在多个 package 中被重复定义。
`ifdef AIP_CMDLINE_SV
  import aip_core_pkg::*;
  `include "dpu_aip_params.svh"
`endif

  `include "dpu_device_types.sv"
  `include "dpu_placement_types.sv"
  `include "dpu_resource_types.sv"
  `include "dpu_placement_cfg.sv"
  `include "dpu_dut_caps.sv"
  `include "dpu_device_cfg.sv"
  `include "dpu_normalized_placement_plan.sv"
  `include "dpu_placement_normalizer.sv"
  `include "dpu_device_snapshot.sv"
  `include "dpu_device_resolver.sv"
  `include "dpu_resource_snapshot.sv"
  `include "dpu_resource_resolver.sv"
  `include "dpu_configuration_resolver.sv"
  `include "dpu_resource_manager.sv"
  `include "dpu_bar_map.sv"
  `include "dpu_table_types.sv"
  `include "dpu_vio_table_types.sv"
  `include "dpu_env_cfg.sv"
  `include "dpu_device_env.sv"
  `include "dpu_names.sv"
endpackage : dpu_resource_pkg

`endif // DPU_RESOURCE_PKG_SV
