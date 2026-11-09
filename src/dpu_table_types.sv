// src：当前 DUT 公共表值类型；仅依赖 DPU 身份、BAR 与资源快照。
// packed 只描述线格式；普通记录借用冻结快照，不拥有或释放设备/DMA 资源。
// 保留 X/Z 供发送前拒绝；所有未知模块基址和端口由平台明确声明。

typedef struct packed {
	logic [12:0]	reserved_31_19;
	logic			vdpa_en;
	logic			ecrc_en;
	logic			valid;
	logic [15:0]	requester_id;
} dpu_bdf_entry_t;

typedef struct packed {
	logic			vf_valid;
	logic [10:0]	vf_num;
	logic [3:0]		pf_num;
} dpu_ep_requester_id_t;

typedef struct packed {
	logic [13:0]	reserved_31_18;
	logic			ecrc_en;
	logic			valid;
	logic [15:0]	completion_id;
} dpu_completion_bdf_entry_t;

typedef struct packed {
	logic [20:0]	reserved_31_11;
	logic [9:0]		first_vf_offset;
	logic			valid;
} dpu_pfvf_entry_t;

typedef struct packed {
	logic [29:0]	reserved_63_34;
	logic			vdpa_en;
	logic			valid;
	logic [31:0]	tlp_prefix;
} dpu_tlp_prefix_entry_t;

typedef struct packed {
	logic [28:0]	reserved_63_35;
	logic [12:0]	global_msix_idx;
	logic [2:0]		host_id;
	logic [9:0]		pfvf_id;
	logic [8:0]		local_msix_idx;
} dpu_msix_linear_entry_t;

typedef struct packed {
	logic [16:0]	reserved_31_15;
	logic			valid;
	logic			self_mask;
	logic [2:0]		host_id;
	logic [9:0]		function_id;
} dpu_msix_info_entry_t;

typedef struct packed {
	logic [15:0]	intrl_pnum;
	logic [15:0]	intrl_rate;
} dpu_msix_interval_entry_t;

typedef struct packed {
	logic [30:0]	reserved_127_97;
	logic			msix_mask;
	logic [31:0]	msix_data;
	logic [63:0]	msix_addr;
} dpu_msix_table_entry_t;

typedef struct packed {
	logic			valid;
	logic [17:0]	reserved_30_13;
	logic [9:0]		net_id;
	logic [2:0]		cos;
} dpu_qsch_q2tc_entry_t;

typedef struct packed {
	logic			valid;
	logic [20:0]	reserved_30_10;
	logic [9:0]		group_id;
} dpu_qsch_n2g_entry_t;

typedef struct packed {
	logic			valid;
	logic [10:0]	reserved_30_20;
	logic [3:0]		dpt;
	logic [11:0]	reserved_15_4;
	logic [3:0]		lvl2_id;
} dpu_qsch_g2p_entry_t;

typedef struct packed {
	logic [27:0]	reserved_31_4;
	logic [2:0]		host_id;
	logic			enable;
} dpu_qsch_rnet_entry_t;

typedef struct packed {
	logic [4:0]		reserved_63_59;
	logic [7:0]		vf_id;
	logic [2:0]		host_id;
	logic [47:0]	base_addr_60_13;
} dpu_rdma_notify_entry_t;

typedef struct packed {
	logic [63:0]	pending;
} dpu_msix_pba_word_t;

typedef struct packed {
	logic [15:0]	intrl_pnum_stat;
	logic [15:0]	intrl_rate_timer;
} dpu_msix_stat_t;

typedef struct packed {
	logic [31:0]	status;
} dpu_pfvf_drop_status_t;

typedef struct packed {
	logic [31:0]	clear_mask;
} dpu_pfvf_drop_clear_t;

// 同域消息必须唯一确定 owner/vector；接收 sink 不依赖是否存在 VIO service。
typedef struct {
	dpu_function_key_t	owner;
	int unsigned		local_vector;
	int unsigned		global_vector;
	logic [63:0]		address;
	logic [31:0]		data;
	logic				masked;
} dpu_msix_message_t;

