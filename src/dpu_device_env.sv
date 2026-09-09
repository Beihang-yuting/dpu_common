/*
 * 所属层次：src/ UVM 设备环境适配层。
 * 文件职责：把设备快照、资源管理器和寄存器计划连接到 UVM 生命周期，协调 bootstrap/VIO 配置与 teardown。
 * 主要依赖：dpu_device_snapshot、dpu_resource_manager、dpu_reg_executor、dpu_vio_register_plan_builder。
 * 所有权与生命周期：env 拥有自身创建的 UVM 子对象，外部 executor/backend 仅借用；失败时保留可诊断终态。
 */
`ifndef DPU_DEVICE_ENV_SV
`define DPU_DEVICE_ENV_SV

// 设计原因：将相关值和操作约束集中在独立边界，避免跨模块重复解释同一契约。
// 职责与所有权：对象/类型按值语义管理自身字段，不隐式取得外部资源或生命周期控制权。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_device_env_config extends uvm_object;
    `uvm_object_utils(dpu_device_env_config)

    dpu_device_cfg device_cfg;
    dpu_resource_placement_cfg placement_cfg;
    dpu_reg_executor executor;
    dpu_vio_register_plan_policy vio_policy;
    dpu_vio_dataplane_plan_extension vio_dataplane_extension;
    // Protocol-neutral ownership hook.  The DPU package does not depend on
    // Virtio Host-memory classes; consumers may publish a typed pool object
    // here and bind it after the snapshot is resolved.
    uvm_object host_mem_pool_ref;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_device_env_config");
        super.new(name);
        device_cfg = dpu_device_cfg::type_id::create({name, "_device_cfg"});
        placement_cfg = dpu_resource_placement_cfg::type_id::create(
            {name, "_placement_cfg"});
        executor = null;
        vio_policy = dpu_vio_register_plan_policy::type_id::create(
            {name, "_vio_policy"});
        vio_dataplane_extension = null;
        host_mem_pool_ref = null;
    endfunction
endclass : dpu_device_env_config


// 设计原因：隔离执行副作用和 UVM 生命周期，使上层计划不依赖具体 backend。
// 职责与所有权：对象拥有本轮执行历史，外部 backend/topology 按接口注入并借用，失败信息由对象保留。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_device_env extends uvm_env;
    `uvm_component_utils(dpu_device_env)

    protected dpu_device_snapshot snapshot;
    protected dpu_resource_snapshot resource_snapshot;
    protected dpu_resource_manager resource_manager;
    protected dpu_config_orchestrator orchestrator;
    protected dpu_vio_register_plan_policy vio_policy;
    protected dpu_vio_dataplane_plan_extension vio_dataplane_extension;
    protected int unsigned active_vio_notify_bank;
    protected dpu_device_state_e state;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name, uvm_component parent);
        super.new(name, parent);
        snapshot = null;
        resource_snapshot = null;
        resource_manager = null;
        orchestrator = null;
        vio_policy = null;
        vio_dataplane_extension = null;
        active_vio_notify_bank = 0;
        state = DPU_DEVICE_UNRESOLVED;
    endfunction

