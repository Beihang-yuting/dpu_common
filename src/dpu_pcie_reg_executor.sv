/*
 * 所属层次：src/ PCIe 寄存器执行适配层。
 * 文件职责：把通用 dpu_reg_op 翻译成 PCIe backend 调用，执行预检、读回校验并导出报告。
 * 主要依赖：dpu_reg_executor、dpu_reg_op、dpu_execution_report、dpu_reg_backend。
 * 所有权与生命周期：借用 backend 和 topology；每次执行前清空本轮结果，失败结果仍可查询。
 */
`ifndef DPU_PCIE_REG_EXECUTOR_SV
`define DPU_PCIE_REG_EXECUTOR_SV

// 设计原因：以抽象 backend 隔离 PCIe 拓扑/传输实现，保持寄存器执行接口可替换。
// 职责与所有权：backend 不由基类取得所有权；调用方注入的拓扑和 backend 仅在执行期间借用。
// 生命周期/失败边界：未绑定 backend、拓扑不兼容或访问失败时必须返回诊断，不得伪造成功。
virtual class dpu_pcie_reg_backend extends uvm_object;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_pcie_reg_backend");
        super.new(name);
    endfunction

// 功能：把调用方提供的 PCIe topology 绑定到执行上下文（bind_topology）。
// 输入/输出：输入为 topology object；无返回值，backend 保存借用引用。
// 边界/副作用：不复制或取得 topology 所有权；类型不兼容时后续 preflight 必须失败。
    virtual function void bind_topology(input uvm_object topology);
    endfunction

// 功能：通过 PCIe backend 执行一条具体的 barrier/read/write 访问（write）。
// 输入/输出：输入为地址、宽度、payload 或 output 结果；返回 backend 状态。
// 边界/副作用：backend 缺失、宽度非法或访问失败时返回失败，不伪造读回值。
    pure virtual task write(input dpu_reg_op operation,
                            output bit ok, output string why);

// 功能：通过 PCIe backend 执行一条具体的 barrier/read/write 访问（read）。
// 输入/输出：输入为地址、宽度、payload 或 output 结果；返回 backend 状态。
// 边界/副作用：backend 缺失、宽度非法或访问失败时返回失败，不伪造读回值。
    pure virtual task read(input dpu_reg_op operation,
                           output bit [63:0] value,
                           output bit ok, output string why);

// 功能：通过 PCIe backend 执行一条具体的 barrier/read/write 访问（barrier）。
// 输入/输出：输入为地址、宽度、payload 或 output 结果；返回 backend 状态。
// 边界/副作用：backend 缺失、宽度非法或访问失败时返回失败，不伪造读回值。
    pure virtual task barrier(input dpu_reg_op operation,
                              output bit ok, output string why);
endclass : dpu_pcie_reg_backend

