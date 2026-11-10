// src：当前 VTX/VRX/Notify 硬件字段与 VIO 导出的实际配置值。
// packed 只描述线格式；普通记录借用冻结快照，不拥有或释放设备/DMA 资源。
// 保留 X/Z 供发送前拒绝；所有未知模块基址和端口由平台明确声明。

// service 需求是 VIO 唯一采样结果的中性投影，供分配和 MSI-X 选择；不复制完整 VIO cfg。
typedef struct {
	dpu_service_key_t	service_key;
	bit					enabled;
	bit					tx_enable;
	bit					rx_enable;
	bit					msix_enable;
	int unsigned		qpairs;
} dpu_vio_service_t;

// 仅包含写表需要的实际 ring 信息；来源是 VIO 已分配 setup，不拥有或释放 ring。
typedef struct {
	dpu_device_snapshot		snapshot;
	dpu_service_key_t		service_key;
	dpu_vio_qpair_binding_t	qpair;
	longint unsigned		generation;
	bit						virtio_mode;
	bit						msix_enable;
	logic					tx_mode;
	int unsigned			local_qid;
	int unsigned			queue_size;
	int unsigned			allocated_qpairs;
	bit [63:0]				desc_iova;
	bit [63:0]				notify_address;
	bit [63:0]				notify_bar_base;
	bit [63:0]				notify_bar_size;
} dpu_vio_queue_t;

typedef struct packed {
	logic [15:0]	reserved_127_112;
	logic [5:0]		reserved_111_106;
	logic [9:0]		sport_id;
	logic [3:0]		dma_info;
	logic [12:0]	dma_msix;
	logic [2:0]		sport;
	logic			queue_stop;
	logic			tail_buf_id_dis;
	logic			redraw_en;
	logic			high_speed_mode;
	logic			seg_en;
	logic			interl_seg_en;
	logic			virtio_mode;
	logic			queue_en;
	logic [3:0]		q_depth;
	logic [63:0]	desc_addr;
} dpu_vtx_entry_t;

typedef struct packed {
	logic [50:0]	reserved_127_77;
	logic [1:0]		notify_type;
	logic [10:0]	global_qid;
	logic [2:0]		host_id;
	logic [53:0]	base_addr_60_7;
	logic [6:0]		local_qid_encoding;
} dpu_vio_notify_entry_t;

typedef struct packed {
	logic			reserved_127;  //[127]
	logic [14:0]	dsc_pre_read_ram_addr;  //[126:112]，单位为 descriptor 槽
	logic [2:0]		dsc_pre_max_num;  //[111:109]，0 表示 256 槽
	logic			reserved_108;  //[108]
	logic [1:0]		dsc_pre_read_threshold;  //[107:106]
	logic [1:0]		dsc_dma_num;  //[105:104]
	logic [1:0]		dsc_mode;  //[103:102]
	logic [2:0]		payload_dsc_len;  //[101:99]
	logic [1:0]		head_dsc_len;  //[98:97]
	logic			dma_msix_en;  //[96]
	logic [12:0]	dma_msix;  //[95:83]
	logic [9:0]		dport_id;  //[82:73]
	logic [2:0]		dport;  //[72:70]
	logic			virtio_mode;  //[69]
	logic			queue_en;  //[68]
	logic [3:0]		q_depth;  //[67:64]，log2(descriptor 数)
	logic [63:0]	dsc_addr;  //[63:0]，设备可见 ring IOVA
} dpu_vrx_entry_t;

// 真实 ring 绑定是校验依据，entry 修改不能反向更改已分配资源。
typedef struct {
	dpu_table_ctx_t	ctx;
	dpu_vio_queue_t	binding;
	dpu_vtx_entry_t	entry;
} dpu_vtx_cfg_t;

// 真实 ring 绑定是校验依据，entry 修改不能反向更改已分配资源。
typedef struct {
	dpu_table_ctx_t	ctx;
	dpu_vio_queue_t	binding;
	dpu_vrx_entry_t	entry;
} dpu_vrx_cfg_t;

// 真实 ring 绑定是校验依据，entry 修改不能反向更改已分配资源。
typedef struct {
	dpu_table_ctx_t			ctx;
	dpu_vio_queue_t			binding;
	dpu_vio_notify_entry_t	entry;
} dpu_vio_notify_cfg_t;

// AUTO/RANDOM 均保持每个启用 TX 的 Function 对应一个 net；MANUAL 使用原显式策略。
// 这里只选择配置前的生成规则，不改变硬件 VNET/ETS 模式，也不支持运行中改配。
typedef enum int unsigned {
	DPU_QSCH_AUTO,
	DPU_QSCH_RANDOM,
	DPU_QSCH_MANUAL
} dpu_qsch_topology_e;

// Function 的调度输入保留 AIP 表达式，直到实际 TX 集合确定后统一分配唯一编号。
// 空字段继承全局输入；固定值不随机，随机表达式不能在 seq 查询时再次采样。
typedef struct {
	string	net_id;
	string	group_id;
	string	dpt;
} dpu_qsch_input_t;

// cfg 保存的 Function→net→group 结果；net_id 是调度编号，不是 BDF、PF 编号或 BAR。
// 同 Function 的全部 TX 队列引用同一项；相同源 Host、目的 dpt 的 net 共享一个 group。
typedef struct {
	dpu_function_key_t	owner;
	int unsigned		net_id;
	int unsigned		group_id;
	int unsigned		dpt;
	int unsigned		lvl2_id;
} dpu_qsch_net_t;

// 队列平台策略按 service 给出；MANUAL 使用 net_base/net_stride/group_id/eth_ports/ets。
// AUTO/RANDOM 的编号来自 cfg.qsch_nets；COS 仍由本 service 的显式策略控制。
// VRX RAM 是 descriptor 槽，域名表示实际共享 RAM；不同 Host 相同域仍检查非重叠。
typedef struct {
	dpu_service_key_t	service_key;
	dpu_vtx_entry_t		vtx;
	dpu_vrx_entry_t		vrx;
	bit					fpga;
	string				prefetch_ram;
	int unsigned		prefetch_start;
	int unsigned		prefetch_slots;
	int unsigned		net_base;
	int unsigned		net_stride;
	int unsigned		group_id;
	int unsigned		cos;
	int unsigned		eth_ports;
	bit					ets;
	bit					distinguish_business;
	int unsigned		ets_priority;
	bit					notify_net_pair5;
	bit					notify_table_base_provided;
	int unsigned		notify_table_bar;
	logic [63:0]		notify_table_offset;
} dpu_vio_policy_t;

// 统一表项用于预检、去重和写入；外部 hook 消费类别对应的 typed cfg。
typedef struct {
	dpu_table_ctx_t		ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	bit					has_queue;
	dpu_vio_queue_t		binding;
	logic [127:0]		entry;
	logic [127:0]		enable_mask;
	logic [127:0]		enable_value;
	string				dependencies[$];
} dpu_table_item_t;

// 使能和辅助上下文仍携带完整 ring 绑定，用户无需回查其他配置对象。
typedef struct {
	dpu_table_ctx_t	ctx;
	dpu_vio_queue_t	binding;
	logic [127:0]	value;
	logic [127:0]	writable_mask;
} dpu_queue_control_cfg_t;