// 功能：执行与对象职责相关的内部辅助操作（build_phase）。
// 输入/输出：输入和输出由函数签名定义；通过返回值或 output 参数报告结果。
// 边界/副作用：除签名明确写入外不产生隐藏副作用，失败时保持状态一致。
    virtual function void build_phase(uvm_phase phase);
        dpu_device_env_config cfg;
        dpu_configuration_resolver configuration_resolver;
        dpu_device_snapshot candidate_snapshot;
        dpu_resource_snapshot candidate_resource_snapshot;
        dpu_resource_manager candidate_manager;
        dpu_resource_registry_authority authority;
        dpu_config_orchestrator candidate_orchestrator;
        string why;

        super.build_phase(phase);
        if (!uvm_config_db#(dpu_device_env_config)::get(this, "", "cfg", cfg)) begin
            `uvm_fatal("DPU_DEVICE_ENV", "device environment configuration 'cfg' is missing")
            return;
        end
        if (cfg == null) begin
            `uvm_fatal("DPU_DEVICE_ENV", "device environment configuration is null")
            return;
        end
        candidate_manager = dpu_resource_manager::type_id::create(
            "dpu_resource_manager"
        );
        authority = candidate_manager.claim_registry_authority();
        if (authority == null) begin
            `uvm_fatal("DPU_DEVICE_ENV", "resource manager authority claim failed")
            return;
        end
        if (cfg.placement_cfg == null) begin
            `uvm_fatal("DPU_DEVICE_ENV", "device environment placement configuration is null")
            return;
        end
        begin
            dpu_placement_diagnostic diagnostic;

            configuration_resolver = dpu_configuration_resolver::type_id::create(
                "dpu_configuration_resolver");
            if (!configuration_resolver.resolve(
                    cfg.device_cfg, cfg.placement_cfg, candidate_snapshot,
                    candidate_resource_snapshot, diagnostic)) begin
                `uvm_fatal("DPU_DEVICE_ENV", {"configuration resolution failed: ",
                           diagnostic.message})
                return;
            end
            if (!candidate_manager.configure_from_snapshots(
                    authority, candidate_snapshot, candidate_resource_snapshot, why)) begin
                `uvm_fatal("DPU_DEVICE_ENV", {"resource manager seeding failed: ", why})
                return;
            end
        end
        candidate_orchestrator = dpu_config_orchestrator::type_id::create(
            "dpu_config_orchestrator");
        if (cfg.executor != null)
            candidate_orchestrator.set_executor(cfg.executor);

        snapshot = candidate_snapshot;
        resource_snapshot = candidate_resource_snapshot;
        resource_manager = candidate_manager;
        orchestrator = candidate_orchestrator;
        if (cfg.executor != null)
            cfg.executor.bind_topology(candidate_snapshot);
        if (cfg.vio_policy == null)
            vio_policy = dpu_vio_register_plan_policy::type_id::create(
                "dpu_device_env_vio_policy");
        else
            vio_policy = cfg.vio_policy;
        active_vio_notify_bank = vio_policy.active_notify_bank;
        vio_dataplane_extension = cfg.vio_dataplane_extension;
        state = DPU_DEVICE_RESOLVED;
        uvm_config_db#(dpu_device_snapshot)::set(
            this, "*", "dpu_device_snapshot", snapshot
        );
        uvm_config_db#(dpu_resource_snapshot)::set(
            this, "*", "dpu_resource_snapshot", resource_snapshot
        );
        uvm_config_db#(dpu_resource_manager)::set(
            this, "*", "dpu_resource_manager", resource_manager
        );
        if (cfg.host_mem_pool_ref != null)
            uvm_config_db#(uvm_object)::set(
                this, "*", "dpu_host_mem_pool", cfg.host_mem_pool_ref
            );
    endfunction

// 功能：按键查询内部索引或导出值复制（get_snapshot）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function dpu_device_snapshot get_snapshot();
        return snapshot;
    endfunction

// 功能：按键查询内部索引或导出值复制（get_resource_manager）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function dpu_resource_manager get_resource_manager();
        return resource_manager;
    endfunction

// 功能：按键查询内部索引或导出值复制（get_resource_snapshot）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function dpu_resource_snapshot get_resource_snapshot();
        return resource_snapshot;
    endfunction

// 功能：按键查询内部索引或导出值复制（get_state）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function dpu_device_state_e get_state();
        return state;
    endfunction

// 功能：按键查询内部索引或导出值复制（find_vio_notify_commit_bank）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    protected function bit find_vio_notify_commit_bank(
        input dpu_reg_plan plan,
        input bit teardown,
        output int unsigned bank
    );
        dpu_reg_op bank0_op;
        dpu_reg_op bank1_op;
        bit has_bank0;
        bit has_bank1;

        bank = 0;
        if (plan == null)
            return 0;
        if (teardown) begin
            has_bank0 = plan.find_operation(
                "vio.teardown.notify.commit.bank0", bank0_op);
            has_bank1 = plan.find_operation(
                "vio.teardown.notify.commit.bank1", bank1_op);
        end else begin
            has_bank0 = plan.find_operation(
                "vio.notify.commit.bank0", bank0_op);
            has_bank1 = plan.find_operation(
                "vio.notify.commit.bank1", bank1_op);
        end
        if (has_bank0 == has_bank1)
            return 0;
        bank = has_bank1 ? 1 : 0;
        return 1;
    endfunction

