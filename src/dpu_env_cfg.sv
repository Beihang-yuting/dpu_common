// src：DPU 资源输入、唯一 BAR 视图和当前 DUT 表配置；不依赖 PCIe/VIO 类。
// cfg 拥有 authoring/冻结表值，借用 resolver 快照；实际 ring/IOVA 由 VIO 导出并管理。
// Host/Function/BAR 只分配一次；发布先验证同源冻结身份，失败保留旧发布值。
// Notify 查找键取实际 doorbell 的高位；运行期刷新不改变拓扑、不自动访问 DUT。
class dpu_env_cfg extends uvm_object;
	`uvm_object_utils(dpu_env_cfg)
	// 默认采用驱动 VIO/QSCH/BDF/MSI-X 布局与无 IP 的 PF0 软件路由；显式平台声明优先。
	// BDF 默认下发，MSI-X 按完成模式选择；其余公共表开关不影响 BAR/队列软件资源。
	string	reg_target = "pf0.bar0";
	bit		print_bar_map = 1;
	bit		configure_public = 0;
	bit		configure_bdf = 1;
	bit		driver_layouts = 1;
	// 日常用例默认只写；调试时开启配置读回，失败则不确认资源。
	bit	verify_readback = 0;

	// QSCH 模式寄存器采用驱动偏移；SP/WRR 与 TC 权重按实际 net_id 生成。
	bit						qsch_configure_controls = 1;
	int unsigned			qsch_mode = 0;
	logic [63:0]			qsch_mode_offset = 'hb001c0;
	logic [31:0]			qsch_spwrr = 'hff;
	logic [31:0]			qsch_tc_weight = 'h11111111;
	dpu_table_layout_t		table_layouts[dpu_table_kind_e];
	dpu_function_policy_t	function_policies[string];
	dpu_vio_policy_t		vio_policies[string];
	dpu_msix_message_t		messages[$];
	// 首次生成消息前保存SV显式catalog；运行期重新生成参数消息时不能把旧生成值误当显式项。
	protected dpu_msix_message_t	authored_messages[$];
	protected bit					message_inputs_saved;
	dpu_bar_mapping_cfg_t			bar_groups[$];
	bit								bar_mapping_per_lease = 0;
	dpu_bar_group_policy_t			bar_group_policies[$];
	dpu_control_cfg_t				platform_controls[$];

	dpu_msix_policy_t	msix_policies[string];
	dpu_msix_message_t	message_templates[string][int unsigned];

	dpu_msix_message_t	frozen_messages[$];
	dpu_table_item_t	records[string];
	// 全部已准备服务的单 bank Notify 排序目录；scope 只筛选，不能重新编号。
	dpu_table_item_t	notify_records[$];
	// MSI-X 线性查找表按 Host/PFVF/local vector 排序，global vector 只保存到内容。
	dpu_table_item_t	msix_linear_records[$];
	protected bit		msix_directory_ready;

	dpu_table_layout_t		frozen_layouts[dpu_table_kind_e];
	dpu_function_policy_t	frozen_functions[string];
	dpu_vio_policy_t		frozen_policies[string];
	string					frozen_reg_target;
	dpu_bar_mapping_cfg_t	frozen_bar_groups[$];
	dpu_control_cfg_t		frozen_controls[$];
	dpu_msix_policy_t		frozen_msix_policies[string];

	dpu_device_cfg				device_cfg;
	dpu_resource_placement_cfg	placement_cfg;
	uvm_object					host_mem_pool_ref;
	dpu_device_snapshot			device_snapshot;
	dpu_resource_snapshot		resource_snapshot;
	dpu_bar_map					bar_map;
	bit							runtime_ready;
	longint unsigned			hosts = 1;
	longint unsigned			pfs_per_host = 1;
	longint unsigned			vfs_per_pf = 0;
	protected bit				params_loaded;
	dpu_vio_service_t			services[string];
	dpu_vio_queue_t				queues_by_host[int unsigned][$];

	// 构造 authoring 输入和缺省 AF 身份；不读取参数、不分配 BAR/ring 或访问 DUT。
	extern function new(string	name = "dpu_env_cfg");

	// 唯一参数构建入口：先采样规模/模板，再创建 Host/PF/VF/placement 和 Host 行为。
	// 再调用幂等返回，不重新采样；已有输入的项目应把加载入口合入原构造点，省去生成循环。
	// 默认生成器拒绝覆盖非空逻辑配置，避免重复追加 Host/PF/VF 和资源请求。
	// base_test 无须逐项赋值；AIP-off 时保留默认值，但仍正常创建对象。
	extern function void load_params();

	// 构造全局 Host 模板；GPA 和 MMIO 分开，BDF 范围覆盖默认 PF/VF 规模。
	// 每 Host 的 identity 和参数覆盖由 load_params 设置，不在这里解析实际地址。
	extern protected function dpu_host_cfg make_host_template();

	// 按 Host/PF/VF 身份创建 Function，并从 DUT caps 取得 BAR 规格。
	// 全部 BAR/BDF 均由 resolver 最终放置；未知规格立即 fatal，不能制造设备能力。
	extern protected function dpu_function_cfg make_function(
		int unsigned		host_id,
		int unsigned		pf_id,
		dpu_function_kind_e	kind,
		int unsigned		vf_id
	);

	// build 或运行期候选加载表目标及消息模板；全局→Host→精确 Function 逐级覆盖。
	// 固定键复用 AIP 宏，动态字段名复用同一 AIP 原生 API；存在性查询不消耗随机采样。
	extern protected function void load_platform_params();

	// 采用驱动中已经核对的模块/表偏移；只补缺项，保留用户提供的完整布局和目标覆盖。
	// 空目标由 frozen_reg_target 解析；短名字通常按 owner Host 访问，Notify/MSI-X 线性表由 Host0 管理。
	extern protected function void set_driver_layout(
		input dpu_table_kind_e		kind,
		input logic [63:0]			module_offset,
		input logic [63:0]			table_offset,
		input int unsigned			entry_bytes,
		input int unsigned			capacity,
		input dpu_index_policy_e	index_policy
	);

	// 安装 VIO/QSCH、BDF 与 MSI-X 的驱动参考布局；BAR/PFVF 等其他公共表仍由平台声明。
	// VTX/VRX 使用四次 DWORD 数据写和控制触发端口，不把间接表当作线性 MMIO。
	extern function void use_driver_reference_layouts();

	// 无 PCIe IP 的参考接线约定为各 Host PF0 / VF=-1 / wire requester=0 / vport=0。
	// 这是 Intel sideband/DMA 软件路由，绝不表示已向 DUT 写 BDF/PFVF 表。
	// 显式 policy 优先作为缺省值；CLI 可覆盖字段，其余 PF/VF 不猜 requester/Intel 身份。
	extern protected function void load_function_routes();

	// 以实际 qpair/net_id 和最终管理 BAR 为键合并默认调度项，覆盖所有实际消费者。
	// 每代从用户 catalog 重建 frozen_controls；同一地址的显式项优先，不改变其值或声明范围。
	// 非 ETS/ETS 必须与全局模式一致；范围/布局失败在任何 VIO MMIO 写入前返回原因。
	extern protected function bit materialize_qsch_controls(output string	why);

	// 以最终 service 完成模式选择 Function；轮询且未要求公共配置时保持空范围，不误选全部。
	// MSI-X pair 必须有对应未屏蔽消息；公共模式另保留显式消息的 AF/其他 Function。
	// 在 env connect 发布资源后、任何 DUT 写入前调用；缺 Host cfg/快照时明确返回依赖错误。
	extern function bit select_msix_scope(
		output dpu_cfg_scope	scope,
		output string			why
	);

	// 驱动按 Host/PFVF 排 Function、按 local vector 排组内项；global vector 仅作为查找结果。
	// 默认独立 API 首次消费完整冻结消息；默认 body 显式选择完成模式范围后生成紧凑目录。
	// 所有行必须落到同一管理 bank，失败不发布半份目录，也不按局部 public scope 重新编号。
	extern protected function bit materialize_msix_linear_records(
		output string		why,
		input dpu_cfg_scope	scope = null
	);

	// 公共向量来自资源快照，AF 额外资源也能在没有任何 VIO service 时产生消息项。
	extern function bit materialize_messages(
		input dpu_resource_snapshot	resources,
		output string				why
	);

	// 同一共享向量只登记一次；显式消息优先但必须与冻结向量身份一致。
	extern protected function bit add_message(
		input dpu_function_key_t	owner,
		input int unsigned			local_vector,
		input int unsigned			global_vector,
		output string				why
	);

	// 仅 PF0/no-VF 且 Intel/PFVF 均为参考编码时通过；其余家族保留平台真实关系校验。
	extern virtual function bit validate_pfvf_relationship(
		input dpu_pfvf_relationship_t	family,
		output string					why
	);

	// 从平台已冻结布局解析真实目标，图片相对偏移单独保留；整个操作范围先检查。
	// 缺失布局时仅按行列出表名、归属与修复入口，不展开完整配置或内部结构体。
	extern function bit make_context(
		input dpu_table_kind_e		kind,
		input dpu_function_key_t	owner,
		input int unsigned			index,
		input longint unsigned		generation,
		output dpu_table_ctx_t		ctx,
		output string				why
	);

	// 同批配置中共享表项必须一致；合并消费者供 typed hook 使用，避免重复写同一硬件项。
	extern function bit remember_record(
		input dpu_table_item_t	record,
		output string			why
	);

	// MSI-X/RNET/RDMA 的 Function 范围由实际 owner service 派生；AF/共享调度范围不能猜测。
	// 显式消费者逐一核对冻结拓扑并去重，表项生成和用户 hook 共用这一份关系。
	extern function bit control_consumers(
		input dpu_control_cfg_t		item,
		output dpu_service_key_t	consumers[$],
		output string				why
	);

	// 控制 payload/mask 只来自已冻结 catalog，不把未定义位扩展成全可写。
	extern function logic [127:0] platform_control_mask(input dpu_table_item_t	record);

	// 公共类别只消费冻结 Function/消息/布局；缺失映射只阻止当前类别，不依赖 VIO ring。
	extern function bit public_records(
		input dpu_table_kind_e	kind,
		input dpu_cfg_scope		scope,
		output dpu_table_item_t	selected[$],
		output string			why
	);

	// 驱动先按 Host/BAR 查找基址排序 Function，再在组内按 pair 编号排列；硬件行号是排序位置。
	// 从完整已准备目录生成一次，RX/TX 共用 pair 项；global_qid 只写入 payload，不作为表行号。
	// 默认从实际 doorbell [60:7] 取基址；显式 BAR/offset 必须命中相同高位，低七位是队列编码。
	// 同 Host 同基址属于不同 service 时存在查找歧义，拒绝发布；失败保持目录为空。
	extern protected function bit materialize_notify_records(output string	why);

	// 队列表按真实 service/qpair/IOVA 生成；任何平台策略越界都在窄字段赋值前拒绝。
	extern function bit queue_records(
		input dpu_cfg_scope		selection,
		input dpu_table_kind_e	kinds[$],
		output dpu_table_item_t	selected[$],
		output string			why
	);

	// 小型类别集合查询，只统一遍历条件，不建立第二个 callback 引擎。
	extern function bit kind_selected(
		input dpu_table_kind_e	kind,
		input dpu_table_kind_e	kinds[$]
	);

	// 只允许状态类别，调用者必须显式提供实测 PBA 容量和各自模块偏移。
	extern function bit get_state_context(
		input dpu_table_kind_e		kind,
		input dpu_function_key_t	owner,
		input int unsigned			index,
		output dpu_state_query_t	item,
		output string				why
	);

	// 同 PF 完整成员和实际 BDF/路由交付平台；缺映射/角色错误在调用纯规则前拒绝。
	extern function bit validate_pfvf_family(
		input dpu_function_key_t	owner,
		output string				why
	);

	// 重采样只构造参数副本，复用冻结身份做校验；不调用DPU resolver或PCIE build流程。
	extern function bit make_runtime_candidate(
		output dpu_env_cfg	candidate,
		output string		why
	);

	// 仅复制明确支持的输入与缓存；同一cfg/Host cfg、BAR、snapshot、pool和sequencer句柄保持不变。
	extern function void apply_runtime_candidate(input dpu_env_cfg	candidate);

	// 返回冻结 Function 的值副本；只读租约和 service，不依赖 PCIe 绑定或 ring。
	extern function void list_functions(output dpu_function_record_t records[$]);

	// 精确身份查询；未知 Function 或未发布快照返回 0，不回退 PF0。
	extern function bit get_function(
		input dpu_function_key_t		key,
		output dpu_function_record_t	record
	);

	// AF 额外资源只来自同一资源快照，不虚构 ring。
	extern function void list_af_extra_queues(output dpu_af_extra_queue_binding_t records[$]);

	// 发布仅接受同源且冻结的 device/resources/BAR；消息与分组先在局部值中验证。
	// 全部通过后才更新句柄及冻结值；首次或再次发布失败都保持原来的可见状态。
	extern function bit publish(
		input dpu_device_snapshot	device,
		input dpu_resource_snapshot	resources,
		input dpu_bar_map			map,
		output string				why
	);

	// 接收 VIO 缓存的最终需求；首次构建时生成固定 placement，重载时只刷新同一 service 的值。
	extern function void add_vio_service(
		input dpu_vio_service_t	service,
		input bit				create_request = 1
	);

	// 接收 VIO 全部实际 ring 导出；只校验资源关联，不分配内存或重新采样参数。
	// 资源身份错误不接收新队列；策略校验失败时保留实际队列供排查，不确认或释放 ring。
	extern function bit set_queues(
		input dpu_vio_queue_t	queues[$],
		output string			why
	);

	// 核对当前已导出的实际队列，拒绝释放后旧记录；VIO 的启停/确认仍由 VIO 管理。
	extern function bit check_queue(
		input dpu_vio_queue_t	queue,
		output string			why
	);

	// VIO 确认 DUT 静止且释放 ring 后调用；保留其他 Host 的实际目录和硬件行号。
	extern function void clear_host_queues(input int unsigned	host_id);
endclass

// 构造 authoring 输入和缺省 AF 身份；不读取参数、不分配 BAR/ring 或访问 DUT。
function dpu_env_cfg::new(string	name = "dpu_env_cfg");
	super.new(name);
	device_cfg                      = dpu_device_cfg::type_id::create("device_cfg");
	placement_cfg                   = dpu_resource_placement_cfg::type_id::create("placement_cfg");
	device_cfg.af_request.mode      = DPU_AF_SELECTED;
	device_cfg.af_request.requester = '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
endfunction

// 唯一参数构建入口：先采样规模/模板，再创建 Host/PF/VF/placement 和 Host 行为。
// 再调用幂等返回，不重新采样；已有输入的项目应把加载入口合入原构造点，省去生成循环。
// 默认生成器拒绝覆盖非空逻辑配置，避免重复追加 Host/PF/VF 和资源请求。
// base_test 无须逐项赋值；AIP-off 时保留默认值，但仍正常创建对象。
function void dpu_env_cfg::load_params();
	dpu_dut_caps				caps;
	dpu_host_cfg				host_template;
	dpu_resource_pool_config_t	profile;

	string	why;

	if (params_loaded) begin
		return;
	end

	if (
		(device_cfg.hosts.size() != 0) ||
		(device_cfg.functions.size() != 0) ||
		(placement_cfg.vio_requests.size() != 0) ||
		(placement_cfg.profiles.size() != 0)
	) begin
		`uvm_fatal("PROJECT_CFG", "default authoring cannot overwrite an existing DPU topology")
	end

	device_cfg.load_params("dpu");
	caps = device_cfg.dut_caps;

	if (!caps.validate(why)) begin
		`uvm_fatal("PROJECT_CFG", why)
	end

`ifdef AIP_CMDLINE_SV
	`DPU_AIP_UINT("dpu", longint unsigned, hosts, this.hosts)
	`DPU_AIP_UINT("dpu", longint unsigned, pfs_per_host, this.pfs_per_host)
	`DPU_AIP_UINT("dpu", longint unsigned, vfs_per_pf, this.vfs_per_pf)

`endif

	if (
		(hosts == 0) ||
		(hosts > caps.max_hosts) ||
		(pfs_per_host == 0) ||
		(pfs_per_host > caps.max_pfs_per_host) ||
		(pfs_per_host > 4) ||
		(vfs_per_pf > caps.max_vfs_per_pf)
	) begin
		`uvm_fatal("PROJECT_CFG", "Host/PF/VF counts exceed DUT or VIO source-id capacity")
	end

	if ((hosts * pfs_per_host * (1 + vfs_per_pf)) > caps.max_functions) begin
		`uvm_fatal("PROJECT_CFG", "total Function count exceeds DUT capability")
	end

