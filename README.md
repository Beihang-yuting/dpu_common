# dpu_common

`dpu_common` 是 DPU 资源和公共 DUT 配置的 SystemVerilog/UVM 仓库。
核心包独立于 PCIe/VIO；原生 PCIe 写表放在可选集成包中。

## 当前集成入口

`dpu_env_cfg` 统一拥有拓扑输入、表布局/策略、冻结资源和 BAR 查询结果；
用户 env_cfg 直接组合它与 VIO/PCIe cfg，不再复制 project 的公共配置。
`dpu_device_env` 只解析和发布资源。VIO 提供实际 ring/IOVA 的 `dpu_vio_queue_t`，
DPU 按这些值生成表，不能再次分配或猜测 descriptor 地址。

| 文件 | 能力 |
| --- | --- |
| `src/dpu_env_cfg.sv` | `load_params`、资源查询、公共/队列表生成及运行期候选 |
| `src/dpu_table_types.sv`、`src/dpu_vio_table_types.sv` | 图片版硬件字段、布局、scope 和中性队列值 |
| `src/dpu_bar_map.sv` | 查询实际 BAR、范围和分组日志 |
| `integration/pcie/dpu_pcie_bar_map.sv` | 同一 BAR 对象上的 RC/Intel 路由 |
| `integration/pcie/dpu_cfg_seq.sv` | 原生 Memory 配置、逐表扩展、AF 同步和 Notify 使能 |
| `integration/pcie/dpu_bar_reg_seq.sv` | PF0 BAR0 相对 `reg_acc`，保持原生寄存器命令字段 |

`dpu_cfg_seq` 从启动 sequencer 的 `dpu_cfg` 键取得 `dpu_env_cfg`；
`virtio_work/integration/dpu/vio_dpu_cfg_seq.sv` 只补 VIO 的准备/导出/确认/释放。
VIO/RDMA 每批 Notify 成功后，每个管理 BAR 写一次 `+0x80044=1`；空批次不写，失败停止。
AF `+0x1010` 的写 magic/读状态8，以及每100次 DWORD 写同步读均保留。

## QSCH 参数与实际写表

先创建 Host/PF/VF，再由 VIO 按每个 Function 的 `pairs` 申请实际队列。
`dpu_env_cfg.set_queues()` 接收实际队列后生成一次映射：一个有 TX 队列的 PF/VF
对应一个 net；同 Function 的全部 TX 队列共享它。同源 Host、同目的 dpt 的 net
共享一个 group。未启用或仅 RX 的 Function 不生成 QSCH 表。

默认 `DPU_QSCH_AUTO`，未指定 net_id 时取冻结 `global_function_id`，未指定
group_id 时取 `host_id*16+dpt`。固定值直接生效，不需要开启随机模式：

```text
+dpu.qsch.net_id=100 +dpu.qsch.group_id=20
+dpu.qsch.dpt=0 +dpu.qsch.cos=3 +dpu.qsch.print=1
```

以上全局固定 net_id 适用于一个活动 TX Function；多个 PF/VF 必须给不同 net，
或统一提供随机候选。随机也不需要切换 topology：

```text
+dpu.qsch.net_id=[100:400]
+dpu.qsch.group_id=random
+dpu.qsch.dpt=0 +dpu.qsch.print=1
+ntb_random_seed=17
```

`rand` 与 `random` 等价；范围、列表等有限整数表达式复用 AIP 解析。net/group 均为
0..1023，唯一分配先保留固定值，再处理随机候选。候选不足/冲突会在 QSCH 写表前返回原因。
`DPU_QSCH_RANDOM` 只把未指定的 net/group 默认改为 rand，显式参数仍优先。
旧 `net_min/net_max` 已替换为单个 `net_id` 表达式。

覆盖顺序为 `dpu.qsch.* → vio.qsch.* → vio.hH.qsch.* →
vio.hH.pfP[.vfV].i0.qsch.*`。例如同 Host 的 PF0 发向 ETH0，PF1 发向 HOST0：

```text
+vio.h0.pf0.i0.qsch.net_id=100 +vio.h0.pf0.i0.qsch.group_id=20
+vio.h0.pf0.i0.qsch.dpt=0
+vio.h0.pf1.i0.qsch.net_id=200 +vio.h0.pf1.i0.qsch.group_id=30
+vio.h0.pf1.i0.qsch.dpt=8
+dpu.qsch.eth_ports=8
```

目的节点按 **94.png**：默认 ETH 数为8（按实际 DUT 用 `dpu.qsch.eth_ports` 修改，1..8），
ETHn 编码为 n，HOSTh 编码为 `eth_ports+h`。例如2个 ETH 时 HOST0=2、HOST1=3；
只能指定当前快照中存在的 HOST0..4。默认 `dpt=0` 为 ETH0，13..15 不采用驱动旧版
FWD_MODE 定义。`dpt=random` 仅在当前有效 ETH/Host 节点中选择，也可以提供固定值或范围。
G2P 的 `lvl2_id` 始终为**源** Host；它不是目的 Host。一个 Function 当前对应一个目的节点，
同 route 的 group 参数应一致，不同 route 不得强制共用 group。
VTX `sport/sport_id` 和 VRX `dport/dport_id` 仍取真实 Host/Function 路由，net 随机不会改变它们。

生成结果保存在 `cfg.qsch_nets[dpu_function_key_name(key)]`，类型 `dpu_qsch_net_t`
包含 `owner/net_id/group_id/dpt/lvl2_id`。`qsch_route(queue, route, why)` 查询同一份结果。
`+dpu.qsch.print=1` 打印 Function→net→group→dpt 及 pair/global_qid，默认明细为 UVM_HIGH。
同一种子及同一执行流程可复现；查询、导出和 seq 不重新随机。

