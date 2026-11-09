// src：可选 DPU 资源发布组件；只负责 resolver 和 config_db 资源绑定。
// 不执行旧 bootstrap/双 bank 寄存器流程；真实 DUT 写表由 dpu_cfg_seq 执行。
// env 拥有 resource_manager，借用用户 dpu_env_cfg，子环境共享同一冻结资源和 Host pool。
class dpu_device_env extends uvm_env;
	`uvm_component_utils(dpu_device_env)

	protected dpu_device_snapshot	snapshot;
	protected dpu_resource_snapshot	resource_snapshot;
	protected dpu_resource_manager	resource_manager;
	protected dpu_device_state_e	state;

	// 仅构造发布组件，资源在 build 阶段统一解析。
	extern function new(
		string			name,
		uvm_component	parent
	);

	// 使用传入 authoring cfg 解析一次；发布同一组快照和管理器，失败终止构建。
	extern virtual function void build_phase(uvm_phase	phase);

	// 返回借用的冻结设备快照；build 完成前为空。
	extern function dpu_device_snapshot get_snapshot();

	// 返回本 env 拥有的唯一资源管理器，不分配第二份资源。
	extern function dpu_resource_manager get_resource_manager();

	// 返回借用的队列/向量快照；build 完成前为空。
	extern function dpu_resource_snapshot get_resource_snapshot();

	// 仅表示软件资源解析状态，不表示 DUT 已配置。
	extern function dpu_device_state_e get_state();

endclass

// 构造资源发布组件，不分配或写 DUT。
function dpu_device_env::new(
	string			name,
	uvm_component	parent
);
	super.new(name, parent);
	snapshot          = null;
	resource_snapshot = null;
	resource_manager  = null;
	state             = DPU_DEVICE_UNRESOLVED;
endfunction

// 解析一次拓扑/资源，发布同一快照和管理器供子环境借用；失败立即终止构建。
function void dpu_device_env::build_phase(uvm_phase	phase);
	dpu_env_cfg						cfg;
	dpu_configuration_resolver		configuration_resolver;
	dpu_device_snapshot				candidate_snapshot;
	dpu_resource_snapshot			candidate_resource_snapshot;
	dpu_resource_manager			candidate_manager;
	dpu_resource_registry_authority	authority;
	string							why;

	super.build_phase(phase);
	if (!uvm_config_db#(dpu_env_cfg)::get(this, "", "cfg", cfg)) begin
		`uvm_fatal("DPU_DEVICE_ENV", "device environment configuration 'cfg' is missing")
		return;
	end
	if (cfg == null) begin
		`uvm_fatal("DPU_DEVICE_ENV", "device environment configuration is null")
		return;
	end
	candidate_manager = dpu_resource_manager::type_id::create("dpu_resource_manager");
	authority         = candidate_manager.claim_registry_authority();
	if (authority == null) begin
		`uvm_fatal("DPU_DEVICE_ENV", "resource manager authority claim failed")
		return;
	end
	if (cfg.placement_cfg == null) begin
		`uvm_fatal("DPU_DEVICE_ENV", "device environment placement configuration is null")
		return;
	end
	begin
		dpu_placement_diagnostic	diagnostic;

		configuration_resolver =
			dpu_configuration_resolver::type_id::create("dpu_configuration_resolver");
		if (!configuration_resolver.resolve(
				cfg.device_cfg,
				cfg.placement_cfg,
				candidate_snapshot,
				candidate_resource_snapshot,
				diagnostic
			)) begin
			`uvm_fatal("DPU_DEVICE_ENV", {"configuration resolution failed: ", diagnostic.message})
			return;
		end
		if (!candidate_manager.configure_from_snapshots(
				authority, candidate_snapshot, candidate_resource_snapshot, why
			)) begin
			`uvm_fatal("DPU_DEVICE_ENV", {"resource manager seeding failed: ", why})
			return;
		end
	end
	snapshot          = candidate_snapshot;
	resource_snapshot = candidate_resource_snapshot;
	resource_manager  = candidate_manager;
	state             = DPU_DEVICE_RESOLVED;
	uvm_config_db#(dpu_device_snapshot)::set(this, "*", "dpu_device_snapshot", snapshot);
	uvm_config_db#(dpu_resource_snapshot)::set(this, "*", "dpu_resource_snapshot",
											   resource_snapshot);
	uvm_config_db#(dpu_resource_manager)::set(this, "*", "dpu_resource_manager", resource_manager);
	if (cfg.host_mem_pool_ref != null)
		uvm_config_db#(uvm_object)::set(this, "*", "dpu_host_mem_pool", cfg.host_mem_pool_ref);
endfunction

// 返回借用的冻结设备快照。
function dpu_device_snapshot dpu_device_env::get_snapshot();
	return snapshot;
endfunction

// 返回唯一资源管理器，调用者不创建第二份。
function dpu_resource_manager dpu_device_env::get_resource_manager();
	return resource_manager;
endfunction

// 返回借用的冻结队列/向量资源。
function dpu_resource_snapshot dpu_device_env::get_resource_snapshot();
	return resource_snapshot;
endfunction

// 返回解析状态；DUT 配置状态由配置 sequence 报告。
function dpu_device_state_e dpu_device_env::get_state();
	return state;
endfunction