`ifdef AIP_CMDLINE_SV
	`aip_string("dpu", reg_target, this.reg_target)
	`aip_int("dpu", bit, print_bar_map, this.print_bar_map)
`endif

	host_template = make_host_template();
	host_template.load_params("dpu");

	profile.name             = "virtio.qpair";
	profile.class_id         = '0;
	profile.kind             = DPU_RESOURCE_KIND_QUEUE;
	profile.capacity         = caps.vio_global_qpair_count;
	profile.max_per_function = caps.max_vio_net_qpairs_per_device;

	placement_cfg.profiles.push_back(profile);

	for (int	unsigned	h = 0; h < hosts; h++) begin
		dpu_host_cfg	host;
		bit [64:0]		base;
		bit [64:0]		limit;

		host = dpu_host_cfg::type_id::create($sformatf("host_%0d", h));
		host.copy_from(host_template);

		host.host_id                     = h;
		host.pcie_domains[0].key.host_id = h;

		base  = {1'b0, host.gpa_base} + h * 65'h0000_0100_0000_0000;
		limit = {1'b0, host.gpa_limit} + h * 65'h0000_0100_0000_0000;

		if (base[64] || limit[64]) begin
			`uvm_fatal("PROJECT_CFG", "Host GPA stride overflows")
		end

		host.gpa_base  = base[63:0];
		host.gpa_limit = limit[63:0];

		base  = {1'b0, host.pcie_domains[0].mmio_windows[0].base} + h * 65'h0000_0010_0000_0000;
		limit = {1'b0, host.pcie_domains[0].mmio_windows[0].limit} + h * 65'h0000_0010_0000_0000;

		if (base[64] || limit[64]) begin
			`uvm_fatal("PROJECT_CFG", "Host MMIO stride overflows")
		end

		host.pcie_domains[0].mmio_windows[0].base  = base[63:0];
		host.pcie_domains[0].mmio_windows[0].limit = limit[63:0];

		host.load_params($sformatf("dpu.h%0d", h));
		device_cfg.hosts.push_back(host);

		for (int	unsigned	pf = 0; pf < pfs_per_host; pf++) begin
			dpu_function_cfg	f;
			string				path;

			path = $sformatf("dpu.h%0d.pf%0d", h, pf);
			f    = make_function(h, pf, DPU_FUNCTION_PF, 0);

			f.load_params(path);
			device_cfg.functions.push_back(f);

			for (int	unsigned	vf = 0; vf < vfs_per_pf; vf++) begin
				f = make_function(h, pf, DPU_FUNCTION_VF, vf);
				f.load_params($sformatf("%s.vf%0d", path, vf));

				device_cfg.functions.push_back(f);

			end
		end
	end

	load_platform_params();
	load_function_routes();
	if (driver_layouts) begin
		use_driver_reference_layouts();
	end
	params_loaded = 1;
endfunction

// 构造全局 Host 模板；GPA 和 MMIO 分开，BDF 范围覆盖默认 PF/VF 规模。
// 每 Host 的 identity 和参数覆盖由 load_params 设置，不在这里解析实际地址。
function dpu_host_cfg dpu_env_cfg::make_host_template();
	dpu_host_cfg		host;
	dpu_pcie_domain_cfg	domain;
	dpu_mmio_window_cfg	window;
	dpu_bdf_range_t		bdf_range;

	host = dpu_host_cfg::type_id::create("host_template");

	host.has_gpa_aperture = 1;
	host.gpa_base         = 64'h0000_1000_0000_0000;
	host.gpa_limit        = host.gpa_base + 64'h1000_0000;

	domain     = dpu_pcie_domain_cfg::type_id::create("domain_template");
	domain.key = '{host_id: 0, segment_id: 0};

	bdf_range = '{first_bdf: 16'h0010, last_bdf: 16'h0fff};

	domain.bdf_ranges.push_back(bdf_range);

	window = dpu_mmio_window_cfg::type_id::create("mmio_template");

	window.base          = 64'h0000_0020_0000_0000;
	window.limit         = window.base + 64'h0000_0001_0000_0000;
	window.allowed_roles = '{DPU_BAR_DEVICE_MEMORY, DPU_BAR_MAILBOX, DPU_BAR_MSIX};

	domain.mmio_windows.push_back(window);
	domain.bar_placement_policy = DPU_BAR_PLACEMENT_RANDOM;

	host.pcie_domains.push_back(domain);

	return host;
endfunction

// 按 Host/PF/VF 身份创建 Function，并从 DUT caps 取得 BAR 规格。
// 全部 BAR/BDF 均由 resolver 最终放置；未知规格立即 fatal，不能制造设备能力。
function dpu_function_cfg dpu_env_cfg::make_function(
	int unsigned		host_id,
	int unsigned		pf_id,
	dpu_function_kind_e	kind,
	int unsigned		vf_id
);
	dpu_function_cfg	f;
	dpu_bar_role_e		roles[3] = '{DPU_BAR_DEVICE_MEMORY, DPU_BAR_MAILBOX, DPU_BAR_MSIX};
	string				why;

	f = dpu_function_cfg::type_id::create(
		$sformatf("fn_h%0d_pf%0d_%0d_vf%0d", host_id, pf_id, kind, vf_id));

	f.key = '{host_id: host_id, pf_id: pf_id, kind: kind, vf_id: vf_id};

	f.domain_key = '{host_id: host_id, segment_id: 0};

	f.bdf_mode = DPU_ALLOC_AUTO;
	f.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);

	foreach (roles[i]) begin
		dpu_bar_profile_t	profile;
		dpu_bar_request		bar;

		if (!device_cfg.dut_caps.lookup_bar_profile(kind, roles[i], profile, why)) begin
			`uvm_fatal("PROJECT_CFG", why)
		end

		bar = dpu_bar_request::type_id::create($sformatf("bar_%0d", i));

		bar.role        = profile.role;
		bar.even_bar_id = profile.even_bar_id;
		bar.size        = profile.size;
		bar.alignment   = profile.alignment;
		bar.placement   = DPU_ALLOC_AUTO;

		f.bars.push_back(bar);
	end

	return f;
endfunction

// build 或运行期候选加载表目标及消息模板；全局→Host→精确 Function 逐级覆盖。
// 固定键复用 AIP 宏，动态字段名复用同一 AIP 原生 API；存在性查询不消耗随机采样。
function void dpu_env_cfg::load_platform_params();
	string				paths[$];
	string				path;
	string				name;
	string				raw;
	string				target;

	dpu_table_kind_e	kinds[$] = '{
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
		DPU_TABLE_RNET
	};
	string	labels[$] = '{
		"bar",
		"af",
		"pfvf",
		"bdf",
		"completion_bdf",
		"tlp_prefix",
		"msix_linear",
		"msix_info",
		"msix_interval",
		"msix_control",
		"msix_table",
		"msix_function",
		"vio_notify",
		"qsch_q2tc",
		"qsch_n2g",
		"qsch_g2p",
		"qsch_spwrr",
		"qsch_tc_weight",
		"vtx",
		"vrx",
		"queue_aux",
		"rdma_notify",
		"qsch_rnet"
	};
	// 无 IP 参考模式：仅使用消息表使能，默认不节流、不自屏蔽；真实消息地址/数据仍必须提供。
	foreach (device_cfg.functions[f]) begin
		name = dpu_function_key_name(device_cfg.functions[f].key);
		if (!msix_policies.exists(name)) begin
			msix_policies[name] = '{
				table_only_enable: 1,
				interval_present: 1,
				self_mask_present: 1,
				default: 0
			};
		end
	end
`ifdef AIP_CMDLINE_SV
	`aip_int("dpu", bit, configure_public, this.configure_public)
	`aip_int("dpu", bit, configure_bdf, this.configure_bdf)
	`aip_int("dpu", bit, driver_layouts, this.driver_layouts)
	`aip_int("dpu", bit, verify_readback, this.verify_readback)
	begin
		longint unsigned	mode;
		longint unsigned	mode_offset;
		longint unsigned	spwrr;
		longint unsigned	tc_weight;
		bit					configure_controls;

		`DPU_AIP_UINT("dpu.qsch", longint unsigned, mode, qsch_mode)
		`DPU_AIP_UINT("dpu.qsch", longint unsigned, mode_offset, qsch_mode_offset)
		`DPU_AIP_UINT("dpu.qsch", longint unsigned, spwrr, qsch_spwrr)
		`DPU_AIP_UINT("dpu.qsch", longint unsigned, tc_weight, qsch_tc_weight)
		`aip_int("dpu.qsch", bit, configure_controls, qsch_configure_controls)

		if (mode > 1 || spwrr > 'hff || tc_weight > 32'hffffffff || mode_offset[1:0] != 0) begin
			`uvm_fatal("PROJECT_CFG",
					   "QSCH mode/weight width or mode register alignment is invalid")
		end

		qsch_mode               = mode;
		qsch_mode_offset        = mode_offset;
		qsch_spwrr              = spwrr;
		qsch_tc_weight          = tc_weight;
		qsch_configure_controls = configure_controls;
	end

	foreach (kinds[k]) begin
		paths.delete();
		case (kinds[k])
			DPU_TABLE_BAR: paths.push_back("dpu.bar_map");
			DPU_TABLE_MSIX_LINEAR, DPU_TABLE_MSIX_INFO, DPU_TABLE_MSIX_INTERVAL, DPU_TABLE_MSIX_CONTROL,
			DPU_TABLE_MSIX_TABLE, DPU_TABLE_MSIX_FUNCTION:
			paths.push_back("dpu.msix");
			DPU_TABLE_Q2TC, DPU_TABLE_N2G, DPU_TABLE_G2P, DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT, DPU_TABLE_RNET:
			paths.push_back("dpu.qsch");
			default: ;
		endcase
		paths.push_back({"dpu.", labels[k]});
		case (kinds[k])
			DPU_TABLE_VTX: paths.push_back("vio.vtx");
			DPU_TABLE_VRX: paths.push_back("vio.vrx");
			DPU_TABLE_NOTIFY: paths.push_back("vio.notify_table");
			default: ;
		endcase
		foreach (paths[i]) begin
			raw = aip_cmdline#(string)::get_cmdline_string("reg_target", paths[i]);
			if (raw != "") begin
				aip_cmdline#(string)::get_single_value("reg_target", paths[i], reg_target, target);
				table_layouts[kinds[k]].reg_target = target;
			end
		end
	end
	foreach (device_cfg.functions[f]) begin
		dpu_msix_policy_t	p;
		dpu_function_key_t	owner;
		bit					address_template_requested;
		bit					data_template_requested;

		owner = device_cfg.functions[f].key;
		name  = dpu_function_key_name(owner);
		if (msix_policies.exists(name)) p = msix_policies[name];
		else p = '{default: 0};
		paths = '{"dpu.msix", $sformatf("dpu.h%0d.msix", owner.host_id)};
		path  = $sformatf("dpu.h%0d.pf%0d", owner.host_id, owner.pf_id);
		if (owner.kind == DPU_FUNCTION_VF) path = {path, $sformatf(".vf%0d", owner.vf_id)};
		paths.push_back({path, ".msix"});
		foreach (paths[i]) begin
			longint unsigned	value;

			string				fields[$] = '{
				"table_bar",
				"table_offset",
				"table_size",
				"pba_bar",
				"pba_offset",
				"pba_words",
				"msg_addr_base",
				"msg_addr_stride",
				"msg_data_base",
				"msg_data_stride",
				"interval_rate",
				"interval_packets",
				"self_mask",
				"table_only_enable"
			};
			foreach (fields[j]) begin
				raw = aip_cmdline#(longint unsigned)::get_cmdline_string(fields[j], paths[i]);
				if (raw == "") continue;
				if (aip_str::str_find(raw, "-") >= 0)
					`uvm_fatal("PROJECT_CFG", "MSI-X unsigned field is negative")
				aip_cmdline#(longint unsigned)::get_single_value(fields[j], paths[i], 0, value);
				if ((fields[j] inside {"table_bar", "table_size", "pba_bar", "pba_words", "msg_data_base", "msg_data_stride"}) && value > 32'hffffffff)
					`uvm_fatal("PROJECT_CFG", "MSI-X field exceeds32 bits")
				if (fields[j] inside {"msg_addr_base", "msg_addr_stride"})
					address_template_requested = 1;
				if (fields[j] inside {"msg_data_base", "msg_data_stride"})
					data_template_requested = 1;
				case (fields[j])
					"table_bar":       p.table_bar = value;
					"table_offset": begin
						p.table_offset  = value;
						p.table_present = 1;
					end
					"table_size":      p.table_size = value;
					"pba_bar":         p.pba_bar = value;
					"pba_offset": begin
						p.pba_offset  = value;
						p.pba_present = 1;
					end
					"pba_words":       p.pba_words = value;
					"msg_addr_base": begin
						p.address_base    = value;
						p.address_present = 1;
					end
					"msg_addr_stride": p.address_stride = value;
					"msg_data_base": begin
						p.data_base    = value;
						p.data_present = 1;
					end
					"msg_data_stride": p.data_stride = value;
					"interval_rate": begin
						if (value > 65535)
							`uvm_fatal("PROJECT_CFG", "MSI-X interval rate exceeds16 bits")
						p.interval_entry.intrl_rate = value;
						p.interval_present          = 1;
					end
					"interval_packets": begin
						if (value > 65535)
							`uvm_fatal("PROJECT_CFG",
									   "MSI-X interval packet threshold exceeds16 bits")
						p.interval_entry.intrl_pnum = value;
						p.interval_present          = 1;
					end
					"self_mask": begin
						if (value > 1) `uvm_fatal("PROJECT_CFG", "MSI-X self_mask must be boolean")
						p.self_mask         = value;
						p.self_mask_present = 1;
					end
					"table_only_enable": begin
						if (value > 1)
							`uvm_fatal("PROJECT_CFG", "MSI-X table_only_enable must be boolean")
						p.table_only_enable = value;
					end
					default:           ;
				endcase
			end
		end
		msix_policies[name] = p;
		for (int	unsigned	v = 0; v < 64; v++) begin
			dpu_msix_message_t	m;
			bit					address_valid;
			bit					data_valid;
			bit [64:0]			address;
			bit [64:0]			data;

			m.owner         = owner;
			m.local_vector  = v;
			m.global_vector = 0;
			m.masked        = 0;
			address         = {1'b0, p.address_base} + 65'(v) * p.address_stride;
			data            = 65'(p.data_base) + 65'(v) * p.data_stride;
			address_valid   = p.address_present;
			data_valid      = p.data_present;
			m.address       = address[63:0];
			m.data          = data[31:0];
			// 恢复后未提供该向量的新值时保留快照模板；显式新base/stride仍可重算整组。
			if (message_templates.exists(name) && message_templates[name].exists(v)) begin
				if (!address_template_requested) begin
					m.address     = message_templates[name][v].address;
					address       = m.address;
					address_valid = 1;
				end
				if (!data_template_requested) begin
					m.data     = message_templates[name][v].data;
					data       = m.data;
					data_valid = 1;
				end
				m.masked = message_templates[name][v].masked;
			end
			foreach (paths[i]) begin
				longint unsigned	value;
				string				vector_path;
				string				fields[$] = '{"msg_addr", "msg_data", "masked"};

				vector_path = {paths[i], $sformatf(".v%0d", v)};
				foreach (fields[j]) begin
					raw =
						aip_cmdline#(longint unsigned)::get_cmdline_string(fields[j], vector_path);
					if (raw == "") continue;
					if (aip_str::str_find(raw, "-") >= 0)
						`uvm_fatal("PROJECT_CFG", "negative MSI-X vector value")
					aip_cmdline#(longint unsigned)::get_single_value(fields[j], vector_path, 0,
																	 value);
					case (fields[j])
						"msg_addr": begin
							m.address     = value;
							address_valid = 1;
							address       = value;
						end
						"msg_data": begin
							if (value > 32'hffffffff)
								`uvm_fatal("PROJECT_CFG", "MSI-X data exceeds32 bits")
							m.data     = value;
							data_valid = 1;
							data       = value;
						end
						"masked": begin
							if (value > 1) `uvm_fatal("PROJECT_CFG", "MSI-X masked must be0/1")
							m.masked = value;
						end
					endcase
				end
			end
			if ((address_valid && address[64]) || (data_valid && data > 32'hffffffff))
				`uvm_fatal("PROJECT_CFG", "MSI-X template overflow")
			if (address_valid && data_valid) message_templates[name][v] = m;
		end
	end
	// 平台表策略沿同一全局→Host→精确 service 路径加载；资源几何仍由核心冻结合同拥有。
	foreach (device_cfg.functions[f]) begin
		dpu_vio_policy_t	q;
		dpu_service_key_t	service;
		bit					provided;

		string				fields[$] = '{
			"vtx.dma_info",
			"vtx.tail_buf_id_dis",
			"vtx.redraw_en",
			"vtx.high_speed_mode",
			"vtx.seg_en",
			"vtx.interl_seg_en",
			"vrx.dsc_pre_max_num",
			"vrx.dsc_pre_read_threshold",
			"vrx.dsc_dma_num",
			"vrx.dsc_mode",
			"vrx.payload_dsc_len",
			"vrx.head_dsc_len",
			"qsch.net_base",
			"qsch.net_stride",
			"qsch.group_id",
			"qsch.cos",
			"qsch.eth_ports",
			"qsch.ets",
			"qsch.distinguish_business",
			"qsch.ets_priority",
			"fpga",
			"prefetch_start",
			"prefetch_slots",
			"notify_net_pair5",
			"notify_table_bar",
			"notify_table_offset"
		};
		service.function_key        = device_cfg.functions[f].key;
		service.service_kind        = DPU_SERVICE_VIO_NET;
		service.service_instance_id = 0;
		name                        = dpu_service_key_name(service);
		provided                    = vio_policies.exists(name);
		if (provided) q = vio_policies[name];
		else q = '{service_key: service, prefetch_ram: "", default: 0};
		paths = '{"dpu", "vio", $sformatf("vio.h%0d", service.function_key.host_id)};
		path =
			$sformatf("vio.h%0d.pf%0d", service.function_key.host_id, service.function_key.pf_id);
		if (service.function_key.kind == DPU_FUNCTION_VF)
			path = {path, $sformatf(".vf%0d", service.function_key.vf_id)};
		paths.push_back({path, ".i0"});
		foreach (paths[i]) begin
			raw = (paths[i] == "dpu") ? "" :
				aip_cmdline#(string)::get_cmdline_string("prefetch_ram", paths[i]);
			if (raw != "") begin
				aip_cmdline#(string)::get_single_value("prefetch_ram", paths[i], "",
													   q.prefetch_ram);
				provided = 1;
			end
			foreach (fields[j]) begin
				longint unsigned	value;
				// dpu.qsch 提供全局调度策略，VIO 路径只覆盖相同字段。
				if (paths[i] == "dpu" && aip_str::str_find(fields[j], "qsch.") != 0) continue;
				raw = aip_cmdline#(longint unsigned)::get_cmdline_string(fields[j], paths[i]);
				if (raw == "") continue;
				if (aip_str::str_find(raw, "-") >= 0)
					`uvm_fatal("PROJECT_CFG", "negative platform queue policy")
				aip_cmdline#(longint unsigned)::get_single_value(fields[j], paths[i], 0, value);
				provided = 1;
				case (fields[j])
					"vtx.dma_info": begin
						if (value > 4'hf)
							`uvm_fatal("PROJECT_CFG", "vtx.dma_info exceeds declared width")
						q.vtx.dma_info = value;
					end
					"vtx.tail_buf_id_dis": begin
						if (value > 1'h1)
							`uvm_fatal("PROJECT_CFG", "vtx.tail_buf_id_dis exceeds declared width")
						q.vtx.tail_buf_id_dis = value;
					end
					"vtx.redraw_en": begin
						if (value > 1'h1)
							`uvm_fatal("PROJECT_CFG", "vtx.redraw_en exceeds declared width")
						q.vtx.redraw_en = value;
					end
					"vtx.high_speed_mode": begin
						if (value > 1'h1)
							`uvm_fatal("PROJECT_CFG", "vtx.high_speed_mode exceeds declared width")
						q.vtx.high_speed_mode = value;
					end
					"vtx.seg_en": begin
						if (value > 1'h1)
							`uvm_fatal("PROJECT_CFG", "vtx.seg_en exceeds declared width")
						q.vtx.seg_en = value;
					end
					"vtx.interl_seg_en": begin
						if (value > 1'h1)
							`uvm_fatal("PROJECT_CFG", "vtx.interl_seg_en exceeds declared width")
						q.vtx.interl_seg_en = value;
					end
					"vrx.dsc_pre_max_num": begin
						if (value > 3'h7)
							`uvm_fatal("PROJECT_CFG", "vrx.dsc_pre_max_num exceeds declared width")
						q.vrx.dsc_pre_max_num = value;
					end
					"vrx.dsc_pre_read_threshold": begin
						if (value > 2'h3)
							`uvm_fatal("PROJECT_CFG",
									   "vrx.dsc_pre_read_threshold exceeds declared width")
						q.vrx.dsc_pre_read_threshold = value;
					end
					"vrx.dsc_dma_num": begin
						if (value > 2'h3)
							`uvm_fatal("PROJECT_CFG", "vrx.dsc_dma_num exceeds declared width")
						q.vrx.dsc_dma_num = value;
					end
					"vrx.dsc_mode": begin
						if (value > 2'h3)
							`uvm_fatal("PROJECT_CFG", "vrx.dsc_mode exceeds declared width")
						q.vrx.dsc_mode = value;
					end
					"vrx.payload_dsc_len": begin
						if (value > 3'h7)
							`uvm_fatal("PROJECT_CFG", "vrx.payload_dsc_len exceeds declared width")
						q.vrx.payload_dsc_len = value;
					end
					"vrx.head_dsc_len": begin
						if (value > 2'h3)
							`uvm_fatal("PROJECT_CFG", "vrx.head_dsc_len exceeds declared width")
						q.vrx.head_dsc_len = value;
					end
					"qsch.net_base": begin
						if (value > 32'hffffffff)
							`uvm_fatal("PROJECT_CFG", "qsch.net_base exceeds declared width")
						q.net_base = value;
					end
					"qsch.net_stride": begin
						if (value > 32'hffffffff)
							`uvm_fatal("PROJECT_CFG", "qsch.net_stride exceeds declared width")
						q.net_stride = value;
					end
					"qsch.group_id": begin
						if (value > 32'hffffffff)
							`uvm_fatal("PROJECT_CFG", "qsch.group_id exceeds declared width")
						q.group_id = value;
					end
					"qsch.cos": begin
						if (value > 32'hffffffff)
							`uvm_fatal("PROJECT_CFG", "qsch.cos exceeds declared width")
						q.cos = value;
					end
					"qsch.eth_ports": begin
						if (value > 32'hffffffff)
							`uvm_fatal("PROJECT_CFG", "qsch.eth_ports exceeds declared width")
						q.eth_ports = value;
					end
					"qsch.ets": begin
						if (value > 1'h1)
							`uvm_fatal("PROJECT_CFG", "qsch.ets exceeds declared width")
						q.ets = value;
					end
					"qsch.distinguish_business": begin
						if (value > 1'h1)
							`uvm_fatal("PROJECT_CFG",
									   "qsch.distinguish_business exceeds declared width")
						q.distinguish_business = value;
					end
					"qsch.ets_priority": begin
						if (value > 32'hffffffff)
							`uvm_fatal("PROJECT_CFG", "qsch.ets_priority exceeds declared width")
						q.ets_priority = value;
					end
					"fpga": begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "fpga exceeds declared width")
						q.fpga = value;
					end
					"prefetch_start": begin
						if (value > 32'hffffffff)
							`uvm_fatal("PROJECT_CFG", "prefetch_start exceeds declared width")
						q.prefetch_start = value;
					end
					"prefetch_slots": begin
						if (value > 32'hffffffff)
							`uvm_fatal("PROJECT_CFG", "prefetch_slots exceeds declared width")
						q.prefetch_slots = value;
					end
					"notify_net_pair5": begin
						if (value > 1'h1)
							`uvm_fatal("PROJECT_CFG", "notify_net_pair5 exceeds declared width")
						q.notify_net_pair5 = value;
					end
					"notify_table_bar": begin
						if (value > 32'hffffffff)
							`uvm_fatal("PROJECT_CFG", "notify_table_bar exceeds declared width")
						// 任一显式字段都表示指定查找基址；另一字段沿用原值/默认零。
						q.notify_table_bar           = value;
						q.notify_table_base_provided = 1;
					end
					"notify_table_offset": begin
						q.notify_table_offset        = value;
						q.notify_table_base_provided = 1;
					end
					default: ;
				endcase
			end
		end
		if (provided) vio_policies[dpu_service_key_name(service)] = q;
	end
`endif
endfunction

// 采用驱动中已经核对的模块/表偏移；只补缺项，保留用户提供的完整布局和目标覆盖。
// 空目标由 frozen_reg_target 解析；短名字通常按 owner Host 访问，Notify/MSI-X 线性表由 Host0 管理。
function void dpu_env_cfg::set_driver_layout(
	input dpu_table_kind_e		kind,
	input logic [63:0]			module_offset,
	input logic [63:0]			table_offset,
	input int unsigned			entry_bytes,
	input int unsigned			capacity,
	input dpu_index_policy_e	index_policy
);
	string	target;
	string	access_target;

	if (table_layouts.exists(kind) && table_layouts[kind].provided) return;
	target = table_layouts.exists(kind) ? table_layouts[kind].reg_target : "";
	access_target = target == "" ? reg_target : target;
	table_layouts[kind] = '{
		provided: 1,
		reg_target: target,
		access_uses_owner_host: (access_target.substr(0, 0) != "h"),
		module_offset: module_offset,
		table_offset: table_offset,
		entry_bytes: entry_bytes,
		capacity: capacity,
		index_policy: index_policy,
		required: !(kind inside {DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT}),
		default: 0
	};

	// 多 Host 共用全局查找表；短目标默认走 Host0，显式 hH 目标保持平台选择。
	if (kind inside {DPU_TABLE_NOTIFY, DPU_TABLE_MSIX_LINEAR} && access_target.substr(0, 0) != "h") begin
		table_layouts[kind].access_host_provided   = 1;
		table_layouts[kind].access_host            = 0;
		table_layouts[kind].access_uses_owner_host = 0;
	end
endfunction

// 安装 VIO/QSCH、BDF 与 MSI-X 的驱动参考布局；BAR/PFVF 等其他公共表仍由平台声明。
// VTX/VRX 使用四次 DWORD 数据写和控制触发端口，不把间接表当作线性 MMIO。
function void dpu_env_cfg::use_driver_reference_layouts();
	set_driver_layout(DPU_TABLE_BDF, 'h100000, 'h08000, 4, 128, DPU_INDEX_EXPLICIT);
	set_driver_layout(DPU_TABLE_MSIX_LINEAR, 'h080000, 'h40000, 8, 2048, DPU_INDEX_EXPLICIT);
	set_driver_layout(DPU_TABLE_MSIX_INFO, 'h100000, 'h50000, 4, 1024, DPU_INDEX_GLOBAL_VECTOR);
	set_driver_layout(DPU_TABLE_MSIX_INTERVAL, 'h100000, 'h40000, 4, 1024, DPU_INDEX_GLOBAL_VECTOR);
	set_driver_layout(DPU_TABLE_MSIX_TABLE, 'h100000, 'h20000, 16, 1024, DPU_INDEX_GLOBAL_VECTOR);
	set_driver_layout(DPU_TABLE_NOTIFY, 'h080000, 'h20000, 16, 512, DPU_INDEX_EXPLICIT);
	set_driver_layout(DPU_TABLE_Q2TC, 'hb00000, 'h10000, 4, 2048, DPU_INDEX_GLOBAL_QPAIR);
	set_driver_layout(DPU_TABLE_N2G, 'hb00000, 'h12000, 4, 1024, DPU_INDEX_EXPLICIT);
	set_driver_layout(DPU_TABLE_G2P, 'hb00000, 'h14000, 4, 1024, DPU_INDEX_EXPLICIT);
	set_driver_layout(DPU_TABLE_SPWRR, 'hb00000, 'h16000, 4, 1024, DPU_INDEX_EXPLICIT);
	set_driver_layout(DPU_TABLE_TC_WEIGHT, 'hb00000, 'h18000, 4, 1024, DPU_INDEX_EXPLICIT);

	if (!table_layouts.exists(DPU_TABLE_VTX) || !table_layouts[DPU_TABLE_VTX].provided) begin
		set_driver_layout(DPU_TABLE_VTX, 'h880000, 'h10000, 16, 2048, DPU_INDEX_GLOBAL_QPAIR);
		table_layouts[DPU_TABLE_VTX].indirect     = 1;
		table_layouts[DPU_TABLE_VTX].data_port    = 'h134;
		table_layouts[DPU_TABLE_VTX].control_port = 'h130;
		table_layouts[DPU_TABLE_VTX].index_mask   = 'h7ff;
		table_layouts[DPU_TABLE_VTX].trigger_mask = 'h2000;
	end

	if (!table_layouts.exists(DPU_TABLE_VRX) || !table_layouts[DPU_TABLE_VRX].provided) begin
		set_driver_layout(DPU_TABLE_VRX, 'h900000, 'h10000, 16, 2048, DPU_INDEX_GLOBAL_QPAIR);
		table_layouts[DPU_TABLE_VRX].indirect     = 1;
		table_layouts[DPU_TABLE_VRX].data_port    = 'h204;
		table_layouts[DPU_TABLE_VRX].control_port = 'h200;
		table_layouts[DPU_TABLE_VRX].index_mask   = 'hffff;
		table_layouts[DPU_TABLE_VRX].trigger_mask = 'h10000;
	end
endfunction

// 无 PCIe IP 的参考接线约定为各 Host PF0 / VF=-1 / wire requester=0 / vport=0。
// 这是 Intel sideband/DMA 软件路由，绝不表示已向 DUT 写 BDF/PFVF 表。
// 显式 policy 优先作为缺省值；CLI 可覆盖字段，其余 PF/VF 不猜 requester/Intel 身份。
function void dpu_env_cfg::load_function_routes();
	foreach (device_cfg.functions[f]) begin
		dpu_function_key_t		owner;
		dpu_function_policy_t	policy;
		string					name;
		string					path;
		bit						provided;
		bit [3:0]				fields_present;

		owner    = device_cfg.functions[f].key;
		name     = dpu_function_key_name(owner);
		provided = function_policies.exists(name);
		if (provided) begin
			policy = function_policies[name];
		end else begin
			policy   = '{key: owner, mode: DPU_HOST_EP, intel_vf: -1, default: 0};
			provided = owner.kind == DPU_FUNCTION_PF && owner.pf_id == 0 && vfs_per_pf == 0;
		end

		if (!function_policies.exists(name)) policy.bdf_index = policy.vport;
		fields_present = provided ? 4'hf : 0;
		path           = $sformatf("dpu.h%0d.pf%0d", owner.host_id, owner.pf_id);
		if (owner.kind == DPU_FUNCTION_VF) path = {path, $sformatf(".vf%0d", owner.vf_id)};
`ifdef AIP_CMDLINE_SV
		begin
			string	fields[$] = '{"requester", "intel_pf", "intel_vf", "vport"};

			foreach (fields[i]) begin
				string			raw;
				longint signed	value;

				raw = aip_cmdline#(longint signed)::get_cmdline_string(fields[i], path);
				if (raw == "") continue;
				aip_cmdline#(longint signed)::get_single_value(fields[i], path, 0, value);
				if ((i == 0 && (value < 0 || value > 65535)) ||
					(i == 1 && (value < 0 || value > 7)) ||
					(i == 2 && ((owner.kind == DPU_FUNCTION_PF && value != -1) ||
						(owner.kind == DPU_FUNCTION_VF && (value < 0 || value > 2047)))) ||
					(i == 3 && (value < 0 || value > 1023))) begin
					`uvm_fatal("PROJECT_CFG", {path, ".", fields[i],
											   " is outside the Intel/VIO field range"})
				end

				case (i)
					0: policy.requester = value;
					1: policy.intel_pf = value;
					2: policy.intel_vf = value;
					3: policy.vport = value;
				endcase
				fields_present[i] = 1;
			end
		end
		begin
			string				raw;
			longint unsigned	value;

			if (!function_policies.exists(name)) policy.bdf_index = policy.vport;
			raw = aip_cmdline#(longint unsigned)::get_cmdline_string("bdf_index", path);
			if (raw != "") begin
				if (aip_str::str_find(raw, "-") >= 0)
					`uvm_fatal("PROJECT_CFG", "bdf_index must be unsigned")
				aip_cmdline#(longint unsigned)::get_single_value("bdf_index", path,
																 policy.bdf_index, value);
				if (value >= 128)
					`uvm_fatal("PROJECT_CFG", "bdf_index exceeds 128-row requester table")
				policy.bdf_index = value;
			end
		end
`endif
		if (fields_present != 0 && fields_present != 4'hf) begin
			`uvm_fatal("PROJECT_CFG", {
					   path, " requires requester, intel_pf, intel_vf and vport together"})
		end
		if (fields_present == 4'hf) function_policies[name] = policy;
	end
endfunction

// 以实际 qpair/net_id 和最终管理 BAR 为键合并默认调度项，覆盖所有实际消费者。
// 每代从用户 catalog 重建 frozen_controls；同一地址的显式项优先，不改变其值或声明范围。
// 非 ETS/ETS 必须与全局模式一致；范围/布局失败在任何 VIO MMIO 写入前返回原因。
function bit dpu_env_cfg::materialize_qsch_controls(output string	why);
	dpu_vio_qpair_binding_t	pairs[$];
	dpu_table_kind_e		kinds[$] = '{DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT};
	bit						automatic_item[int];

	frozen_controls = platform_controls;
	why             = "";
	if (!qsch_configure_controls) return 1;
	if (qsch_mode > 1 || $isunknown({qsch_mode_offset, qsch_spwrr, qsch_tc_weight}) || qsch_mode_offset[1:0] != 0 || qsch_spwrr > 'hff) begin
		why = "QSCH mode/weight width or mode register alignment is invalid";
		return 0;
	end

	resource_snapshot.list_vio_bindings(pairs);
	foreach (pairs[p]) begin
		dpu_vio_policy_t	policy;
		dpu_vio_service_t	requirement;
		logic [63:0]		net_id;
		string				name;

		name = dpu_service_key_name(pairs[p].service_key);
		if (!frozen_policies.exists(name)) begin
			why = {"queue platform policy missing: ", name};
			return 0;
		end
		policy = frozen_policies[name];
		if (!services.exists(name)) begin
			why = {"service demand missing: ", name};
			return 0;
		end
		requirement = services[name];
		if (!requirement.tx_enable) continue;
		if (policy.ets != qsch_mode) begin
			why = {"QSCH mode disagrees with service ets: ", name};
			return 0;
		end
		net_id = 64'(policy.net_base) + 64'(pairs[p].virtio_pair_index) * policy.net_stride;
		if (net_id >= 1024) begin
			why = {"QSCH net_id exceeds 10 bits: ", name};
			return 0;
		end

		foreach (kinds[k]) begin
			dpu_control_cfg_t	item;
			int					match;

			item.owner = pairs[p].service_key.function_key;
			if (!make_context(kinds[k], item.owner, int'(net_id), 0, item.ctx, why)) return 0;
			match = -1;
			foreach (frozen_controls[c]) begin
				dpu_table_ctx_t	ctx;

				if (frozen_controls[c].ctx.kind != kinds[k]) continue;
				if (!make_context(
						kinds[k],
						frozen_controls[c].owner,
						frozen_controls[c].ctx.table_index,
						0,
						ctx,
						why
					))
					return 0;
				if (ctx.record_key == item.ctx.record_key) begin
					match = c;
					break;
				end
			end

			if (match == -1) begin
				item.consumers = '{pairs[p].service_key};
				item.consumers_complete = 1;
				item.value = kinds[k] == DPU_TABLE_SPWRR ? 128'(qsch_spwrr) : 128'(qsch_tc_weight);
				item.writable_mask = kinds[k] == DPU_TABLE_SPWRR ? 128'hff : 128'hffffffff;
				automatic_item[frozen_controls.size()] = 1;
				frozen_controls.push_back(item);
			end else if (automatic_item.exists(match)) begin
				bit	found;

				found = 0;
				foreach (frozen_controls[match].consumers[c]) begin
					if (dpu_service_key_name(frozen_controls[match].consumers[c]) == name)
						found = 1;
				end
				if (!found) frozen_controls[match].consumers.push_back(pairs[p].service_key);
			end
		end
	end
	return 1;
endfunction

// 以最终 service 完成模式选择 Function；轮询且未要求公共配置时保持空范围，不误选全部。
// MSI-X pair 必须有对应未屏蔽消息；公共模式另保留显式消息的 AF/其他 Function。
// 在 env connect 发布资源后、任何 DUT 写入前调用；缺 Host cfg/快照时明确返回依赖错误。
function bit dpu_env_cfg::select_msix_scope(
	output dpu_cfg_scope	scope,
	output string			why
);
	dpu_vio_qpair_binding_t	pairs[$];
	dpu_function_key_t		keys[$];
	int unsigned			bars[$];
	bit						seen[string];

	scope = null;
	why   = "MSI-X selection requires published DPU resources";
	if (resource_snapshot == null || device_snapshot == null) return 0;
	resource_snapshot.list_vio_bindings(pairs);
	foreach (pairs[p]) begin
		dpu_vio_service_t	requirement;
		bit					found;
		string				name;

		name = dpu_service_key_name(pairs[p].service_key);
		if (!services.exists(name)) begin
			why = {"service demand missing: ", name};
			return 0;
		end
		requirement = services[name];
		if (!requirement.enabled || !requirement.msix_enable) continue;
		found = 0;
		foreach (frozen_messages[m]) begin
			if (!dpu_same_function_key(frozen_messages[m].owner, pairs[p].service_key.function_key) || frozen_messages[m].local_vector != pairs[p].local_msix_vector_id)
				continue;
			if (frozen_messages[m].global_vector != pairs[p].global_msix_vector_id ||
				frozen_messages[m].masked !== 1'b0 ||
				$isunknown({frozen_messages[m].address, frozen_messages[m].data})) begin
				why = "MSI-X queue message is masked, unknown or disagrees with allocated vector";
				return 0;
			end
			found = 1;
		end
		if (!found) begin
			why = {
				"MSI-X completion requires explicit message address/data: ",
				dpu_service_key_name(pairs[p].service_key)
			};
			return 0;
		end
		name = dpu_function_key_name(pairs[p].service_key.function_key);
		if (!seen.exists(name)) begin
			seen[name] = 1;
			keys.push_back(pairs[p].service_key.function_key);
		end
	end
	if (configure_public) begin
		foreach (frozen_messages[m]) begin
			string	name;

			name = dpu_function_key_name(frozen_messages[m].owner);
			if (!seen.exists(name)) begin
				seen[name] = 1;
				keys.push_back(frozen_messages[m].owner);
			end
		end
	end
	msix_linear_records.delete();
	msix_directory_ready = 1;
	why                  = "";
	if (keys.size() == 0) return 1;
	scope = new("msix_scope", device_snapshot, keys, bars);
	if (!scope.validate(device_snapshot, why)) return 0;
	return materialize_msix_linear_records(why, scope);
endfunction

// 驱动按 Host/PFVF 排 Function、按 local vector 排组内项；global vector 仅作为查找结果。
// 默认独立 API 首次消费完整冻结消息；默认 body 显式选择完成模式范围后生成紧凑目录。
// 所有行必须落到同一管理 bank，失败不发布半份目录，也不按局部 public scope 重新编号。
function bit dpu_env_cfg::materialize_msix_linear_records(
	output string		why,
	input dpu_cfg_scope	scope
);
	dpu_table_item_t		pending[$];
	dpu_function_record_t	functions[$];
	string					owner_by_key[int unsigned];
	bit						checked_family[string];

	msix_directory_ready = 0;
	msix_linear_records.delete();
	why = "";
	list_functions(functions);
	foreach (frozen_messages[m]) begin
		dpu_function_policy_t	policy;
		dpu_msix_linear_entry_t	entry;
		dpu_table_item_t		record;
		string					name;
		int unsigned			lookup_key;

		if (scope != null && !scope.selects(frozen_messages[m].owner)) continue;
		name = dpu_function_key_name(frozen_messages[m].owner);
		if (!frozen_functions.exists(name)) begin
			why = {"MSI-X Function routing policy missing: ", name};
			return 0;
		end
		policy = frozen_functions[name];
		if (!checked_family.exists(name)) begin
			if (!validate_pfvf_family(policy.key, why)) return 0;
			checked_family[name] = 1;
		end
		if (policy.key.host_id >= 8 || policy.pfvf >= 1024 ||
			frozen_messages[m].local_vector >= 512 || frozen_messages[m].global_vector >= 8192) begin
			why = "MSI-X linear field exceeds screenshot encoding";
			return 0;
		end
		lookup_key = (policy.key.host_id << 19) | (policy.pfvf << 9) | frozen_messages[m].local_vector;
		if (owner_by_key.exists(lookup_key)) begin
			why = "duplicate MSI-X Host/PFVF/local-vector lookup key";
			return 0;
		end
		owner_by_key[lookup_key] = name;
		entry                    = '0;
		entry.global_msix_idx    = frozen_messages[m].global_vector;
		entry.host_id            = policy.key.host_id;
		entry.pfvf_id            = policy.pfvf;
		entry.local_msix_idx     = frozen_messages[m].local_vector;
		record.owner             = frozen_messages[m].owner;
		record.has_queue         = 0;
		record.entry             = 128'(entry);
		record.enable_mask       = 0;
		record.enable_value      = 0;
		record.consumers.delete();
		record.dependencies.delete();
		foreach (functions[f]) begin
			if (dpu_same_function_key(functions[f].key, record.owner))
				record.consumers = functions[f].services;
		end
		pending.push_back(record);
	end
	pending.sort() with (item.entry[21:0]);
	if (pending.size() > 2048) begin
		why = "MSI-X linear single-bank image exceeds 2048 rows";
		return 0;
	end
	foreach (pending[i]) begin
		if (!make_context(DPU_TABLE_MSIX_LINEAR, pending[i].owner, i, 0, pending[i].ctx, why))
			return 0;
		if (i != 0 && (
			pending[i].ctx.target.canonical_name != pending[0].ctx.target.canonical_name ||
			pending[i].ctx.layout.module_offset != pending[0].ctx.layout.module_offset ||
			pending[i].ctx.layout.table_offset != pending[0].ctx.layout.table_offset ||
			pending[i].ctx.layout.capacity != pending[0].ctx.layout.capacity
		)) begin
			why = "MSI-X linear directory requires one management window; set dpu.msix_linear.reg_target";
			return 0;
		end
	end
	msix_linear_records  = pending;
	msix_directory_ready = 1;
	return 1;
endfunction

// 公共向量来自资源快照，AF 额外资源也能在没有任何 VIO service 时产生消息项。
function bit dpu_env_cfg::materialize_messages(
	input dpu_resource_snapshot	resources,
	output string				why
);
	dpu_vio_qpair_binding_t			pairs[$];
	dpu_af_extra_queue_binding_t	extras[$];

	why = "resource snapshot missing";
	if (resources == null) return 0;
	if (!message_inputs_saved) begin
		authored_messages    = messages;
		message_inputs_saved = 1;
	end
	resources.list_vio_bindings(pairs);
	resources.list_af_extra_queue_bindings(extras);
	foreach (pairs[i])
	if (!add_message(
			pairs[i].service_key.function_key,
			pairs[i].local_msix_vector_id,
			pairs[i].global_msix_vector_id,
			why
		))
		return 0;
	foreach (extras[i])
	if (!add_message(
			extras[i].af_function_key,
			extras[i].local_msix_vector_id,
			extras[i].global_msix_vector_id,
			why
		))
		return 0;
	why = "";
	return 1;
endfunction

// 同一共享向量只登记一次；显式消息优先但必须与冻结向量身份一致。
function bit dpu_env_cfg::add_message(
	input dpu_function_key_t	owner,
	input int unsigned			local_vector,
	input int unsigned			global_vector,
	output string				why
);
	string				name;
	dpu_msix_message_t	m;

	name = dpu_function_key_name(owner);
	why  = "";
	foreach (messages[i]) begin
		if (dpu_same_function_key(messages[i].owner, owner) && messages[i].local_vector == local_vector) begin
			if (messages[i].global_vector != global_vector) begin
				why = "explicit shared MSI-X vector conflicts with DPU binding";
				return 0;
			end
			return 1;
		end
	end
	if (!message_templates.exists(name) || !message_templates[name].exists(local_vector)) return 1;
	m               = message_templates[name][local_vector];
	m.global_vector = global_vector;
	messages.push_back(m);
	return 1;
endfunction

// 仅 PF0/no-VF 且 Intel/PFVF 均为参考编码时通过；其余家族保留平台真实关系校验。
function bit dpu_env_cfg::validate_pfvf_relationship(
	input dpu_pfvf_relationship_t	family,
	output string					why
);
	if (family.functions.size() == 1 && family.policies.size() == 1 &&
		family.functions[0].key.kind == DPU_FUNCTION_PF && family.functions[0].key.pf_id == 0 &&
		family.policies[0].intel_pf == 0 && family.policies[0].intel_vf == -1 &&
		family.policies[0].pfvf == 0) begin
		why = "";
		return 1;
	end
	why = "platform PFVF relationship validator is required beyond the PF0/no-VF reference";
	return 0;
endfunction

// 从平台已冻结布局解析真实目标，图片相对偏移单独保留；整个操作范围先检查。
// 缺失布局时仅按行列出表名、归属与修复入口，不展开完整配置或内部结构体。
function bit dpu_env_cfg::make_context(
	input dpu_table_kind_e		kind,
	input dpu_function_key_t	owner,
	input int unsigned			index,
	input longint unsigned		generation,
	output dpu_table_ctx_t		ctx,
	output string				why
);
	dpu_table_layout_t	layout;
	bit [64:0]			offset;
	bit [63:0]			address;
	bit [63:0]			expected_offset;
	string				name;

	why = "";
	if (bar_map == null) begin
		why = "BAR registry is unavailable; publish the environment configuration first";
		return 0;
	end
	if (frozen_layouts.exists(kind)) layout = frozen_layouts[kind];
	else begin
		layout.provided               = 0;
		layout.reg_target             = "";
		layout.access_host_provided   = 0;
		layout.access_host            = 0;
		layout.access_uses_owner_host = 0;
		layout.module_offset          = 0;
		layout.table_offset           = 0;
		layout.capacity               = 0;
		layout.entry_bytes            = 0;
		layout.index_policy           = DPU_INDEX_EXPLICIT;
		layout.indirect               = 0;
		layout.data_port              = 0;
		layout.control_port           = 0;
		layout.index_mask             = 0;
		layout.control_fixed          = 0;
		layout.trigger_mask           = 0;
		layout.index_shift            = 0;
		layout.required               = 0;
	end
	if (kind inside {DPU_TABLE_MSIX_TABLE, DPU_TABLE_MSIX_PBA} && frozen_msix_policies.exists(dpu_function_key_name(owner))) begin
		dpu_msix_policy_t	p;
		bit					provided;
		bit [63:0]			base;
		int unsigned		bar_id;

		p = frozen_msix_policies[dpu_function_key_name(owner)];
		if (p.table_present && p.pba_present && p.table_bar == p.pba_bar) begin
			bit [64:0]	table_end;
			bit [64:0]	pba_end;

			table_end = {1'b0, p.table_offset} + 65'(p.table_size) * 16;
			pba_end   = {1'b0, p.pba_offset} + 65'(p.pba_words) * 8;
			if ($isunknown({p.table_offset, p.pba_offset}) || table_end[64] || pba_end[64] ||
					({1'b0, p.table_offset} < pba_end && {1'b0, p.pba_offset} < table_end)) begin
				why = "MSI-X table/PBA declarations overlap or overflow";
				return 0;
			end
		end
		provided = kind == DPU_TABLE_MSIX_TABLE ? p.table_present : p.pba_present;
		if (provided) begin
			base   = kind == DPU_TABLE_MSIX_TABLE ? p.table_offset : p.pba_offset;
			bar_id = kind == DPU_TABLE_MSIX_TABLE ? p.table_bar : p.pba_bar;
			if (base < (kind == DPU_TABLE_MSIX_TABLE ? 'h20000 : 'h10000) || $isunknown(base) || (kind == DPU_TABLE_MSIX_TABLE &&
					  (base[3:0] != 0 || p.table_size == 0 || p.table_size > 1024)) ||
					(kind == DPU_TABLE_MSIX_PBA && (base[2:0] != 0 || p.pba_words == 0))) begin
				why = "explicit MSI-X/PBA layout has invalid offset/capacity";
				return 0;
			end
			layout.provided   = 1;
			layout.reg_target = $sformatf("h%0d.pf%0d", owner.host_id, owner.pf_id);
			if (owner.kind == DPU_FUNCTION_VF)
				layout.reg_target = {layout.reg_target, $sformatf(".vf%0d", owner.vf_id)};
			layout.reg_target    = {layout.reg_target, $sformatf(".bar%0d", bar_id)};
			layout.table_offset  = kind == DPU_TABLE_MSIX_TABLE ? 'h20000 : 'h10000;
			layout.module_offset = base - layout.table_offset;
			layout.capacity      = kind == DPU_TABLE_MSIX_TABLE ? p.table_size : p.pba_words;
			layout.entry_bytes   = kind == DPU_TABLE_MSIX_TABLE ? 16 : 8;
			layout.index_policy  = DPU_INDEX_LOCAL_VECTOR;
			layout.indirect      = 0;
		end
	end
	if (!layout.provided) begin
		name = $sformatf("h%0d.pf%0d", owner.host_id, owner.pf_id);
		if (owner.kind == DPU_FUNCTION_VF) name = {name, $sformatf(".vf%0d", owner.vf_id)};
		why = $sformatf(
			{
				"missing platform layout: %s\n",
				"  Function           : %s\n",
				"  Target BAR         : %s\n",
				"  Missing            : provided table layout\n",
				"  dpu.driver_layouts : %0b\n",
				"  Reference layout   : +dpu.driver_layouts=1 before env build\n",
				"  Custom layout      : dpu_cfg.table_layouts[%s], provided=1, before env build\n",
				"  Note               : reg_target selects a BAR; it does not define a table layout"
			},
			kind.name(),
			name,
			layout.reg_target == "" ? frozen_reg_target : layout.reg_target,
			driver_layouts,
			kind.name()
		);
		return 0;
	end
	if ($isunknown(
			{layout.module_offset, layout.table_offset, layout.data_port, layout.control_port,
		layout.index_mask, layout.control_fixed, layout.trigger_mask}
		) || !(layout.entry_bytes inside {4, 8, 12, 16}) || index >= layout.capacity) begin
		why = "layout/index has unknown values or unsupported capacity/width";
		return 0;
	end
	if ((kind inside {DPU_TABLE_VTX,DPU_TABLE_VRX,DPU_TABLE_NOTIFY,DPU_TABLE_MSIX_TABLE} && layout.entry_bytes != 16) ||
		(kind inside {DPU_TABLE_PREFIX,DPU_TABLE_MSIX_LINEAR,DPU_TABLE_RDMA_NOTIFY,DPU_TABLE_MSIX_PBA} && layout.entry_bytes != 8) ||
		(kind inside {DPU_TABLE_BDF,DPU_TABLE_PFVF,DPU_TABLE_COMPLETION_BDF,DPU_TABLE_MSIX_INFO,DPU_TABLE_MSIX_INTERVAL,
			DPU_TABLE_Q2TC,DPU_TABLE_N2G,DPU_TABLE_G2P,DPU_TABLE_RNET,DPU_TABLE_MSIX_STAT,DPU_TABLE_PFVF_DROP} && layout.entry_bytes != 4)) begin
		why = "declared table width contradicts screenshot";
		return 0;
	end
	case (kind)
		DPU_TABLE_BDF, DPU_TABLE_PFVF: expected_offset = 'h8000;
		DPU_TABLE_COMPLETION_BDF, DPU_TABLE_PREFIX: expected_offset = 'h18000;
		DPU_TABLE_MSIX_LINEAR, DPU_TABLE_MSIX_INTERVAL: expected_offset = 'h40000;
		DPU_TABLE_MSIX_INFO: expected_offset = 'h50000;
		DPU_TABLE_MSIX_TABLE, DPU_TABLE_NOTIFY: expected_offset = 'h20000;
		DPU_TABLE_Q2TC, DPU_TABLE_VTX, DPU_TABLE_VRX: expected_offset = 'h10000;
		DPU_TABLE_N2G: expected_offset = 'h12000;
		DPU_TABLE_G2P: expected_offset = 'h14000;
		DPU_TABLE_RNET: expected_offset = 'h15000;
		DPU_TABLE_RDMA_NOTIFY: expected_offset = 'hc000;
		DPU_TABLE_MSIX_PBA: expected_offset = 'h10000;
		DPU_TABLE_MSIX_STAT: expected_offset = 'h48000;
		DPU_TABLE_PFVF_DROP: expected_offset = 'ha000;
		default: expected_offset = layout.table_offset;
	endcase
	if (layout.table_offset != expected_offset ||
		(kind inside {DPU_TABLE_VTX, DPU_TABLE_VRX} && !layout.indirect)) begin
		why = "layout contradicts screenshot offset or required indirect access";
		return 0;
	end
	name = layout.reg_target == "" ? frozen_reg_target : layout.reg_target;
	if (!bar_map.resolve_name(
			name,
			ctx.target,
			why,
			layout.access_host_provided || layout.access_uses_owner_host,
			layout.access_host_provided ? layout.access_host : owner.host_id
		))
		return 0;
	if (kind inside {DPU_TABLE_MSIX_TABLE, DPU_TABLE_MSIX_PBA}) begin
		bit [64:0]	span_offset;

		span_offset = {1'b0, layout.module_offset} + {1'b0, layout.table_offset};
		if (span_offset[64] || !bar_map.check_range(
				ctx.target,
				span_offset[63:0],
				64'(layout.capacity) * layout.entry_bytes,
				address,
				why
			))
			return 0;
	end
	offset = {1'b0, layout.module_offset} + {1'b0, layout.table_offset} + 65'(index) * layout.entry_bytes;
	if (offset[64] || !bar_map.check_range(ctx.target, offset[63:0], layout.entry_bytes, address, why))
		return 0;
	if (layout.indirect) begin
		bit [64:0]	data_offset;
		bit [64:0]	control_offset;

		data_offset    = {1'b0, layout.module_offset} + {1'b0, layout.data_port};
		control_offset = {1'b0, layout.module_offset} + {1'b0, layout.control_port};
		if (data_offset[64] || control_offset[64] || layout.index_shift >= 32 ||
			((64'(index) << layout.index_shift) & ~64'(layout.index_mask)) != 0 ||
			(layout.index_mask & (layout.control_fixed | layout.trigger_mask)) != 0 ||
			layout.trigger_mask == 0 || (layout.control_fixed & layout.trigger_mask) != 0 ||
			!bar_map.check_range(ctx.target, data_offset[63:0], layout.entry_bytes, address, why) || !bar_map.check_range(ctx.target, control_offset[63:0], 4, address, why) || data_offset[1:0] != 0 || control_offset[1:0] != 0 ||
				data_offset[11:0] + layout.entry_bytes > 4096) begin
			why = "indirect ports/index do not fit declared BAR operation";
			return 0;
		end
	end
	ctx.snapshot = device_snapshot;
	ctx.snapshot_id = 1;
	ctx.config_generation = generation;
	ctx.layout_id = "image-2026-11-07";
	ctx.kind = kind;
	ctx.layout = layout;
	ctx.table_index = index;
	ctx.byte_offset = offset[63:0];
	ctx.record_key = $sformatf("%0d:%s:%016h", kind, ctx.target.canonical_name, ctx.byte_offset);
	why = "";
	return 1;
endfunction

// 同批配置中共享表项必须一致；合并消费者供 typed hook 使用，避免重复写同一硬件项。
function bit dpu_env_cfg::remember_record(
	input dpu_table_item_t	record,
	output string			why
);
	string	key;

	key = record.ctx.record_key;
	why = "";
	if (records.exists(key)) begin
		if (records[key].ctx !== record.ctx || records[key].entry !== record.entry ||
			records[key].enable_mask !== record.enable_mask || records[key].enable_value !== record.enable_value) begin
			why = {"conflicting table input: ", key};
			return 0;
		end
		foreach (record.consumers[i]) begin
			bit	found;

			found = 0;
			foreach (records[key].consumers[j])
			if (dpu_service_key_name(record.consumers[i]) == dpu_service_key_name(records[key].consumers[j]))
				found = 1;
			if (!found) records[key].consumers.push_back(record.consumers[i]);
		end
		return 1;
	end
	records[key] = record;
	return 1;
endfunction

// MSI-X/RNET/RDMA 的 Function 范围由实际 owner service 派生；AF/共享调度范围不能猜测。
// 显式消费者逐一核对冻结拓扑并去重，表项生成和用户 hook 共用这一份关系。
function bit dpu_env_cfg::control_consumers(
	input dpu_control_cfg_t		item,
	output dpu_service_key_t	consumers[$],
	output string				why
);
	dpu_function_record_t	functions[$];
	bit						seen[string];
	bit						owner_found;

	consumers.delete();
	list_functions(functions);
	if ((item.ctx.kind inside {DPU_TABLE_AF, DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT} || item.consumers.size() != 0) &&
		!item.consumers_complete) begin
		why = "platform control requires complete explicit consumer scope";
		return 0;
	end
	foreach (functions[f]) begin
		if (!dpu_same_function_key(functions[f].key, item.owner)) continue;
		owner_found = 1;
		if (!(item.ctx.kind inside {DPU_TABLE_MSIX_CONTROL, DPU_TABLE_MSIX_FUNCTION, DPU_TABLE_RNET, DPU_TABLE_RDMA_NOTIFY}))
			continue;
		foreach (functions[f].services[v]) begin
			consumers.push_back(functions[f].services[v]);
			seen[dpu_service_key_name(functions[f].services[v])] = 1;
		end
	end
	if (!owner_found) begin
		why = "control owner absent from frozen topology";
		return 0;
	end
	foreach (item.consumers[c]) begin
		bit		found;
		string	name;

		name  = dpu_service_key_name(item.consumers[c]);
		found = 0;
		foreach (functions[f])
		foreach (functions[f].services[v])
		if (dpu_service_key_name(functions[f].services[v]) == name) found = 1;
		if (!found) begin
			why = "control consumer absent from frozen topology";
			return 0;
		end
		if (!seen.exists(name)) begin
			consumers.push_back(item.consumers[c]);
			seen[name] = 1;
		end
	end
	return 1;
endfunction

// 控制 payload/mask 只来自已冻结 catalog，不把未定义位扩展成全可写。
function logic [127:0] dpu_env_cfg::platform_control_mask(input dpu_table_item_t	record);
	foreach (frozen_controls[c])
	if (frozen_controls[c].ctx.kind == record.ctx.kind && frozen_controls[c].ctx.table_index == record.ctx.table_index &&
			dpu_same_function_key(frozen_controls[c].owner, record.owner))
		return frozen_controls[c].writable_mask;
	return 0;
endfunction

// 公共类别只消费冻结 Function/消息/布局；缺失映射只阻止当前类别，不依赖 VIO ring。
function bit dpu_env_cfg::public_records(
	input dpu_table_kind_e	kind,
	input dpu_cfg_scope		scope,
	output dpu_table_item_t	selected[$],
	output string			why
);
	dpu_function_record_t	functions[$];
	dpu_function_policy_t	p;
	dpu_table_item_t		r;
	int unsigned			index;

	selected.delete();
	if (scope == null) return 0;
	if (!scope.validate(device_snapshot, why)) return 0;
	list_functions(functions);
	if (kind == DPU_TABLE_MSIX_LINEAR) begin
		if (!msix_directory_ready && !materialize_msix_linear_records(why)) return 0;
		foreach (msix_linear_records[i]) begin
			if (scope.selects(msix_linear_records[i].owner))
				selected.push_back(msix_linear_records[i]);
		end
		return 1;
	end
	if (kind == DPU_TABLE_BAR) begin
		if (frozen_bar_groups.size() == 0) begin
			why = "BAR mapping atomic groups must be explicitly declared";
			return 0;
		end
		foreach (frozen_bar_groups[g]) begin
			bit	any_selected;
			bit	all_selected;

			any_selected = 0;
			all_selected = 1;
			if (frozen_bar_groups[g].members.size() == 0) begin
				why = "empty BAR mapping group";
				return 0;
			end
			foreach (frozen_bar_groups[g].members[m]) begin
				dpu_bar_target_t	target;
				bit					chosen;

				target = frozen_bar_groups[g].members[m];
				chosen = scope.selects(target.function_key) &&
					scope.selects_bar(target.bar_lease.even_bar_id);
				any_selected |= chosen;
				all_selected &= chosen;
				begin
					bit [63:0]	address;

					if (!bar_map.check_range(target, 0, target.bar_lease.size, address, why))
						return 0;
				end
			end
			if (!any_selected) continue;
			if (!all_selected) begin
				why = "BAR scope splits a declared atomic group";
				return 0;
			end
			r.ctx                   = frozen_bar_groups[g].ctx;
			r.ctx.snapshot          = device_snapshot;
			r.ctx.snapshot_id       = 1;
			r.ctx.config_generation = 0;
			r.ctx.kind              = DPU_TABLE_BAR;
			r.ctx.table_index       = g;
			r.ctx.record_key        = $sformatf("BAR:%0d", g);
			r.owner                 = frozen_bar_groups[g].members[0].function_key;
			r.has_queue             = 0;
			r.entry                 = '0;
			r.enable_mask           = '0;
			r.enable_value          = '0;
			r.consumers.delete();
			foreach (functions[f])
			foreach (frozen_bar_groups[g].members[m]) begin
				if (!dpu_same_function_key(functions[f].key, frozen_bar_groups[g].members[m].function_key))
					continue;
				foreach (functions[f].services[v]) r.consumers.push_back(functions[f].services[v]);
			end
			r.dependencies.delete();
			selected.push_back(r);
		end
		// 全部选中租约必须有且只有一个声明组，不能默默遗漏未编码的 BAR。
		foreach (functions[f]) begin
			if (!scope.selects(functions[f].key)) continue;
			foreach (functions[f].bars[b]) begin
				int unsigned	count;

				if (!scope.selects_bar(functions[f].bars[b].even_bar_id)) continue;
				count = 0;
				foreach (selected[s])
				foreach (frozen_bar_groups[selected[s].ctx.table_index].members[m]) begin
					dpu_bar_target_t	t;

					t = frozen_bar_groups[selected[s].ctx.table_index].members[m];
					if (dpu_same_function_key(t.function_key, functions[f].key) && t.bar_lease.even_bar_id == functions[f].bars[b].even_bar_id)
						count++;
				end
				if (count != 1) begin
					why = "selected BAR has missing/duplicate mapping group membership";
					return 0;
				end
			end
		end
		return 1;
	end
	// 图中没有定义的控制项仅按平台显式 catalog 遍历，不补默认寄存器或 payload。
	if (kind inside {DPU_TABLE_AF, DPU_TABLE_MSIX_CONTROL, DPU_TABLE_MSIX_FUNCTION, DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT, DPU_TABLE_QUEUE_AUX, DPU_TABLE_RDMA_NOTIFY, DPU_TABLE_RNET}) begin
		foreach (frozen_controls[i]) begin
			if (frozen_controls[i].ctx.kind != kind || !scope.selects(frozen_controls[i].owner))
				continue;
			r.ctx = frozen_controls[i].ctx;
			if (!make_context(kind, frozen_controls[i].owner, r.ctx.table_index, 0, r.ctx, why))
				return 0;
			r.owner = frozen_controls[i].owner;
			if (!control_consumers(frozen_controls[i], r.consumers, why)) return 0;
			r.entry        = frozen_controls[i].value;
			r.enable_mask  = '0;
			r.enable_value = '0;
			r.has_queue    = 0;
			if ($isunknown({r.entry, frozen_controls[i].writable_mask}) || (r.entry & ~frozen_controls[i].writable_mask) != 0) begin
				why = "platform control contains unknown/reserved bits";
				return 0;
			end
			if (kind == DPU_TABLE_RNET) begin
				dpu_qsch_rnet_entry_t	e;

				e = dpu_qsch_rnet_entry_t'(r.entry);
				if (r.entry[127:32] != 0 || e.reserved_31_4 != 0 || e.host_id != r.owner.host_id || r.ctx.table_index >= 256) begin
					why = "RNET reserved/Host/index encoding invalid";
					return 0;
				end
			end
			if (kind == DPU_TABLE_RDMA_NOTIFY) begin
				dpu_rdma_notify_entry_t	e;

				e = dpu_rdma_notify_entry_t'(r.entry);
				if (r.entry[127:64] != 0 || e.reserved_63_59 != 0 || e.host_id != r.owner.host_id ||
					r.owner.kind != DPU_FUNCTION_VF || r.ctx.table_index >= 256) begin
					why = "RDMA notify reserved/Host/VF/index encoding invalid";
					return 0;
				end
			end
			selected.push_back(r);
		end
		if (kind inside {DPU_TABLE_MSIX_CONTROL, DPU_TABLE_MSIX_FUNCTION}) begin
			foreach (frozen_messages[m]) begin
				bit		covered;
				string	owner_name;

				if (!scope.selects(frozen_messages[m].owner)) continue;
				owner_name = dpu_function_key_name(frozen_messages[m].owner);
				covered = frozen_msix_policies.exists(owner_name) &&
					frozen_msix_policies[owner_name].table_only_enable;
				foreach (selected[c])
				if (dpu_same_function_key(selected[c].owner, frozen_messages[m].owner)) covered = 1;
				if (!covered) begin
					why = "MSI-X requires explicit control or table-only enable declaration";
					return 0;
				end
			end
		end
		if (selected.size() == 0 && (kind == DPU_TABLE_AF || (frozen_layouts.exists(kind) && frozen_layouts[kind].required))) begin
			why = {"required platform control catalog is empty: ", kind.name()};
			return 0;
		end
		return 1;
	end
	foreach (functions[f]) begin
		string	name;

		if (!scope.selects(functions[f].key)) continue;
		name = dpu_function_key_name(functions[f].key);
		if (!frozen_functions.exists(name)) begin
			why = {"platform Function mapping missing: ", name};
			return 0;
		end
		p = frozen_functions[name];
		if (kind == DPU_TABLE_PFVF && !validate_pfvf_family(p.key, why)) return 0;
		r.owner        = functions[f].key;
		r.consumers    = functions[f].services;
		r.has_queue    = 0;
		r.entry        = '0;
		r.enable_mask  = '0;
		r.enable_value = '0;
		r.dependencies.delete();
		if (kind inside {DPU_TABLE_MSIX_INFO, DPU_TABLE_MSIX_INTERVAL, DPU_TABLE_MSIX_TABLE}) begin
			foreach (frozen_messages[m]) begin
				dpu_msix_message_t	message;

				message = frozen_messages[m];
				if (!dpu_same_function_key(message.owner, r.owner)) continue;
				if (kind == DPU_TABLE_MSIX_TABLE && frozen_msix_policies.exists(name) && frozen_msix_policies[name].table_present)
					index = message.local_vector;
				else begin
					if (!frozen_layouts.exists(kind) || !(frozen_layouts[kind].index_policy
							   inside {DPU_INDEX_GLOBAL_VECTOR, DPU_INDEX_LOCAL_VECTOR})) begin
						why = "MSI-X table requires explicit local/global vector index policy";
						return 0;
					end
					index = frozen_layouts[kind].index_policy == DPU_INDEX_GLOBAL_VECTOR ? message.global_vector : message.local_vector;
				end
				if (index >= 1024 || (kind == DPU_TABLE_MSIX_INFO && p.vport >= 128)) begin
					why = "MSI-X mapping exceeds screenshot capacity/reserved fields";
					return 0;
				end
				case (kind)
					DPU_TABLE_MSIX_INFO: begin
						dpu_msix_info_entry_t	e;

						e = '0;
						if (!frozen_msix_policies.exists(name) || !frozen_msix_policies[name].self_mask_present || $isunknown(frozen_msix_policies[name].self_mask)) begin
							why = "MSI-X info requires explicit self-mask policy";
							return 0;
						end
						e.self_mask   = frozen_msix_policies[name].self_mask;
						e.valid       = 1;
						e.host_id     = p.key.host_id;
						e.function_id = p.vport;
						r.entry       = 128'(e);
					end
					DPU_TABLE_MSIX_INTERVAL: begin
						if (!frozen_msix_policies.exists(name) || !frozen_msix_policies[name].interval_present || $isunknown(frozen_msix_policies[name].interval_entry)) begin
							why = "MSI-X interval requires explicit rate/packet policy";
							return 0;
						end
						r.entry = 128'(frozen_msix_policies[name].interval_entry);
					end
					DPU_TABLE_MSIX_TABLE: begin
						dpu_msix_table_entry_t	e;

						e           = '0;
						e.msix_addr = message.address;
						e.msix_data = message.data;
						e.msix_mask = message.masked;
						r.entry     = 128'(e);
					end
					default: ;
				endcase
				if (!make_context(kind, r.owner, index, 0, r.ctx, why)) return 0;
				selected.push_back(r);
			end
			continue;
		end
		case (kind)
			DPU_TABLE_BDF: begin
				dpu_bdf_entry_t			e;
				dpu_ep_requester_id_t	ep;

				if (p.bdf_index >= 128 || $isunknown(p.requester)) begin
					why = "requester table index/encoding invalid";
					return 0;
				end
				ep = dpu_ep_requester_id_t'(p.requester);
				if ((p.mode == DPU_HOST_SW && p.requester != functions[f].pcie_id.bdf) ||
					(p.mode == DPU_HOST_EP && ep.vf_valid != (p.key.kind == DPU_FUNCTION_VF))) begin
					why = "requester EP/SW encoding contradicts explicit route";
					return 0;
				end
				e              = '0;
				e.requester_id = p.requester;
				e.valid        = 1;
				e.ecrc_en      = p.ecrc;
				e.vdpa_en      = p.vdpa;
				r.entry        = 128'(e);
				index          = p.bdf_index;
			end
			DPU_TABLE_COMPLETION_BDF: begin
				dpu_completion_bdf_entry_t	e;

				if (p.mode == DPU_HOST_EP) continue;
				if (p.completion_index >= 4096) begin
					why = "Completion table index exceeds screenshot";
					return 0;
				end
				e               = '0;
				e.valid         = 1;
				e.ecrc_en       = p.ecrc;
				e.completion_id = functions[f].pcie_id.bdf;
				r.entry         = 128'(e);
				index           = p.completion_index;
			end
			DPU_TABLE_PFVF: begin
				dpu_pfvf_entry_t	e;

				if (p.key.kind != DPU_FUNCTION_PF) continue;
				// PFVF 是整族依赖；按冻结身份收集实际 VF，不推断连续编号。
				r.consumers.delete();
				foreach (functions[member]) begin
					if (functions[member].key.host_id != p.key.host_id || functions[member].key.pf_id != p.key.pf_id)
						continue;
					foreach (functions[member].services[service])
					r.consumers.push_back(functions[member].services[service]);
				end
				if (p.intel_pf >= 4 || p.first_vf_offset >= 1024) begin
					why = "PFVF mapping exceeds screenshot fields";
					return 0;
				end
				e                 = '0;
				e.valid           = 1;
				e.first_vf_offset = p.first_vf_offset;
				r.entry           = 128'(e);
				index             = p.intel_pf;
			end
			DPU_TABLE_PREFIX: begin
				dpu_tlp_prefix_entry_t	e;

				if (!p.prefix_enabled) continue;
				if (p.prefix_index >= 256 || $isunknown(p.prefix)) begin
					why = "prefix invalid";
					return 0;
				end
				e            = '0;
				e.valid      = 1;
				e.vdpa_en    = p.vdpa;
				e.tlp_prefix = p.prefix;
				r.entry      = 128'(e);
				index        = p.prefix_index;
			end
			default: begin
				why = "category is not a public table";
				return 0;
			end
		endcase
		if (!make_context(kind, r.owner, index, 0, r.ctx, why)) return 0;
		selected.push_back(r);
	end
	why = "";
	return 1;
endfunction

// 驱动先按 Host/BAR 查找基址排序 Function，再在组内按 pair 编号排列；硬件行号是排序位置。
// 从完整已准备目录生成一次，RX/TX 共用 pair 项；global_qid 只写入 payload，不作为表行号。
// 默认从实际 doorbell [60:7] 取基址；显式 BAR/offset 必须命中相同高位，低七位是队列编码。
// 同 Host 同基址属于不同 service 时存在查找歧义，拒绝发布；失败保持目录为空。
function bit dpu_env_cfg::materialize_notify_records(output string	why);
	dpu_table_item_t	pending[$];
	dpu_vio_queue_t		queues[$];

	string				service_by_base[bit [63:0]];
	int					pair_rows[string];

	notify_records.delete();
	why = "";
	foreach (queues_by_host[h]) begin
		queues = queues_by_host[h];
		foreach (queues[q]) begin
			dpu_vio_policy_t		policy;
			dpu_vio_notify_entry_t	entry;
			dpu_bar_target_t		target;
			dpu_table_item_t		record;
			bit [63:0]				base;
			bit [63:0]				lookup_key;
			string					service;
			string					pair_name;

			service = dpu_service_key_name(queues[q].service_key);
			if (!frozen_policies.exists(service)) begin
				why = {"queue platform policy missing: ", service};
				return 0;
			end
			policy = frozen_policies[service];
			// 实际 doorbell 已由 VIO 导出；表只匹配 [60:7]，不能把 RX/TX 的低位当成基址差异。
			base = {3'b0, queues[q].notify_address[60:7], 7'b0};
			if (policy.notify_table_base_provided) begin
				if ($isunknown(policy.notify_table_offset)) begin
					why = "notify table lookup offset contains unknown bits";
					return 0;
				end
				if (!bar_map.resolve_function(
						queues[q].service_key.function_key, policy.notify_table_bar, target, why
					) || !bar_map.check_range(target, policy.notify_table_offset, 128, base, why))
					return 0;
				if (base[60:7] != queues[q].notify_address[60:7]) begin
					why = "notify table lookup base differs from exported doorbell [60:7]";
					return 0;
				end
			end
			if (!policy.notify_net_pair5 || queues[q].qpair.virtio_pair_index >= 32 ||
				queues[q].qpair.rx_local_virtqueue_id >= 64 || queues[q].qpair.tx_local_virtqueue_id >= 64 ||
				queues[q].qpair.global_qpair_id >= 2048 || h >= 8 ||
				base[63:61] != 0 || base[6:0] != 0 || queues[q].notify_address[63:61] != 0) begin
				why = "notify single-bank pair5/base/index cannot represent binding";
				return 0;
			end

			lookup_key = (64'(h) << 61) | base;
			if (service_by_base.exists(lookup_key) && service_by_base[lookup_key] != service) begin
				why = "different VIO services share the same Notify Host/BAR lookup base";
				return 0;
			end
			service_by_base[lookup_key] = service;
			entry = '0;
			entry.global_qid = queues[q].qpair.global_qpair_id;
			entry.host_id = h;
			entry.base_addr_60_7 = base[60:7];
			entry.local_qid_encoding = (queues[q].qpair.virtio_pair_index << 1) | 1;
			pair_name = $sformatf("%s.pair%0d", service, queues[q].qpair.virtio_pair_index);
			if (pair_rows.exists(pair_name)) begin
				if (pending[pair_rows[pair_name]].entry != 128'(entry)) begin
					why = "RX/TX of one qpair disagree on the Notify mapping";
					return 0;
				end
				continue;
			end

			record.owner        = queues[q].service_key.function_key;
			record.consumers    = '{queues[q].service_key};
			record.has_queue    = 1;
			record.binding      = queues[q];
			record.entry        = entry;
			record.enable_mask  = 0;
			record.enable_value = 0;
			record.dependencies.delete();
			pair_rows[pair_name] = pending.size();
			pending.push_back(record);
		end
	end

	// 低 64 位恰好为 {host_id, base_addr_60_7, local_qid_encoding}，不含 global_qid。
	pending.sort() with (item.entry[63:0]);
	if (pending.size() > 512) begin
		why = "Notify single-bank image exceeds 512 rows";
		return 0;
	end
	foreach (pending[i]) begin
		if (!make_context(
				DPU_TABLE_NOTIFY,
				pending[i].owner,
				i,
				pending[i].binding.generation,
				pending[i].ctx,
				why
			))
			return 0;

		// 全局行号必须落到同一 bank；按 owner 分散窗口会留下未初始化的中间行。
		if (i != 0 && (
			pending[i].ctx.target.canonical_name != pending[0].ctx.target.canonical_name ||
			pending[i].ctx.layout.module_offset != pending[0].ctx.layout.module_offset ||
			pending[i].ctx.layout.table_offset != pending[0].ctx.layout.table_offset ||
			pending[i].ctx.layout.capacity != pending[0].ctx.layout.capacity
		)) begin
			why = "Notify single-bank directory requires one management window; set vio.notify_table.reg_target to a complete hH.pfP.barB target";
			return 0;
		end
	end
	notify_records = pending;
	return 1;
endfunction

// 队列表按真实 service/qpair/IOVA 生成；任何平台策略越界都在窄字段赋值前拒绝。
function bit dpu_env_cfg::queue_records(
	input dpu_cfg_scope		selection,
	input dpu_table_kind_e	kinds[$],
	output dpu_table_item_t	selected[$],
	output string			why
);
	dpu_vio_queue_t			queues[$];
	dpu_vio_policy_t		policy;
	dpu_function_policy_t	fp;
	dpu_table_item_t		r;
	int unsigned			depth;
	int unsigned			pre_count;
	int unsigned			pre_start;
	int unsigned			net_id;
	int unsigned			index;
	string					service;

	selected.delete();
	if (selection == null || !selection.validate(device_snapshot, why)) return 0;
	if (kind_selected(DPU_TABLE_NOTIFY, kinds)) begin
		foreach (notify_records[i]) begin
			int unsigned	host_id;

			host_id = notify_records[i].owner.host_id;
			if (selection.selects_service(notify_records[i].binding.service_key)) begin
				selected.push_back(notify_records[i]);
			end
		end
		if (kinds.size() == 1) begin
			why = "";
			return 1;
		end
	end
	foreach (queues_by_host[h]) begin
		queues = queues_by_host[h];
		foreach (queues[q]) begin
			if (!selection.selects_service(queues[q].service_key)) continue;
			service = dpu_service_key_name(queues[q].service_key);
			if (!frozen_policies.exists(service) || !frozen_functions.exists(dpu_function_key_name(queues[q].service_key.function_key))) begin
				why = {"queue platform policy missing: ", service};
				return 0;
			end
			policy = frozen_policies[service];
			fp     = frozen_functions[dpu_function_key_name(queues[q].service_key.function_key)];
			if (queues[q].queue_size < 32 || queues[q].queue_size > 32768 ||
				(!queues[q].virtio_mode && queues[q].queue_size > 4096) ||
				(queues[q].queue_size & (queues[q].queue_size-1)) != 0 || fp.vport >= 1024 ||
				queues[q].qpair.global_msix_vector_id >= 8192 || queues[q].qpair.global_qpair_id >= (policy.fpga ? 512 : 2048)) begin
				why = "queue geometry/vector/vport exceeds screenshot or VIP bounds";
				return 0;
			end
			depth   = $clog2(queues[q].queue_size);
			r.owner = queues[q].service_key.function_key;
			r.consumers.delete();
			r.consumers.push_back(queues[q].service_key);
			r.has_queue = 1;
			r.binding   = queues[q];
			r.dependencies.delete();
			foreach (kinds[k]) begin
				bit	found;

				if (!(kinds[k] inside {DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT, DPU_TABLE_QUEUE_AUX}))
					continue;
				found = 0;
				foreach (frozen_controls[c]) begin
					bit	selected_consumer;

					if (frozen_controls[c].ctx.kind != kinds[k]) continue;
					selected_consumer = dpu_same_function_key(frozen_controls[c].owner,
															  queues[q].service_key.function_key);
					foreach (frozen_controls[c].consumers[v]) begin
						if (dpu_service_key_name(frozen_controls[c].consumers[v]) == service)
							selected_consumer = 1;
					end
					if (!selected_consumer) continue;
					if (kinds[k] == DPU_TABLE_QUEUE_AUX && frozen_controls[c].ctx.table_index != queues[q].qpair.global_qpair_id)
						continue;
					if ($isunknown({frozen_controls[c].value, frozen_controls[c].writable_mask}) || (frozen_controls[c].value & ~frozen_controls[c].writable_mask) !=
							0) begin
						why = "queue control contains unknown/reserved bits";
						return 0;
					end
					if (!control_consumers(frozen_controls[c], r.consumers, why)) return 0;
					if (kinds[k] == DPU_TABLE_QUEUE_AUX) begin
						bit	bound_consumer;

						bound_consumer = 0;
						foreach (r.consumers[v])
						if (dpu_service_key_name(r.consumers[v]) == service) bound_consumer = 1;
						if (!bound_consumer) r.consumers.push_back(queues[q].service_key);
					end
					r.owner        = frozen_controls[c].owner;
					r.has_queue    = kinds[k] == DPU_TABLE_QUEUE_AUX;
					r.entry        = frozen_controls[c].value;
					r.enable_mask  = 0;
					r.enable_value = 0;
					if (!make_context(
							kinds[k],
							r.owner,
							frozen_controls[c].ctx.table_index,
							kinds[k] == DPU_TABLE_QUEUE_AUX ? queues[q].generation : 0,
							r.ctx,
							why
						))
						return 0;
					selected.push_back(r);
					found = 1;
				end
				if (!found && frozen_layouts.exists(kinds[k]) && frozen_layouts[kinds[k]].required) begin
					why = {"required queue control missing: ", kinds[k].name()};
					return 0;
				end
			end
			r.owner = queues[q].service_key.function_key;
			r.consumers.delete();
			r.consumers.push_back(queues[q].service_key);
			r.has_queue    = 1;
			r.enable_mask  = 128'h1 << 68;
			r.enable_value = r.enable_mask;
			if ((queues[q].tx_mode && kind_selected(DPU_TABLE_VTX, kinds)) || (!queues[q].tx_mode && kind_selected(DPU_TABLE_VRX, kinds))) begin
				if (queues[q].tx_mode) begin
					dpu_vtx_entry_t	e;

					e = policy.vtx;
					if ($isunknown(e) || e.reserved_127_112 != 0 || e.reserved_111_106 != 0 || e.queue_en != 0
							|| e.queue_stop != 0 || (e.high_speed_mode && depth < 7) || h > 6) begin
						why = "VTX template reserved/enable/Host/high-speed constraint violated";
						return 0;
					end
					e.desc_addr   = queues[q].desc_iova;
					e.q_depth     = depth;
					e.virtio_mode = queues[q].virtio_mode;
					e.sport       = h;
					e.sport_id    = fp.vport;
					e.dma_msix    = queues[q].qpair.global_msix_vector_id;
					r.entry       = e;
					if (!make_context(
							DPU_TABLE_VTX,
							r.owner,
							queues[q].qpair.global_qpair_id,
							queues[q].generation,
							r.ctx,
							why
						))
						return 0;
				end else begin
					dpu_vrx_entry_t	e;

					e = policy.vrx;
					pre_count = e.dsc_pre_max_num == 0 ? 256 : e.dsc_pre_max_num == 1 ? 128 : e.dsc_pre_max_num == 2 ? 64 : e.dsc_pre_max_num == 3 ? 32 : 16;
					pre_start = policy.prefetch_start + queues[q].qpair.virtio_pair_index * pre_count;
					if ($isunknown(e) || e.reserved_127 != 0 || e.reserved_108 != 0 || e.queue_en != 0 ||
							e.dsc_mode != 0 || e.payload_dsc_len != 0 || e.head_dsc_len != 0 || h >
							3 || policy.prefetch_ram == "" || pre_count >= queues[q].queue_size ||
							policy.prefetch_slots != pre_count || pre_start % pre_count != 0 ||
							64'(policy.prefetch_start) + 64'(queues[q].allocated_qpairs) *
							pre_count > (policy.fpga ? 16384 : 32768)) begin
						why = "VRX reserved/head-split/Host/prefetch policy invalid";
						return 0;
					end
					// 以全部冻结 service 的 RAM 预留检查重叠，局部 scope 不会重新从零分配。
					foreach (frozen_policies[other]) begin
						if (other != service && frozen_policies[other].prefetch_ram == policy.prefetch_ram) begin
							dpu_vio_service_t	other_requirement;

							if (!services.exists(other)) begin
								why = {"service demand missing: ", other};
								return 0;
							end
							other_requirement = services[other];
							if (other_requirement.enabled && other_requirement.rx_enable &&
							64'(policy.prefetch_start) < 64'(frozen_policies[other].prefetch_start) + 64'(other_requirement.qpairs)*frozen_policies[other].prefetch_slots &&
							64'(frozen_policies[other].prefetch_start) < 64'(policy.prefetch_start) + 64'(queues[q].allocated_qpairs)*pre_count) begin
								why = "VRX descriptor RAM reservations overlap across services/Hosts";
								return 0;
							end
						end
					end
					e.dsc_addr              = queues[q].desc_iova;
					e.q_depth               = depth;
					e.virtio_mode           = queues[q].virtio_mode;
					e.dport                 = h;
					e.dport_id              = fp.vport;
					e.dma_msix              = queues[q].qpair.global_msix_vector_id;
					e.dma_msix_en           = queues[q].msix_enable;
					e.dsc_pre_read_ram_addr = pre_start;
					r.entry                 = e;
					if (!make_context(
							DPU_TABLE_VRX,
							r.owner,
							queues[q].qpair.global_qpair_id,
							queues[q].generation,
							r.ctx,
							why
						))
						return 0;
				end
				selected.push_back(r);
			end
			// 非 ring 表不携带 ring enable 位，独立批次与合并 verify 必须生成相同记录。
			r.enable_mask  = 0;
			r.enable_value = 0;
			if (kind_selected(DPU_TABLE_Q2TC, kinds) || kind_selected(DPU_TABLE_N2G, kinds) || kind_selected(DPU_TABLE_G2P, kinds)) begin
				// Q2TC/N2G/G2P 编号由显式策略生成；net/group 十位先检查再赋值。
				if (64'(policy.net_base) + 64'(queues[q].qpair.virtio_pair_index)*policy.net_stride >= 1024 ||
				policy.group_id >= 1024 || policy.cos >= 8 || policy.eth_ports + h >= 16 ||
				policy.eth_ports == 0 || (policy.ets && policy.ets_priority >= 8) || (!policy.ets && h >= 5) ||
				queues[q].qpair.global_qpair_id >= 1024) begin
					why = "QSCH topology exceeds declared screenshot encoding";
					return 0;
				end
				net_id = policy.net_base + queues[q].qpair.virtio_pair_index * policy.net_stride;
				if (kind_selected(DPU_TABLE_Q2TC, kinds)) begin
					dpu_qsch_q2tc_entry_t	e;

					e        = '0;
					e.valid  = 1;
					e.net_id = net_id;
					e.cos    = policy.cos;
					r.entry  = e;
					if (!make_context(
							DPU_TABLE_Q2TC,
							r.owner,
							queues[q].qpair.global_qpair_id,
							queues[q].generation,
							r.ctx,
							why
						))
						return 0;
					selected.push_back(r);
				end
				r.has_queue = 0;
				if (kind_selected(DPU_TABLE_N2G, kinds)) begin
					dpu_qsch_n2g_entry_t	e;

					e          = '0;
					e.valid    = 1;
					e.group_id = policy.group_id;
					r.entry    = e;
					if (!make_context(DPU_TABLE_N2G, r.owner, net_id, 0, r.ctx, why)) return 0;
					selected.push_back(r);
				end
				if (kind_selected(DPU_TABLE_G2P, kinds)) begin
					dpu_qsch_g2p_entry_t	e;

					e         = '0;
					e.valid   = 1;
					e.dpt     = policy.eth_ports + h;
					e.lvl2_id = policy.ets ? policy.ets_priority : h;
					r.entry   = e;
					if (!make_context(DPU_TABLE_G2P, r.owner, policy.group_id, 0, r.ctx, why))
						return 0;
					selected.push_back(r);
				end
			end
		end
	end
	why = "";
	return 1;
endfunction

// 小型类别集合查询，只统一遍历条件，不建立第二个 callback 引擎。
function bit dpu_env_cfg::kind_selected(
	input dpu_table_kind_e	kind,
	input dpu_table_kind_e	kinds[$]
);
	foreach (kinds[i]) if (kind == kinds[i]) return 1;
	return 0;
endfunction

// 只允许状态类别，调用者必须显式提供实测 PBA 容量和各自模块偏移。
function bit dpu_env_cfg::get_state_context(
	input dpu_table_kind_e		kind,
	input dpu_function_key_t	owner,
	input int unsigned			index,
	output dpu_state_query_t	item,
	output string				why
);
	why = "not a readable state category";
	if (!(kind inside {DPU_TABLE_MSIX_PBA, DPU_TABLE_MSIX_STAT, DPU_TABLE_PFVF_DROP})) return 0;
	item.owner = owner;
	return make_context(kind, owner, index, 0, item.ctx, why);
endfunction

// 同 PF 完整成员和实际 BDF/路由交付平台；缺映射/角色错误在调用纯规则前拒绝。
function bit dpu_env_cfg::validate_pfvf_family(
	input dpu_function_key_t	owner,
	output string				why
);
	dpu_function_record_t	functions[$];
	dpu_pfvf_relationship_t	family;

	list_functions(functions);
	foreach (functions[i]) begin
		string	name;

		if (functions[i].key.host_id != owner.host_id || functions[i].key.pf_id != owner.pf_id)
			continue;
		name = dpu_function_key_name(functions[i].key);
		if (!frozen_functions.exists(name)) begin
			why = "PFVF family lacks explicit routing policy";
			return 0;
		end
		if (frozen_functions[name].pfvf >= 1024 || frozen_functions[name].first_vf_offset >= 1024) begin
			why = "PFVF family field exceeds screenshot width";
			return 0;
		end
		family.functions.push_back(functions[i]);
		family.policies.push_back(frozen_functions[name]);
	end
	if (family.functions.size() == 0) begin
		why = "PFVF family is empty";
		return 0;
	end
	return this.validate_pfvf_relationship(family, why);
endfunction

// 重采样只构造参数副本，复用冻结身份做校验；不调用DPU resolver或PCIE build流程。
function bit dpu_env_cfg::make_runtime_candidate(
	output dpu_env_cfg	candidate,
	output string		why
);
	dpu_cfg_scope		msix_scope;
	longint unsigned	requested_hosts;
	longint unsigned	requested_pfs;
	longint unsigned	requested_vfs;

	candidate = null;
	why       = "runtime reload requires published configuration";
	if (!params_loaded || !runtime_ready || bar_map == null || resource_snapshot == null) return 0;
	requested_hosts = hosts;
	requested_pfs   = pfs_per_host;
	requested_vfs   = vfs_per_pf;
`ifdef AIP_CMDLINE_SV
	begin
		longint unsigned	hosts;
		longint unsigned	pfs_per_host;
		longint unsigned	vfs_per_pf;

		`DPU_AIP_UINT("dpu", longint unsigned, hosts, requested_hosts)
		`DPU_AIP_UINT("dpu", longint unsigned, pfs_per_host, requested_pfs)
		`DPU_AIP_UINT("dpu", longint unsigned, vfs_per_pf, requested_vfs)
		requested_hosts = hosts;
		requested_pfs   = pfs_per_host;
		requested_vfs   = vfs_per_pf;
	end
`endif
	if (requested_hosts != hosts || requested_pfs != pfs_per_host || requested_vfs != vfs_per_pf) begin
		why = "runtime reload preserves Host/PF/VF topology; rebuild for count changes";
		return 0;
	end

	candidate                         = new("runtime_candidate");
	candidate.device_cfg              = device_cfg;
	candidate.placement_cfg           = placement_cfg;
	candidate.services                = services;
	candidate.device_snapshot         = device_snapshot;
	candidate.resource_snapshot       = resource_snapshot;
	candidate.bar_map                 = bar_map;
	candidate.hosts                   = hosts;
	candidate.pfs_per_host            = pfs_per_host;
	candidate.vfs_per_pf              = vfs_per_pf;
	candidate.reg_target              = reg_target;
	candidate.print_bar_map           = print_bar_map;
	candidate.configure_public        = configure_public;
	candidate.configure_bdf           = configure_bdf;
	candidate.driver_layouts          = driver_layouts;
	candidate.verify_readback         = verify_readback;
	candidate.qsch_configure_controls = qsch_configure_controls;
	candidate.qsch_mode               = qsch_mode;
	candidate.qsch_mode_offset        = qsch_mode_offset;
	candidate.qsch_spwrr              = qsch_spwrr;
	candidate.qsch_tc_weight          = qsch_tc_weight;
	candidate.table_layouts           = table_layouts;
	candidate.function_policies       = function_policies;
	candidate.vio_policies            = vio_policies;
	candidate.msix_policies           = msix_policies;
	candidate.message_templates       = message_templates;
	candidate.messages                = authored_messages;
	candidate.platform_controls       = platform_controls;
	candidate.frozen_functions        = frozen_functions;
	candidate.frozen_bar_groups       = frozen_bar_groups;

`ifdef AIP_CMDLINE_SV
	begin
		string	reg_target;
		bit		print_bar_map;

		`aip_string("dpu", reg_target, candidate.reg_target)
		`aip_int("dpu", bit, print_bar_map, candidate.print_bar_map)
		candidate.reg_target    = reg_target;
		candidate.print_bar_map = print_bar_map;
	end
`endif
	candidate.load_platform_params();
	if (candidate.driver_layouts != driver_layouts) begin
		why = "driver_layouts is a build-time default; edit explicit layouts before reload instead";
		return 0;
	end
	if (!candidate.materialize_messages(resource_snapshot, why)) return 0;
	candidate.frozen_messages      = candidate.messages;
	candidate.frozen_layouts       = candidate.table_layouts;
	candidate.frozen_policies      = candidate.vio_policies;
	candidate.frozen_reg_target    = candidate.reg_target;
	candidate.frozen_controls      = candidate.platform_controls;
	candidate.frozen_msix_policies = candidate.msix_policies;
	why                            = "";
	return 1;
endfunction

// 仅复制明确支持的输入与缓存；同一cfg/Host cfg、BAR、snapshot、pool和sequencer句柄保持不变。
function void dpu_env_cfg::apply_runtime_candidate(input dpu_env_cfg	candidate);
	reg_target              = candidate.reg_target;
	print_bar_map           = candidate.print_bar_map;
	configure_public        = candidate.configure_public;
	configure_bdf           = candidate.configure_bdf;
	verify_readback         = candidate.verify_readback;
	qsch_configure_controls = candidate.qsch_configure_controls;
	qsch_mode               = candidate.qsch_mode;
	qsch_mode_offset        = candidate.qsch_mode_offset;
	qsch_spwrr              = candidate.qsch_spwrr;
	qsch_tc_weight          = candidate.qsch_tc_weight;
	table_layouts           = candidate.table_layouts;
	vio_policies            = candidate.vio_policies;
	msix_policies           = candidate.msix_policies;
	message_templates       = candidate.message_templates;
	messages                = candidate.messages;
	frozen_messages         = candidate.frozen_messages;
	frozen_layouts          = candidate.frozen_layouts;
	frozen_policies         = candidate.frozen_policies;
	frozen_reg_target       = candidate.frozen_reg_target;
	frozen_controls         = candidate.frozen_controls;
	frozen_msix_policies    = candidate.frozen_msix_policies;
	services                = candidate.services;
	records.delete();
	notify_records.delete();
	msix_linear_records.delete();
	msix_directory_ready = 0;
endfunction

// 返回冻结 Function 的值副本；只读租约和 service，不依赖 PCIe 绑定或 ring。
function void dpu_env_cfg::list_functions(output dpu_function_record_t records[$]);
	dpu_function_key_t		keys[$];
	dpu_function_record_t	record;

	records.delete();
	if (device_snapshot == null) return;
	device_snapshot.list_functions(keys);
	foreach (keys[i]) if (get_function(keys[i], record)) records.push_back(record);
endfunction

// 精确身份查询；未知 Function 或未发布快照返回 0，不回退 PF0。
function bit dpu_env_cfg::get_function(
	input dpu_function_key_t		key,
	output dpu_function_record_t	record
);
	dpu_function_key_t		af;
	dpu_bar_pair_lease_t	af_bar;
	dpu_service_key_t		keys[$];
	string					why;

	if (device_snapshot == null) return 0;
	record.key = key;
	if (!device_snapshot.get_pcie_id(key, record.pcie_id, why) || !device_snapshot.get_global_function_id(key, record.global_function_id, why) || !device_snapshot.list_bars(key, record.bars, why) || !device_snapshot.get_expected_af(af, af_bar, why))
		return 0;
	record.is_af = dpu_same_function_key(key, af);
	record.services.delete();
	device_snapshot.list_services(DPU_SERVICE_VIO_NET, keys);
	foreach (keys[i])
	if (dpu_same_function_key(key, keys[i].function_key)) record.services.push_back(keys[i]);
	return 1;
endfunction

// AF 额外资源只来自同一资源快照，不虚构 ring。
function void dpu_env_cfg::list_af_extra_queues(output dpu_af_extra_queue_binding_t records[$]);
	records.delete();
	if (resource_snapshot != null) resource_snapshot.list_af_extra_queue_bindings(records);
endfunction

// 发布仅接受同源且冻结的 device/resources/BAR；消息与分组先在局部值中验证。
// 全部通过后才更新句柄及冻结值；首次或再次发布失败都保持原来的可见状态。
function bit dpu_env_cfg::publish(
	input dpu_device_snapshot	device,
	input dpu_resource_snapshot	resources,
	input dpu_bar_map			map,
	output string				why
);
	dpu_bar_mapping_cfg_t	groups[$];
	dpu_env_cfg				candidate;

	why = "publication requires frozen device/resources/BAR map";
	if (device == null || resources == null || map == null) return 0;
	if (!device.is_frozen() || !resources.is_frozen() || !map.is_frozen()) return 0;
	if (!resources.references_device_snapshot(device) || !map.references_device_snapshot(device)) begin
		why = "publication device/resources/BAR map refer to different snapshots";
		return 0;
	end
	if (device_snapshot != null && device_snapshot != device) begin
		why = "new device snapshot requires environment rebuild";
		return 0;
	end
	// 复用现有 cfg 查询和消息生成，不提前改写 this；临时 cfg 不采样参数或分配资源。
	candidate                      = new("publication_candidate");
	candidate.device_snapshot      = device;
	candidate.messages             = messages;
	candidate.authored_messages    = authored_messages;
	candidate.message_inputs_saved = message_inputs_saved;
	candidate.message_templates    = message_templates;
	if (!candidate.materialize_messages(resources, why)) return 0;
	groups = bar_groups;
	begin
		dpu_function_record_t	functions[$];

		candidate.list_functions(functions);
		if (bar_mapping_per_lease && (bar_group_policies.size() != 0 || bar_groups.size() != 0)) begin
			why = "BAR per-lease and explicit group declarations are mutually exclusive";
			return 0;
		end
		if (bar_mapping_per_lease) begin
			foreach (functions[f])
			foreach (functions[f].bars[b]) begin
				dpu_bar_mapping_cfg_t	group;
				dpu_bar_target_t		target;

				if (!map.resolve_function(
						functions[f].key, functions[f].bars[b].even_bar_id, target, why
					))
					return 0;
				group.owners.push_back(functions[f]);
				group.members.push_back(target);
				group.ctx           = dpu_empty_context(target);
				group.ctx.layout_id = "platform-bar-per-lease";
				groups.push_back(group);
			end
		end else
			foreach (bar_group_policies[g]) begin
				dpu_bar_mapping_cfg_t	group;
				dpu_bar_target_t		target;
				dpu_function_record_t	owner;

				if (bar_group_policies[g].functions.size() == 0 ||
				bar_group_policies[g].functions.size() != bar_group_policies[g].bar_ids.size()) begin
					why = "BAR atomic group requires complete Function/BAR pairs";
					return 0;
				end
				foreach (bar_group_policies[g].functions[m]) begin
					if (!candidate.get_function(bar_group_policies[g].functions[m], owner) ||
						!map.resolve_function(owner.key, bar_group_policies[g].bar_ids[m], target, why))
						return 0;
					group.owners.push_back(owner);
					group.members.push_back(target);
				end
				group.ctx           = dpu_empty_context(group.members[0]);
				group.ctx.layout_id = bar_group_policies[g].name;
				groups.push_back(group);
			end
	end
	foreach (candidate.messages[i]) begin
		dpu_function_record_t	owner;

		if (!candidate.get_function(candidate.messages[i].owner, owner) ||
			$isunknown({candidate.messages[i].address, candidate.messages[i].data, candidate.messages[i].masked}) ||
			candidate.messages[i].address[1:0] != 0 || candidate.messages[i].local_vector >= 64 ||
			candidate.messages[i].global_vector >= 8192) begin
			why = "public MSI-X catalog contains invalid owner/address/vector";
			return 0;
		end
		foreach (candidate.messages[j])
		if (j < i &&
			candidate.messages[i].owner.host_id == candidate.messages[j].owner.host_id &&
			((candidate.messages[i].address == candidate.messages[j].address &&
				candidate.messages[i].data == candidate.messages[j].data) ||
			(dpu_same_function_key(candidate.messages[i].owner, candidate.messages[j].owner) &&
				candidate.messages[i].local_vector == candidate.messages[j].local_vector))) begin
			why = "public MSI-X catalog has ambiguous message or duplicate vector";
			return 0;
		end
	end
	// 此后没有可能失败的分支；一起发布身份、生成消息和公共表冻结值。
	device_snapshot      = device;
	resource_snapshot    = resources;
	bar_map              = map;
	messages             = candidate.messages;
	authored_messages    = candidate.authored_messages;
	message_inputs_saved = candidate.message_inputs_saved;
	frozen_messages      = candidate.messages;
	frozen_layouts       = table_layouts;
	frozen_functions     = function_policies;
	frozen_policies      = vio_policies;
	frozen_reg_target    = reg_target;
	frozen_bar_groups    = groups;
	frozen_controls      = platform_controls;
	frozen_msix_policies = msix_policies;
	runtime_ready        = 1;
	why                  = "";
	return 1;
endfunction

// 接收 VIO 缓存的最终需求；首次构建时生成固定 placement，重载时只刷新同一 service 的值。
function void dpu_env_cfg::add_vio_service(
	input dpu_vio_service_t	service,
	input bit				create_request = 1
);
	dpu_vio_placement_request	request;

	services[dpu_service_key_name(service.service_key)] = service;
	if (!create_request || !service.enabled) return;
	request = dpu_vio_placement_request::type_id::create(dpu_service_key_name(service.service_key));
	request.request_id = placement_cfg.vio_requests.size();
	request.service_instance_id = service.service_key.service_instance_id;
	request.total_qpairs = service.qpairs;
	request.candidate_kind = service.service_key.function_key.kind == DPU_FUNCTION_VF ?
		DPU_VIO_CANDIDATE_VF_ONLY : DPU_VIO_CANDIDATE_PF_ONLY;
	request.device_policy = DPU_VIO_DEVICE_FIXED;
	request.fixed_devices.push_back(service.service_key.function_key);
	placement_cfg.vio_requests.push_back(request);
endfunction

// 接收 VIO 全部实际 ring 导出；只校验资源关联，不分配内存或重新采样参数。
// 资源身份错误不接收新队列；策略校验失败时保留实际队列供排查，不确认或释放 ring。
function bit dpu_env_cfg::set_queues(
	input dpu_vio_queue_t	queues[$],
	output string			why
);
	dpu_vio_queue_t			pending[int unsigned][$];
	dpu_vio_qpair_binding_t	pair;
	bit						seen[string];
	string					key;

	why = "queue export requires published resources";
	if (!runtime_ready || resource_snapshot == null) return 0;
	foreach (queues[i]) begin
		key =
			$sformatf("%s.q%0d", dpu_service_key_name(queues[i].service_key), queues[i].local_qid);
		if (queues[i].snapshot != device_snapshot || queues[i].generation == 0 || seen.exists(key) || !resource_snapshot.get_vio_binding_by_service_virtio_pair(
				queues[i].service_key, queues[i].qpair.virtio_pair_index, pair
			) || pair != queues[i].qpair || queues[i].local_qid !=
				(queues[i].tx_mode ? pair.tx_local_virtqueue_id : pair.rx_local_virtqueue_id)) begin
			why = {"queue export differs from allocated resource: ", key};
			return 0;
		end
		seen[key] = 1;
		pending[queues[i].service_key.function_key.host_id].push_back(queues[i]);
	end
	queues_by_host  = pending;
	frozen_policies = vio_policies;
	return materialize_qsch_controls(why) && materialize_notify_records(why);
endfunction

// 核对当前已导出的实际队列，拒绝释放后旧记录；VIO 的启停/确认仍由 VIO 管理。
function bit dpu_env_cfg::check_queue(
	input dpu_vio_queue_t	queue,
	output string			why
);
	int unsigned	h;

	h   = queue.service_key.function_key.host_id;
	why = "queue export is no longer current";
	if (!queues_by_host.exists(h)) return 0;
	foreach (queues_by_host[h][q])
	if (queues_by_host[h][q] === queue) begin
		why = "";
		return 1;
	end
	return 0;
endfunction

// VIO 确认 DUT 静止且释放 ring 后调用；保留其他 Host 的实际目录和硬件行号。
function void dpu_env_cfg::clear_host_queues(input int unsigned	host_id);
	string	remove_keys[$];

	queues_by_host.delete(host_id);
	for (int	i = notify_records.size() - 1; i >= 0; i--)
	if (notify_records[i].owner.host_id == host_id) notify_records.delete(i);
	foreach (records[name]) begin
		if (records[name].ctx.kind inside {DPU_TABLE_N2G, DPU_TABLE_G2P, DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT}) begin
			for (int	c = records[name].consumers.size() - 1; c >= 0; c--)
			if (records[name].consumers[c].function_key.host_id == host_id)
				records[name].consumers.delete(c);
			if (records[name].consumers.size() == 0) remove_keys.push_back(name);
		end else if (records[name].has_queue && records[name].owner.host_id == host_id)
			remove_keys.push_back(name);
	end
	foreach (remove_keys[i]) records.delete(remove_keys[i]);
endfunction
