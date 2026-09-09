/*
 * 所属层次：src/ VIO 放置规范化结果层。
 * 文件职责：将候选请求、目标 function、qpair 配对和保留区间转换为稳定、可冻结的中间计划。
 * 主要依赖：dpu_placement_cfg、dpu_placement_types。
 * 所有权与生命周期：plan 冻结前拥有规范化请求和排序索引，冻结后只读；不反向修改 authoring 对象。
 */
`ifndef DPU_NORMALIZED_PLACEMENT_PLAN_SV
`define DPU_NORMALIZED_PLACEMENT_PLAN_SV

// 设计原因：为 authoring 输入提供明确字段边界，避免调用方以散落变量表达设备约束。
// 职责与所有权：对象由调用方创建、编辑和拥有；解析器只读取或复制字段，不接管原始配置。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_normalized_vio_request extends uvm_object;
    `uvm_object_utils(dpu_normalized_vio_request)

    int unsigned request_id, service_instance_id, total_qpairs, seed;
    int unsigned lan_msix_vectors;
    dpu_vio_device_policy_e device_policy;
    dpu_placement_order_e ordering;
    dpu_function_key_t canonical_candidates[$];
    dpu_function_key_t effective_candidates[$];
    dpu_vio_participant_target_t targets[$];
    dpu_normalized_vio_pair_t pairs[$];

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_normalized_vio_request");
        super.new(name);
    endfunction

// 功能：把源对象的配置或结果深拷贝到当前对象（copy_from）。
// 输入/输出：输入为同型 rhs；无返回值，动态数组按值复制。
// 边界/副作用：调用方仍拥有 rhs；空源或类型不符时拒绝，避免共享可变引用。
    function void copy_from(input dpu_normalized_vio_request rhs);
        request_id = rhs.request_id;
        service_instance_id = rhs.service_instance_id;
        total_qpairs = rhs.total_qpairs;
        lan_msix_vectors = rhs.lan_msix_vectors;
        seed = rhs.seed;
        device_policy = rhs.device_policy;
        ordering = rhs.ordering;
        canonical_candidates = rhs.canonical_candidates;
        effective_candidates = rhs.effective_candidates;
        targets = rhs.targets;
        pairs = rhs.pairs;
    endfunction

// 功能：实现 UVM copy 钩子，将源对象字段复制到当前对象（do_copy）。
// 输入/输出：输入为 UVM object，先转换为同型对象；无返回值。
// 边界/副作用：源对象保持不变；类型不兼容时拒绝复制并保留可诊断状态。
    virtual function void do_copy(uvm_object rhs);
        dpu_normalized_vio_request typed_rhs;
        super.do_copy(rhs);
        if ($cast(typed_rhs, rhs))
            copy_from(typed_rhs);
    endfunction
endclass : dpu_normalized_vio_request

// 设计原因：把跨阶段解析结果和派生索引封装起来，避免消费者直接依赖可变配置。
// 职责与所有权：对象在 freeze 前填充并拥有内部副本，freeze 后只读，查询者只能获得值复制。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_normalized_placement_plan extends uvm_object;
    `uvm_object_utils(dpu_normalized_placement_plan)

    int unsigned effective_global_capacity, effective_device_capacity;
    protected dpu_normalized_vio_request requests[$];
    protected dpu_resource_pool_config_t profiles[$];
    protected int unsigned reserved_global_qpair_ids[$];
    protected dpu_global_id_range_t reserved_global_qpair_ranges[$];
    protected bit frozen;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_normalized_placement_plan");
        super.new(name);
        frozen = 0;
    endfunction

// 功能：比较两个键或范围，提供确定性的排序或兼容性判定（request_less）。
// 输入/输出：输入为两个值语义对象；返回 bit，不修改输入。
// 边界/副作用：比较规则必须覆盖 domain/owner 和边界值，保证排序与资源冲突检查使用同一语义。
    protected function bit request_less(
        input dpu_normalized_vio_request lhs,
        input dpu_normalized_vio_request rhs
    );
        return lhs.request_id < rhs.request_id;
    endfunction

