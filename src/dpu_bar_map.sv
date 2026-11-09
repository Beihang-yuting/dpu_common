// src：冻结 BAR 租约的唯一查询视图，不依赖 PCIe/VIO，不分配资源。
// 对象借用 DPU snapshot；initialize 后建立值目录，freeze 后只读，目标与发布校验保留同一快照身份。
typedef struct {
	dpu_function_key_t		function_key;
	dpu_pcie_function_id_t	pcie_id;
	int unsigned			global_function_id;
	dpu_bar_pair_lease_t	bar_lease;
	string					canonical_name;
	dpu_device_snapshot		snapshot;
	longint unsigned		snapshot_generation;
} dpu_bar_target_t;

class dpu_bar_map extends uvm_object;
	`uvm_object_utils(dpu_bar_map)
	protected dpu_device_snapshot	m_snapshot;
	protected longint unsigned		m_generation;
	protected bit					m_frozen;
	protected dpu_bar_target_t		m_targets[$];
	protected static bit			m_auto_printed[string];

	// 创建空对象；调用 initialize 前任何查询/绑定都失败。
	extern function new(string	name = "dpu_bar_map");

	// 借用冻结快照，generation 由发布方提供且非零；禁止二次初始化。
	extern function bit initialize(
		dpu_device_snapshot	snapshot,
		longint unsigned	generation,
		output string		why
	);

	// 冻结实际 BAR 目录；核心不依赖 PCIe 路由，发送前由 PCIe 集成层检查绑定。
	extern virtual function bit freeze(output string	why);

	// 判断生命周期；不给调用方可写内部容器。
	extern function bit is_frozen();

	// 发布前核对借用的设备身份；只接受冻结目录与同一非空快照，不导出可写句柄。
	extern function bit references_device_snapshot(input dpu_device_snapshot	snapshot);

	// 严格完整解析名字；显式前缀与访问上下文冲突时报错，无上下文只允许唯一 Host。
	extern function bit resolve_name(
		string					name,
		output dpu_bar_target_t	target,
		output string			why,
		input bit				has_access_host = 0,
		input int unsigned		access_host = 0
	);

	// 使用完整 Function 和实际偶数 BAR ID 查询，绝不把 ID 当成 role。
	extern function bit resolve_function(
		dpu_function_key_t		key,
		int unsigned			bar_id,
		output dpu_bar_target_t	target,
		output string			why
	);

	// 高级调试只接受真实 base，域内须唯一；BAR 内部地址不是 base。
	extern function bit resolve_base(
		int unsigned			host_id,
		int unsigned			segment_id,
		bit [63:0]				base,
		output dpu_bar_target_t	target,
		output string			why
	);

	// 校验引用身份及内容后以 65 位检查完整区间；失败地址清零，width 不可为零。
	extern function bit check_range(
		dpu_bar_target_t	target,
		bit [63:0]			byte_offset,
		bit [63:0]			width_bytes,
		output bit [63:0]	address,
		output string		why
	);

	// 一次输出按 Host/Function 分组的地址清单，共享身份不逐 BAR 重复；不展开内部结构体。
	// 保留冻结时的稳定顺序与自动去重语义，手工调用可重复查看同一份资源。
	extern function bit print_bar_map(
		output string	why,
		input bit		automatic_print = 0
	);

	// 统一状态门；只在未冻结的已初始化对象上允许构建操作。
	extern protected function bit mutable(output string	why);

	// 严格消费文字 token；失败时不推进 cursor。
	extern protected function bit consume(
		string				name,
		string				token,
		ref int unsigned	cursor
	);

	// 逐字符十进制累积，提前检查 uint 溢出，至少要求一位数字。
	extern protected function bit decimal(
		string				name,
		ref int unsigned	cursor,
		output int unsigned	value
	);
endclass

// 创建空对象；调用 initialize 前任何查询/绑定都失败。
function dpu_bar_map::new(string	name = "dpu_bar_map");
	super.new(name);
endfunction

// 借用冻结快照，generation 由发布方提供且非零；禁止二次初始化。
function bit dpu_bar_map::initialize(
	dpu_device_snapshot	snapshot,
	longint unsigned	generation,
	output string		why
);
	why = "";

	if (m_snapshot != null || snapshot == null || generation == 0) begin
		why = "BAR registry requires a new instance, frozen snapshot and nonzero generation";
		return 0;
	end

	if (!snapshot.is_frozen()) begin
		why = "BAR registry snapshot is not frozen";
		return 0;
	end
	m_snapshot   = snapshot;
	m_generation = generation;
	return 1;
endfunction

// 冻结实际 BAR 目录；核心不依赖 PCIe 路由，发送前由 PCIe 集成层检查绑定。
function bit dpu_bar_map::freeze(output string	why);
	dpu_function_key_t	keys[$];
	dpu_bar_target_t	pending[$];

	if (!mutable(why)) begin
		return 0;
	end
	m_snapshot.list_functions(keys);

	foreach (keys[i]) begin
		dpu_bar_pair_lease_t	bars[$];
		dpu_pcie_function_id_t	id;
		int unsigned			global_id;
		string					key_name;

		if (!m_snapshot.get_pcie_id(keys[i], id, why) || !m_snapshot.get_global_function_id(keys[i], global_id, why) || !m_snapshot.list_bars(keys[i], bars, why)) begin
			return 0;
		end

		key_name = dpu_function_key_name(keys[i]);

		// DPU 的列表按 role 排序；这里按真实 BAR 编号排序，避免展示顺序暗示 role=id。
		bars.sort() with (item.even_bar_id);

		foreach (bars[b]) begin
			dpu_bar_target_t	target;

			if (bars[b].even_bar_id > 4 || bars[b].even_bar_id[0] || bars[b].size == 0) begin
				why = "invalid 64-bit BAR pair id or empty lease";
				return 0;
			end

			if (b > 0 && bars[b-1].even_bar_id == bars[b].even_bar_id) begin
				why = "duplicate BAR id within Function";
				return 0;
			end
			target.function_key       = keys[i];
			target.pcie_id            = id;
			target.global_function_id = global_id;
			target.bar_lease          = bars[b];
			target.canonical_name     = $sformatf("h%0d.pf%0d", keys[i].host_id, keys[i].pf_id);

			if (keys[i].kind == DPU_FUNCTION_VF) begin
				target.canonical_name = {target.canonical_name, $sformatf(".vf%0d", keys[i].vf_id)};
			end
			target.canonical_name = {
				target.canonical_name, $sformatf(".bar%0d", bars[b].even_bar_id)
			};
			target.snapshot = m_snapshot;
			target.snapshot_generation = m_generation;
			pending.push_back(target);
		end
	end
	m_targets = pending;
	m_frozen  = 1;
	why       = "";
	return 1;
endfunction

// 判断生命周期；不给调用方可写内部容器。
function bit dpu_bar_map::is_frozen();
	return m_frozen;
endfunction

// 发布前核对借用的设备身份；只接受冻结目录与同一非空快照，不导出可写句柄。
function bit dpu_bar_map::references_device_snapshot(input dpu_device_snapshot	snapshot);
	return m_frozen && snapshot != null && snapshot == m_snapshot;
endfunction

// 严格完整解析名字；显式前缀与访问上下文冲突时报错，无上下文只允许唯一 Host。
function bit dpu_bar_map::resolve_name(
	string					name,
	output dpu_bar_target_t	target,
	output string			why,
	input bit				has_access_host = 0,
	input int unsigned		access_host = 0
);
	dpu_function_key_t	key;
	int unsigned		cursor;
	int unsigned		bar_id;
	dpu_host_info_t		hosts[$];
	bit					explicit_host;

	target = '{
		function_key: '{0, 0, DPU_FUNCTION_PF, 0},
		bar_lease: '{DPU_BAR_DEVICE_MEMORY, 0, 0, 0},
		snapshot: null,
		canonical_name: "",
		default: 0
	};
	key = '{0, 0, DPU_FUNCTION_PF, 0};
	cursor = 0;
	why = {"invalid BAR target syntax: ", name};
	explicit_host = consume(name, "h", cursor);

	if (explicit_host) begin
		if (!decimal(name, cursor, key.host_id) || !consume(name, ".", cursor)) begin
			return 0;
		end

		if (has_access_host && key.host_id != access_host) begin
			why = "explicit target Host conflicts with access Host";
			return 0;
		end
	end

	if (!consume(name, "pf", cursor) || !decimal(name, cursor, key.pf_id)) begin
		return 0;
	end

	if (consume(name, ".vf", cursor)) begin
		key.kind = DPU_FUNCTION_VF;

		if (!decimal(name, cursor, key.vf_id)) begin
			return 0;
		end
	end

	if (!consume(name, ".bar", cursor) || !decimal(name, cursor, bar_id) || cursor != name.len()) begin
		return 0;
	end

	if (m_snapshot == null || !m_frozen) begin
		why = "BAR map is not frozen";
		return 0;
	end
	m_snapshot.list_hosts(hosts);
	if (!explicit_host) begin
		if (has_access_host) begin
			key.host_id = access_host;
		end else if (hosts.size() == 1) begin
			key.host_id = hosts[0].host_id;
		end else begin
			why = "short BAR target requires explicit access Host in multi-Host registry";
			return 0;
		end
	end
	return resolve_function(key, bar_id, target, why);
endfunction

// 使用完整 Function 和实际偶数 BAR ID 查询，绝不把 ID 当成 role。
function bit dpu_bar_map::resolve_function(
	dpu_function_key_t		key,
	int unsigned			bar_id,
	output dpu_bar_target_t	target,
	output string			why
);
	target = '{
		function_key: '{0, 0, DPU_FUNCTION_PF, 0},
		bar_lease: '{DPU_BAR_DEVICE_MEMORY, 0, 0, 0},
		snapshot: null,
		canonical_name: "",
		default: 0
	};
	why = "BAR registry not frozen, Function/BAR unknown,";

	if (!m_frozen) begin
		return 0;
	end

	foreach (m_targets[i]) begin
		if (dpu_same_function_key(m_targets[i].function_key, key) && m_targets[i].bar_lease.even_bar_id == bar_id) begin
			target = m_targets[i];
			why    = "";
			return 1;
		end
	end
	return 0;
endfunction

// 高级调试只接受真实 base，域内须唯一；BAR 内部地址不是 base。
function bit dpu_bar_map::resolve_base(
	int unsigned			host_id,
	int unsigned			segment_id,
	bit [63:0]				base,
	output dpu_bar_target_t	target,
	output string			why
);
	int	match_index;

	target = '{
		function_key: '{0, 0, DPU_FUNCTION_PF, 0},
		bar_lease: '{DPU_BAR_DEVICE_MEMORY, 0, 0, 0},
		snapshot: null,
		canonical_name: "",
		default: 0
	};

	if (!m_frozen) begin
		return 0;
	end
	match_index = -1;

	foreach (m_targets[i]) begin
		if (m_targets[i].function_key.host_id == host_id &&
			m_targets[i].pcie_id.domain.segment_id == segment_id && m_targets[i].bar_lease.base == base) begin
			if (match_index >= 0) begin
				why = "ambiguous BAR base in domain";
				return 0;
			end
			match_index = i;
		end
	end

	if (match_index < 0) begin
		why = "address is not a registered BAR base";
		return 0;
	end
	return resolve_function(
		m_targets[match_index].function_key,
		m_targets[match_index].bar_lease.even_bar_id,
		target,
		why
	);
endfunction

// 校验引用身份及内容后以 65 位检查完整区间；失败地址清零，width 不可为零。
function bit dpu_bar_map::check_range(
	dpu_bar_target_t	target,
	bit [63:0]			byte_offset,
	bit [63:0]			width_bytes,
	output bit [63:0]	address,
	output string		why
);
	dpu_bar_target_t	current;
	bit [64:0]			last_offset;
	bit [64:0]			first_address;
	bit [64:0]			last_address;

	address = 0;
	why     = "stale BAR target snapshot or generation";

	if (!m_frozen || target.snapshot != m_snapshot || target.snapshot_generation != m_generation) begin
		return 0;
	end

	if (!resolve_function(target.function_key, target.bar_lease.even_bar_id, current, why)) begin
		return 0;
	end

	if (target.pcie_id != current.pcie_id || target.global_function_id != current.global_function_id ||
		target.bar_lease != current.bar_lease ||
		target.canonical_name != current.canonical_name) begin
		why = "BAR target contents differ from frozen registry";
		return 0;
	end

	if (width_bytes == 0) begin
		why = "BAR access has zero width";
		return 0;
	end
	last_offset   = {1'b0, byte_offset} + {1'b0, width_bytes} - 1;
	first_address = {1'b0, current.bar_lease.base} + {1'b0, byte_offset};
	last_address  = first_address + {1'b0, width_bytes} - 1;
	// 先限制 BAR 内偏移，避免两个 65 位和仍在极大无效输入下发生第二次进位。
	if (last_offset[64] || last_offset >= {1'b0, current.bar_lease.size} || first_address[64] || last_address[64]) begin
		why = "BAR access crosses lease boundary or overflows 64-bit address";
		return 0;
	end
	address = first_address[63:0];
	why     = "";
	return 1;
endfunction

// 一次输出按 Host/Function 分组的地址清单，共享身份不逐 BAR 重复；不展开内部结构体。
// 保留冻结时的稳定顺序与自动去重语义，手工调用可重复查看同一份资源。
function bit dpu_bar_map::print_bar_map(
	output string	why,
	input bit		automatic_print = 0
);
	string				identity;
	string				report;
	string				function_name;
	dpu_function_key_t	previous_key;
	bit					first_row = 1;

	why = "";

	if (!m_frozen) begin
		why = "BAR map is not ready for publication";
		return 0;
	end
	identity = $sformatf("%0d:%0d", m_snapshot.get_inst_id(), m_generation);

	if (automatic_print && m_auto_printed.exists(identity)) begin
		return 1;
	end
	report = $sformatf(
		"BAR map (snapshot=%0d, identity=%0d, windows=%0d)",
		m_generation,
		m_snapshot.get_inst_id(),
		m_targets.size()
	);

	foreach (m_targets[i]) begin
		if (first_row || previous_key.host_id != m_targets[i].function_key.host_id) begin
			report = {
				report,
				$sformatf(
					"\n  Host %0d  (segment=%0d)",
					m_targets[i].function_key.host_id,
					m_targets[i].pcie_id.domain.segment_id
				)
			};
		end

		if (first_row || !dpu_same_function_key(previous_key, m_targets[i].function_key)) begin
			function_name = $sformatf("h%0d.pf%0d", m_targets[i].function_key.host_id,
									  m_targets[i].function_key.pf_id);
			if (m_targets[i].function_key.kind == DPU_FUNCTION_VF)
				function_name = {
					function_name, $sformatf(".vf%0d", m_targets[i].function_key.vf_id)
				};

			report = {
				report,
				$sformatf(
					"\n    %s  (BDF=%04h, global_function=%0d)",
					function_name,
					m_targets[i].pcie_id.bdf,
					m_targets[i].global_function_id
				)
			};
			report = {report, "\n      BAR   Base                Size                Role"};
		end

		report = {
			report,
			$sformatf(
				"\n      %0d     0x%016h  0x%016h  %s",
				m_targets[i].bar_lease.even_bar_id,
				m_targets[i].bar_lease.base,
				m_targets[i].bar_lease.size,
				m_targets[i].bar_lease.role.name()
			)
		};
		previous_key = m_targets[i].function_key;
		first_row = 0;
	end

	`uvm_info("DPU_BAR_MAP", report, UVM_LOW)

	if (automatic_print) begin
		m_auto_printed[identity] = 1;
	end
	return 1;
