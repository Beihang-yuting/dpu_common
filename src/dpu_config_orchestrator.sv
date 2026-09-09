/*
 * 所属层次：src/ 配置执行编排层。
 * 文件职责：把已解析的设备/寄存器计划交给可替换的执行器，并统一收集执行报告。
 * 主要依赖：dpu_device_snapshot、dpu_reg_plan、dpu_reg_executor、dpu_execution_report。
 * 所有权与生命周期：不拥有快照或执行器；调用方负责注入和释放，报告在一次调用期间生成并按值导出。
 */
`ifndef DPU_CONFIG_ORCHESTRATOR_SV
`define DPU_CONFIG_ORCHESTRATOR_SV

// 设计原因：将相关值和操作约束集中在独立边界，避免跨模块重复解释同一契约。
// 职责与所有权：对象/类型按值语义管理自身字段，不隐式取得外部资源或生命周期控制权。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_config_orchestrator extends uvm_object;
    `uvm_object_utils(dpu_config_orchestrator)

    protected dpu_reg_executor executor;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_config_orchestrator");
        super.new(name);
        executor = null;
    endfunction

// 功能：设置对象的配置字段、依赖对象或错误上下文（set_executor）。
// 输入/输出：输入为新值或外部对象；通常无返回值，字段写入当前对象。
// 边界/副作用：必须尊重冻结边界；外部对象按约定借用或复制。
    function void set_executor(input dpu_reg_executor new_executor);
        executor = new_executor;
    endfunction

// 功能：清理临时结果、错误状态或执行历史（clear_executor）。
// 输入/输出：无输入或清理选项；无返回值，状态恢复初始值。
// 边界/副作用：只清理本对象拥有的状态，清理后可按约定复用。
    function void clear_executor();
        executor = null;
    endfunction

// 功能：判断对象是否满足指定状态、资格或引用关系（has_executor）。
// 输入/输出：输入为待判断的键/状态；返回 bit，不修改对象。
// 边界/副作用：边界值显式判断，不触发分配、排序或其他隐藏副作用。
    function bit has_executor();
        return executor != null;
    endfunction

// 功能：协调执行器应用寄存器计划并收集终态报告（apply_with_report）。
// 输入/输出：输入为快照/计划和 executor，输出 execution report 或状态。
// 边界/副作用：执行器为空、预检失败或操作失败时保留原因，不修改快照。
    task apply_with_report(
        dpu_reg_plan plan,
        output dpu_execution_report report
    );
        dpu_reg_executor active_executor;
        dpu_cfg_status_e status;
        string why;

        status = DPU_CFG_STATUS_PLAN_INVALID;
        why = "";
        report = dpu_execution_report::type_id::create(
            {get_name(), "_execution_report"});
        active_executor = executor;
        if (plan == null) begin
            why = "configuration orchestrator received a null register plan";
            report.set_terminal(status, why);
            return;
        end
        if (!plan.freeze(why)) begin
            report.set_terminal(status, why);
            return;
        end

        if (active_executor == null) begin
            status = DPU_CFG_STATUS_NOT_EXECUTED;
            why = {"validated register plan was not executed because no ",
                   "executor is installed"};
            report.set_terminal(status, why);
            return;
        end
        if (!active_executor.preflight(plan, why)) begin
            status = DPU_CFG_STATUS_PREFLIGHT_FAILED;
            if (why == "")
                why = active_executor.last_error();
            if (why == "") begin
                why =
                    "register executor preflight failed without an error message";
            end
            active_executor.export_results(report);
            report.set_terminal(status, why);
            return;
        end

        active_executor.execute(plan, status);
        case (status)
            DPU_CFG_STATUS_SUCCEEDED: why = "";
            DPU_CFG_STATUS_EXECUTION_FAILED: begin
                why = active_executor.last_error();
                if (why == "") begin
                    why = "register executor failed without an error message";
                end
            end
            default: begin
                status = DPU_CFG_STATUS_EXECUTION_FAILED;
                why = "register executor returned an invalid terminal status";
            end
        endcase
        active_executor.export_results(report);
        report.set_terminal(status, why);
    endtask

// 功能：协调执行器应用寄存器计划并收集终态报告（apply）。
// 输入/输出：输入为快照/计划和 executor，输出 execution report 或状态。
// 边界/副作用：执行器为空、预检失败或操作失败时保留原因，不修改快照。
    task apply(
        dpu_reg_plan plan,
        output dpu_cfg_status_e status,
        output string why
    );
        dpu_execution_report report;

        apply_with_report(plan, report);
        status = report.status();
        why = report.reason();
    endtask
endclass : dpu_config_orchestrator

`endif // DPU_CONFIG_ORCHESTRATOR_SV
