/*
 * 所属层次：src/ authoring 配置模型层。
 * 文件职责：声明 Host、PCIe domain、PF/VF、service、BAR 和 AF 请求等逻辑设备配置。
 * 主要依赖：dpu_device_types、dpu_resource_types。
 * 所有权与生命周期：对象由调用方编辑和拥有；resolver 复制其内容，配置冻结后不依赖原对象的后续修改。
 */
`ifndef DPU_DEVICE_CFG_SV
`define DPU_DEVICE_CFG_SV

// 设计原因：为 authoring 输入提供明确字段边界，避免调用方以散落变量表达设备约束。
// 职责与所有权：对象由调用方创建、编辑和拥有；解析器只读取或复制字段，不接管原始配置。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_mmio_window_cfg extends uvm_object;
    `uvm_object_utils(dpu_mmio_window_cfg)

    bit [63:0] base;
    bit [63:0] limit;
    dpu_bar_role_e allowed_roles[$];

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_mmio_window_cfg");
        super.new(name);
        base = '0;
        limit = '0;
    endfunction

// 功能：判断对象是否满足指定状态、资格或引用关系（allows_role）。
// 输入/输出：输入为待判断的键/状态；返回 bit，不修改对象。
// 边界/副作用：边界值显式判断，不触发分配、排序或其他隐藏副作用。
    function bit allows_role(input dpu_bar_role_e role);
        foreach (allowed_roles[index]) begin
            if (allowed_roles[index] == role)
                return 1;
        end
        return 0;
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_mmio_window_cfg rhs);
        base = rhs.base;
        limit = rhs.limit;
        allowed_roles = rhs.allowed_roles;
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_mmio_window_cfg typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "mmio window copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_mmio_window_cfg


// 设计原因：为 authoring 输入提供明确字段边界，避免调用方以散落变量表达设备约束。
// 职责与所有权：对象由调用方创建、编辑和拥有；解析器只读取或复制字段，不接管原始配置。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_pcie_domain_cfg extends uvm_object;
    `uvm_object_utils(dpu_pcie_domain_cfg)

    dpu_pcie_domain_key_t key;
    dpu_bdf_range_t bdf_ranges[$];
    bit [15:0] reserved_bdfs[$];
    dpu_mmio_window_cfg mmio_windows[$];
    dpu_address_range_t reserved_mmio_ranges[$];
    dpu_bar_placement_policy_e bar_placement_policy;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_pcie_domain_cfg");
        super.new(name);
        bar_placement_policy = DPU_BAR_PLACEMENT_FIRST_FIT;
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_pcie_domain_cfg rhs);
        dpu_mmio_window_cfg window_copy;

        key = rhs.key;
        bdf_ranges = rhs.bdf_ranges;
        reserved_bdfs = rhs.reserved_bdfs;
        reserved_mmio_ranges = rhs.reserved_mmio_ranges;
        bar_placement_policy = rhs.bar_placement_policy;
        mmio_windows.delete();
        foreach (rhs.mmio_windows[index]) begin
            if (rhs.mmio_windows[index] == null) begin
                mmio_windows.push_back(null);
            end else begin
                window_copy = dpu_mmio_window_cfg::type_id::create(
                    $sformatf("%s_window_%0d", get_name(), index));
                window_copy.copy_from(rhs.mmio_windows[index]);
                mmio_windows.push_back(window_copy);
            end
        end
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_pcie_domain_cfg typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "PCIe domain copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_pcie_domain_cfg


