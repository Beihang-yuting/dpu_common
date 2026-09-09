/*
 * 所属层次：src/ 测试用寄存器执行器层。
 * 文件职责：记录计划预检和执行尝试，允许测试注入指定失败而不依赖真实硬件 backend。
 * 主要依赖：dpu_reg_executor、dpu_reg_plan、dpu_execution_report。
 * 所有权与生命周期：spy 拥有历史 operation 副本；reset_history 清空可复用状态。
 */
`ifndef DPU_SPY_REG_EXECUTOR_SV
`define DPU_SPY_REG_EXECUTOR_SV

// 设计原因：隔离执行副作用和 UVM 生命周期，使上层计划不依赖具体 backend。
// 职责与所有权：对象拥有本轮执行历史，外部 backend/topology 按接口注入并借用，失败信息由对象保留。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_spy_reg_executor extends dpu_reg_executor;
    `uvm_object_utils(dpu_spy_reg_executor)

    protected dpu_reg_op recorded_operations[$];
    protected dpu_reg_op_result_e recorded_results[$];
    protected string latest_attempt_operation_ids[$];
    protected dpu_reg_op_result_e latest_attempt_results[$];
    protected string failed_operation_id;
    protected string authorized_failed_operation_id;
    protected string preflight_failure_text;
    protected bit preflight_called;
    protected bit preflight_empty_history;
    protected bit preflight_succeeded;
    protected dpu_reg_plan preflight_plan;
    protected bit execute_authorization_consumed;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_spy_reg_executor");
        super.new(name);
        recorded_operations.delete();
        recorded_results.delete();
        latest_attempt_operation_ids.delete();
        latest_attempt_results.delete();
        failed_operation_id = "";
        authorized_failed_operation_id = "";
        preflight_failure_text = "";
        preflight_called = 0;
        preflight_empty_history = 0;
        preflight_succeeded = 0;
        preflight_plan = null;
        execute_authorization_consumed = 0;
    endfunction

// 功能：复制寄存器操作及其依赖字段（copy_operation）。
// 输入/输出：输入为同型 operation；返回新副本或无返回值。
// 边界/副作用：依赖数组和校验字段必须一起复制；不改变源操作。
// 功能：复制计划或操作的全部字段和派生集合（copy_operation）。
// 输入/输出：输入为同型源对象；无返回值或返回副本，具体由签名决定。
// 边界/副作用：复制后不共享可变数组；源对象保持不变，空源由调用方先行拒绝。
    local function bit copy_operation(
        input dpu_reg_op source,
        input string expected_id,
        output dpu_reg_op copied,
        output string why
    );
        copied = null;
        why = "";
        if (source == null) begin
            why = $sformatf(
                "failed to copy spy operation %s", expected_id);
            return 0;
        end

        copied = source.copy_op(expected_id);
        if (copied == null) begin
            why = $sformatf(
                "failed to copy spy operation %s", expected_id);
            return 0;
        end
        if (copied.op_id != expected_id) begin
            why = $sformatf(
                "spy operation copy ID %s does not match expected ID %s",
                copied.op_id, expected_id);
            copied = null;
            return 0;
        end
        return 1;
    endfunction

// 功能：保存一次 spy 执行尝试的 operation 和结果快照（capture_latest_attempt）。
// 输入/输出：输入为 operation/result 集合；无返回值，更新 latest attempt 历史。
// 边界/副作用：保存副本而非共享指针；新尝试更新最新视图。
    local function void capture_latest_attempt(
        input dpu_reg_op operations[$],
        input dpu_reg_op_result_e results[$]
    );
        latest_attempt_operation_ids.delete();
        latest_attempt_results.delete();
        foreach (operations[index]) begin
            latest_attempt_operation_ids.push_back(operations[index].op_id);
            latest_attempt_results.push_back(results[index]);
        end
    endfunction

// 功能：清理临时结果、错误状态或执行历史（reset_history）。
// 输入/输出：无输入或清理选项；无返回值，状态恢复初始值。
// 边界/副作用：只清理本对象拥有的状态，清理后可按约定复用。
    function void reset_history();
        recorded_operations.delete();
        recorded_results.delete();
        latest_attempt_operation_ids.delete();
        latest_attempt_results.delete();
        preflight_called = 0;
        preflight_empty_history = 0;
        preflight_succeeded = 0;
        preflight_plan = null;
        execute_authorization_consumed = 0;
        failed_operation_id = "";
        authorized_failed_operation_id = "";
        preflight_failure_text = "";
        set_last_error("");
    endfunction

// 功能：把失败原因和上下文写入诊断对象（fail_operation）。
// 输入/输出：输入为文本及可选定位上下文；无返回值。
// 边界/副作用：不得继续分配资源，避免后续错误覆盖根因。
    function void fail_operation(input string op_id);
        failed_operation_id = op_id;
    endfunction

// 功能：把失败原因和上下文写入诊断对象（fail_preflight）。
// 输入/输出：输入为文本及可选定位上下文；无返回值。
// 边界/副作用：不得继续分配资源，避免后续错误覆盖根因。
    function void fail_preflight(input string why);
        preflight_failure_text = why;
    endfunction

// 功能：查询当前对象的计数、状态或最近错误文本（record_count）。
// 输入/输出：无输入；返回值语义结果，不修改对象。
// 边界/副作用：空集合或尚未执行时返回定义明确的默认值。
    function int unsigned record_count();
        return recorded_operations.size();
    endfunction

// 功能：查询当前对象的计数、状态或最近错误文本（preflight_history_was_empty）。
// 输入/输出：无输入；返回值语义结果，不修改对象。
// 边界/副作用：空集合或尚未执行时返回定义明确的默认值。
    function bit preflight_history_was_empty();
        return preflight_empty_history;
    endfunction

// 功能：在访问硬件前检查 backend、拓扑和所有操作是否可执行（preflight）。
// 输入/输出：输入为计划或操作集合；返回 bit，并通过错误文本说明失败。
// 边界/副作用：只读检查，不进行寄存器写入；任一操作非法时整体拒绝。
    virtual function bit preflight(
        dpu_reg_plan plan,
        output string why
    );
        dpu_reg_op injected_failure_operation;

        latest_attempt_operation_ids.delete();
        latest_attempt_results.delete();
        preflight_called = 1;
        preflight_empty_history =
            (recorded_operations.size() == 0) &&
            (recorded_results.size() == 0);
        preflight_succeeded = 0;
        preflight_plan = null;
        authorized_failed_operation_id = "";
        execute_authorization_consumed = 0;
        why = "";
        set_last_error("");
        if (plan == null) begin
            why = "spy executor received a null register plan";
            set_last_error(why);
            return 0;
        end
        if (!plan.is_frozen()) begin
            why = "spy executor requires a frozen register plan";
            set_last_error(why);
            return 0;
        end
        if (preflight_failure_text != "") begin
            why = preflight_failure_text;
            set_last_error(why);
            return 0;
        end
        if ((failed_operation_id != "") &&
            !plan.find_operation(
                failed_operation_id, injected_failure_operation)) begin
            why = $sformatf(
                "spy failure operation %s is not in the register plan",
                failed_operation_id);
            set_last_error(why);
            return 0;
        end
        preflight_succeeded = 1;
        preflight_plan = plan;
        authorized_failed_operation_id = failed_operation_id;
        return 1;
    endfunction

// 功能：按已排序的寄存器操作访问 backend，并记录每个操作的结果（execute）。
// 输入/输出：输入为 operation/plan 和执行上下文；通过 task 完成副作用并更新结果历史。
// 边界/副作用：执行前必须满足 preflight；读回值按 mask 校验。
    virtual task execute(
        dpu_reg_plan plan,
        output dpu_cfg_status_e status
    );
        dpu_reg_op ordered[$];
        dpu_reg_op recorded_copy;
        dpu_reg_op staged_operations[$];
        dpu_reg_op_result_e staged_results[$];
        dpu_reg_plan execution_plan;
        string execution_failed_operation_id;
        string why;

        status = DPU_CFG_STATUS_EXECUTION_FAILED;
        if (!preflight_called) begin
            set_last_error("spy executor execute called before preflight");
            return;
        end
        if (execute_authorization_consumed) begin
            set_last_error(
                "spy executor execute authorization was already consumed");
            return;
        end
        if (!preflight_succeeded) begin
            set_last_error(
                "spy executor execute called without successful preflight");
            return;
        end
        execution_plan = preflight_plan;
        execution_failed_operation_id = authorized_failed_operation_id;
        execute_authorization_consumed = 1;
        preflight_succeeded = 0;
        preflight_plan = null;
        authorized_failed_operation_id = "";
        if (plan != execution_plan) begin
            set_last_error(
                "spy executor execute plan does not match preflight plan");
            return;
        end
        if (!plan.ordered_operations(ordered, why)) begin
            set_last_error(why);
            return;
        end

        // History is cumulative until reset_history(). Copies and results for
        // one execute call remain local until either the whole run succeeds or
        // an injected functional failure establishes an executed prefix.
        foreach (ordered[index]) begin
            if (!copy_operation(
                ordered[index], ordered[index].op_id,
                recorded_copy, why)) begin
                set_last_error(why);
                return;
            end
            staged_operations.push_back(recorded_copy);
            if (ordered[index].op_id == execution_failed_operation_id) begin
                staged_results.push_back(DPU_REG_OP_RESULT_FAILED);
                capture_latest_attempt(staged_operations, staged_results);
                recorded_operations = {
                    recorded_operations, staged_operations
                };
                recorded_results = {recorded_results, staged_results};
                set_last_error($sformatf(
                    "injected execution failure at operation %s",
                    ordered[index].op_id));
                return;
            end
            staged_results.push_back(DPU_REG_OP_RESULT_SUCCEEDED);
        end
        capture_latest_attempt(staged_operations, staged_results);
        recorded_operations = {recorded_operations, staged_operations};
        recorded_results = {recorded_results, staged_results};
        set_last_error("");
        status = DPU_CFG_STATUS_SUCCEEDED;
    endtask

// 功能：按稳定索引导出一条历史或执行结果的值复制（record_at）。
// 输入/输出：输入为数组索引和 output 对象；返回 bit 表示索引是否有效。
// 边界/副作用：索引越界时返回失败并清空/保持 output 约定状态，不伪造结果。
    function bit record_at(
        input int unsigned index,
        output dpu_reg_op operation,
        output dpu_reg_op_result_e result,
        output string why
    );
        operation = null;
        result = DPU_REG_OP_RESULT_NOT_RUN;
        why = "";
        if ((index >= recorded_operations.size()) ||
            (index >= recorded_results.size())) begin
            why = $sformatf(
                "spy record index %0d is out of range", index);
            return 0;
        end
        if (!copy_operation(
            recorded_operations[index], recorded_operations[index].op_id,
            operation, why)) begin
            operation = null;
            return 0;
        end
        result = recorded_results[index];
        return 1;
    endfunction

// 功能：把本轮执行结果按值复制到 execution report（export_results）。
// 输入/输出：输入为 report 对象；无返回值，报告获得当前 operation ID/result 序列。
// 边界/副作用：report 为空或执行尚未开始时按接口约定清空/保持空结果，不暴露内部数组。
    virtual function void export_results(input dpu_execution_report report);
        if (report == null)
            return;
        report.clear_results();
        foreach (latest_attempt_operation_ids[index]) begin
            report.append_result(
                latest_attempt_operation_ids[index],
                latest_attempt_results[index]);
        end
    endfunction
endclass : dpu_spy_reg_executor

`endif // DPU_SPY_REG_EXECUTOR_SV