// 功能：执行与对象职责相关的内部辅助操作（build_bootstrap_plan）。
// 输入/输出：输入和输出由函数签名定义；通过返回值或 output 参数报告结果。
// 边界/副作用：除签名明确写入外不产生隐藏副作用，失败时保持状态一致。
    function bit build_bootstrap_plan(
        output dpu_reg_plan plan,
        output string why
    );
        dpu_device_bootstrap_plan_builder builder;

        plan = null;
        why = "";
        if (state != DPU_DEVICE_RESOLVED) begin
            why = $sformatf(
                "bootstrap plan build requires RESOLVED state, current state is %0d",
                state);
            return 0;
        end
        builder = dpu_device_bootstrap_plan_builder::type_id::create(
            "dpu_device_bootstrap_plan_builder");
        return builder.build(snapshot, plan, why);
    endfunction

// 功能：执行与对象职责相关的内部辅助操作（apply_bootstrap）。
// 输入/输出：输入和输出由函数签名定义；通过返回值或 output 参数报告结果。
// 边界/副作用：除签名明确写入外不产生隐藏副作用，失败时保持状态一致。
    task apply_bootstrap(
        input dpu_reg_plan plan,
        output dpu_execution_report report
    );
        if (state != DPU_DEVICE_RESOLVED) begin
            report = dpu_execution_report::type_id::create(
                "rejected_bootstrap_report");
            report.set_terminal(
                DPU_CFG_STATUS_PLAN_INVALID,
                $sformatf(
                    "bootstrap apply requires RESOLVED state, current state is %0d",
                    state));
            return;
        end
        if (orchestrator == null) begin
            report = dpu_execution_report::type_id::create(
                "missing_orchestrator_report");
            report.set_terminal(
                DPU_CFG_STATUS_PLAN_INVALID,
                "device environment has no configuration orchestrator");
            return;
        end

        state = DPU_DEVICE_APPLYING;
        orchestrator.apply_with_report(plan, report);
        case (report.status())
            DPU_CFG_STATUS_SUCCEEDED:
                state = DPU_DEVICE_ACTIVE;
            DPU_CFG_STATUS_EXECUTION_FAILED:
                state = DPU_DEVICE_FAILED;
            default:
                state = DPU_DEVICE_RESOLVED;
        endcase
    endtask

// 功能：执行与对象职责相关的内部辅助操作（build_vio_register_plan）。
// 输入/输出：输入和输出由函数签名定义；通过返回值或 output 参数报告结果。
// 边界/副作用：除签名明确写入外不产生隐藏副作用，失败时保持状态一致。
    function bit build_vio_register_plan(
        output dpu_reg_plan plan,
        output string why
    );
        dpu_vio_register_plan_builder builder;

        plan = null;
        why = "";
        if (state != DPU_DEVICE_RESOLVED) begin
            why = $sformatf(
                "VIO register plan build requires RESOLVED state, current state is %0d",
                state);
            return 0;
        end
        builder = dpu_vio_register_plan_builder::type_id::create(
            "dpu_vio_register_plan_builder");
        vio_policy.active_notify_bank = active_vio_notify_bank;
        builder.set_policy(vio_policy);
        builder.set_dataplane_extension(vio_dataplane_extension);
        return builder.build(snapshot, resource_snapshot, plan, why);
    endfunction

