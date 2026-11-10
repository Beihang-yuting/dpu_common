/*
 * 所属层次：src/ VIO 放置 authoring 配置层。
 * 文件职责：声明候选过滤器、设备约束、qpair 覆盖、放置请求和诊断信息。
 * 主要依赖：dpu_device_types、dpu_placement_types、dpu_resource_types。
 * 可选参数入口：load_params 显式读取 AIP；未编译 AIP 时无副作用，不在构造/复制中读取。
 * 加载边界：只更新 authoring 输入；拓扑创建、完整校验、快照冻结仍由调用方负责。
 * 所有权与生命周期：配置对象由调用方编辑和拥有，normalizer 复制需要的字段；diagnostic 可清空复用。
 */
`ifndef DPU_PLACEMENT_CFG_SV
`define DPU_PLACEMENT_CFG_SV

`ifdef AIP_CMDLINE_SV
// 候选/固定设备使用已有 function key 的值语义，不建立 PF/VF 或绑定资源。
// 仅显式给出集合覆盖时应用 schema；新增条目的缺省键为 h0/pf0/PF/vf0。
// 原集合无参数时完整保留。显式重建集合后，由 load_params 和 normalizer 验证键与拓扑引用。
`aip_struct_type_begin(dpu_function_key_t)
    `aip_field_int(int unsigned, host_id, 0)
    `aip_field_int(int unsigned, pf_id, 0)
    `aip_field_enum(dpu_function_kind_e, kind, DPU_FUNCTION_PF)
    `aip_field_int(int unsigned, vf_id, 0)
`aip_struct_type_end(dpu_function_key_t)
`endif

// 设计原因：将相关值和操作约束集中在独立边界，避免跨模块重复解释同一契约。
// 职责与所有权：对象/类型按值语义管理自身字段，不隐式取得外部资源或生命周期控制权。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_vio_candidate_filter extends uvm_object;
    `uvm_object_utils(dpu_vio_candidate_filter)

    int unsigned host_ids[$];
    dpu_function_key_t parent_pf_keys[$];
    int unsigned vf_ids[$];
    dpu_function_key_t function_keys[$];

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_vio_candidate_filter");
        super.new(name);
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_vio_candidate_filter rhs);
        host_ids = rhs.host_ids;
        parent_pf_keys = rhs.parent_pf_keys;
        vf_ids = rhs.vf_ids;
        function_keys = rhs.function_keys;
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_vio_candidate_filter typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "candidate filter copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction

    // 功能：显式加载 AIP 参数，当前字段作为缺省值；构造、复制均不会自动读取。
    // 输入：path 是本次唯一作用域；AIP 不提供父路径继承，调用方应先加载模板再复制并覆盖实例。
    // 副作用：只读取本对象 authoring 字段；不分配硬件资源、不创建拓扑或访问快照。
    // 边界：类型/位宽或地址溢出立即 fatal；跨对象整体约束由调用方随后 validate/resolver 检查。
    // 未编译 AIP 时为空操作；重复调用表示显式重新抽样，调用方应控制调用次数。
    function void load_params(string	path = "dpu");
`ifdef AIP_CMDLINE_SV
        begin
            bit	present;
            int unsigned	host_ids[$];
            `DPU_AIP_PRESENT(path, "host_ids", present)
            if (present) begin
                `DPU_AIP_UNSIGNED_QUEUE(path, "host_ids")
                `aip_int_queue(path, int unsigned, host_ids, 0)
                foreach (host_ids[index]) begin
                    if (host_ids[index] >= DPU_MAX_HOSTS)
                        $fatal(1, "DPU_PARAMS: %s.host_ids[%0d] exceeds legal ID capacity", path, index);
                end
                this.host_ids = host_ids;
            end
        end
        begin
            bit	present;
            int unsigned	vf_ids[$];
            `DPU_AIP_PRESENT(path, "vf_ids", present)
            if (present) begin
                `DPU_AIP_UNSIGNED_QUEUE(path, "vf_ids")
                `aip_int_queue(path, int unsigned, vf_ids, 0)
                foreach (vf_ids[index]) begin
                    if (vf_ids[index] >= DPU_MAX_VFS_PER_PF)
                        $fatal(1, "DPU_PARAMS: %s.vf_ids[%0d] exceeds legal ID capacity", path, index);
                end
                this.vf_ids = vf_ids;
            end
        end
        begin
            bit	present;
            dpu_function_key_t	parent_pfs[$];
            `DPU_AIP_PRESENT(path, "parent_pfs", present)
            if (present) begin
                // 显式集合是一次完整声明；支持 AIP size/each/索引/compact，缺省键由 schema 定义。
                `DPU_AIP_UNSIGNED_QUEUE(path, "parent_pfs")
                `aip_struct_queue_apply(({path, ".parent_pfs"}), dpu_function_key_t, parent_pfs)
                foreach (parent_pfs[index]) begin
                    if (parent_pfs[index].host_id >= DPU_MAX_HOSTS ||
                        parent_pfs[index].pf_id >= DPU_MAX_PFS_PER_HOST ||
                        parent_pfs[index].vf_id >= DPU_MAX_VFS_PER_PF ||
                        (parent_pfs[index].kind == DPU_FUNCTION_PF && parent_pfs[index].vf_id != 0) ||
                        parent_pfs[index].kind != DPU_FUNCTION_PF)
                        $fatal(1, "DPU_PARAMS: %s.parent_pfs[%0d] contains an invalid function key", path, index);
                end
                this.parent_pf_keys = parent_pfs;
            end
        end
        begin
            bit	present;
            dpu_function_key_t	functions[$];
            `DPU_AIP_PRESENT(path, "functions", present)
            if (present) begin
                // 显式集合是一次完整声明；支持 AIP size/each/索引/compact，缺省键由 schema 定义。
                `DPU_AIP_UNSIGNED_QUEUE(path, "functions")
                `aip_struct_queue_apply(({path, ".functions"}), dpu_function_key_t, functions)
                foreach (functions[index]) begin
                    if (functions[index].host_id >= DPU_MAX_HOSTS ||
                        functions[index].pf_id >= DPU_MAX_PFS_PER_HOST ||
                        functions[index].vf_id >= DPU_MAX_VFS_PER_PF ||
                        (functions[index].kind == DPU_FUNCTION_PF && functions[index].vf_id != 0))
                        $fatal(1, "DPU_PARAMS: %s.functions[%0d] contains an invalid function key", path, index);
                end
                this.function_keys = functions;
            end
        end