// 设计原因：为 authoring 输入提供明确字段边界，避免调用方以散落变量表达设备约束。
// 职责与所有权：对象由调用方创建、编辑和拥有；解析器只读取或复制字段，不接管原始配置。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_host_cfg extends uvm_object;
    `uvm_object_utils(dpu_host_cfg)

    int unsigned host_id;
    // Host 开关和名称只描述逻辑配置，物理 PCIe 角色由上层适配层决定。
    bit enabled;
    string name;
    int unsigned address_width;
    bit has_gpa_aperture;
    bit [63:0] gpa_base;
    bit [63:0] gpa_limit;
    dpu_pcie_domain_cfg pcie_domains[$];

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_host_cfg");
        super.new(name);
        host_id = 0;
        enabled = 1'b1;
        this.name = "";
        address_width = 64;
        has_gpa_aperture = 1'b0;
        gpa_base = '0;
        gpa_limit = '0;
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_host_cfg rhs);
        dpu_pcie_domain_cfg domain_copy;

        host_id = rhs.host_id;
        enabled = rhs.enabled;
        name = rhs.name;
        address_width = rhs.address_width;
        has_gpa_aperture = rhs.has_gpa_aperture;
        gpa_base = rhs.gpa_base;
        gpa_limit = rhs.gpa_limit;
        pcie_domains.delete();
        foreach (rhs.pcie_domains[index]) begin
            if (rhs.pcie_domains[index] == null) begin
                pcie_domains.push_back(null);
            end else begin
                domain_copy = dpu_pcie_domain_cfg::type_id::create(
                    $sformatf("%s_domain_%0d", get_name(), index));
                domain_copy.copy_from(rhs.pcie_domains[index]);
                pcie_domains.push_back(domain_copy);
            end
        end
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_host_cfg typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "host copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_host_cfg


// 设计原因：为 authoring 输入提供明确字段边界，避免调用方以散落变量表达设备约束。
// 职责与所有权：对象由调用方创建、编辑和拥有；解析器只读取或复制字段，不接管原始配置。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_bar_request extends uvm_object;
    `uvm_object_utils(dpu_bar_request)

    dpu_bar_role_e role;
    int unsigned even_bar_id;
    bit [63:0] size;
    bit [63:0] alignment;
    dpu_allocation_mode_e placement;
    bit [63:0] pinned_base;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_bar_request");
        super.new(name);
        role = DPU_BAR_DEVICE_MEMORY;
        even_bar_id = 0;
        size = '0;
        alignment = '0;
        placement = DPU_ALLOC_AUTO;
        pinned_base = '0;
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_bar_request rhs);
        role = rhs.role;
        even_bar_id = rhs.even_bar_id;
        size = rhs.size;
        alignment = rhs.alignment;
        placement = rhs.placement;
        pinned_base = rhs.pinned_base;
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_bar_request typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "BAR request copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_bar_request


// 设计原因：为 authoring 输入提供明确字段边界，避免调用方以散落变量表达设备约束。
// 职责与所有权：对象由调用方创建、编辑和拥有；解析器只读取或复制字段，不接管原始配置。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_service_decl extends uvm_object;
    `uvm_object_utils(dpu_service_decl)

    dpu_service_kind_e service_kind;
    int unsigned service_instance_id;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_service_decl");
        super.new(name);
        service_kind = DPU_SERVICE_VIO_NET;
        service_instance_id = 0;
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_service_decl rhs);
        service_kind = rhs.service_kind;
        service_instance_id = rhs.service_instance_id;
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_service_decl typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "service declaration copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_service_decl


// 功能：执行与对象职责相关的内部辅助操作（dpu_service_kind_is_eligible）。
// 输入/输出：输入和输出由函数签名定义；通过返回值或 output 参数报告结果。
// 边界/副作用：除签名明确写入外不产生隐藏副作用，失败时保持状态一致。
function automatic bit dpu_service_kind_is_eligible(
    input dpu_service_kind_e kinds[$],
    input dpu_service_kind_e service_kind
);
    foreach (kinds[index]) begin
        if (kinds[index] == service_kind)
            return 1;
    end
    return 0;
endfunction


// 设计原因：为 authoring 输入提供明确字段边界，避免调用方以散落变量表达设备约束。
// 职责与所有权：对象由调用方创建、编辑和拥有；解析器只读取或复制字段，不接管原始配置。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_vf_template_cfg extends uvm_object;
    `uvm_object_utils(dpu_vf_template_cfg)

    int unsigned vf_id;
    dpu_pcie_domain_key_t domain_key;
    dpu_allocation_mode_e bdf_mode;
    bit [15:0] pinned_bdf;
    dpu_bar_request bars[$];
    dpu_service_kind_e eligible_service_kinds[$];

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_vf_template_cfg");
        super.new(name);
        vf_id = 0;
        bdf_mode = DPU_ALLOC_AUTO;
        pinned_bdf = '0;
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_vf_template_cfg rhs);
        dpu_bar_request bar_copy;

        vf_id = rhs.vf_id;
        domain_key = rhs.domain_key;
        bdf_mode = rhs.bdf_mode;
        pinned_bdf = rhs.pinned_bdf;
        bars.delete();
        foreach (rhs.bars[index]) begin
            if (rhs.bars[index] == null) begin
                bars.push_back(null);
            end else begin
                bar_copy = dpu_bar_request::type_id::create(
                    $sformatf("%s_bar_%0d", get_name(), index));
                bar_copy.copy_from(rhs.bars[index]);
                bars.push_back(bar_copy);
            end
        end
        eligible_service_kinds = rhs.eligible_service_kinds;
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_vf_template_cfg typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "VF template copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_vf_template_cfg


