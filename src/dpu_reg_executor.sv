/*
 * 所属层次：src/ 寄存器执行抽象层。
 * 文件职责：定义所有寄存器 executor 必须遵守的绑定、错误保存和结果导出接口。
 * 主要依赖：dpu_reg_op、dpu_execution_report 与 UVM object。
 * 所有权与生命周期：基类不拥有具体 backend；派生类负责执行细节，last_error 只表示最近一次调用的诊断文本。
 */
`ifndef DPU_REG_EXECUTOR_SV
`define DPU_REG_EXECUTOR_SV

// 设计原因：隔离执行副作用和 UVM 生命周期，使上层计划不依赖具体 backend。
// 职责与所有权：对象拥有本轮执行历史，外部 backend 按接口注入并借用。
// 生命周期/失败边界：非法输入通过返回值或诊断路径报告。
virtual class dpu_reg_executor extends uvm_object;
    protected string last_error_text;

// 功能：实现寄存器执行器的new接口。
// 输入/输出：输入和返回值由函数签名定义；无额外隐式输出。
// 边界/副作用：遵守基类生命周期约束；非法输入通过错误文本或返回值报告。
    function new(string name = "dpu_reg_executor");
        super.new(name);
        last_error_text = "";
    endfunction

// 功能：实现寄存器执行器的set_last_error接口。
// 输入/输出：输入和返回值由函数签名定义；无额外隐式输出。
// 边界/副作用：遵守基类生命周期约束；非法输入通过错误文本或返回值报告。
    protected function void set_last_error(input string why);
        last_error_text = why;
    endfunction

// 功能：实现寄存器执行器的last_error接口。
// 输入/输出：输入和返回值由函数签名定义；无额外隐式输出。
// 边界/副作用：遵守基类生命周期约束；非法输入通过错误文本或返回值报告。
    function string last_error();
        return last_error_text;
    endfunction

    // Optional topology hand-off performed by dpu_device_env after resolving
    // the frozen snapshot.  Generic executors ignore it; concrete PCIe
    // executors use it to translate BAR-relative register offsets at the
    // final execution boundary.
// 功能：实现寄存器执行器的bind_topology接口。
// 输入/输出：输入和返回值由函数签名定义；无额外隐式输出。
// 边界/副作用：遵守基类生命周期约束；非法输入通过错误文本或返回值报告。
// 功能：把调用方提供的 PCIe topology 绑定到执行上下文（bind_topology）。
// 输入/输出：输入为 topology object；无返回值，backend 保存借用引用。
// 边界/副作用：不复制或取得 topology 所有权；类型不兼容时后续 preflight 必须失败。
    virtual function void bind_topology(input uvm_object topology);
    endfunction

// 功能：实现寄存器执行器的preflight接口。
// 输入/输出：输入和返回值由函数签名定义；无额外隐式输出。
// 边界/副作用：遵守基类生命周期约束；非法输入通过错误文本或返回值报告。
    pure virtual function bit preflight(
        dpu_reg_plan plan,
        output string why
    );

// 功能：实现寄存器执行器的execute接口。
// 输入/输出：输入和返回值由函数签名定义；无额外隐式输出。
// 边界/副作用：遵守基类生命周期约束；非法输入通过错误文本或返回值报告。
    pure virtual task execute(
        dpu_reg_plan plan,
        output dpu_cfg_status_e status
    );

// 功能：实现寄存器执行器的export_results接口。
// 输入/输出：输入和返回值由函数签名定义；无额外隐式输出。
// 边界/副作用：遵守基类生命周期约束；非法输入通过错误文本或返回值报告。
// 功能：把本轮执行结果按值复制到 execution report（export_results）。
// 输入/输出：输入为 report 对象；无返回值，报告获得当前 operation ID/result 序列。
// 边界/副作用：report 为空或执行尚未开始时按接口约定清空/保持空结果，不暴露内部数组。
    virtual function void export_results(input dpu_execution_report report);
        if (report != null)
            report.clear_results();
    endfunction
endclass : dpu_reg_executor

`endif // DPU_REG_EXECUTOR_SV