`endif
    endfunction

endclass : dpu_vio_candidate_filter


// 设计原因：将相关值和操作约束集中在独立边界，避免跨模块重复解释同一契约。
// 职责与所有权：对象/类型按值语义管理自身字段，不隐式取得外部资源或生命周期控制权。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_vio_device_constraint extends uvm_object;
    `uvm_object_utils(dpu_vio_device_constraint)

    dpu_function_key_t function_key;
    dpu_count_constraint_mode_e mode;
    int unsigned qpair_count;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_vio_device_constraint");
        super.new(name);
        mode = DPU_COUNT_EXACT;
        qpair_count = 0;
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_vio_device_constraint rhs);
        function_key = rhs.function_key;
        mode = rhs.mode;
        qpair_count = rhs.qpair_count;
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_vio_device_constraint typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "device constraint copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction

    // 功能：显式加载 AIP 参数，当前字段作为缺省值；构造、复制均不会自动读取。
    // 输入：path 是本次唯一作用域；AIP 不提供父路径继承，调用方应先加载模板再复制并覆盖实例。
    // 副作用：只读取本对象 authoring 字段；不分配硬件资源、不创建拓扑或访问快照。
    // 边界：类型/位宽或地址溢出立即 fatal；跨对象整体约束由调用方随后 validate/resolver 检查。
    // 未编译 AIP 时为空操作；重复调用表示显式重新抽样，调用方应控制调用次数。
    function void load_params(string	path = "dpu.device");