// 功能：按稳定键整理集合并重建派生索引（sort_requests）。
// 输入/输出：输入为内部或引用传入的数组；无返回值，排序结果写回数组/索引。
// 边界/副作用：只改变表示顺序，不改变元素语义，保证快照和计划确定性。
    protected function void sort_requests();
        dpu_normalized_vio_request swap;
        for (int left = 0; left < requests.size(); left++) begin
            for (int right = left + 1; right < requests.size(); right++) begin
                if (request_less(requests[right], requests[left])) begin
                    swap = requests[left];
                    requests[left] = requests[right];
                    requests[right] = swap;
                end
            end
        end
    endfunction

// 功能：执行与对象职责相关的内部辅助操作（target_order）。
// 输入/输出：输入和输出由函数签名定义；通过返回值或 output 参数报告结果。
// 边界/副作用：除签名明确写入外不产生隐藏副作用，失败时保持状态一致。
    protected function int unsigned target_order(
        input dpu_normalized_vio_request request,
        input dpu_vio_participant_target_t target
    );
        foreach (request.effective_candidates[index]) begin
            if (dpu_same_function_key(request.effective_candidates[index],
                                      target.service_key.function_key))
                return index;
        end
        return request.effective_candidates.size();
    endfunction

// 功能：按稳定键整理集合并重建派生索引（sort_targets）。
// 输入/输出：输入为内部或引用传入的数组；无返回值，排序结果写回数组/索引。
// 边界/副作用：只改变表示顺序，不改变元素语义，保证快照和计划确定性。
    protected function void sort_targets(input dpu_normalized_vio_request request);
        dpu_vio_participant_target_t swap;
        int unsigned left_order;
        int unsigned right_order;
        for (int left = 0; left < request.targets.size(); left++) begin
            for (int right = left + 1; right < request.targets.size(); right++) begin
                left_order = target_order(request, request.targets[left]);
                right_order = target_order(request, request.targets[right]);
                if ((right_order < left_order) ||
                    ((right_order == left_order) &&
                     (dpu_function_key_name(request.targets[right].service_key.function_key) <
                      dpu_function_key_name(request.targets[left].service_key.function_key)))) begin
                    swap = request.targets[left];
                    request.targets[left] = request.targets[right];
                    request.targets[right] = swap;
                end
            end
        end
    endfunction

// 功能：按稳定键整理集合并重建派生索引（sort_pairs）。
// 输入/输出：输入为内部或引用传入的数组；无返回值，排序结果写回数组/索引。
// 边界/副作用：只改变表示顺序，不改变元素语义，保证快照和计划确定性。
    protected function void sort_pairs(input dpu_normalized_vio_request request);
        dpu_normalized_vio_pair_t swap;
        for (int left = 0; left < request.pairs.size(); left++) begin
            for (int right = left + 1; right < request.pairs.size(); right++) begin
                if (request.pairs[right].request_pair_index <
                    request.pairs[left].request_pair_index) begin
                    swap = request.pairs[left];
                    request.pairs[left] = request.pairs[right];
                    request.pairs[right] = swap;
                end
            end
        end
    endfunction

// 功能：校验拓扑、绑定或保留区间之间的跨对象不变量（reservations_are_valid）。
// 输入/输出：输入为当前快照/计划及诊断输出；返回 bit 并写明首个冲突。
// 边界/副作用：发现重复 global/local ID、owner 不匹配或区间重叠时必须整体失败。
    protected function bit reservations_are_valid(
        input int unsigned ids[$],
        input dpu_global_id_range_t ranges[$]
    );
        foreach (ids[index]) begin
            if (ids[index] >= DPU_MAX_VIO_GLOBAL_QPAIRS)
                return 0;
        end
        foreach (ranges[index]) begin
            if ((ranges[index].first_id > ranges[index].last_id) ||
                (ranges[index].last_id >= DPU_MAX_VIO_GLOBAL_QPAIRS))
                return 0;
        end
        return 1;
    endfunction

