// integration/pcie：在同一个 DPU BAR map 上绑定 Host RC 和 Intel 路由。
// 不创建地址或内存，sequencer/快照均借用；所有 Memory/Completion 发送前检查实际路由。
// 平台 requester 编码可不同于快照 BDF；显式记录可避免 EP/SW 模式推断。
typedef struct {
	dpu_function_key_t	function_key;
	int unsigned		pf_index;
	int					vf_index;
	bit [15:0]			requester_id;
} dpu_intel_function_route_t;

class dpu_pcie_bar_map extends dpu_bar_map;
	`uvm_object_utils(dpu_pcie_bar_map)
	protected int unsigned					m_slot_by_host[int unsigned];
	protected dpu_intel_function_route_t	m_routes[string];

	uvm_sequencer #(pcie_tl_tlp)			rc_sequencers[int unsigned];

	// 创建空路由目录，初始化和冻结由发布方依次完成。
	extern function new(string	name = "dpu_pcie_bar_map");

	// 绑定唯一 Host→RC slot；未知 Host、重复 slot 或冻结后修改返回失败。
	extern function bit bind_host(
		int unsigned	host_id,
		int unsigned	rc_slot,
		output string	why
	);

	// 绑定实际 Intel PF/VF 与 requester；检查位宽和同域歧义，不分配 BDF。
	extern function bit bind_function(
		dpu_function_key_t	key,
		int unsigned		pf_index,
		int					vf_index,
		bit [15:0]			requester_id,
		output string		why
	);

	// 查询已冻结 Host/segment 的 RC 下标；未知域不回退到 RC0。
	extern function bit get_slot(
		int unsigned		host_id,
		int unsigned		segment_id,
		output int unsigned	rc_slot,
		output string		why
	);

	// 以实际 BAR 地址和完整访问跨度查找 Intel 路由，跨租约请求返回失败。
	extern function bit route_memory(
		int unsigned				host_id,
		int unsigned				segment_id,
		bit [63:0]					address,
		bit [63:0]					width_bytes,
		output pcie_tl_cq_route_t	route,
		output string				why
	);

	// 按 Host/segment/requester 查找 Completion 目标；不借用另一 Host 的相同编号。
	extern function bit route_completion(
		int unsigned				host_id,
		int unsigned				segment_id,
		bit [15:0]					requester_id,
		output pcie_tl_cq_route_t	route,
		output string				why
	);

	// 从接收请求的 Host/requester 查找逻辑 Function 和冻结 BDF，供 IOMMU 选择。
	extern function bit resolve_requester(
		input int unsigned				host_id,
		input bit [15:0]				requester_id,
		output dpu_function_key_t		key,
		output dpu_pcie_function_id_t	pcie_id,
		output string					why
	);

	// 所有 Host 有唯一 RC 才冻结；Function 路由仍在实际发送前检查。
	extern virtual function bit freeze(output string	why);
	// 从真实租约构造 Intel sideband；未绑定 Function 时明确失败。
	extern function bit get_route(
		input dpu_bar_target_t		target,
		output pcie_tl_cq_route_t	route,
		output string				why
	);
	// 返回实际 Host 的 RC，不按 BAR owner 推测 slot。
	extern function bit get_sequencer(
		input dpu_bar_target_t				target,
		output uvm_sequencer#(pcie_tl_tlp)	sequencer,
		output string						why
	);
endclass

// 基类只冻结资源；PCIe 扩展先检查所有 Host/segment 均可路由。
function bit dpu_pcie_bar_map::freeze(output string	why);
	dpu_host_info_t			hosts[$];
	dpu_function_key_t		keys[$];
	dpu_pcie_function_id_t	id;

	if (!mutable(why)) return 0;
	m_snapshot.list_hosts(hosts);
	foreach (hosts[i]) begin
		if (!m_slot_by_host.exists(hosts[i].host_id)) begin
			why = "snapshot Host has no RC binding";
			return 0;
		end
	end
	m_snapshot.list_functions(keys);
	foreach (keys[i]) begin
		if (!m_snapshot.get_pcie_id(keys[i], id, why)) return 0;
		if (id.domain.segment_id != 0) begin
			why = "Intel route requires segment 0";
			return 0;
		end
	end
	return super.freeze(why);
endfunction

// 不缓存第二份 BAR；sideband 始终从已校验的实际目标及显式 Function 映射生成。
function bit dpu_pcie_bar_map::get_route(
	input dpu_bar_target_t		target,
	output pcie_tl_cq_route_t	route,
	output string				why
);
	string		name;
	bit [63:0]	address;

	route = pcie_tl_cq_route_default();
	if (!check_range(target, 0, 1, address, why)) return 0;
	name = dpu_function_key_name(target.function_key);
	if (!m_routes.exists(name)) begin
		why = "Function has no Intel route binding";
		return 0;
	end
	route.valid        = 1;
	route.target_bdf   = target.pcie_id.bdf;
	route.target_func  = target.pcie_id.bdf[7:0];
	route.bar_id       = 3'(target.bar_lease.even_bar_id);
	route.bar_aperture = 6'($clog2(target.bar_lease.size));
	route.pf_index     = int'(m_routes[name].pf_index);
	route.is_vf        = target.function_key.kind == DPU_FUNCTION_VF;
	route.vf_index     = m_routes[name].vf_index;
	return 1;
endfunction

// 发送前同时验证 Function 路由及 RC 句柄；失败不回退到调用者所在的其他 Host。
function bit dpu_pcie_bar_map::get_sequencer(
	input dpu_bar_target_t				target,
	output uvm_sequencer#(pcie_tl_tlp)	sequencer,
	output string						why
);
	int unsigned		slot;
	pcie_tl_cq_route_t	route;

	sequencer = null;
	if (!get_route(target, route, why) || !get_slot(target.function_key.host_id, target.pcie_id.domain.segment_id, slot, why))
		return 0;
	if (!rc_sequencers.exists(slot) || rc_sequencers[slot] == null) begin
		why = "Host has no RC sequencer";
		return 0;
	end
	sequencer = rc_sequencers[slot];
	return 1;
endfunction

// 创建空对象；调用 initialize 前任何查询/绑定都失败。
function dpu_pcie_bar_map::new(string	name);
	super.new(name);
endfunction

// Host 与 RC slot 一一对应；重复/未知 Host 或冻结后修改均失败。
function bit dpu_pcie_bar_map::bind_host(
	int unsigned	host_id,
	int unsigned	rc_slot,
	output string	why
);
	dpu_host_info_t	hosts[$];
	bit				found;

	if (!mutable(why)) begin
		return 0;
	end
	m_snapshot.list_hosts(hosts);

	foreach (hosts[i]) begin
		if (hosts[i].host_id == host_id) begin
			found = 1;
		end
	end

	if (!found || m_slot_by_host.exists(host_id)) begin
		why = "unknown or duplicate Host binding";
		return 0;
	end

	foreach (m_slot_by_host[h]) begin
		if (m_slot_by_host[h] == rc_slot) begin
			why = "RC slot already belongs to another Host";
			return 0;
		end
	end
	m_slot_by_host[host_id] = rc_slot;
	return 1;
endfunction

// 显式绑定 Intel 3 位 PF/11 位 VF 与 DMA requester；PF 的 vf_index 必须为 -1。
function bit dpu_pcie_bar_map::bind_function(
	dpu_function_key_t	key,
	int unsigned		pf_index,
	int					vf_index,
	bit [15:0]			requester_id,
	output string		why
);
	dpu_pcie_function_id_t	id;
	string					key_name;

	if (!mutable(why)) begin
		return 0;
	end

	if (!m_snapshot.get_pcie_id(key, id, why)) begin
		return 0;
	end
	key_name = dpu_function_key_name(key);

	if (id.domain.segment_id != 0 || pf_index > 7 ||
		(key.kind == DPU_FUNCTION_PF && vf_index != -1) ||
		(key.kind == DPU_FUNCTION_VF && (vf_index < 0 || vf_index > 2047))) begin
		why = "Intel route exceeds PF/VF width or unsupported segment/kind";
		return 0;
	end

	if (m_routes.exists(key_name)) begin
		why = "duplicate Function route binding";
		return 0;
	end

	foreach (m_routes[k]) begin
		if (m_routes[k].function_key.host_id == key.host_id) begin
			if (m_routes[k].requester_id == requester_id ||
				(m_routes[k].pf_index == pf_index && m_routes[k].vf_index == vf_index)) begin
				why = "ambiguous Intel Function or requester binding in Host domain";
				return 0;
			end
		end
	end
	m_routes[key_name] = '{key, pf_index, vf_index, requester_id};
	return 1;
endfunction

// 验证指定 Host/segment 的 RC slot；segment 当前只接受 0。
function bit dpu_pcie_bar_map::get_slot(
	int unsigned		host_id,
	int unsigned		segment_id,
	output int unsigned	rc_slot,
	output string		why
);
	rc_slot = 0;
	why     = "";

	if (!m_frozen || segment_id != 0 || !m_slot_by_host.exists(host_id)) begin
		why = "BAR registry not ready or Host/segment route missing";
		return 0;
	end
	rc_slot = m_slot_by_host[host_id];
	return 1;
endfunction

// Memory 使用实际窗口和整个字节跨度；不读取或改变 requester 身份。
function bit dpu_pcie_bar_map::route_memory(
	int unsigned				host_id,
	int unsigned				segment_id,
	bit [63:0]					address,
	bit [63:0]					width_bytes,
	output pcie_tl_cq_route_t	route,
	output string				why
);
	int unsigned	slot;
	int				match_index;
	bit [63:0]		checked;

	route = pcie_tl_cq_route_default();

	if (!get_slot(host_id, segment_id, slot, why)) begin
		return 0;
	end
	match_index = -1;

	foreach (m_targets[i]) begin
		if (m_targets[i].function_key.host_id == host_id &&
			address >= m_targets[i].bar_lease.base && address - m_targets[i].bar_lease.base < m_targets[i].bar_lease.size) begin
			if (match_index >= 0) begin
				why = "ambiguous Memory address in Host domain";
				return 0;
			end
			match_index = i;
		end
	end

	if (match_index < 0) begin
		why = "Memory address has no registered BAR window";
		return 0;
	end

	if (!check_range(
			m_targets[match_index],
			address - m_targets[match_index].bar_lease.base,
			width_bytes,
			checked,
			why
		)) begin
		return 0;
	end
	if (!get_route(m_targets[match_index], route, why)) return 0;
	route.bar_offset = address - m_targets[match_index].bar_lease.base;
	return 1;
endfunction

// Completion 反查原 Requester ID，完全独立于 Memory 地址和 BAR 归属。
function bit dpu_pcie_bar_map::route_completion(
	int unsigned				host_id,
	int unsigned				segment_id,
	bit [15:0]					requester_id,
	output pcie_tl_cq_route_t	route,
	output string				why
);
	int unsigned			slot;
	dpu_pcie_function_id_t	id;

	route = pcie_tl_cq_route_default();

	if (!get_slot(host_id, segment_id, slot, why)) begin
		return 0;
	end

	foreach (m_routes[k]) begin
		if (m_routes[k].function_key.host_id == host_id && m_routes[k].requester_id == requester_id) begin
			if (!m_snapshot.get_pcie_id(m_routes[k].function_key, id, why)) begin
				return 0;
			end
			route.valid       = 1;
			route.target_bdf  = id.bdf;
			route.target_func = id.bdf[7:0];
			route.pf_index    = int'(m_routes[k].pf_index);
			route.is_vf       = m_routes[k].function_key.kind == DPU_FUNCTION_VF;
			route.vf_index    = m_routes[k].vf_index;
			return 1;
		end
	end
	why = "Completion Requester ID has no explicit Intel Function mapping";
	return 0;
endfunction

// 只读遍历平台 requester 映射；只有冻结 registry 可用于接收，未知身份明确拒绝。
function bit dpu_pcie_bar_map::resolve_requester(
	input int unsigned				host_id,
	input bit [15:0]				requester_id,
	output dpu_function_key_t		key,
	output dpu_pcie_function_id_t	pcie_id,
	output string					why
);
	why = "unknown DMA requester in frozen Host registry";
	if (!m_frozen) return 0;
	foreach (m_routes[name]) begin
		if (m_routes[name].function_key.host_id == host_id &&
			m_routes[name].requester_id == requester_id) begin
			key = m_routes[name].function_key;
			return m_snapshot.get_pcie_id(key, pcie_id, why);
		end
	end
	return 0;
endfunction