// 类别独立记账；可选平台项不冒充截图已有位域，状态读取不进入初始化类别。
typedef enum int unsigned {
	DPU_TABLE_BAR,
	DPU_TABLE_AF,
	DPU_TABLE_PFVF,
	DPU_TABLE_BDF,
	DPU_TABLE_COMPLETION_BDF,
	DPU_TABLE_PREFIX,
	DPU_TABLE_MSIX_LINEAR,
	DPU_TABLE_MSIX_INFO,
	DPU_TABLE_MSIX_INTERVAL,
	DPU_TABLE_MSIX_CONTROL,
	DPU_TABLE_MSIX_TABLE,
	DPU_TABLE_MSIX_FUNCTION,
	DPU_TABLE_NOTIFY,
	DPU_TABLE_Q2TC,
	DPU_TABLE_N2G,
	DPU_TABLE_G2P,
	DPU_TABLE_SPWRR,
	DPU_TABLE_TC_WEIGHT,
	DPU_TABLE_VTX,
	DPU_TABLE_VRX,
	DPU_TABLE_QUEUE_AUX,
	DPU_TABLE_RDMA_NOTIFY,
	DPU_TABLE_RNET,
	DPU_TABLE_MSIX_PBA,
	DPU_TABLE_MSIX_STAT,
	DPU_TABLE_PFVF_DROP
} dpu_table_kind_e;

// 平台必须声明索引来源；局部/全局编号不能因为数值恰巧相同就互换。
typedef enum int unsigned {
	DPU_INDEX_EXPLICIT,
	DPU_INDEX_GLOBAL_FUNCTION,
	DPU_INDEX_GLOBAL_QPAIR,
	DPU_INDEX_GLOBAL_VECTOR,
	DPU_INDEX_LOCAL_VECTOR
} dpu_index_policy_e;

typedef enum int unsigned {
	DPU_HOST_EP,
	DPU_HOST_SW
} dpu_host_mode_e;

// 表目标独立于表项 owner；offset 是选定 BAR 内模块偏移，绝非物理地址。
// 间接端口数据宽度固定为该项宽度；control 写入先 clear 再 set trigger_mask。
typedef struct {
	bit					provided;
	string				reg_target;
	bit					access_host_provided;
	int unsigned		access_host;
	bit					access_uses_owner_host;
	logic [63:0]		module_offset;
	logic [63:0]		table_offset;
	int unsigned		capacity;
	int unsigned		entry_bytes;
	dpu_index_policy_e	index_policy;
	bit					indirect;
	logic [63:0]		data_port;
	logic [63:0]		control_port;
	logic [31:0]		index_mask;
	logic [31:0]		control_fixed;
	logic [31:0]		trigger_mask;
	int unsigned		index_shift;
	bit					required;
} dpu_table_layout_t;

// 每 Function 的平台编码输入。完整 VF Routing ID 由平台给出，绝不按数量推断。
typedef struct {
	dpu_function_key_t	key;
	dpu_host_mode_e		mode;
	int unsigned		intel_pf;
	int					intel_vf;
	logic [15:0]		requester;
	int unsigned		vport;
	int unsigned		pfvf;
	int unsigned		first_vf_offset;
	int unsigned		bdf_index;
	int unsigned		completion_index;
	int unsigned		prefix_index;
	logic [31:0]		prefix;
	bit					prefix_enabled;
	bit					ecrc;
	bit					vdpa;
} dpu_function_policy_t;

// ctx 保存真实访问目标和整个操作范围；仅冻结视图生成，checked helper 再核对原件。
typedef struct {
	dpu_device_snapshot	snapshot;
	longint unsigned	snapshot_id;
	longint unsigned	config_generation;
	string				layout_id;
	dpu_table_kind_e	kind;
	dpu_bar_target_t	target;
	dpu_table_layout_t	layout;
	int unsigned		table_index;
	bit [63:0]			byte_offset;
	string				record_key;
} dpu_table_ctx_t;

