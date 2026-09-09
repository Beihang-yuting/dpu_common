/*
 * 所属层次：src/ 资源解析结果快照层。
 * 文件职责：保存 VIO qpair、AF extra queue、保留区间和反向索引，并在 freeze 后提供一致性查询。
 * 主要依赖：dpu_normalized_placement_plan、dpu_placement_diagnostic、dpu_device_snapshot。
 * 所有权与生命周期：拥有所有绑定和索引副本；freeze 前允许填充，freeze 后拒绝写入。
 */
`ifndef DPU_RESOURCE_SNAPSHOT_SV
`define DPU_RESOURCE_SNAPSHOT_SV

// 设计原因：把跨阶段解析结果和派生索引封装起来，避免消费者直接依赖可变配置。
// 职责与所有权：对象在 freeze 前填充并拥有内部副本，freeze 后只读，查询者只能获得值复制。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_resource_snapshot extends uvm_object;
    `uvm_object_utils(dpu_resource_snapshot)

    protected bit m_frozen;
    protected dpu_normalized_placement_plan m_plan;
    protected dpu_device_snapshot m_device_snapshot;
    protected dpu_vio_qpair_binding_t m_bindings[$];
    protected dpu_af_extra_queue_binding_t m_af_extra_bindings[$];
    protected int unsigned m_request_index[string];
    protected int unsigned m_service_local_index[string];
    protected int unsigned m_service_virtio_pair_index[string];
    protected int unsigned m_global_index[string];
    protected int unsigned m_af_extra_offset_index[string];
    protected int unsigned m_af_extra_global_index[string];
    protected int unsigned m_reserved_ids[$];
    protected dpu_global_id_range_t m_reserved_ranges[$];
    protected dpu_resource_pool_config_t m_profiles[$];

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_resource_snapshot");
        super.new(name);
        m_frozen = 0;
        m_plan = null;
        m_device_snapshot = null;
    endfunction

// 功能：按需创建或补齐诊断对象，保证失败路径可报告（ensure_diagnostic）。
// 输入/输出：输入为 diagnostic 引用或上下文；无返回值。
// 边界/副作用：只初始化缺失字段，不覆盖已有根因。
    protected function void ensure_diagnostic(
        output dpu_placement_diagnostic diagnostic
    );
        if (diagnostic == null)
            diagnostic = dpu_placement_diagnostic::type_id::create(
                {get_name(), "_diagnostic"});
    endfunction

// 功能：记录资源解析失败的错误码、文本和可选定位上下文（set_failure）。
// 输入/输出：输入为 diagnostic、阶段、错误码和 message；无返回值。
// 边界/副作用：只保留可诊断根因，不覆盖已有更具体错误，也不继续写入冻结对象。
    protected function void set_failure(
        output dpu_placement_diagnostic diagnostic,
        input dpu_placement_error_e error_code,
        input string message
    );
        ensure_diagnostic(diagnostic);
        diagnostic.set(DPU_PLACE_STAGE_RESOURCE_RESOLUTION, error_code,
                       message);
    endfunction

// 功能：把逻辑键转换为稳定的诊断/索引字符串（request_key）。
// 输入/输出：输入为值语义键；返回格式化字符串，不修改输入。
// 边界/副作用：格式必须与对应 lookup/list 索引一致；非法枚举不得静默映射为另一个合法键。
    protected function string request_key(
        input int unsigned request_id,
        input int unsigned request_pair_index
    );
        return $sformatf("%0d:%0d", request_id, request_pair_index);
    endfunction

// 功能：把逻辑键转换为稳定的诊断/索引字符串（service_local_key）。
// 输入/输出：输入为值语义键；返回格式化字符串，不修改输入。
// 边界/副作用：格式必须与对应 lookup/list 索引一致；非法枚举不得静默映射为另一个合法键。
    protected function string service_local_key(
        input dpu_service_key_t service_key,
        input int unsigned local_pair_id
    );
        return {dpu_service_key_name(service_key),
                $sformatf(":%0d", local_pair_id)};
    endfunction

// 功能：把逻辑键转换为稳定的诊断/索引字符串（service_virtio_pair_key）。
// 输入/输出：输入为值语义键；返回格式化字符串，不修改输入。
// 边界/副作用：格式必须与对应 lookup/list 索引一致；非法枚举不得静默映射为另一个合法键。
    protected function string service_virtio_pair_key(
        input dpu_service_key_t service_key,
        input int unsigned virtio_pair_index
    );
        return {dpu_service_key_name(service_key),
                $sformatf(":%0d", virtio_pair_index)};
    endfunction

// 功能：把逻辑键转换为稳定的诊断/索引字符串（global_key）。
// 输入/输出：输入为值语义键；返回格式化字符串，不修改输入。
// 边界/副作用：格式必须与对应 lookup/list 索引一致；非法枚举不得静默映射为另一个合法键。
    protected function string global_key(input int unsigned global_qpair_id);
        return $sformatf("%0d", global_qpair_id);
    endfunction

// 功能：判断对象是否满足指定状态、资格或引用关系（mutable）。
// 输入/输出：输入为待判断的键/状态；返回 bit，不修改对象。
// 边界/副作用：边界值显式判断，不触发分配、排序或其他隐藏副作用。
    protected function bit mutable(output dpu_placement_diagnostic diagnostic);
        ensure_diagnostic(diagnostic);
        diagnostic.clear();
        if (m_frozen) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "resource snapshot is frozen");
            return 0;
        end
        return 1;
    endfunction

// 功能：比较两个键或范围，提供确定性的排序或兼容性判定（binding_less）。
// 输入/输出：输入为两个值语义对象；返回 bit，不修改输入。
// 边界/副作用：比较规则必须覆盖 domain/owner 和边界值，保证排序与资源冲突检查使用同一语义。
    protected function bit binding_less(
        input dpu_vio_qpair_binding_t lhs,
        input dpu_vio_qpair_binding_t rhs
    );
        return (lhs.request_id < rhs.request_id) ||
            ((lhs.request_id == rhs.request_id) &&
             (lhs.request_pair_index < rhs.request_pair_index));
    endfunction

// 功能：按稳定键整理集合并重建派生索引（sort_bindings）。
// 输入/输出：输入为内部或引用传入的数组；无返回值，排序结果写回数组/索引。
// 边界/副作用：只改变表示顺序，不改变元素语义，保证快照和计划确定性。
    protected function void sort_bindings();
        dpu_vio_qpair_binding_t swap;
        for (int left = 0; left < m_bindings.size(); left++) begin
            for (int right = left + 1; right < m_bindings.size(); right++) begin
                if (binding_less(m_bindings[right], m_bindings[left])) begin
                    swap = m_bindings[left];
                    m_bindings[left] = m_bindings[right];
                    m_bindings[right] = swap;
                end
            end
        end
    endfunction

// 功能：按稳定键整理集合并重建派生索引（sort_af_extra_bindings）。
// 输入/输出：输入为内部或引用传入的数组；无返回值，排序结果写回数组/索引。
// 边界/副作用：只改变表示顺序，不改变元素语义，保证快照和计划确定性。
    protected function void sort_af_extra_bindings();
        dpu_af_extra_queue_binding_t swap;
        for (int left = 0; left < m_af_extra_bindings.size(); left++) begin
            for (int right = left + 1;
                 right < m_af_extra_bindings.size(); right++) begin
                if (m_af_extra_bindings[right].extra_queue_offset <
                    m_af_extra_bindings[left].extra_queue_offset) begin
                    swap = m_af_extra_bindings[left];
                    m_af_extra_bindings[left] = m_af_extra_bindings[right];
                    m_af_extra_bindings[right] = swap;
                end
            end
        end
    endfunction

// 功能：按稳定键整理集合并重建派生索引（rebuild_indexes）。
// 输入/输出：输入为内部或引用传入的数组；无返回值，排序结果写回数组/索引。
// 边界/副作用：只改变表示顺序，不改变元素语义，保证快照和计划确定性。
    protected function void rebuild_indexes();
        m_request_index.delete();
        m_service_local_index.delete();
        m_service_virtio_pair_index.delete();
        m_global_index.delete();
        m_af_extra_offset_index.delete();
        m_af_extra_global_index.delete();
        foreach (m_bindings[index]) begin
            m_request_index[request_key(m_bindings[index].request_id,
                                        m_bindings[index].request_pair_index)] = index;
            m_service_local_index[service_local_key(m_bindings[index].service_key,
                                                    m_bindings[index].local_pair_id)] = index;
            m_service_virtio_pair_index[service_virtio_pair_key(
                m_bindings[index].service_key,
                m_bindings[index].virtio_pair_index)] = index;
            m_global_index[global_key(m_bindings[index].global_qpair_id)] = index;
        end
        foreach (m_af_extra_bindings[index]) begin
            m_af_extra_offset_index[$sformatf(
                "%0d", m_af_extra_bindings[index].extra_queue_offset)] = index;
            m_af_extra_global_index[global_key(
                m_af_extra_bindings[index].global_qpair_id)] = index;
        end
    endfunction

// 功能：清理临时结果、错误状态或执行历史（clear_binding）。
// 输入/输出：无输入或清理选项；无返回值，状态恢复初始值。
// 边界/副作用：只清理本对象拥有的状态，清理后可按约定复用。
    protected function void clear_binding(
        output dpu_vio_qpair_binding_t binding
    );
        binding.request_id = 0;
        binding.request_pair_index = 0;
        binding.service_key.function_key.host_id = 0;
        binding.service_key.function_key.pf_id = 0;
        binding.service_key.function_key.kind = DPU_FUNCTION_PF;
        binding.service_key.function_key.vf_id = 0;
        binding.service_key.service_kind = DPU_SERVICE_VIO_NET;
        binding.service_key.service_instance_id = 0;
        binding.virtio_pair_index = 0;
        binding.local_pair_id = 0;
        binding.rx_local_virtqueue_id = 0;
        binding.tx_local_virtqueue_id = 0;
        binding.global_qpair_id = 0;
        binding.local_msix_vector_id = 0;
        binding.global_msix_vector_id = 0;
    endfunction

// 功能：按稳定键整理集合并重建派生索引（sort_and_merge_ranges）。
// 输入/输出：输入为内部或引用传入的数组；无返回值，排序结果写回数组/索引。
// 边界/副作用：只改变表示顺序，不改变元素语义，保证快照和计划确定性。
    protected function void sort_and_merge_ranges(
        ref dpu_global_id_range_t ranges[$]
    );
        dpu_global_id_range_t swap;
        dpu_global_id_range_t result[$];
        for (int left = 0; left < ranges.size(); left++) begin
            for (int right = left + 1; right < ranges.size(); right++) begin
                if ((ranges[right].first_id < ranges[left].first_id) ||
                    ((ranges[right].first_id == ranges[left].first_id) &&
                     (ranges[right].last_id < ranges[left].last_id))) begin
                    swap = ranges[left];
                    ranges[left] = ranges[right];
                    ranges[right] = swap;
                end
            end
        end
        foreach (ranges[index]) begin
            if ((result.size() == 0) ||
                (ranges[index].first_id > result[result.size() - 1].last_id + 1)) begin
                result.push_back(ranges[index]);
            end else if (ranges[index].last_id > result[result.size() - 1].last_id) begin
                result[result.size() - 1].last_id = ranges[index].last_id;
            end
        end
        ranges = result;
    endfunction

// 功能：按稳定键整理集合并重建派生索引（canonicalize_reservations）。
// 输入/输出：输入为内部或引用传入的数组；无返回值，排序结果写回数组/索引。
// 边界/副作用：只改变表示顺序，不改变元素语义，保证快照和计划确定性。
    protected function void canonicalize_reservations(
        ref int unsigned ids[$],
        ref dpu_global_id_range_t ranges[$]
    );
        dpu_global_id_range_t intervals[$];

        intervals = ranges;
        foreach (ids[index]) begin
            intervals.push_back('{first_id: ids[index], last_id: ids[index]});
        end
        sort_and_merge_ranges(intervals);
        ids.delete();
        ranges.delete();
        foreach (intervals[index]) begin
            if (intervals[index].first_id == intervals[index].last_id)
                ids.push_back(intervals[index].first_id);
            else
                ranges.push_back(intervals[index]);
        end
    endfunction

// 功能：复制计划或操作的全部字段和派生集合（copy_plan）。
// 输入/输出：输入为同型源对象；无返回值或返回副本，具体由签名决定。
// 边界/副作用：复制后不共享可变数组；源对象保持不变，空源由调用方先行拒绝。
    protected function bit copy_plan(
        input dpu_normalized_placement_plan source,
        output dpu_normalized_placement_plan copied,
        output int unsigned reservation_ids[$],
        output dpu_global_id_range_t reservation_ranges[$],
        output dpu_resource_pool_config_t profiles[$],
        output dpu_placement_diagnostic diagnostic
    );
        dpu_normalized_vio_request requests[$];
        string why;

        copied = null;
        reservation_ids.delete();
        reservation_ranges.delete();
        profiles.delete();
        if ((source == null) || !source.is_frozen()) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "normalized placement plan must be frozen");
            return 0;
        end
        source.list_requests(requests);
        source.list_reserved_global_qpair_ids(reservation_ids);
        source.list_reserved_global_qpair_ranges(reservation_ranges);
        source.list_resource_profiles(profiles);
        canonicalize_reservations(reservation_ids, reservation_ranges);
        copied = dpu_normalized_placement_plan::type_id::create(
            {get_name(), "_plan"});
        copied.effective_global_capacity = source.effective_global_capacity;
        copied.effective_device_capacity = source.effective_device_capacity;
        copied.set_profiles(profiles);
        copied.set_reservations(reservation_ids, reservation_ranges);
        foreach (requests[index]) begin
            if (!copied.add_request(requests[index], why)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            {"cannot copy normalized placement plan: ", why});
                copied = null;
                return 0;
            end
        end
        if (!copied.freeze(why)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        {"cannot freeze normalized placement plan copy: ", why});
            copied = null;
            return 0;
        end
        return 1;
    endfunction

// 功能：校验拓扑、绑定或保留区间之间的跨对象不变量（validate_vio_service_topology）。
// 输入/输出：输入为当前快照/计划及诊断输出；返回 bit 并写明首个冲突。
// 边界/副作用：发现重复 global/local ID、owner 不匹配或区间重叠时必须整体失败。
    protected function bit validate_vio_service_topology(
        input dpu_device_snapshot snapshot,
        input dpu_service_key_t service_key,
        input int unsigned request_id,
        input bit has_pair_index,
        input int unsigned request_pair_index,
        output dpu_placement_diagnostic diagnostic
    );
        dpu_service_key_t services[$];
        int unsigned service_count;
        bit found_service;

        if (service_key.service_instance_id != 0) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "VIO-net resource service instance must be zero");
            diagnostic.set_request_context(request_id);
            if (has_pair_index)
                diagnostic.set_pair_context(request_pair_index);
            diagnostic.set_service_context(service_key);
            diagnostic.set_function_context(service_key.function_key);
            return 0;
        end
        snapshot.list_services(DPU_SERVICE_VIO_NET, services);
        service_count = 0;
        found_service = 0;
        foreach (services[index]) begin
            if (dpu_same_function_key(services[index].function_key,
                                      service_key.function_key)) begin
                service_count++;
                if (dpu_service_key_name(services[index]) ==
                    dpu_service_key_name(service_key))
                    found_service = 1;
            end
        end
        if (!found_service) begin
            set_failure(diagnostic, DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH,
                        "participating VIO-net service is absent from device snapshot");
            diagnostic.set_request_context(request_id);
            if (has_pair_index)
                diagnostic.set_pair_context(request_pair_index);
            diagnostic.set_service_context(service_key);
            diagnostic.set_function_context(service_key.function_key);
            return 0;
        end
        if (service_count != 1) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "participating function must expose exactly one VIO-net service");
            diagnostic.set_request_context(request_id);
            if (has_pair_index)
                diagnostic.set_pair_context(request_pair_index);
            diagnostic.set_service_context(service_key);
            diagnostic.set_function_context(service_key.function_key);
            return 0;
        end
        return 1;
    endfunction

// 功能：校验拓扑、绑定或保留区间之间的跨对象不变量（validate_bindings）。
// 输入/输出：输入为当前快照/计划及诊断输出；返回 bit 并写明首个冲突。
// 边界/副作用：发现重复 global/local ID、owner 不匹配或区间重叠时必须整体失败。
    protected function bit validate_bindings(
        input dpu_device_snapshot device_snapshot,
        output dpu_placement_diagnostic diagnostic
    );
        dpu_normalized_vio_request request;
        dpu_normalized_vio_pair_t pairs[$];
        dpu_vio_participant_target_t targets[$];
        bit pair_keys[string];
        bit msix_occupied[DPU_MAX_GLOBAL_MSIX_VECTORS];
        dpu_function_key_t msix_owner[DPU_MAX_GLOBAL_MSIX_VECTORS];
        int unsigned msix_local[DPU_MAX_GLOBAL_MSIX_VECTORS];
        int unsigned function_local_global[string];
        dpu_dut_caps caps;
        dpu_function_key_t expected_af_key;
        dpu_bar_pair_lease_t expected_af_bar0;
        int unsigned af_regular_qpair_count;
        int unsigned af_lan_msix_count;
        int unsigned af_msix_base;
        bit af_msix_base_valid;
        string caps_why;

        msix_occupied = '{default: 0};
        caps = device_snapshot.snapshot_dut_caps();
        if ((caps == null) || !caps.validate(caps_why)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_PROFILE,
                        (caps == null) ?
                        "resource snapshot cannot read DUT capabilities" :
                        {"resource snapshot has invalid DUT capabilities: ",
                         caps_why});
            return 0;
        end
        if (!device_snapshot.get_expected_af(expected_af_key,
                                             expected_af_bar0, caps_why)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH,
                        {"resource snapshot cannot resolve AF: ", caps_why});
            return 0;
        end
        af_regular_qpair_count = 0;
        af_lan_msix_count = 0;
        af_msix_base = 0;
        af_msix_base_valid = 0;
        foreach (m_bindings[index]) begin
            if (dpu_same_function_key(
                    m_bindings[index].service_key.function_key,
                    expected_af_key)) begin
                int unsigned candidate_base;
                af_regular_qpair_count++;
                if ((m_bindings[index].local_msix_vector_id + 1) >
                    af_lan_msix_count)
                    af_lan_msix_count =
                        m_bindings[index].local_msix_vector_id + 1;
                if (m_bindings[index].global_msix_vector_id <
                    m_bindings[index].local_msix_vector_id) begin
                    set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                "AF VIO MSI-X binding has an invalid vector base");
                    return 0;
                end
                candidate_base = m_bindings[index].global_msix_vector_id -
                                 m_bindings[index].local_msix_vector_id;
                if (af_msix_base_valid && (candidate_base != af_msix_base)) begin
                    set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                "AF VIO MSI-X bindings disagree on the function vector base");
                    return 0;
                end
                af_msix_base = candidate_base;
                af_msix_base_valid = 1;
            end
        end

        if ((m_plan == null) || !m_plan.is_frozen()) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "resource snapshot has no frozen normalized placement plan");
            return 0;
        end
        if ((m_plan.effective_global_capacity == 0) ||
            (m_plan.effective_device_capacity == 0)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_PROFILE,
                        "normalized placement plan has no effective qpair capacity");
            return 0;
        end
        begin
            dpu_normalized_vio_request requests[$];
            m_plan.list_requests(requests);
            foreach (requests[request_index]) begin
                int unsigned hard_device_capacity;

                hard_device_capacity = (m_plan.effective_device_capacity <
                                        DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE) ?
                                       m_plan.effective_device_capacity :
                                       DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE;
                m_plan.list_targets(requests[request_index].request_id, targets);
                foreach (targets[target_index]) begin
                    if ((targets[target_index].qpair_count == 0) ||
                        (targets[target_index].qpair_count >
                         hard_device_capacity)) begin
                        set_failure(diagnostic,
                                    DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
                                    "participant qpair count exceeds fixed VIO-net device ceiling");
                        diagnostic.set_request_context(requests[request_index].request_id);
                        diagnostic.set_service_context(targets[target_index].service_key);
                        return 0;
                    end
                    if (!validate_vio_service_topology(
                            device_snapshot, targets[target_index].service_key,
                            requests[request_index].request_id, 0, 0,
                            diagnostic))
                        return 0;
                end
            end
        end
        foreach (m_bindings[index]) begin
            string key;

            if (!m_plan.get_request(m_bindings[index].request_id, request)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "binding has an unknown normalized request");
                diagnostic.set_request_context(m_bindings[index].request_id);
                diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                return 0;
            end
            m_plan.list_pairs(m_bindings[index].request_id, pairs);
            key = request_key(m_bindings[index].request_id,
                              m_bindings[index].request_pair_index);
            pair_keys[key] = 0;
            foreach (pairs[pair_index]) begin
                if (pairs[pair_index].request_pair_index ==
                    m_bindings[index].request_pair_index) begin
                    if (dpu_service_key_name(pairs[pair_index].service_key) !=
                        dpu_service_key_name(m_bindings[index].service_key)) begin
                        set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                    "binding service disagrees with normalized pair");
                        diagnostic.set_request_context(m_bindings[index].request_id);
                        diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                        return 0;
                    end
                    pair_keys[key] = 1;
                    break;
                end
            end
            if (!pair_keys[key]) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "binding has an unknown normalized pair");
                diagnostic.set_request_context(m_bindings[index].request_id);
                diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                return 0;
            end
            if ((m_bindings[index].service_key.service_kind != DPU_SERVICE_VIO_NET) ||
                !validate_vio_service_topology(
                    device_snapshot, m_bindings[index].service_key,
                    m_bindings[index].request_id, 1,
                    m_bindings[index].request_pair_index, diagnostic))
                return 0;
            if ((m_bindings[index].local_pair_id >=
                 DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE) ||
                (m_bindings[index].local_pair_id >=
                 m_plan.effective_device_capacity)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_LOCAL_QID_OUT_OF_RANGE,
                            "binding local qpair ID exceeds effective device capacity");
                diagnostic.set_request_context(m_bindings[index].request_id);
                diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                diagnostic.set_service_context(m_bindings[index].service_key);
                return 0;
            end
            if (m_bindings[index].virtio_pair_index >=
                m_plan.effective_device_capacity ||
                (m_bindings[index].rx_local_virtqueue_id !=
                 2 * m_bindings[index].virtio_pair_index) ||
                (m_bindings[index].tx_local_virtqueue_id !=
                 (2 * m_bindings[index].virtio_pair_index + 1)) ||
                (m_bindings[index].rx_local_virtqueue_id >= 64) ||
                (m_bindings[index].tx_local_virtqueue_id >= 64)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "binding virtqueue IDs are not derived from software pair index");
                diagnostic.set_request_context(m_bindings[index].request_id);
                diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                diagnostic.set_service_context(m_bindings[index].service_key);
                return 0;
            end
            if ((m_bindings[index].global_qpair_id >=
                 DPU_MAX_VIO_GLOBAL_QPAIRS) ||
                (m_bindings[index].global_qpair_id >=
                 m_plan.effective_global_capacity)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_GLOBAL_QID_OUT_OF_RANGE,
                            "binding global qpair ID exceeds effective global capacity");
                diagnostic.set_request_context(m_bindings[index].request_id);
                diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                diagnostic.set_service_context(m_bindings[index].service_key);
                return 0;
            end
            if ((m_bindings[index].local_msix_vector_id >= 128) ||
                (m_bindings[index].global_msix_vector_id >=
                 caps.global_msix_vector_count)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "binding MSI-X vector is outside the driver table domain");
                diagnostic.set_request_context(m_bindings[index].request_id);
                diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                diagnostic.set_service_context(m_bindings[index].service_key);
                return 0;
            end
            if (msix_occupied[m_bindings[index].global_msix_vector_id] &&
                (!dpu_same_function_key(
                    msix_owner[m_bindings[index].global_msix_vector_id],
                    m_bindings[index].service_key.function_key) ||
                 (msix_local[m_bindings[index].global_msix_vector_id] !=
                  m_bindings[index].local_msix_vector_id))) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "binding global MSI-X vector conflicts with another function or local vector");
                diagnostic.set_request_context(m_bindings[index].request_id);
                diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                diagnostic.set_service_context(m_bindings[index].service_key);
                return 0;
            end
            if (!msix_occupied[m_bindings[index].global_msix_vector_id]) begin
                msix_occupied[m_bindings[index].global_msix_vector_id] = 1;
                msix_owner[m_bindings[index].global_msix_vector_id] =
                    m_bindings[index].service_key.function_key;
                msix_local[m_bindings[index].global_msix_vector_id] =
                    m_bindings[index].local_msix_vector_id;
            end
            begin
                string function_local_key;
                function_local_key = {dpu_function_key_name(
                    m_bindings[index].service_key.function_key), ":",
                    $sformatf("%0d", m_bindings[index].local_msix_vector_id)};
                if (function_local_global.exists(function_local_key) &&
                    (function_local_global[function_local_key] !=
                     m_bindings[index].global_msix_vector_id)) begin
                    set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                "local MSI-X vector maps to multiple global vectors");
                    diagnostic.set_request_context(m_bindings[index].request_id);
                    diagnostic.set_pair_context(m_bindings[index].request_pair_index);
                    diagnostic.set_service_context(m_bindings[index].service_key);
                    return 0;
                end
                function_local_global[function_local_key] =
                    m_bindings[index].global_msix_vector_id;
            end
        end
        if (m_af_extra_bindings.size() != caps.af_extra_queue_count) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "AF extra queue binding count disagrees with DUT capability");
            diagnostic.set_function_context(expected_af_key);
            return 0;
        end
        if ((af_regular_qpair_count + m_af_extra_bindings.size()) >
            caps.max_vio_net_qpairs_per_device) begin
            set_failure(diagnostic, DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
                        "AF ordinary and extra qpairs exceed the per-device ceiling");
            diagnostic.set_function_context(expected_af_key);
            return 0;
        end
        foreach (m_af_extra_bindings[index]) begin
            dpu_af_extra_queue_kind_e expected_kind;
            int unsigned expected_port;
            int unsigned expected_queue;
            int unsigned candidate_base;
            string function_local_key;

            if (!dpu_same_function_key(
                    m_af_extra_bindings[index].af_function_key,
                    expected_af_key)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH,
                            "AF extra queue binding owner is not the selected AF");
                diagnostic.set_function_context(
                    m_af_extra_bindings[index].af_function_key);
                return 0;
            end
            if ((m_af_extra_bindings[index].extra_queue_offset != index) ||
                !dpu_decode_af_extra_queue_offset(
                    m_af_extra_bindings[index].extra_queue_offset,
                    expected_kind, expected_port, expected_queue) ||
                (m_af_extra_bindings[index].kind != expected_kind) ||
                (m_af_extra_bindings[index].eth_port_id != expected_port) ||
                (m_af_extra_bindings[index].eth_queue_id != expected_queue)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "AF extra queue binding disagrees with the driver layout");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            if (m_af_extra_bindings[index].local_queue_index !=
                (af_regular_qpair_count + index)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_LOCAL_QID_OUT_OF_RANGE,
                            "AF extra queue local index is not appended after LAN qpairs");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            if ((m_af_extra_bindings[index].global_qpair_id >=
                 m_plan.effective_global_capacity) ||
                (m_af_extra_bindings[index].global_qpair_id >=
                 DPU_MAX_VIO_GLOBAL_QPAIRS)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_GLOBAL_QID_OUT_OF_RANGE,
                            "AF extra queue global qpair ID exceeds effective capacity");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            if (m_af_extra_bindings[index].local_msix_vector_id !=
                (af_lan_msix_count + index)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "AF extra queue MSI-X vector is not appended after LAN vectors");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            if ((m_af_extra_bindings[index].local_msix_vector_id >= 128) ||
                (m_af_extra_bindings[index].global_msix_vector_id >=
                 caps.global_msix_vector_count) ||
                (m_af_extra_bindings[index].global_msix_vector_id <
                 m_af_extra_bindings[index].local_msix_vector_id)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "AF extra queue MSI-X vector is outside the driver table domain");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            candidate_base =
                m_af_extra_bindings[index].global_msix_vector_id -
                m_af_extra_bindings[index].local_msix_vector_id;
            if (af_msix_base_valid && (candidate_base != af_msix_base)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "AF extra queue MSI-X binding disagrees with the function vector base");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            af_msix_base = candidate_base;
            af_msix_base_valid = 1;
            if (msix_occupied[
                    m_af_extra_bindings[index].global_msix_vector_id]) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "AF extra queue global MSI-X vector conflicts with another binding");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            msix_occupied[m_af_extra_bindings[index].global_msix_vector_id] = 1;
            msix_owner[m_af_extra_bindings[index].global_msix_vector_id] =
                expected_af_key;
            msix_local[m_af_extra_bindings[index].global_msix_vector_id] =
                m_af_extra_bindings[index].local_msix_vector_id;
            function_local_key = {dpu_function_key_name(expected_af_key), ":",
                $sformatf("%0d",
                    m_af_extra_bindings[index].local_msix_vector_id)};
            if (function_local_global.exists(function_local_key) &&
                (function_local_global[function_local_key] !=
                 m_af_extra_bindings[index].global_msix_vector_id)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "AF extra local MSI-X vector maps to multiple global vectors");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            function_local_global[function_local_key] =
                m_af_extra_bindings[index].global_msix_vector_id;
        end
        begin
            dpu_normalized_vio_request requests[$];
            m_plan.list_requests(requests);
            foreach (requests[request_index]) begin
                int unsigned request_count;
                m_plan.list_pairs(requests[request_index].request_id, pairs);
                if (pairs.size() != requests[request_index].total_qpairs) begin
                    set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                "normalized request pair count disagrees with total");
                    diagnostic.set_request_context(requests[request_index].request_id);
                    return 0;
                end
                request_count = 0;
                foreach (pairs[pair_index]) begin
                    string key;
                    key = request_key(requests[request_index].request_id,
                                      pairs[pair_index].request_pair_index);
                    if (!m_request_index.exists(key)) begin
                        set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                    "normalized pair has no resource binding");
                        diagnostic.set_request_context(requests[request_index].request_id);
                        diagnostic.set_pair_context(pairs[pair_index].request_pair_index);
                        return 0;
                    end
                    request_count++;
                end
                if (request_count != requests[request_index].total_qpairs) begin
                    set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                "resource binding count disagrees with normalized total");
                    return 0;
                end
                m_plan.list_targets(requests[request_index].request_id, targets);
                foreach (targets[target_index]) begin
                    int unsigned participant_count;
                    participant_count = 0;
                    foreach (m_bindings[binding_index]) begin
                        if ((m_bindings[binding_index].request_id ==
                             requests[request_index].request_id) &&
                            (dpu_service_key_name(m_bindings[binding_index].service_key) ==
                             dpu_service_key_name(targets[target_index].service_key)))
                            participant_count++;
                    end
                    if (participant_count != targets[target_index].qpair_count) begin
                        set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                                    "participant binding count disagrees with target");
                        diagnostic.set_service_context(targets[target_index].service_key);
                        return 0;
                    end
                end
            end
        end
        return 1;
    endfunction

// 功能：设置对象的配置字段、依赖对象或错误上下文（set_normalized_plan）。
// 输入/输出：输入为新值或外部对象；通常无返回值，字段写入当前对象。
// 边界/副作用：必须尊重冻结边界；外部对象按约定借用或复制。
    function bit set_normalized_plan(
        input dpu_normalized_placement_plan plan,
        output dpu_placement_diagnostic diagnostic
    );
        dpu_normalized_placement_plan copied;
        int unsigned reservation_ids[$];
        dpu_global_id_range_t reservation_ranges[$];
        dpu_resource_pool_config_t profiles[$];

        if (!mutable(diagnostic))
            return 0;
        if (m_plan != null) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "resource snapshot normalized plan is already set");
            return 0;
        end
        if (!copy_plan(plan, copied, reservation_ids, reservation_ranges,
                       profiles, diagnostic))
            return 0;
        m_plan = copied;
        m_reserved_ids = reservation_ids;
        m_reserved_ranges = reservation_ranges;
        m_profiles = profiles;
        return 1;
    endfunction

// 功能：向对象加入配置项、绑定或寄存器操作（add_vio_binding）。
// 输入/输出：输入为待加入值；成功返回 1/无返回值，失败返回 why 或记录诊断。
// 边界/副作用：加入前检查重复键、所有权和冻结状态，失败不得留下半写入元素。
    function bit add_vio_binding(
        input dpu_vio_qpair_binding_t binding,
        output dpu_placement_diagnostic diagnostic
    );
        string key;

        if (!mutable(diagnostic))
            return 0;
        if (m_plan == null) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "resource snapshot requires a normalized plan before bindings");
            return 0;
        end
        key = request_key(binding.request_id, binding.request_pair_index);
        if (m_request_index.exists(key)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_DUPLICATE_REQUEST,
                        "resource snapshot has a duplicate request/pair binding");
            return 0;
        end
        key = service_local_key(binding.service_key, binding.local_pair_id);
        if (m_service_local_index.exists(key)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_LOCAL_QID_CONFLICT,
                        "resource snapshot has a duplicate service/local binding");
            return 0;
        end
        key = service_virtio_pair_key(binding.service_key,
                                      binding.virtio_pair_index);
        if (m_service_virtio_pair_index.exists(key)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "resource snapshot has a duplicate service/virtio pair binding");
            return 0;
        end
        key = global_key(binding.global_qpair_id);
        if (m_global_index.exists(key) || m_af_extra_global_index.exists(key)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_GLOBAL_QID_CONFLICT,
                        "resource snapshot has a duplicate global binding");
            return 0;
        end
        m_bindings.push_back(binding);
        rebuild_indexes();
        return 1;
    endfunction

// 功能：向对象加入配置项、绑定或寄存器操作（add_af_extra_queue_binding）。
// 输入/输出：输入为待加入值；成功返回 1/无返回值，失败返回 why 或记录诊断。
// 边界/副作用：加入前检查重复键、所有权和冻结状态，失败不得留下半写入元素。
    function bit add_af_extra_queue_binding(
        input dpu_af_extra_queue_binding_t binding,
        output dpu_placement_diagnostic diagnostic
    );
        string key;

        if (!mutable(diagnostic))
            return 0;
        if (m_plan == null) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "resource snapshot requires a normalized plan before AF extra bindings");
            return 0;
        end
        key = $sformatf("%0d", binding.extra_queue_offset);
        if (m_af_extra_offset_index.exists(key)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_LOCAL_QID_CONFLICT,
                        "resource snapshot has a duplicate AF extra queue offset");
            return 0;
        end
        key = global_key(binding.global_qpair_id);
        if (m_global_index.exists(key) ||
            m_af_extra_global_index.exists(key)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_GLOBAL_QID_CONFLICT,
                        "resource snapshot has a duplicate global qpair binding");
            return 0;
        end
        m_af_extra_bindings.push_back(binding);
        rebuild_indexes();
        return 1;
    endfunction

// 功能：完成索引重建、排序和一致性校验，并把可变对象转换为只读快照（freeze）。
// 输入/输出：输入为当前未冻结对象；返回 bit，失败通过 why/diagnostic 说明。
// 边界/副作用：冻结成功后所有写入接口必须拒绝修改。
    function bit freeze(
        input dpu_device_snapshot device_snapshot,
        output dpu_placement_diagnostic diagnostic
    );
        if (!mutable(diagnostic))
            return 0;
        if ((device_snapshot == null) || !device_snapshot.is_frozen()) begin
            set_failure(diagnostic, DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH,
                        "resource snapshot requires a frozen device snapshot");
            return 0;
        end
        sort_bindings();
        sort_af_extra_bindings();
        rebuild_indexes();
        if (!validate_bindings(device_snapshot, diagnostic))
            return 0;
        m_device_snapshot = device_snapshot;
        m_frozen = 1;
        ensure_diagnostic(diagnostic);
        diagnostic.clear();
        return 1;
    endfunction

// 功能：查询对象是否已经完成冻结生命周期阶段（is_frozen）。
// 输入/输出：无输入；返回 bit，不修改对象。
// 边界/副作用：只反映内部生命周期标志，不代替 validate/freeze。
    function bit is_frozen();
        return m_frozen;
    endfunction

// 功能：按键查询内部索引或导出值复制（list_vio_bindings）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_vio_bindings(ref dpu_vio_qpair_binding_t bindings[$]);
        bindings.delete();
        if (m_frozen)
            bindings = m_bindings;
    endfunction

// 功能：按键查询内部索引或导出值复制（list_af_extra_queue_bindings）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_af_extra_queue_bindings(
        ref dpu_af_extra_queue_binding_t bindings[$]
    );
        bindings.delete();
        if (m_frozen)
            bindings = m_af_extra_bindings;
    endfunction

// 功能：按键查询内部索引或导出值复制（get_vio_binding）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit get_vio_binding(
        input int unsigned request_id,
        input int unsigned request_pair_index,
        output dpu_vio_qpair_binding_t binding
    );
        string key;
        clear_binding(binding);
        if (!m_frozen)
            return 0;
        key = request_key(request_id, request_pair_index);
        if (!m_request_index.exists(key))
            return 0;
        binding = m_bindings[m_request_index[key]];
        return 1;
    endfunction

// 功能：按键查询内部索引或导出值复制（get_vio_binding_by_service_local）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit get_vio_binding_by_service_local(
        input dpu_service_key_t service_key,
        input int unsigned local_pair_id,
        output dpu_vio_qpair_binding_t binding
    );
        string key;
        clear_binding(binding);
        if (!m_frozen)
            return 0;
        key = service_local_key(service_key, local_pair_id);
        if (!m_service_local_index.exists(key))
            return 0;
        binding = m_bindings[m_service_local_index[key]];
        return 1;
    endfunction

// 功能：按键查询内部索引或导出值复制（get_vio_binding_by_service_virtio_pair）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit get_vio_binding_by_service_virtio_pair(
        input dpu_service_key_t service_key,
        input int unsigned virtio_pair_index,
        output dpu_vio_qpair_binding_t binding
    );
        string key;
        clear_binding(binding);
        if (!m_frozen)
            return 0;
        key = service_virtio_pair_key(service_key, virtio_pair_index);
        if (!m_service_virtio_pair_index.exists(key))
            return 0;
        binding = m_bindings[m_service_virtio_pair_index[key]];
        return 1;
    endfunction

// 功能：按键查询内部索引或导出值复制（get_vio_binding_by_global）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit get_vio_binding_by_global(
        input int unsigned global_qpair_id,
        output dpu_vio_qpair_binding_t binding
    );
        string key;
        clear_binding(binding);
        if (!m_frozen)
            return 0;
        key = global_key(global_qpair_id);
        if (!m_global_index.exists(key))
            return 0;
        binding = m_bindings[m_global_index[key]];
        return 1;
    endfunction

// 功能：按键查询内部索引或导出值复制（list_vio_bindings_for_service）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_vio_bindings_for_service(
        input dpu_service_key_t service_key,
        ref dpu_vio_qpair_binding_t bindings[$]
    );
        bindings.delete();
        if (!m_frozen)
            return;
        foreach (m_bindings[index]) begin
            if (dpu_service_key_name(m_bindings[index].service_key) ==
                dpu_service_key_name(service_key))
                bindings.push_back(m_bindings[index]);
        end
    endfunction

// 功能：按键查询内部索引或导出值复制（list_vio_participants）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_vio_participants(
        ref dpu_vio_participant_target_t participants[$]
    );
        dpu_normalized_vio_request requests[$];
        dpu_vio_participant_target_t targets[$];
        participants.delete();
        if (!m_frozen || (m_plan == null))
            return;
        m_plan.list_requests(requests);
        foreach (requests[index]) begin
            m_plan.list_targets(requests[index].request_id, targets);
            foreach (targets[target_index])
                participants.push_back(targets[target_index]);
        end
    endfunction

// 功能：按键查询内部索引或导出值复制（get_normalized_request）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit get_normalized_request(
        input int unsigned request_id,
        output dpu_normalized_vio_request request
    );
        request = null;
        if (!m_frozen || (m_plan == null))
            return 0;
        return m_plan.get_request(request_id, request);
    endfunction

// 功能：按键查询内部索引或导出值复制（list_reserved_global_qpair_ids）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_reserved_global_qpair_ids(ref int unsigned ids[$]);
        ids.delete();
        if (m_frozen)
            ids = m_reserved_ids;
    endfunction

// 功能：按键查询内部索引或导出值复制（list_reserved_global_qpair_ranges）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_reserved_global_qpair_ranges(
        ref dpu_global_id_range_t ranges[$]
    );
        ranges.delete();
        if (m_frozen)
            ranges = m_reserved_ranges;
    endfunction

// 功能：按键查询内部索引或导出值复制（list_resource_profiles）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_resource_profiles(
        ref dpu_resource_pool_config_t profiles[$]
    );
        profiles.delete();
        if (m_frozen)
            profiles = m_profiles;
    endfunction

// 功能：判断对象是否满足指定状态、资格或引用关系（references_device_snapshot）。
// 输入/输出：输入为待判断的键/状态；返回 bit，不修改对象。
// 边界/副作用：边界值显式判断，不触发分配、排序或其他隐藏副作用。
    function bit references_device_snapshot(input dpu_device_snapshot snapshot);
        return m_frozen && (snapshot != null) && (snapshot == m_device_snapshot);
    endfunction
endclass : dpu_resource_snapshot

`endif // DPU_RESOURCE_SNAPSHOT_SV