// 功能：按稳定键整理集合并重建派生索引（canonicalize_reservations）。
// 输入/输出：输入为内部或引用传入的数组；无返回值，排序结果写回数组/索引。
// 边界/副作用：只改变表示顺序，不改变元素语义，保证快照和计划确定性。
    protected function void canonicalize_reservations();
        dpu_global_id_range_t intervals[$];
        dpu_global_id_range_t merged[$];
        dpu_global_id_range_t swap;

        intervals = reserved_global_qpair_ranges;
        foreach (reserved_global_qpair_ids[index]) begin
            intervals.push_back('{first_id: reserved_global_qpair_ids[index],
                                  last_id: reserved_global_qpair_ids[index]});
        end
        for (int left = 0; left < intervals.size(); left++) begin
            for (int right = left + 1; right < intervals.size(); right++) begin
                if ((intervals[right].first_id < intervals[left].first_id) ||
                    ((intervals[right].first_id == intervals[left].first_id) &&
                     (intervals[right].last_id < intervals[left].last_id))) begin
                    swap = intervals[left];
                    intervals[left] = intervals[right];
                    intervals[right] = swap;
                end
            end
        end
        foreach (intervals[index]) begin
            if ((merged.size() == 0) ||
                (intervals[index].first_id >
                 (merged[merged.size() - 1].last_id + 1))) begin
                merged.push_back(intervals[index]);
            end else if (intervals[index].last_id >
                         merged[merged.size() - 1].last_id) begin
                merged[merged.size() - 1].last_id = intervals[index].last_id;
            end
        end
        reserved_global_qpair_ids.delete();
        reserved_global_qpair_ranges.delete();
        foreach (merged[index]) begin
            if (merged[index].first_id == merged[index].last_id)
                reserved_global_qpair_ids.push_back(merged[index].first_id);
            else
                reserved_global_qpair_ranges.push_back(merged[index]);
        end
    endfunction

// 功能：向对象加入配置项、绑定或寄存器操作（add_request）。
// 输入/输出：输入为待加入值；成功返回 1/无返回值，失败返回 why 或记录诊断。
// 边界/副作用：加入前检查重复键、所有权和冻结状态，失败不得留下半写入元素。
    function bit add_request(input dpu_normalized_vio_request request,
                             output string why);
        dpu_normalized_vio_request request_copy;
        why = "";
        if (frozen) begin
            why = "cannot add a request to a frozen placement plan";
            return 0;
        end
        if (request == null) begin
            why = "cannot add a null normalized request";
            return 0;
        end
        foreach (requests[index]) begin
            if (requests[index].request_id == request.request_id) begin
                why = "normalized placement plan has a duplicate request ID";
                return 0;
            end
        end
        foreach (request.pairs[index]) begin
            for (int prior = 0; prior < index; prior++) begin
                if (request.pairs[prior].request_pair_index ==
                    request.pairs[index].request_pair_index) begin
                    why = "normalized placement plan has duplicate explicit pair records";
                    return 0;
                end
            end
        end
        request_copy = dpu_normalized_vio_request::type_id::create(
            $sformatf("%s_request_%0d", get_name(), request.request_id));
        request_copy.copy_from(request);
        sort_targets(request_copy);
        sort_pairs(request_copy);
        requests.push_back(request_copy);
        return 1;
    endfunction

// 功能：完成索引重建、排序和一致性校验，并把可变对象转换为只读快照（freeze）。
// 输入/输出：输入为当前未冻结对象；返回 bit，失败通过 why/diagnostic 说明。
// 边界/副作用：冻结成功后所有写入接口必须拒绝修改。
    function bit freeze(output string why);
        why = "";
        if (frozen)
            return 1;
        sort_requests();
        frozen = 1;
        return 1;
    endfunction

