/*
 * 所属层次：src/ 执行结果值对象层。
 * 文件职责：记录一次寄存器计划执行的终态、原因和按顺序排列的每个操作结果。
 * 主要依赖：dpu_reg_plan_types 状态枚举。
 * 所有权与生命周期：报告由一次执行调用创建或清空，结果按值复制，不持有 executor/backend 引用。
 */
`ifndef DPU_EXECUTION_REPORT_SV
`define DPU_EXECUTION_REPORT_SV

// 设计原因：把状态、错误上下文和结果集合统一成可复制的值对象，便于跨层传递。
// 职责与所有权：对象拥有自身文本和结果副本，不持有 executor 或配置的可变引用。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_execution_report extends uvm_object;
    `uvm_object_utils(dpu_execution_report)

    local dpu_cfg_status_e terminal_status_value;
    local string terminal_reason_text;
    local string operation_ids[$];
    local dpu_reg_op_result_e operation_results[$];

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_execution_report");
        super.new(name);
        terminal_status_value = DPU_CFG_STATUS_NOT_EXECUTED;
        terminal_reason_text = "";
        operation_ids.delete();
        operation_results.delete();
    endfunction

// 功能：设置对象的配置字段、依赖对象或错误上下文（set_terminal）。
// 输入/输出：输入为新值或外部对象；通常无返回值，字段写入当前对象。
// 边界/副作用：必须尊重冻结边界；外部对象按约定借用或复制。
    function void set_terminal(
        input dpu_cfg_status_e new_status,
        input string new_reason
    );
        terminal_status_value = new_status;
        terminal_reason_text = new_reason;
    endfunction

// 功能：查询当前对象的计数、状态或最近错误文本（status）。
// 输入/输出：无输入；返回值语义结果，不修改对象。
// 边界/副作用：空集合或尚未执行时返回定义明确的默认值。
    function dpu_cfg_status_e status();
        return terminal_status_value;
    endfunction

// 功能：查询当前对象的计数、状态或最近错误文本（reason）。
// 输入/输出：无输入；返回值语义结果，不修改对象。
// 边界/副作用：空集合或尚未执行时返回定义明确的默认值。
    function string reason();
        return terminal_reason_text;
    endfunction

// 功能：清理临时结果、错误状态或执行历史（clear_results）。
// 输入/输出：无输入或清理选项；无返回值，状态恢复初始值。
// 边界/副作用：只清理本对象拥有的状态，清理后可按约定复用。
    function void clear_results();
        operation_ids.delete();
        operation_results.delete();
    endfunction

// 功能：向对象加入配置项、绑定或寄存器操作（append_result）。
// 输入/输出：输入为待加入值；成功返回 1/无返回值，失败返回 why 或记录诊断。
// 边界/副作用：加入前检查重复键、所有权和冻结状态，失败不得留下半写入元素。
    function void append_result(
        input string op_id,
        input dpu_reg_op_result_e result
    );
        operation_ids.push_back(op_id);
        operation_results.push_back(result);
    endfunction

// 功能：查询当前对象的计数、状态或最近错误文本（result_count）。
// 输入/输出：无输入；返回值语义结果，不修改对象。
// 边界/副作用：空集合或尚未执行时返回定义明确的默认值。
    function int unsigned result_count();
        return operation_ids.size();
    endfunction

// 功能：按稳定索引导出一条历史或执行结果的值复制（result_at）。
// 输入/输出：输入为数组索引和 output 对象；返回 bit 表示索引是否有效。
// 边界/副作用：索引越界时返回失败并清空/保持 output 约定状态，不伪造结果。
    function bit result_at(
        input int unsigned index,
        output string op_id,
        output dpu_reg_op_result_e result,
        output string why
    );
        op_id = "";
        result = DPU_REG_OP_RESULT_NOT_RUN;
        why = "";
        if ((index >= operation_ids.size()) ||
            (index >= operation_results.size())) begin
            why = $sformatf(
                "execution report result index %0d is out of range", index);
            return 0;
        end
        op_id = operation_ids[index];
        result = operation_results[index];
        return 1;
    endfunction
endclass : dpu_execution_report

`endif // DPU_EXECUTION_REPORT_SV