`ifdef AIP_CMDLINE_SV
        begin
            int unsigned	host;
            `DPU_AIP_UINT(path, int unsigned, host, this.function_key.host_id)
            this.function_key.host_id = host;
        end
        begin
            int unsigned	pf;
            `DPU_AIP_UINT(path, int unsigned, pf, this.function_key.pf_id)
            this.function_key.pf_id = pf;
        end
        begin
            dpu_function_kind_e	kind;
            `aip_enum(path, dpu_function_kind_e, kind, this.function_key.kind)
            this.function_key.kind = kind;
        end
        begin
            int unsigned	vf;
            `DPU_AIP_UINT(path, int unsigned, vf, this.function_key.vf_id)
            this.function_key.vf_id = vf;
        end
        begin
            dpu_count_constraint_mode_e	mode;
            `aip_enum(path, dpu_count_constraint_mode_e, mode, this.mode)
            this.mode = mode;
        end
        begin
            int unsigned	qpairs;
            `DPU_AIP_UINT(path, int unsigned, qpairs, this.qpair_count)
            this.qpair_count = qpairs;
        end

`endif
    endfunction

endclass : dpu_vio_device_constraint


// 设计原因：将相关值和操作约束集中在独立边界，避免跨模块重复解释同一契约。
// 职责与所有权：对象/类型按值语义管理自身字段，不隐式取得外部资源或生命周期控制权。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_vio_qpair_override extends uvm_object;
    `uvm_object_utils(dpu_vio_qpair_override)

    int unsigned request_pair_index;
    dpu_assignment_mode_e owner_mode;
    dpu_function_key_t requested_owner;
    dpu_assignment_mode_e local_mode;
    int unsigned requested_local_pair_id;
    dpu_assignment_mode_e global_mode;
    int unsigned requested_global_qpair_id;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_vio_qpair_override");
        super.new(name);
        request_pair_index = 0;
        owner_mode = DPU_ASSIGN_AUTO;
        local_mode = DPU_ASSIGN_AUTO;
        global_mode = DPU_ASSIGN_AUTO;
        requested_local_pair_id = 0;
        requested_global_qpair_id = 0;
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_vio_qpair_override rhs);
        request_pair_index = rhs.request_pair_index;
        owner_mode = rhs.owner_mode;
        requested_owner = rhs.requested_owner;
        local_mode = rhs.local_mode;
        requested_local_pair_id = rhs.requested_local_pair_id;
        global_mode = rhs.global_mode;
        requested_global_qpair_id = rhs.requested_global_qpair_id;
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_vio_qpair_override typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "qpair override copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction

    // 功能：显式加载 AIP 参数，当前字段作为缺省值；构造、复制均不会自动读取。
    // 输入：path 是本次唯一作用域；AIP 不提供父路径继承，调用方应先加载模板再复制并覆盖实例。
    // 副作用：只读取本对象 authoring 字段；不分配硬件资源、不创建拓扑或访问快照。
    // 边界：类型/位宽或地址溢出立即 fatal；跨对象整体约束由调用方随后 validate/resolver 检查。
    // 未编译 AIP 时为空操作；重复调用表示显式重新抽样，调用方应控制调用次数。
    function void load_params(string	path = "dpu.pair");
`ifdef AIP_CMDLINE_SV
        begin
            int unsigned	index;
            `DPU_AIP_UINT(path, int unsigned, index, this.request_pair_index)
            this.request_pair_index = index;
        end
        begin
            dpu_assignment_mode_e	owner_mode;
            `aip_enum(path, dpu_assignment_mode_e, owner_mode, this.owner_mode)
            this.owner_mode = owner_mode;
        end
        begin
            int unsigned	owner_host;
            `DPU_AIP_UINT(path, int unsigned, owner_host, this.requested_owner.host_id)
            this.requested_owner.host_id = owner_host;
        end
        begin
            int unsigned	owner_pf;
            `DPU_AIP_UINT(path, int unsigned, owner_pf, this.requested_owner.pf_id)
            this.requested_owner.pf_id = owner_pf;
        end
        begin
            dpu_function_kind_e	owner_kind;
            `aip_enum(path, dpu_function_kind_e, owner_kind, this.requested_owner.kind)
            this.requested_owner.kind = owner_kind;
        end
        begin
            int unsigned	owner_vf;
            `DPU_AIP_UINT(path, int unsigned, owner_vf, this.requested_owner.vf_id)
            this.requested_owner.vf_id = owner_vf;
        end
        begin
            dpu_assignment_mode_e	local_mode;
            `aip_enum(path, dpu_assignment_mode_e, local_mode, this.local_mode)
            this.local_mode = local_mode;
        end
        begin
            int unsigned	local_id;
            `DPU_AIP_UINT(path, int unsigned, local_id, this.requested_local_pair_id)
            this.requested_local_pair_id = local_id;
        end
        begin
            dpu_assignment_mode_e	global_mode;
            `aip_enum(path, dpu_assignment_mode_e, global_mode, this.global_mode)
            this.global_mode = global_mode;
        end
        begin
            int unsigned	global_id;
            `DPU_AIP_UINT(path, int unsigned, global_id, this.requested_global_qpair_id)
            this.requested_global_qpair_id = global_id;
        end

