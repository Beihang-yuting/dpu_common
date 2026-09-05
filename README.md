# dpu_common

`dpu_common` 是 DPU 设备配置的独立 SystemVerilog/UVM 仓库。它只负责
逻辑设备状态，不负责 PCIe 物理拓扑或具体传输后端。

## 所有权边界

本仓库负责：

- Host、PCIe domain、PF/VF 和 service 的逻辑声明；
- BDF、BAR aperture/base、资源放置和寄存器计划解析；
- 解析完成后的不可变 `dpu_device_snapshot` 与资源快照。

PCIe RC/EP/Switch 角色、Root 编号、USP/DSP、lane/Gen、Serial/PIPE、TL
或 Synopsys SVT 均由上层 `pcie_work` 负责。Host 是逻辑地址域，不能在
本仓库中添加 `root_index`、`link_id` 或物理角色字段。

每个 Host 可配置 `enabled`、人类可读名称、`address_width` 和可选的 GPA
aperture；Host 数量始终由 `dpu_device_cfg.hosts[$]` 动态数组派生。解析成功
后，冻结的 `dpu_device_snapshot` 提供 `host_count()`、
`enabled_host_count()`、`list_hosts()` 和 `lookup_host()`。这些接口只返回
按值复制的逻辑 Host 信息，适配层查询时不会修改 authoring 配置。名称为空
时使用稳定的 `host_<id>` 名称；GPA aperture 要求 `base < limit`，地址宽度
必须在 1 到 64 位之间。

## 编译

将 `DPU_COMMON_ROOT` 指向本仓库根目录，然后把
`filelists/dpu_common.f` 加入 VCS filelist：

```bash
export DPU_COMMON_ROOT=/path/to/dpu_common
vcs -sverilog -ntb_opts uvm \
    -f "$DPU_COMMON_ROOT/filelists/dpu_common.f" \
    +incdir+"$DPU_COMMON_ROOT/src"
```

`dpu_resource_pkg` 的实现通过 package 内的 include 按依赖顺序编译；
因此不应再把同一批 `src/*.sv` 文件逐个加入编译命令。

## 快照到 PCIe

调用方先解析并冻结 `dpu_device_snapshot`，再将快照交给
`pcie_work/pcie_dpu_integration`。PCIe 适配层保留快照里的 BDF/BAR，不会
重新分配资源。Host/domain 到 Root 的绑定、PF/VF 到物理 Endpoint/link
的绑定，以及 Host memory manager 的共享关系，全部在 PCIe 侧显式声明。