endfunction

// 统一状态门；只在未冻结的已初始化对象上允许构建操作。
function bit dpu_bar_map::mutable(output string	why);
	why = "";

	if (m_snapshot == null || m_frozen) begin
		why = "BAR registry is uninitialized or frozen";
		return 0;
	end
	return 1;
endfunction

// 严格消费文字 token；失败时不推进 cursor。
function bit dpu_bar_map::consume(
	string				name,
	string				token,
	ref int unsigned	cursor
);
	if (cursor + token.len() > name.len()) begin
		return 0;
	end

	for (int	unsigned	i = 0; i < token.len(); i++) begin
		if (name.getc(cursor + i) != token.getc(i)) begin
			return 0;
		end
	end
	cursor += token.len();
	return 1;
endfunction

// 逐字符十进制累积，提前检查 uint 溢出，至少要求一位数字。
function bit dpu_bar_map::decimal(
	string				name,
	ref int unsigned	cursor,
	output int unsigned	value
);
	int unsigned	start;
	int unsigned	digit;

	start = cursor;
	value = 0;

	while (cursor < name.len() && name.getc(cursor) >= "0" && name.getc(cursor) <= "9") begin
		digit = name.getc(cursor) - "0";

		if (value > (32'hffffffff - digit) / 10) begin
			return 0;
		end
		value = value * 10 + digit;
		cursor++;
	end
	return cursor > start;
endfunction