`endif
    endfunction

endclass : dpu_vio_qpair_override


// 设计原因：为 authoring 输入提供明确字段边界，避免调用方以散落变量表达设备约束。
// 职责与所有权：对象由调用方创建、编辑和拥有；解析器只读取或复制字段，不接管原始配置。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_vio_placement_request extends uvm_object;
    `uvm_object_utils(dpu_vio_placement_request)

    int unsigned request_id;
    int unsigned service_instance_id;
    int unsigned total_qpairs;
    // Number of LAN MSI-X vectors requested for this function.  Zero keeps
    // the driver default (one vector per qpair in this model); a smaller
    // value models the real driver's min(online_cpus, rxq) sharing policy.
    int unsigned lan_msix_vectors;
    int unsigned seed;
    dpu_vio_candidate_kind_e candidate_kind;
    dpu_vio_device_policy_e device_policy;
    dpu_placement_order_e ordering;
    dpu_vio_candidate_filter candidate_filter;
    dpu_function_key_t fixed_devices[$];
    dpu_vio_device_constraint device_constraints[$];
    dpu_vio_qpair_override qpair_overrides[$];

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_vio_placement_request");
        super.new(name);
        request_id = 0;
        service_instance_id = 0;
        total_qpairs = 0;
        lan_msix_vectors = 0;
        seed = 0;
        candidate_kind = DPU_VIO_CANDIDATE_PF_AND_VF;
        device_policy = DPU_VIO_DEVICE_AUTO_MINIMUM;
        ordering = DPU_PLACEMENT_CANONICAL;
        candidate_filter = dpu_vio_candidate_filter::type_id::create(
            {name, "_candidate_filter"});
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_vio_placement_request rhs);
        dpu_vio_device_constraint constraint_copy;
        dpu_vio_qpair_override override_copy;

        request_id = rhs.request_id;
        service_instance_id = rhs.service_instance_id;
        total_qpairs = rhs.total_qpairs;
        lan_msix_vectors = rhs.lan_msix_vectors;
        seed = rhs.seed;
        candidate_kind = rhs.candidate_kind;
        device_policy = rhs.device_policy;
        ordering = rhs.ordering;
        fixed_devices = rhs.fixed_devices;
        if (rhs.candidate_filter == null) begin
            candidate_filter = null;
        end else begin
            candidate_filter = dpu_vio_candidate_filter::type_id::create(
                {get_name(), "_candidate_filter"});
            candidate_filter.copy_from(rhs.candidate_filter);
        end
        device_constraints.delete();
        foreach (rhs.device_constraints[index]) begin
            if (rhs.device_constraints[index] == null) begin
                device_constraints.push_back(null);
            end else begin
                constraint_copy = dpu_vio_device_constraint::type_id::create(
                    $sformatf("%s_constraint_%0d", get_name(), index));
                constraint_copy.copy_from(rhs.device_constraints[index]);
                device_constraints.push_back(constraint_copy);
            end
        end
        qpair_overrides.delete();
        foreach (rhs.qpair_overrides[index]) begin
            if (rhs.qpair_overrides[index] == null) begin
                qpair_overrides.push_back(null);
            end else begin
                override_copy = dpu_vio_qpair_override::type_id::create(
                    $sformatf("%s_override_%0d", get_name(), index));
                override_copy.copy_from(rhs.qpair_overrides[index]);
                qpair_overrides.push_back(override_copy);
            end
        end
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_vio_placement_request typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "placement request copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction

    // 功能：显式加载 AIP 参数，当前字段作为缺省值；构造、复制均不会自动读取。
    // 输入：path 是本次唯一作用域；AIP 不提供父路径继承，调用方应先加载模板再复制并覆盖实例。
    // 副作用：只读取本对象 authoring 字段；不分配硬件资源、不创建拓扑或访问快照。
    // 边界：类型/位宽或地址溢出立即 fatal；跨对象整体约束由调用方随后 validate/resolver 检查。
    // 未编译 AIP 时为空操作；重复调用表示显式重新抽样，调用方应控制调用次数。
    function void load_params(string	path = "dpu");