| 配置 seq 消费的表 | 索引 | 参数/数据来源 |
| --- | --- | --- |
| Q2TC | 实际 global_qpair_id | net_id、service COS |
| N2G | net_id | group_id |
| G2P | group_id | dpt、源 host_id |
| SPWRR / TC_WEIGHT | net_id | `dpu.qsch.spwrr/tc_weight` |

`vio_dpu_cfg_seq` 先准备实际 ring 并调用 `set_queues()`，随后继承的
`dpu_cfg_seq.configure_qsch()` 读取以上记录，经 `pcie_tl_reg_seq` 写管理 BAR。
用户沿用已有 `dut_config` 注册/启动方式即可，env/base_test 不需要重复传 net/group。
管理 BAR 由 `dpu.qsch.reg_target`（默认继承 `dpu.reg_target`）选择，不由 net_id 推导。

AUTO/RANDOM 当前支持 VNET (`dpu.qsch.mode=0`)；原
`net_base/net_stride/group_id/eth_ports/ets` 策略使用 `DPU_QSCH_MANUAL`。
运行期参数重载需先释放已有 VIO 队列，随后重新启动配置 seq 才会生成/下发新拓扑；
重载不自动修改正在工作的 DUT，也不重新分配 Host/PF/VF/BAR。

用户集成可以使用 `dpu_cfg`、`dpu_dev_cfg`、`dpu_dev_snap`、`dpu_res_snap`、
`dpu_res_mgr`、`dpu_dev_env`、`dpu_bars` 和 `dpu_caps` 这些对象短别名；
`dpu_func_key_t`、`dpu_svc_key_t`、`dpu_pcie_id_t`、`dpu_host_t`、
`dpu_bar_lease_t` 是常用身份/资源值别名，`dpu_scope`、`dpu_table_t`、
`dpu_layout_t` 是公共表选择别名，`dpu_vtx_t`、`dpu_vrx_t`、`dpu_notify_t`、
`dpu_q2tc_t`、`dpu_n2g_t`、`dpu_g2p_t` 是硬件 packed 表项别名。完整类名和
完整类型名继续保留给已有测试和底层实现。

新增声明遵循统一排版：类型名与变量名之间至少使用一个制表位。例如：

```systemverilog
dpu_cfg		cfg;
dpu_dev_snap	snapshot;
dpu_func_key_t	key;
```

VIO Notify 查找基址默认来自实际队列导出的 `notify_address[60:7]`；显式 BAR/offset
覆盖需与该地址高位一致。公共 `publish()` 要求 device/resource/BAR map 同源且已冻结，
消息和分组检查全部成功后才发布，失败保留原有可见状态。

旧 DUT bootstrap/VIO 双 bank builder 和通用寄存器计划执行链已删除。
当前配置统一由 `dpu_cfg_seq` 直接通过 PCIe TL 写入，资源 env 只负责冻结并发布
快照，不再保留第二套寄存器执行入口。

## 所有权边界

本仓库负责：

- Host、PCIe domain、PF/VF 和 service 的逻辑声明；
- BDF、BAR aperture/base、资源放置和硬件表项解析；
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

具体 PCIe 集成需要先编译 `dpu_resource_pkg` 和 `pcie_tl_pkg`，再显式加入：

```text
-f $DPU_COMMON_ROOT/filelists/dpu_pcie.f
```

该入口不重复编译核心，也不依赖 VIO 或参考 project。

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

低层 authoring 类仍可单独使用。当前参考入口 `dpu_env_cfg.load_params()` 已完成下列
拓扑构建；VIO 再提交缓存的 service 需求。自行使用低层对象时，按以下顺序：

1. 调用 `device.load_params("dpu")` 读取 caps 和 AF，先用 `caps.validate`
   检查能力是否在模型上限内，再按这些能力创建拓扑及资源输入。
2. 创建 Host 模板及已有 domain/MMIO window，然后仅调用一次
   `host_template.load_params("dpu")`。
3. 深复制模板到各 Host，设置其拓扑身份，再调用
   `host.load_params($sformatf("dpu.h%0d", host.host_id))`。
4. 建立 placement 的 profiles/requests，调用
   `placement.load_params("dpu")`；QSCH 拓扑由 `dpu_env_cfg` 根据冻结资源和实际队列统一生成。
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
| `dpu_dut_caps` / `dpu.caps` | `max_hosts/max_pfs_per_host/max_vfs_per_pf/max_functions/global_msix_vector_count/mailbox_msix_vectors/af_extra_msix_vectors/af_extra_queue_count/vio_global_qpair_count/max_vio_net_qpairs_per_device/vio_notify_entries_per_bank` |

当前公共写表不注册旧 `dpu.notify.bank/auto_bank/full_bank` 参数，Notify 仅单 bank。
MSI-X 消息/间隔、VIO 表字段和管理窗口由 `dpu_env_cfg` 的 AIP 加载入口读取；
参数路径仍为 `dpu.*`、`vio.*`。底层 Host 的 `enabled/name` 由 SV 显式设置。

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

上表低层 `load_params` 不自动创建拓扑、逐设备约束或逐 qpair 覆盖对象；
`dpu_env_cfg.load_params()` 才根据 hosts/pfs_per_host/vfs_per_pf 创建默认拓扑。低层类不读取多段 BDF 区间、reserved MMIO ranges、reserved
qpair ranges、caps BAR profiles。它们继续由调用方显式构造。未支持的集合
参数不应传入并期待产生对象，已存在对象的加载范围以本表为准。