// 设计原因：为 authoring 输入提供明确字段边界，避免调用方以散落变量表达设备约束。
// 职责与所有权：对象由调用方创建、编辑和拥有；解析器只读取或复制字段，不接管原始配置。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_vf_pool_cfg extends uvm_object;
    `uvm_object_utils(dpu_vf_pool_cfg)

    dpu_function_key_t parent_pf;
    dpu_vf_template_cfg vf_templates[$];

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_vf_pool_cfg");
        super.new(name);
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_vf_pool_cfg rhs);
        dpu_vf_template_cfg template_copy;

        parent_pf = rhs.parent_pf;
        vf_templates.delete();
        foreach (rhs.vf_templates[index]) begin
            if (rhs.vf_templates[index] == null) begin
                vf_templates.push_back(null);
            end else begin
                template_copy = dpu_vf_template_cfg::type_id::create(
                    $sformatf("%s_template_%0d", get_name(), index));
                template_copy.copy_from(rhs.vf_templates[index]);
                vf_templates.push_back(template_copy);
            end
        end
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_vf_pool_cfg typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "VF pool copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_vf_pool_cfg


// 设计原因：为 authoring 输入提供明确字段边界，避免调用方以散落变量表达设备约束。
// 职责与所有权：对象由调用方创建、编辑和拥有；解析器只读取或复制字段，不接管原始配置。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_function_cfg extends uvm_object;
    `uvm_object_utils(dpu_function_cfg)

    dpu_function_key_t key;
    dpu_pcie_domain_key_t domain_key;
    dpu_allocation_mode_e bdf_mode;
    bit [15:0] pinned_bdf;
    dpu_bar_request bars[$];
    dpu_service_decl services[$];
    dpu_service_kind_e eligible_service_kinds[$];

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_function_cfg");
        super.new(name);
        bdf_mode = DPU_ALLOC_AUTO;
        pinned_bdf = '0;
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_function_cfg rhs);
        dpu_bar_request bar_copy;
        dpu_service_decl service_copy;

        key = rhs.key;
        domain_key = rhs.domain_key;
        bdf_mode = rhs.bdf_mode;
        pinned_bdf = rhs.pinned_bdf;
        bars.delete();
        foreach (rhs.bars[index]) begin
            if (rhs.bars[index] == null) begin
                bars.push_back(null);
            end else begin
                bar_copy = dpu_bar_request::type_id::create(
                    $sformatf("%s_bar_%0d", get_name(), index));
                bar_copy.copy_from(rhs.bars[index]);
                bars.push_back(bar_copy);
            end
        end
        services.delete();
        foreach (rhs.services[index]) begin
            if (rhs.services[index] == null) begin
                services.push_back(null);
            end else begin
                service_copy = dpu_service_decl::type_id::create(
                    $sformatf("%s_service_%0d", get_name(), index));
                service_copy.copy_from(rhs.services[index]);
                services.push_back(service_copy);
            end
        end
        eligible_service_kinds = rhs.eligible_service_kinds;
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_function_cfg typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "function copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_function_cfg