`ifdef AIP_CMDLINE_SV
        begin
            int unsigned	qpairs;
            `DPU_AIP_UINT(path, int unsigned, qpairs, this.total_qpairs)
            this.total_qpairs = qpairs;
        end
        begin
            int unsigned	lan_msix;
            `DPU_AIP_UINT(path, int unsigned, lan_msix, this.lan_msix_vectors)
            this.lan_msix_vectors = lan_msix;
        end
        begin
            int unsigned	placement_seed;
            `DPU_AIP_UINT(path, int unsigned, placement_seed, this.seed)
            this.seed = placement_seed;
        end
        begin
            dpu_vio_candidate_kind_e	candidate_kind;
            `aip_enum(path, dpu_vio_candidate_kind_e, candidate_kind, this.candidate_kind)
            this.candidate_kind = candidate_kind;
        end
        begin
            dpu_vio_device_policy_e	device_policy;
            `aip_enum(path, dpu_vio_device_policy_e, device_policy, this.device_policy)
            this.device_policy = device_policy;
        end
        begin
            dpu_placement_order_e	ordering;
            `aip_enum(path, dpu_placement_order_e, ordering, this.ordering)
            this.ordering = ordering;
        end
        begin
            bit	present;
            dpu_function_key_t	fixed_devices[$];
            `DPU_AIP_PRESENT(path, "fixed_devices", present)
            if (present) begin
                // 显式集合是一次完整声明；支持 AIP size/each/索引/compact，缺省键由 schema 定义。
                `DPU_AIP_UNSIGNED_QUEUE(path, "fixed_devices")
                `aip_struct_queue_apply(({path, ".fixed_devices"}), dpu_function_key_t, fixed_devices)
                foreach (fixed_devices[index]) begin
                    if (fixed_devices[index].host_id >= DPU_MAX_HOSTS ||
                        fixed_devices[index].pf_id >= DPU_MAX_PFS_PER_HOST ||
                        fixed_devices[index].vf_id >= DPU_MAX_VFS_PER_PF ||
                        (fixed_devices[index].kind == DPU_FUNCTION_PF && fixed_devices[index].vf_id != 0))
                        $fatal(1, "DPU_PARAMS: %s.fixed_devices[%0d] contains an invalid function key", path, index);
                end
                this.fixed_devices = fixed_devices;
            end
        end
        if (candidate_filter != null) candidate_filter.load_params(path);
        // 复杂的逐设备约束/逐 qpair 覆盖只加载既有对象，不通过数量参数创建它们。
        foreach (device_constraints[index]) begin
            if (device_constraints[index] != null)
                device_constraints[index].load_params($sformatf("%s.device%0d", path, index));
        end
        foreach (qpair_overrides[index]) begin
            if (qpair_overrides[index] != null)
                qpair_overrides[index].load_params($sformatf("%s.pair%0d", path, index));
        end