// 功能：执行与对象职责相关的内部辅助操作（apply_vio_register_plan）。
// 输入/输出：输入和输出由函数签名定义；通过返回值或 output 参数报告结果。
// 边界/副作用：除签名明确写入外不产生隐藏副作用，失败时保持状态一致。
    task apply_vio_register_plan(
        input dpu_reg_plan plan,
        output dpu_execution_report report
    );
        if (state != DPU_DEVICE_RESOLVED) begin
            report = dpu_execution_report::type_id::create(
                "rejected_vio_register_plan_report");
            report.set_terminal(
                DPU_CFG_STATUS_PLAN_INVALID,
                $sformatf(
                    "VIO register plan apply requires RESOLVED state, current state is %0d",
                    state));
            return;
        end
        if (orchestrator == null) begin
            report = dpu_execution_report::type_id::create(
                "missing_vio_orchestrator_report");
            report.set_terminal(
                DPU_CFG_STATUS_PLAN_INVALID,
                "device environment has no configuration orchestrator");
            return;
        end

        state = DPU_DEVICE_APPLYING;
        orchestrator.apply_with_report(plan, report);
        case (report.status())
            DPU_CFG_STATUS_SUCCEEDED: begin
                int unsigned committed_bank;
                if (find_vio_notify_commit_bank(
                        plan, 0, committed_bank)) begin
                    active_vio_notify_bank = committed_bank;
                    vio_policy.active_notify_bank = committed_bank;
                end
                state = DPU_DEVICE_ACTIVE;
            end
            DPU_CFG_STATUS_EXECUTION_FAILED:
                state = DPU_DEVICE_FAILED;
            default:
                state = DPU_DEVICE_RESOLVED;
        endcase
    endtask

// 功能：执行与对象职责相关的内部辅助操作（build_vio_teardown_plan）。
// 输入/输出：输入和输出由函数签名定义；通过返回值或 output 参数报告结果。
// 边界/副作用：除签名明确写入外不产生隐藏副作用，失败时保持状态一致。
    function bit build_vio_teardown_plan(
        output dpu_reg_plan plan,
        output string why
    );
        dpu_vio_register_plan_builder builder;

        plan = null;
        why = "";
        if (state != DPU_DEVICE_ACTIVE) begin
            why = $sformatf(
                "VIO teardown plan build requires ACTIVE state, current state is %0d",
                state);
            return 0;
        end
        builder = dpu_vio_register_plan_builder::type_id::create(
            "dpu_vio_teardown_plan_builder");
        vio_policy.active_notify_bank = active_vio_notify_bank;
        builder.set_policy(vio_policy);
        return builder.build_teardown(
            snapshot, resource_snapshot, plan, why);
    endfunction

// 功能：执行与对象职责相关的内部辅助操作（apply_vio_teardown_plan）。
// 输入/输出：输入和输出由函数签名定义；通过返回值或 output 参数报告结果。
// 边界/副作用：除签名明确写入外不产生隐藏副作用，失败时保持状态一致。
    task apply_vio_teardown_plan(
        input dpu_reg_plan plan,
        output dpu_execution_report report
    );
        if (state != DPU_DEVICE_ACTIVE) begin
            report = dpu_execution_report::type_id::create(
                "rejected_vio_teardown_plan_report");
            report.set_terminal(
                DPU_CFG_STATUS_PLAN_INVALID,
                $sformatf(
                    "VIO teardown plan apply requires ACTIVE state, current state is %0d",
                    state));
            return;
        end
        if (orchestrator == null) begin
            report = dpu_execution_report::type_id::create(
                "missing_vio_teardown_orchestrator_report");
            report.set_terminal(
                DPU_CFG_STATUS_PLAN_INVALID,
                "device environment has no configuration orchestrator");
            return;
        end

        state = DPU_DEVICE_APPLYING;
        orchestrator.apply_with_report(plan, report);
        case (report.status())
            DPU_CFG_STATUS_SUCCEEDED: begin
                int unsigned committed_bank;
                if (find_vio_notify_commit_bank(
                        plan, 1, committed_bank)) begin
                    active_vio_notify_bank = committed_bank;
                    vio_policy.active_notify_bank = committed_bank;
                end
                state = DPU_DEVICE_RESOLVED;
            end
            DPU_CFG_STATUS_EXECUTION_FAILED:
                state = DPU_DEVICE_FAILED;
            default:
                state = DPU_DEVICE_ACTIVE;
        endcase
    endtask
endclass : dpu_device_env

`endif // DPU_DEVICE_ENV_SV