// 设计原因：为 authoring 输入提供明确字段边界，避免调用方以散落变量表达设备约束。
// 职责与所有权：对象由调用方创建、编辑和拥有；解析器只读取或复制字段，不接管原始配置。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_af_request extends uvm_object;
    `uvm_object_utils(dpu_af_request)

    dpu_af_selection_mode_e mode;
    dpu_function_key_t requester;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_af_request");
        super.new(name);
        mode = DPU_AF_SELECTED;
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_af_request rhs);
        mode = rhs.mode;
        requester = rhs.requester;
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_af_request typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "AF request copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_af_request


// 设计原因：为 authoring 输入提供明确字段边界，避免调用方以散落变量表达设备约束。
// 职责与所有权：对象由调用方创建、编辑和拥有；解析器只读取或复制字段，不接管原始配置。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_device_cfg extends uvm_object;
    `uvm_object_utils(dpu_device_cfg)

    dpu_dut_caps dut_caps;
    dpu_host_cfg hosts[$];
    dpu_function_cfg functions[$];
    dpu_vf_pool_cfg vf_pools[$];
    dpu_af_request af_request;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_device_cfg");
        super.new(name);
        dut_caps = dpu_dut_caps::type_id::create({name, "_dut_caps"});
        af_request = dpu_af_request::type_id::create({name, "_af_request"});
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_device_cfg rhs);
        dpu_host_cfg host_copy;
        dpu_function_cfg function_copy;
        dpu_vf_pool_cfg pool_copy;

        if (rhs.dut_caps == null) begin
            dut_caps = null;
        end else begin
            dut_caps = dpu_dut_caps::type_id::create({get_name(), "_dut_caps"});
            dut_caps.copy_from(rhs.dut_caps);
        end
        hosts.delete();
        foreach (rhs.hosts[index]) begin
            if (rhs.hosts[index] == null) begin
                hosts.push_back(null);
            end else begin
                host_copy = dpu_host_cfg::type_id::create(
                    $sformatf("%s_host_%0d", get_name(), index));
                host_copy.copy_from(rhs.hosts[index]);
                hosts.push_back(host_copy);
            end
        end
        functions.delete();
        foreach (rhs.functions[index]) begin
            if (rhs.functions[index] == null) begin
                functions.push_back(null);
            end else begin
                function_copy = dpu_function_cfg::type_id::create(
                    $sformatf("%s_function_%0d", get_name(), index));
                function_copy.copy_from(rhs.functions[index]);
                functions.push_back(function_copy);
            end
        end
        vf_pools.delete();
        foreach (rhs.vf_pools[index]) begin
            if (rhs.vf_pools[index] == null) begin
                vf_pools.push_back(null);
            end else begin
                pool_copy = dpu_vf_pool_cfg::type_id::create(
                    $sformatf("%s_vf_pool_%0d", get_name(), index));
                pool_copy.copy_from(rhs.vf_pools[index]);
                vf_pools.push_back(pool_copy);
            end
        end
        if (rhs.af_request == null) begin
            af_request = null;
        end else begin
            af_request = dpu_af_request::type_id::create(
                {get_name(), "_af_request"});
            af_request.copy_from(rhs.af_request);
        end
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_device_cfg typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "device configuration copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_device_cfg

`endif // DPU_DEVICE_CFG_SV