`endif
    endfunction

endclass : dpu_vio_placement_request


// 设计原因：为 authoring 输入提供明确字段边界，避免调用方以散落变量表达设备约束。
// 职责与所有权：对象由调用方创建、编辑和拥有；解析器只读取或复制字段，不接管原始配置。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_resource_placement_cfg extends uvm_object;
    `uvm_object_utils(dpu_resource_placement_cfg)

    dpu_resource_pool_config_t profiles[$];
    dpu_vio_placement_request vio_requests[$];
    int unsigned reserved_global_qpair_ids[$];
    dpu_global_id_range_t reserved_global_qpair_ranges[$];

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_resource_placement_cfg");
        super.new(name);
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_resource_placement_cfg rhs);
        dpu_vio_placement_request request_copy;

        profiles = rhs.profiles;
        reserved_global_qpair_ids = rhs.reserved_global_qpair_ids;
        reserved_global_qpair_ranges = rhs.reserved_global_qpair_ranges;
        vio_requests.delete();
        foreach (rhs.vio_requests[index]) begin
            if (rhs.vio_requests[index] == null) begin
                vio_requests.push_back(null);
            end else begin
                request_copy = dpu_vio_placement_request::type_id::create(
                    $sformatf("%s_request_%0d", get_name(), index));
                request_copy.copy_from(rhs.vio_requests[index]);
                vio_requests.push_back(request_copy);
            end
        end
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_resource_placement_cfg typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "placement config copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction

    // 功能：显式加载 AIP 参数，当前字段作为缺省值；构造、复制均不会自动读取。
    // 输入：path 是本次唯一作用域；AIP 不提供父路径继承，调用方应先加载模板再复制并覆盖实例。
    // 副作用：只读取本对象 authoring 字段；不分配硬件资源、不创建拓扑或访问快照。
    // 边界：类型/位宽或地址溢出立即 fatal；跨对象整体约束由调用方随后 validate/resolver 检查。
    // 未编译 AIP 时为空操作；重复调用表示显式重新抽样，调用方应控制调用次数。
    function void load_params(string	path = "dpu");
`ifdef AIP_CMDLINE_SV
        begin
            bit	present;
            int unsigned	reserved_qpairs[$];
            `DPU_AIP_PRESENT(path, "reserved_qpairs", present)
            if (present) begin
                `DPU_AIP_UNSIGNED_QUEUE(path, "reserved_qpairs")
                `aip_int_queue(path, int unsigned, reserved_qpairs, 0)
                foreach (reserved_qpairs[index]) begin
                    if (reserved_qpairs[index] >= DPU_MAX_VIO_GLOBAL_QPAIRS)
                        $fatal(1, "DPU_PARAMS: %s.reserved_qpairs[%0d] exceeds legal ID capacity", path, index);
                end
                this.reserved_global_qpair_ids = reserved_qpairs;
            end
        end
        foreach (profiles[index]) begin
            if (profiles[index].name == "virtio.qpair") begin
                int unsigned	qpair_capacity;
                int unsigned	qpair_per_func;
                `DPU_AIP_UINT(path, int unsigned, qpair_capacity, profiles[index].capacity)
                `DPU_AIP_UINT(path, int unsigned, qpair_per_func, profiles[index].max_per_function)
                profiles[index].capacity = qpair_capacity;
                profiles[index].max_per_function = qpair_per_func;
            end else begin
                string	pool_path;
                int unsigned	capacity;
                int unsigned	max_per_function;
                pool_path = $sformatf("%s.pool%0d", path, index);
                `DPU_AIP_UINT(pool_path, int unsigned, capacity, profiles[index].capacity)
                `DPU_AIP_UINT(pool_path, int unsigned, max_per_function, profiles[index].max_per_function)
                profiles[index].capacity = capacity;
                profiles[index].max_per_function = max_per_function;
            end
        end
        // 单 request 使用顶层短名；多 request 各有独立作用域，不重复消费全局随机参数。
        foreach (vio_requests[index]) begin
            if (vio_requests[index] != null)
                vio_requests[index].load_params(vio_requests.size() == 1 ? path :
                                               $sformatf("%s.request%0d", path, index));
        end

`endif
    endfunction

endclass : dpu_resource_placement_cfg


// 设计原因：把状态、错误上下文和结果集合统一成可复制的值对象，便于跨层传递。
// 职责与所有权：对象拥有自身文本和结果副本，不持有配置的可变引用。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_placement_diagnostic extends uvm_object;
    `uvm_object_utils(dpu_placement_diagnostic)

    dpu_placement_stage_e stage;
    dpu_placement_error_e error_code;
    bit has_request_id;
    bit has_function_key;
    bit has_service_key;
    bit has_pair_index;
    int unsigned request_id;
    int unsigned request_pair_index;
    dpu_function_key_t function_key;
    dpu_service_key_t service_key;
    string message;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_placement_diagnostic");
        super.new(name);
        clear();
    endfunction

