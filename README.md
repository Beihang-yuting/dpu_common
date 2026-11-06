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

## 可选 AIP 参数加载

在 `dpu_resource_pkg` 之前编译 `aip_core_pkg.sv` 时，各 authoring 类提供
`function void load_params(string path = "dpu...")`。未编译 AIP 时这些方法
仍存在并且不修改对象。`new`、`copy_from`、快照和运行状态均不会读取参数。
调用方完成加载后必须调用原有整体校验/解析流程；加载只检查输入类型、
位宽、无符号负值以及地址相加溢出。

AIP 不提供 `dpu` 到 `dpu.h0` 的层级继承。推荐顺序如下：

1. 调用 `device.load_params("dpu")` 读取 caps 和 AF，先用 `caps.validate`
   检查能力是否在模型上限内，再按这些能力创建拓扑及资源输入。
2. 创建 Host 模板及已有 domain/MMIO window，然后仅调用一次
   `host_template.load_params("dpu")`。
3. 深复制模板到各 Host，设置其拓扑身份，再调用
   `host.load_params($sformatf("dpu.h%0d", host.host_id))`。
4. 建立 placement 的 profiles/requests，调用
   `placement.load_params("dpu")`；随后加载 policy 与 QSCH generator。
5. 执行跨对象的整体校验与解析，成功后发布冻结快照。

每次显式调用都可能消费随机参数，因此不要对同一个模板或实例重复加载。
`device.load_params` 不遍历 Host/函数；Host 则递归其已有 domain/window。
单 domain、单 window 使用 Host 相同的短路径，多实例按索引附加
`.domainN`、`.mmioN`。所有数量及对象创建由上层 author_config 负责。

| 类/默认路径 | 参数与原字段映射 |
| --- | --- |
| `dpu_host_cfg` / `dpu` | `mem_base/mem_size` → GPA 半开区间；`use_gpa` → `has_gpa_aperture`；`address_width` 仅为地址约束 |
| `dpu_pcie_domain_cfg` / `dpu` | `bdf_first/bdf_last` → 已有唯一 BDF 区间；`reserved_bdfs`；`bar_policy` |
| `dpu_mmio_window_cfg` / `dpu` | `mmio_base/mmio_size` → MMIO 半开区间；`roles` → `allowed_roles` |
| `dpu_bar_request` / `dpu.bar` | `role/bar/size/alignment/placement/base` → role/even_bar_id/size/alignment/placement/pinned_base |
| `dpu_function_cfg`、`dpu_vf_template_cfg` / `dpu.function` | `bdf_mode/bdf/segment/services`；services 表示 eligible service kinds；已有 BAR 递归到 `.bar<even_bar_id>` |
| `dpu_vf_pool_cfg` / `dpu.vf_pool` | 只递归已有模板到 `.vf<vf_id>` |
| `dpu_service_decl` / `dpu.service` | `kind/instance` → service_kind/service_instance_id |
| `dpu_af_request` / `dpu` | `af_host/af_pf/af_kind/af_vf` → requester 键 |
| `dpu_resource_placement_cfg` / `dpu` | 既有 `virtio.qpair` profile 使用 `qpair_capacity/qpair_per_func`；其他 profile 使用 `poolN.capacity/max_per_function`；`reserved_qpairs` → reserved_global_qpair_ids |
| `dpu_vio_placement_request` / `dpu` | `qpairs/lan_msix/placement_seed/candidate_kind/device_policy/ordering/fixed_devices`；单 request 使用根路径，多 request 使用 `.requestN` |
| `dpu_vio_candidate_filter` / `dpu` | `host_ids/vf_ids/parent_pfs/functions` → host_ids/vf_ids/parent_pf_keys/function_keys |
| `dpu_vio_device_constraint` / `dpu.device` | `host/pf/kind/vf/mode/qpairs`；request 对既有对象使用 `.deviceN` |
| `dpu_vio_qpair_override` / `dpu.pair` | `index/owner_mode/owner_host/owner_pf/owner_kind/owner_vf/local_mode/local_id/global_mode/global_id`；request 对既有对象使用 `.pairN` |
| `dpu_vio_register_plan_policy` / `dpu` | `notify.bank/auto_bank/type/offset/verify/retries/full_bank/interval_ns`；`msix.rate/packets/self_mask/emit_interval` |
| `dpu_qsch_topology_generator` / `dpu.qsch` | `mode/max_groups/max_ports/max_tc/shared_group/include_af` |
| `dpu_dut_caps` / `dpu.caps` | `max_hosts/max_pfs_per_host/max_vfs_per_pf/max_functions/global_msix_vector_count/mailbox_msix_vectors/af_extra_msix_vectors/af_extra_queue_count/vio_global_qpair_count/max_vio_net_qpairs_per_device/vio_notify_entries_per_bank` |

`notify.retries` 沿用公共短名，实际语义是**包含首次写入的总尝试次数**。
`notify.interval_ns` 是整数纳秒，显式乘以编译作用域中的 `1ns`，检查 `time`
溢出；未指定时直接保留当前 `time` 值，不做单位往返。`active_notify_bank`
属于运行观测输入，由调用方设置，不作为命令行开关。Host 的 `enabled/name`
也不在这次参数范围内。

所有集合在没有对应参数时完整保留。显式集合参数表示一次新的集合声明，
支持 AIP 的 `.size/.each/[i]` 及整体列表形式；未提供的元素字段使用该声明
的缺省值，不对旧集合逐字段合并。function-key 集合使用
`host_id/pf_id/kind/vf_id` schema，缺省键为 h0/pf0/PF/vf0。例如：

```text
+dpu.host_ids=0,1
+dpu.parent_pfs.size=1
+dpu.parent_pfs[0].host_id=0
+dpu.parent_pfs[0].pf_id=1
+dpu.fixed_devices.size=1
+dpu.fixed_devices[0].host_id=0
+dpu.fixed_devices[0].pf_id=1
+dpu.fixed_devices[0].kind=DPU_FUNCTION_PF
+dpu.qpairs=4
+dpu.h0.mem_base=0x100000000
+dpu.h0.mem_size=0x10000000
```

本轮不自动创建 Host/domain/window/PF/VF/service/profile/request、逐设备约束
或逐 qpair 覆盖对象；不读取多段 BDF 区间、reserved MMIO ranges、reserved
qpair ranges、caps BAR profiles。它们继续由调用方显式构造。未支持的集合
参数不应传入并期待产生对象，已存在对象的加载范围以本表为准。