// 设计原因：隔离执行副作用和 UVM 生命周期，使上层计划不依赖具体 backend。
// 职责与所有权：对象拥有本轮执行历史，外部 backend/topology 按接口注入并借用，失败信息由对象保留。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_pcie_reg_executor extends dpu_reg_executor;
    `uvm_object_utils(dpu_pcie_reg_executor)

    protected dpu_pcie_reg_backend backend;
    protected dpu_reg_plan preflight_plan;
    protected bit preflight_called;
    protected bit preflight_succeeded;
    protected bit execute_authorization_consumed;
    protected string latest_operation_ids[$];
    protected dpu_reg_op_result_e latest_operation_results[$];

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_pcie_reg_executor");
        super.new(name);
        backend = null;
        reset_backend_state();
    endfunction

// 功能：设置对象的配置字段、依赖对象或错误上下文（set_backend）。
// 输入/输出：输入为新值或外部对象；通常无返回值，字段写入当前对象。
// 边界/副作用：必须尊重冻结边界；外部对象按约定借用或复制。
    function void set_backend(input dpu_pcie_reg_backend new_backend);
        backend = new_backend;
        reset_backend_state();
    endfunction

// 功能：清理临时结果、错误状态或执行历史（clear_backend）。
// 输入/输出：无输入或清理选项；无返回值，状态恢复初始值。
// 边界/副作用：只清理本对象拥有的状态，清理后可按约定复用。
    function void clear_backend();
        backend = null;
        reset_backend_state();
    endfunction

// 功能：判断对象是否满足指定状态、资格或引用关系（has_backend）。
// 输入/输出：输入为待判断的键/状态；返回 bit，不修改对象。
// 边界/副作用：边界值显式判断，不触发分配、排序或其他隐藏副作用。
    function bit has_backend();
        return backend != null;
    endfunction

// 功能：把调用方提供的 PCIe topology 绑定到执行上下文（bind_topology）。
// 输入/输出：输入为 topology object；无返回值，backend 保存借用引用。
// 边界/副作用：不复制或取得 topology 所有权；类型不兼容时后续 preflight 必须失败。
    virtual function void bind_topology(input uvm_object topology);
        if (backend != null)
            backend.bind_topology(topology);
    endfunction

    // Clears only the one-shot preflight authorization and result staging;
    // backend configuration itself remains installed.
// 功能：清理临时结果、错误状态或执行历史（reset_backend_state）。
// 输入/输出：无输入或清理选项；无返回值，状态恢复初始值。
// 边界/副作用：只清理本对象拥有的状态，清理后可按约定复用。
    function void reset_backend_state();
        preflight_plan = null;
        preflight_called = 0;
        preflight_succeeded = 0;
        execute_authorization_consumed = 0;
        latest_operation_ids.delete();
        latest_operation_results.delete();
        set_last_error("");
    endfunction

// 功能：在访问硬件前检查 backend、拓扑和所有操作是否可执行（preflight）。
// 输入/输出：输入为计划或操作集合；返回 bit，并通过错误文本说明失败。
// 边界/副作用：只读检查，不进行寄存器写入；任一操作非法时整体拒绝。
    virtual function bit preflight(
        dpu_reg_plan plan,
        output string why
    );
        why = "";
        reset_backend_state();
        preflight_called = 1;
        if (backend == null) begin
            why = "PCIe register executor has no backend installed";
            set_last_error(why);
            return 0;
        end
        if (plan == null) begin
            why = "PCIe register executor received a null register plan";
            set_last_error(why);
            return 0;
        end
        if (!plan.is_frozen()) begin
            why = "PCIe register executor requires a frozen register plan";
            set_last_error(why);
            return 0;
        end
        if (!plan.validate(why)) begin
            set_last_error(why);
            return 0;
        end
        preflight_plan = plan;
        preflight_succeeded = 1;
        return 1;
    endfunction

// 功能：准备或校验一次寄存器执行结果（stage_result）。
// 输入/输出：输入为 operation、读回值或结果枚举；返回成功标志并更新状态。
// 边界/副作用：校验使用 operation 声明的 mask/expected value，并保留 operation ID。
    protected function void stage_result(input dpu_reg_op operation,
                                         input dpu_reg_op_result_e result);
        latest_operation_ids.push_back(operation.op_id);
        latest_operation_results.push_back(result);
    endfunction

// 功能：准备或校验一次寄存器执行结果（verify_read_value）。
// 输入/输出：输入为 operation、读回值或结果枚举；返回成功标志并更新状态。
// 边界/副作用：校验使用 operation 声明的 mask/expected value，并保留 operation ID。
    protected function bit verify_read_value(input dpu_reg_op operation,
                                             input bit [63:0] value,
                                             output string why);
        why = "";
        if ((value & operation.read_mask) !=
            (operation.expected_value & operation.read_mask)) begin
            why = $sformatf(
                "PCIe readback mismatch at %s: got=0x%016x expected=0x%016x mask=0x%016x",
                operation.op_id, value, operation.expected_value,
                operation.read_mask);
            return 0;
        end
        return 1;
    endfunction

// 功能：按已排序的寄存器操作访问 backend，并记录每个操作的结果（execute）。
// 输入/输出：输入为 operation/plan 和执行上下文；通过 task 完成副作用并更新结果历史。
// 边界/副作用：执行前必须满足 preflight；读回值按 mask 校验。
    virtual task execute(
        dpu_reg_plan plan,
        output dpu_cfg_status_e status
    );
        dpu_reg_op operations[$];
        bit ok;
        bit [63:0] value;
        string why;
        string operation_why;

        status = DPU_CFG_STATUS_EXECUTION_FAILED;
        latest_operation_ids.delete();
        latest_operation_results.delete();
        if (!preflight_called || !preflight_succeeded ||
            (preflight_plan == null)) begin
            set_last_error("PCIe register executor execute called before preflight");
            return;
        end
        if (execute_authorization_consumed) begin
            set_last_error(
                "PCIe register executor execute authorization was already consumed");
            return;
        end
        execute_authorization_consumed = 1;
        preflight_succeeded = 0;
        if (plan != preflight_plan) begin
            set_last_error(
                "PCIe register executor execute plan does not match preflight plan");
            return;
        end
        if (!plan.ordered_operations(operations, why)) begin
            set_last_error(why);
            return;
        end

        foreach (operations[index]) begin
            dpu_reg_op operation;
            operation = operations[index];
            operation_why = "";
            ok = 0;
            value = '0;
            case (operation.kind)
                DPU_REG_OP_PCI_CFG_WRITE,
                DPU_REG_OP_MMIO_WRITE,
                DPU_REG_OP_COMMIT: begin
                    backend.write(operation, ok, operation_why);
                end
                DPU_REG_OP_READ_VERIFY: begin
                    backend.read(operation, value, ok, operation_why);
                    if (ok)
                        ok = verify_read_value(operation, value, operation_why);
                end
                DPU_REG_OP_POLL_UNTIL: begin
                    ok = 0;
                    for (int unsigned attempt = 0;
                         attempt < operation.max_attempts; attempt++) begin
                        backend.read(operation, value, ok, operation_why);
                        if (ok && verify_read_value(operation, value,
                                                     operation_why)) begin
                            ok = 1;
                            break;
                        end
                        if (attempt + 1 < operation.max_attempts &&
                            operation.retry_interval != 0)
                            #(operation.retry_interval);
                    end
                    if (!ok && operation_why == "")
                        operation_why = $sformatf(
                            "PCIe poll %s exhausted %0d attempts",
                            operation.op_id, operation.max_attempts);
                end
                DPU_REG_OP_BARRIER: begin
                    backend.barrier(operation, ok, operation_why);
                end
                default: begin
                    operation_why = $sformatf(
                        "PCIe executor received unsupported operation %s",
                        operation.op_id);
                end
            endcase
            if (!ok) begin
                stage_result(operation, DPU_REG_OP_RESULT_FAILED);
                if (operation_why == "")
                    operation_why = $sformatf(
                        "PCIe backend failed operation %s", operation.op_id);
                set_last_error(operation_why);
                return;
            end
            stage_result(operation, DPU_REG_OP_RESULT_SUCCEEDED);
        end
        set_last_error("");
        status = DPU_CFG_STATUS_SUCCEEDED;
    endtask

// 功能：把本轮执行结果按值复制到 execution report（export_results）。
// 输入/输出：输入为 report 对象；无返回值，报告获得当前 operation ID/result 序列。
// 边界/副作用：report 为空或执行尚未开始时按接口约定清空/保持空结果，不暴露内部数组。
    virtual function void export_results(input dpu_execution_report report);
        if (report == null)
            return;
        report.clear_results();
        foreach (latest_operation_ids[index])
            report.append_result(latest_operation_ids[index],
                                 latest_operation_results[index]);
    endfunction
endclass : dpu_pcie_reg_executor

`endif // DPU_PCIE_REG_EXECUTOR_SV