// 功能：清空或设置一条 placement diagnostic 的阶段、错误码和上下文（clear）。
// 输入/输出：输入为诊断字段或错误详情；无返回值，更新当前 diagnostic。
// 边界/副作用：清空只影响诊断对象；设置失败上下文不得继续修改资源分配结果。
    function void clear();
        stage = DPU_PLACE_STAGE_NONE;
        error_code = DPU_PLACE_ERR_NONE;
        has_request_id = 0;
        has_function_key = 0;
        has_service_key = 0;
        has_pair_index = 0;
        request_id = 0;
        request_pair_index = 0;
        function_key.host_id = 0;
        function_key.pf_id = 0;
        function_key.kind = DPU_FUNCTION_PF;
        function_key.vf_id = 0;
        service_key.function_key.host_id = 0;
        service_key.function_key.pf_id = 0;
        service_key.function_key.kind = DPU_FUNCTION_PF;
        service_key.function_key.vf_id = 0;
        service_key.service_kind = DPU_SERVICE_VIO_NET;
        service_key.service_instance_id = 0;
        message = "";
    endfunction

// 功能：清空或设置一条 placement diagnostic 的阶段、错误码和上下文（set）。
// 输入/输出：输入为诊断字段或错误详情；无返回值，更新当前 diagnostic。
// 边界/副作用：清空只影响诊断对象；设置失败上下文不得继续修改资源分配结果。
    function void set(
        input dpu_placement_stage_e new_stage,
        input dpu_placement_error_e new_error_code,
        input string new_message
    );
        clear();
        stage = new_stage;
        error_code = new_error_code;
        message = new_message;
    endfunction

// 功能：为 placement diagnostic 写入 request/function/service/pair 定位上下文（set_request_context）。
// 输入/输出：输入为对应标识；无返回值，不改变 placement plan。
// 边界/副作用：上下文只用于错误定位；无效标识由上层校验并保留原错误原因。
    function void set_request_context(input int unsigned value);
        has_request_id = 1;
        request_id = value;
    endfunction

// 功能：为 placement diagnostic 写入 request/function/service/pair 定位上下文（set_function_context）。
// 输入/输出：输入为对应标识；无返回值，不改变 placement plan。
// 边界/副作用：上下文只用于错误定位；无效标识由上层校验并保留原错误原因。
    function void set_function_context(input dpu_function_key_t value);
        has_function_key = 1;
        function_key = value;
    endfunction

// 功能：为 placement diagnostic 写入 request/function/service/pair 定位上下文（set_service_context）。
// 输入/输出：输入为对应标识；无返回值，不改变 placement plan。
// 边界/副作用：上下文只用于错误定位；无效标识由上层校验并保留原错误原因。
    function void set_service_context(input dpu_service_key_t value);
        has_service_key = 1;
        service_key = value;
    endfunction

// 功能：为 placement diagnostic 写入 request/function/service/pair 定位上下文（set_pair_context）。
// 输入/输出：输入为对应标识；无返回值，不改变 placement plan。
// 边界/副作用：上下文只用于错误定位；无效标识由上层校验并保留原错误原因。
    function void set_pair_context(input int unsigned value);
        has_pair_index = 1;
        request_pair_index = value;
    endfunction

// 功能：设置对象的配置字段、依赖对象或错误上下文（set_device_resolution_failure）。
// 输入/输出：输入为新值或外部对象；通常无返回值，字段写入当前对象。
// 边界/副作用：必须尊重冻结边界；外部对象按约定借用或复制。
    function void set_device_resolution_failure(input string detail);
        set(DPU_PLACE_STAGE_DEVICE_RESOLUTION,
            DPU_PLACE_ERR_DEVICE_RESOLUTION_FAILED, detail);
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_placement_diagnostic rhs);
        stage = rhs.stage;
        error_code = rhs.error_code;
        has_request_id = rhs.has_request_id;
        has_function_key = rhs.has_function_key;
        has_service_key = rhs.has_service_key;
        has_pair_index = rhs.has_pair_index;
        request_id = rhs.request_id;
        request_pair_index = rhs.request_pair_index;
        function_key = rhs.function_key;
        service_key = rhs.service_key;
        message = rhs.message;
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_placement_diagnostic typed_rhs;

        super.do_copy(rhs);
        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("DPU_CFG_COPY", "placement diagnostic copy received incompatible object")
            return;
        end
        copy_from(typed_rhs);
    endfunction
endclass : dpu_placement_diagnostic

`endif // DPU_PLACEMENT_CFG_SV