// 初始化非 packed 上下文时显式处理 class/string/enum，避免四态垃圾参与副本校验。
function automatic dpu_table_ctx_t dpu_empty_context(input dpu_bar_target_t	target);
	dpu_table_ctx_t	value;

	value.snapshot          = null;
	value.snapshot_id       = 0;
	value.config_generation = 0;
	value.layout_id         = "";
	value.kind              = DPU_TABLE_BAR;
	value.target            = target;
	value.layout            = '{reg_target: "", index_policy: DPU_INDEX_EXPLICIT, default: 0};
	value.table_index       = 0;
	value.byte_offset       = 0;
	value.record_key        = "";
	return value;
endfunction

// 公共 Function 查询不依赖 VIO ring；service 集合与租约来自同一个冻结快照。
typedef struct {
	dpu_function_key_t		key;
	dpu_pcie_function_id_t	pcie_id;
	int unsigned			global_function_id;
	bit						is_af;
	dpu_service_key_t		services[$];
	dpu_bar_pair_lease_t	bars[$];
} dpu_function_record_t;

// BAR 编码未知，保持真实租约及平台声明的完整原子组，不制造可发送 payload。
typedef struct {
	dpu_table_ctx_t			ctx;
	dpu_function_record_t	owners[$];
	dpu_bar_target_t		members[$];
} dpu_bar_mapping_cfg_t;

// 平台控制项没有截图线格式，保留显式声明的 raw/mask；不同类别仍使用独立 hook。
// consumers_complete 声明 catalog 的共享消费者完整（允许明确空集）；AF/SPWRR/TC_WEIGHT 必填。
// MSI-X/RNET/RDMA 自动加入实际 owner service；非空额外消费者也必须声明完整并属于冻结拓扑。
typedef struct {
	dpu_table_ctx_t		ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	bit					consumers_complete;
	logic [127:0]		value;
	logic [127:0]		writable_mask;
} dpu_control_cfg_t;

// bdf 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	dpu_table_ctx_t		ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	dpu_bdf_entry_t		entry;
} dpu_bdf_cfg_t;

// completion_bdf 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	dpu_table_ctx_t				ctx;
	dpu_function_key_t			owner;
	dpu_service_key_t			consumers[$];
	dpu_completion_bdf_entry_t	entry;
} dpu_completion_bdf_cfg_t;

// pfvf 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	dpu_table_ctx_t		ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	dpu_pfvf_entry_t	entry;
} dpu_pfvf_cfg_t;

// tlp_prefix 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	dpu_table_ctx_t			ctx;
	dpu_function_key_t		owner;
	dpu_service_key_t		consumers[$];
	dpu_tlp_prefix_entry_t	entry;
} dpu_tlp_prefix_cfg_t;

// msix_linear 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	dpu_table_ctx_t			ctx;
	dpu_function_key_t		owner;
	dpu_service_key_t		consumers[$];
	dpu_msix_linear_entry_t	entry;
} dpu_msix_linear_cfg_t;

// msix_info 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	dpu_table_ctx_t			ctx;
	dpu_function_key_t		owner;
	dpu_service_key_t		consumers[$];
	dpu_msix_info_entry_t	entry;
} dpu_msix_info_cfg_t;

// msix_interval 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	dpu_table_ctx_t				ctx;
	dpu_function_key_t			owner;
	dpu_service_key_t			consumers[$];
	dpu_msix_interval_entry_t	entry;
} dpu_msix_interval_cfg_t;

// msix_table 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	dpu_table_ctx_t			ctx;
	dpu_function_key_t		owner;
	dpu_service_key_t		consumers[$];
	dpu_msix_table_entry_t	entry;
} dpu_msix_table_cfg_t;

// qsch_q2tc 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	dpu_table_ctx_t			ctx;
	dpu_function_key_t		owner;
	dpu_service_key_t		consumers[$];
	dpu_qsch_q2tc_entry_t	entry;
} dpu_qsch_q2tc_cfg_t;

// qsch_n2g 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	dpu_table_ctx_t			ctx;
	dpu_function_key_t		owner;
	dpu_service_key_t		consumers[$];
	dpu_qsch_n2g_entry_t	entry;
} dpu_qsch_n2g_cfg_t;