// 功能：查询对象是否已经完成冻结生命周期阶段（is_frozen）。
// 输入/输出：无输入；返回 bit，不修改对象。
// 边界/副作用：只反映内部生命周期标志，不代替 validate/freeze。
    function bit is_frozen();
        return frozen;
    endfunction

// 功能：设置对象的配置字段、依赖对象或错误上下文（set_profiles）。
// 输入/输出：输入为新值或外部对象；通常无返回值，字段写入当前对象。
// 边界/副作用：必须尊重冻结边界；外部对象按约定借用或复制。
    function void set_profiles(input dpu_resource_pool_config_t value[$]);
        if (!frozen)
            profiles = value;
    endfunction

// 功能：设置对象的配置字段、依赖对象或错误上下文（set_reservations）。
// 输入/输出：输入为新值或外部对象；通常无返回值，字段写入当前对象。
// 边界/副作用：必须尊重冻结边界；外部对象按约定借用或复制。
    function void set_reservations(input int unsigned ids[$],
                                   input dpu_global_id_range_t ranges[$]);
        if (!frozen) begin
            reserved_global_qpair_ids = ids;
            reserved_global_qpair_ranges = ranges;
            // Preserve malformed authoring for the resolver's structured
            // validation.  Every valid authoring form is normalized to one
            // ascending, non-overlapping union before any query or allocation.
            if (reservations_are_valid(ids, ranges))
                canonicalize_reservations();
        end
    endfunction

// 功能：按键查询内部索引或导出值复制（list_targets）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_targets(input int unsigned request_id,
                               ref dpu_vio_participant_target_t targets[$]);
        targets.delete();
        foreach (requests[index]) begin
            if (requests[index].request_id == request_id) begin
                targets = requests[index].targets;
                return;
            end
        end
    endfunction

// 功能：按键查询内部索引或导出值复制（list_pairs）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_pairs(input int unsigned request_id,
                             ref dpu_normalized_vio_pair_t pairs[$]);
        pairs.delete();
        foreach (requests[index]) begin
            if (requests[index].request_id == request_id) begin
                pairs = requests[index].pairs;
                return;
            end
        end
    endfunction

// 功能：按键查询内部索引或导出值复制（list_requests）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_requests(ref dpu_normalized_vio_request value[$]);
        dpu_normalized_vio_request request_copy;
        value.delete();
        foreach (requests[index]) begin
            request_copy = dpu_normalized_vio_request::type_id::create(
                $sformatf("%s_request_copy_%0d", get_name(), index));
            request_copy.copy_from(requests[index]);
            value.push_back(request_copy);
        end
    endfunction

// 功能：按键查询内部索引或导出值复制（get_request）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit get_request(input int unsigned request_id,
                             output dpu_normalized_vio_request request);
        request = null;
        foreach (requests[index]) begin
            if (requests[index].request_id == request_id) begin
                request = dpu_normalized_vio_request::type_id::create(
                    $sformatf("%s_request_copy_%0d", get_name(), request_id));
                request.copy_from(requests[index]);
                return 1;
            end
        end
        return 0;
    endfunction

// 功能：按键查询内部索引或导出值复制（list_reserved_global_qpair_ids）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_reserved_global_qpair_ids(ref int unsigned ids[$]);
        ids = reserved_global_qpair_ids;
    endfunction

// 功能：按键查询内部索引或导出值复制（list_reserved_global_qpair_ranges）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_reserved_global_qpair_ranges(
        ref dpu_global_id_range_t ranges[$]
    );
        ranges = reserved_global_qpair_ranges;
    endfunction

// 功能：按键查询内部索引或导出值复制（list_resource_profiles）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_resource_profiles(
        ref dpu_resource_pool_config_t value[$]
    );
        value = profiles;
    endfunction
endclass : dpu_normalized_placement_plan

`endif // DPU_NORMALIZED_PLACEMENT_PLAN_SV