// qsch_g2p 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	dpu_table_ctx_t			ctx;
	dpu_function_key_t		owner;
	dpu_service_key_t		consumers[$];
	dpu_qsch_g2p_entry_t	entry;
} dpu_qsch_g2p_cfg_t;

// qsch_rnet 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	dpu_table_ctx_t			ctx;
	dpu_function_key_t		owner;
	dpu_service_key_t		consumers[$];
	dpu_qsch_rnet_entry_t	entry;
} dpu_qsch_rnet_cfg_t;

// rdma_notify 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	dpu_table_ctx_t			ctx;
	dpu_function_key_t		owner;
	dpu_service_key_t		consumers[$];
	dpu_rdma_notify_entry_t	entry;
} dpu_rdma_notify_cfg_t;

// 公共只读导出拥有值副本、借用 snapshot/registry；不依赖 VIO ring 生命周期。
// 只读/W1C 查询只接受独立上下文；禁止用状态值进入普通初始化 dispatch。
typedef struct {
	dpu_table_ctx_t		ctx;
	dpu_function_key_t	owner;
} dpu_state_query_t;

typedef struct {
	dpu_table_ctx_t			ctx;
	dpu_function_key_t		owner;
	dpu_pfvf_drop_clear_t	entry;
} dpu_pfvf_drop_clear_cfg_t;

// MSI-X 地址/数据模板独立于 VIO；存在标志区分显式零与未提供，PBA 容量必须明确。
typedef struct {
	bit							table_only_enable;
	bit							interval_present;
	dpu_msix_interval_entry_t	interval_entry;
	bit							self_mask_present;
	logic						self_mask;
	bit							address_present;
	bit							data_present;
	logic [63:0]				address_base;
	logic [63:0]				address_stride;
	logic [31:0]				data_base;
	logic [31:0]				data_stride;
	bit							table_present;
	int unsigned				table_bar;
	logic [63:0]				table_offset;
	int unsigned				table_size;
	bit							pba_present;
	int unsigned				pba_bar;
	logic [63:0]				pba_offset;
	int unsigned				pba_words;
} dpu_msix_policy_t;

// BAR 原子组只声明逻辑成员，发布时解析真实租约；不要求用户在 build 前知道随机 BAR base。
typedef struct {
	string				name;
	dpu_function_key_t	functions[$];
	int unsigned		bar_ids[$];
} dpu_bar_group_policy_t;

// PFVF 关系校验输入包含同一 PF 的完整实际成员，不用数量/隐含 VF stride 推算路由。
typedef struct {
	dpu_function_record_t	functions[$];
	dpu_function_policy_t	policies[$];
} dpu_pfvf_relationship_t;

// 独立选择范围借用资源快照；空 Function/BAR/service 集合表示该类全部实际成员。
class dpu_cfg_scope extends uvm_object;
	local dpu_device_snapshot	m_snapshot;
	local dpu_function_key_t	m_keys[$];
	local int unsigned			m_bars[$];
	local dpu_table_kind_e		m_kinds[$];
	local dpu_service_key_t		m_services[$];

	// 仅保存选择，不分配资源；未知/重复身份由 validate 在写表前拒绝。
	extern function new(
		string				name,
		dpu_device_snapshot	snapshot,
		dpu_function_key_t	keys[$],
		int unsigned		bars[$],
		dpu_table_kind_e	kinds[$] = {},
		dpu_service_key_t	services[$] = {}
	);
	// 只接受同一冻结快照和实际 Function/BAR/service，失败给出原因。
	extern function bit validate(
		input dpu_device_snapshot	snapshot,
		output string				why
	);
	// 空集合选择全部，非连续集合按完整身份匹配。
	extern function bit selects(input dpu_function_key_t	key);
	// BAR ID 是偶数编号，不是 role。
	extern function bit selects_bar(input int unsigned	bar_id);
	// 仅筛选类别，不重新编号。
	extern function bit selects_kind(input dpu_table_kind_e	kind);
	// service 选择还受 Function 范围约束。
	extern function bit selects_service(input dpu_service_key_t	key);
endclass

// 保存选择及快照身份，后续不允许换代复用。
function dpu_cfg_scope::new(
	string				name,
	dpu_device_snapshot	snapshot,
	dpu_function_key_t	keys[$],
	int unsigned		bars[$],
	dpu_table_kind_e	kinds[$],
	dpu_service_key_t	services[$]
);
	super.new(name);
	m_snapshot = snapshot;
	m_keys     = keys;
	m_bars     = bars;
	m_kinds    = kinds;
	m_services = services;
endfunction

// 预检完整选择，避免写到一半才发现未知成员；不依赖任何传输或 ring 类型。
function bit dpu_cfg_scope::validate(
	input dpu_device_snapshot	snapshot,
	output string				why
);
	dpu_function_key_t		keys[$];
	dpu_service_key_t		services[$];
	dpu_pcie_function_id_t	id;
	dpu_bar_pair_lease_t	bars[$];
	bit						seen[string];
	bit						found;

	why = "scope belongs to another device snapshot";
	if (snapshot == null || snapshot != m_snapshot) return 0;
	foreach (m_keys[i]) begin
		if (!snapshot.get_pcie_id(m_keys[i], id, why) || seen.exists(dpu_function_key_name(m_keys[i]))) begin
			why = "scope contains unknown/duplicate Function";
			return 0;
		end
		seen[dpu_function_key_name(m_keys[i])] = 1;
	end
	snapshot.list_functions(keys);
	foreach (m_bars[b]) begin
		foreach (m_bars[j])
		if (j < b && m_bars[b] == m_bars[j]) begin
			why = "scope contains duplicate BAR";
			return 0;
		end
		foreach (keys[f]) begin
			if (!selects(keys[f])) continue;
			if (!snapshot.list_bars(keys[f], bars, why)) return 0;
			found = 0;
			foreach (bars[k]) if (bars[k].even_bar_id == m_bars[b]) found = 1;
			if (!found) begin
				why = "scope BAR is not a real lease on every selected Function";
				return 0;
			end
		end
	end
	snapshot.list_services(DPU_SERVICE_VIO_NET, services);
	seen.delete();
	foreach (m_services[i]) begin
		found = 0;
		foreach (services[j])
		if (dpu_service_key_name(services[j]) == dpu_service_key_name(m_services[i])) found = 1;
		if (!found || !selects(m_services[i].function_key) || seen.exists(dpu_service_key_name(m_services[i]))) begin
			why = "scope contains unknown/duplicate/out-of-range service";
			return 0;
		end
		seen[dpu_service_key_name(m_services[i])] = 1;
	end
	why = "";
	return 1;
endfunction

// 不按全局编号范围推测成员，非连续 Function 保持原身份。
function bit dpu_cfg_scope::selects(input dpu_function_key_t	key);
	if (m_keys.size() == 0) return 1;
	foreach (m_keys[i]) if (dpu_same_function_key(m_keys[i], key)) return 1;
	return 0;
endfunction

// 空 BAR 列表表示选中 Function 的实际全部租约。
function bit dpu_cfg_scope::selects_bar(input int unsigned	bar_id);
	if (m_bars.size() == 0) return 1;
	foreach (m_bars[i]) if (m_bars[i] == bar_id) return 1;
	return 0;
endfunction

// 空类别列表保持全类别视图；明确类别只能确认其自己的账本项。
function bit dpu_cfg_scope::selects_kind(input dpu_table_kind_e	kind);
	if (m_kinds.size() == 0) return 1;
	foreach (m_kinds[i]) if (m_kinds[i] == kind) return 1;
	return 0;
endfunction

// 完整 service 身份与 Function 过滤同时成立才选中。
function bit dpu_cfg_scope::selects_service(input dpu_service_key_t	key);
	if (!selects(key.function_key)) return 0;
	if (m_services.size() == 0) return 1;
	foreach (m_services[i])
	if (dpu_service_key_name(m_services[i]) == dpu_service_key_name(key)) return 1;
	return 0;
endfunction
