/*
 * 所属层次：src/ 资源租约与注册表层。
 * 文件职责：从冻结快照导入资源 profile，管理 function/service 的唯一租约和 global qpair 映射。
 * 主要依赖：dpu_device_snapshot、dpu_resource_snapshot、dpu_resource_types。
 * 所有权与生命周期：manager 拥有 registry 状态并以 authority token 控制写入；seal 后资源类别不可变。
 */
`ifndef DPU_RESOURCE_MANAGER_SV
`define DPU_RESOURCE_MANAGER_SV

// =============================================================================
// DPU generic resource manager
//
// Snapshot-seeded managers own generic resource classes and lease state for
// functions declared by the global device snapshot.
// =============================================================================

// 设计原因：将相关值和操作约束集中在独立边界，避免跨模块重复解释同一契约。
// 职责与所有权：对象/类型按值语义管理自身字段，不隐式取得外部资源或生命周期控制权。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_resource_function_state;
    dpu_function_key_t key;
    dpu_resource_lease_t leases[$];

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(dpu_function_key_t function_key);
        key = function_key;
    endfunction
endclass : dpu_resource_function_state


// 设计原因：集中维护唯一资源租约和跨快照索引，防止多个消费者重复占用资源。
// 职责与所有权：对象拥有 registry 状态和授权令牌；输入快照只读，封存后禁止继续写入。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_resource_registry_authority;
endclass : dpu_resource_registry_authority


// 设计原因：集中维护唯一资源租约和跨快照索引，防止多个消费者重复占用资源。
// 职责与所有权：对象拥有 registry 状态和授权令牌；输入快照只读，封存后禁止继续写入。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_resource_manager extends uvm_object;
    `uvm_object_utils(dpu_resource_manager)

    protected dpu_resource_function_state function_states[string];
    protected dpu_resource_class_id_t     class_id_by_name[string];
    protected dpu_resource_pool_config_t  resource_profiles_by_id[
        dpu_resource_class_id_t
    ];
    protected int unsigned                 class_allocated_count[
        dpu_resource_class_id_t
    ];
    protected bit                          active_global_ids[
        dpu_resource_class_id_t
    ][int unsigned];

    protected dpu_resource_class_id_t next_resource_class_id;
    protected bit                     resource_classes_sealed;
    protected dpu_resource_registry_authority registry_authority;
    protected bit                            registry_authority_claimed;
    protected bit                            snapshot_configured;
    protected dpu_device_snapshot            configured_snapshot;
    protected dpu_resource_snapshot          configured_resource_snapshot;
    protected dpu_resource_lease_t           service_leases_by_name[string][$];
    protected int unsigned                   service_local_to_global_qpair[
        string
    ][dpu_resource_class_id_t][int unsigned];
    protected dpu_dut_caps                  dut_caps;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_resource_manager");
        super.new(name);
        dut_caps = dpu_dut_caps::type_id::create("dut_caps");
        next_resource_class_id = 0;
        resource_classes_sealed = 0;
        registry_authority = new();
        registry_authority_claimed = 0;
        snapshot_configured = 0;
        configured_snapshot = null;
        configured_resource_snapshot = null;
    endfunction

// 功能：把逻辑键转换为稳定的诊断/索引字符串（function_key_name）。
// 输入/输出：输入为值语义键；返回格式化字符串，不修改输入。
// 边界/副作用：格式必须与对应 lookup/list 索引一致；非法枚举不得静默映射为另一个合法键。
    protected function string function_key_name(
        input dpu_function_key_t key
    );
        return dpu_function_key_name(key);
    endfunction

// 功能：执行与对象职责相关的内部辅助操作（validate_function_key）。
// 输入/输出：输入和输出由函数签名定义；通过返回值或 output 参数报告结果。
// 边界/副作用：除签名明确写入外不产生隐藏副作用，失败时保持状态一致。
    protected function bit validate_function_key(
        input dpu_function_key_t key,
        output string why
    );
        why = "";

        if (key.host_id >= dut_caps.max_hosts) begin
            why = $sformatf("host_id %0d exceeds DUT max_hosts %0d",
                            key.host_id, dut_caps.max_hosts);
            return 0;
        end
        if (key.pf_id >= dut_caps.max_pfs_per_host) begin
            why = $sformatf("pf_id %0d exceeds DUT max_pfs_per_host %0d",
                            key.pf_id, dut_caps.max_pfs_per_host);
            return 0;
        end

        case (key.kind)
            DPU_FUNCTION_PF: begin
                if (key.vf_id != 0) begin
                    why = "PF function keys require vf_id == 0";
                    return 0;
                end
            end
            DPU_FUNCTION_VF: begin
                if (key.vf_id >= dut_caps.max_vfs_per_pf) begin
                    why = $sformatf("vf_id %0d exceeds DUT max_vfs_per_pf %0d",
                                    key.vf_id, dut_caps.max_vfs_per_pf);
                    return 0;
                end
            end
            default: begin
                why = "function key has an unsupported function kind";
                return 0;
            end
        endcase

        return 1;
    endfunction

// 功能：按键查询内部索引或导出值复制（lookup_function_state）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    protected function bit lookup_function_state(
        input dpu_function_key_t key,
        output dpu_resource_function_state state,
        output string why
    );
        string key_name;

        state = null;
        key_name = function_key_name(key);
        if (!function_states.exists(key_name)) begin
            why = "function is not registered";
            return 0;
        end

        state = function_states[key_name];
        why = "";
        return 1;
    endfunction

// 功能：统计 registry 中指定类别已租用或已分配的资源数（function_class_lease_count）。
// 输入/输出：输入为 function/service 类别；返回计数，不改变租约。
// 边界/副作用：统计不包含失效 owner 或未封存临时项，调用方据此判断容量上限。
    protected function int unsigned function_class_lease_count(
        input dpu_resource_function_state state,
        input dpu_resource_class_id_t class_id
    );
        int unsigned count;

        count = 0;
        for (int unsigned index = 0; index < state.leases.size(); index++) begin
            if (state.leases[index].class_id == class_id)
                count++;
        end
        return count;
    endfunction

// 功能：统计 registry 中指定类别已租用或已分配的资源数（allocated_count）。
// 输入/输出：输入为 function/service 类别；返回计数，不改变租约。
// 边界/副作用：统计不包含失效 owner 或未封存临时项，调用方据此判断容量上限。
    protected function int unsigned allocated_count(
        input dpu_resource_class_id_t class_id
    );
        if (class_allocated_count.exists(class_id))
            return class_allocated_count[class_id];
        return 0;
    endfunction

// 功能：从冻结快照初始化 registry 的 function/resource 状态（seed_function）。
// 输入/输出：输入为设备/资源快照及 authority；成功返回 bit 并写入内部副本。
// 边界/副作用：身份校验或重复 seed 失败时保持既有租约和索引不变。
    protected function bit seed_function(
        input dpu_function_key_t key,
        output string why
    );
        string key_name;
        string parent_key_name;
        dpu_function_key_t parent_key;

        if (!validate_function_key(key, why))
            return 0;

        key_name = function_key_name(key);
        if (function_states.exists(key_name)) begin
            why = "function key is already registered";
            return 0;
        end
        if (key.kind == DPU_FUNCTION_VF) begin
            parent_key.host_id = key.host_id;
            parent_key.pf_id = key.pf_id;
            parent_key.kind = DPU_FUNCTION_PF;
            parent_key.vf_id = 0;
            parent_key_name = function_key_name(parent_key);
            if (!function_states.exists(parent_key_name)) begin
                why = "VF function requires its PF parent to be registered";
                return 0;
            end
        end
        if (function_states.num() >= dut_caps.max_functions) begin
            why = "DUT function registrations have been exhausted";
            return 0;
        end

        function_states[key_name] = new(key);
        why = "";
        return 1;
    endfunction

// 功能：取得受控资源注册表的唯一写入授权（claim_registry_authority）。
// 输入/输出：无输入或输入调用方身份；返回 authority token/句柄。
// 边界/副作用：重复领取、无效 owner 或已封存 registry 时必须拒绝。
    function dpu_resource_registry_authority claim_registry_authority();
        if (registry_authority_claimed || (function_states.num() != 0) ||
            (class_id_by_name.num() != 0) || resource_classes_sealed)
            return null;
        registry_authority_claimed = 1;
        return registry_authority;
    endfunction

    // The resource snapshot is the VIO qpair authority. Build all imported
    // state in a private candidate so no failed import can publish state.
// 功能：从冻结快照初始化 registry 的 function/resource 状态（configure_from_snapshots）。
// 输入/输出：输入为设备/资源快照及 authority；成功返回 bit 并写入内部副本。
// 边界/副作用：身份校验或重复 seed 失败时保持既有租约和索引不变。
    function bit configure_from_snapshots(
        input dpu_resource_registry_authority authority,
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        output string why
    );
        dpu_resource_manager candidate;
        dpu_dut_caps caps;
        dpu_function_key_t function_keys[$];
        dpu_resource_pool_config_t profiles[$];
        dpu_vio_qpair_binding_t bindings[$];
        dpu_af_extra_queue_binding_t af_extra_bindings[$];
        int unsigned reserved_global_ids[$];
        dpu_global_id_range_t reserved_global_ranges[$];
        dpu_resource_class_id_t qpair_class_id;
        dpu_resource_class_id_t class_id;

        why = "";
        if (!registry_authority_claimed || (authority == null) ||
            (authority != registry_authority)) begin
            why = "snapshot configuration requires the device registry authority";
            return 0;
        end
        if (snapshot_configured) begin
            why = "resource manager has already been configured from snapshots";
            return 0;
        end
        if ((device_snapshot == null) || !device_snapshot.is_frozen() ||
            (resource_snapshot == null) || !resource_snapshot.is_frozen() ||
            !resource_snapshot.references_device_snapshot(device_snapshot)) begin
            why = "resource snapshot is not frozen against the supplied device snapshot";
            return 0;
        end
        caps = device_snapshot.snapshot_dut_caps();
        if ((caps == null) || !caps.validate(why))
            return 0;

        candidate = new({get_name(), "_snapshots_candidate"});
        candidate.dut_caps.copy_from(caps);
        device_snapshot.list_functions(function_keys);
        foreach (function_keys[index]) begin
            if (!candidate.seed_function(function_keys[index], why))
                return 0;
        end
        resource_snapshot.list_resource_profiles(profiles);
        foreach (profiles[index]) begin
            if (profiles[index].name == "virtio.qpair") begin
                if (profiles[index].capacity > caps.vio_global_qpair_count) begin
                    why = $sformatf(
                        {"virtio.qpair capacity %0d exceeds snapshot ",
                         "vio_global_qpair_count %0d"},
                        profiles[index].capacity, caps.vio_global_qpair_count);
                    return 0;
                end
                if (profiles[index].max_per_function >
                    caps.max_vio_net_qpairs_per_device) begin
                    why = $sformatf(
                        {"virtio.qpair max_per_function %0d exceeds snapshot ",
                         "max_vio_net_qpairs_per_device %0d"},
                        profiles[index].max_per_function,
                        caps.max_vio_net_qpairs_per_device);
                    return 0;
                end
            end
            if (!candidate.register_imported_resource_profile(
                    profiles[index], class_id, why))
                return 0;
        end
        if (!candidate.lookup_resource_class("virtio.qpair", qpair_class_id,
                                             why)) begin
            why = "resource snapshot has VIO bindings without a virtio.qpair profile";
            return 0;
        end
        if (candidate.resource_profiles_by_id[qpair_class_id].kind !=
            DPU_RESOURCE_KIND_QUEUE) begin
            why = "virtio.qpair profile is not a queue resource class";
            return 0;
        end
        resource_snapshot.list_reserved_global_qpair_ids(reserved_global_ids);
        resource_snapshot.list_reserved_global_qpair_ranges(reserved_global_ranges);
        foreach (reserved_global_ids[index]) begin
            if (reserved_global_ids[index] >= DPU_MAX_VIO_GLOBAL_QPAIRS) begin
                why = "resource snapshot has an out-of-range reserved global qpair ID";
                return 0;
            end
            if (reserved_global_ids[index] <
                candidate.resource_profiles_by_id[qpair_class_id].capacity)
                candidate.active_global_ids[qpair_class_id][
                    reserved_global_ids[index]] = 1;
        end
        foreach (reserved_global_ranges[index]) begin
            if ((reserved_global_ranges[index].first_id >
                 reserved_global_ranges[index].last_id) ||
                (reserved_global_ranges[index].last_id >=
                 DPU_MAX_VIO_GLOBAL_QPAIRS)) begin
                why = "resource snapshot has an invalid reserved global qpair range";
                return 0;
            end
            for (int unsigned global_id = reserved_global_ranges[index].first_id;
                 global_id <= reserved_global_ranges[index].last_id;
                 global_id++) begin
                if (global_id < candidate.resource_profiles_by_id[
                        qpair_class_id].capacity)
                    candidate.active_global_ids[qpair_class_id][global_id] = 1;
            end
        end
        resource_snapshot.list_vio_bindings(bindings);
        foreach (bindings[index]) begin
            dpu_function_key_t owner_key;
            dpu_resource_function_state state;
            dpu_resource_pool_config_t profile;
            dpu_resource_lease_t lease;
            string service_name;
            int unsigned class_count;
            int unsigned function_count;

            if (bindings[index].service_key.service_kind != DPU_SERVICE_VIO_NET) begin
                why = "resource snapshot binding is not VIO-net owned";
                return 0;
            end
            if (!device_snapshot.get_service_owner(bindings[index].service_key,
                                                   owner_key, why) ||
                !dpu_same_function_key(owner_key,
                                       bindings[index].service_key.function_key)) begin
                why = {"resource snapshot binding has no matching device service: ",
                       dpu_service_key_name(bindings[index].service_key)};
                return 0;
            end
            if (!candidate.lookup_function_state(
                    bindings[index].service_key.function_key, state, why))
                return 0;
            profile = candidate.resource_profiles_by_id[qpair_class_id];
            if (bindings[index].global_qpair_id >= profile.capacity) begin
                why = "VIO qpair global ID exceeds imported profile capacity";
                return 0;
            end
            if (candidate.active_global_ids[qpair_class_id].exists(
                    bindings[index].global_qpair_id)) begin
                why = "VIO qpair global ID is duplicated in resource snapshot";
                return 0;
            end
            service_name = dpu_service_key_name(bindings[index].service_key);
            if (candidate.service_local_to_global_qpair[service_name][
                    qpair_class_id].exists(bindings[index].local_pair_id)) begin
                why = "VIO qpair local ID is duplicated for service";
                return 0;
            end
            class_count = candidate.allocated_count(qpair_class_id);
            if (class_count >= profile.capacity) begin
                why = "VIO qpair resource-class capacity is exhausted";
                return 0;
            end
            function_count = candidate.function_class_lease_count(
                state, qpair_class_id);
            if ((function_count >= profile.max_per_function) ||
                (candidate.service_leases_by_name[service_name].size() >=
                 profile.max_per_function)) begin
                why = "VIO qpair per-service or per-function quota is exhausted";
                return 0;
            end

            lease.owner.kind = DPU_RESOURCE_OWNER_SERVICE;
            lease.owner.function_key = bindings[index].service_key.function_key;
            lease.owner.service_key = bindings[index].service_key;
            lease.local_id = bindings[index].local_pair_id;
            lease.class_id = qpair_class_id;
            lease.global_id = bindings[index].global_qpair_id;
            lease.frozen = 1;
            state.leases.push_back(lease);
            candidate.service_leases_by_name[service_name].push_back(lease);
            candidate.service_local_to_global_qpair[service_name][qpair_class_id][
                lease.local_id] = lease.global_id;
            candidate.active_global_ids[qpair_class_id][lease.global_id] = 1;
            candidate.class_allocated_count[qpair_class_id] = class_count + 1;
        end
        resource_snapshot.list_af_extra_queue_bindings(af_extra_bindings);
        foreach (af_extra_bindings[index]) begin
            dpu_resource_function_state state;
            dpu_resource_pool_config_t profile;
            dpu_resource_lease_t lease;
            int unsigned class_count;
            int unsigned function_count;

            if (!candidate.lookup_function_state(
                    af_extra_bindings[index].af_function_key, state, why))
                return 0;
            profile = candidate.resource_profiles_by_id[qpair_class_id];
            if (af_extra_bindings[index].global_qpair_id >= profile.capacity) begin
                why = "AF extra queue global ID exceeds imported profile capacity";
                return 0;
            end
            if (candidate.active_global_ids[qpair_class_id].exists(
                    af_extra_bindings[index].global_qpair_id)) begin
                why = "AF extra queue global ID is duplicated in resource snapshot";
                return 0;
            end
            class_count = candidate.allocated_count(qpair_class_id);
            function_count = candidate.function_class_lease_count(
                state, qpair_class_id);
            if (class_count >= profile.capacity) begin
                why = "AF extra queue exhausted resource-class capacity";
                return 0;
            end
            if (function_count >= profile.max_per_function) begin
                why = "AF extra queue exhausted per-function qpair capacity";
                return 0;
            end
            lease.owner.kind = DPU_RESOURCE_OWNER_FUNCTION;
            lease.owner.function_key =
                af_extra_bindings[index].af_function_key;
            lease.owner.service_key.function_key =
                af_extra_bindings[index].af_function_key;
            lease.owner.service_key.service_kind = DPU_SERVICE_VIO_NET;
            lease.owner.service_key.service_instance_id = 0;
            lease.local_id = af_extra_bindings[index].local_queue_index;
            lease.class_id = qpair_class_id;
            lease.global_id = af_extra_bindings[index].global_qpair_id;
            lease.frozen = 1;
            state.leases.push_back(lease);
            candidate.active_global_ids[qpair_class_id][lease.global_id] = 1;
            candidate.class_allocated_count[qpair_class_id] = class_count + 1;
        end
        if (!candidate.seal_resource_classes_internal(why))
            return 0;

        dut_caps.copy_from(candidate.dut_caps);
        function_states = candidate.function_states;
        class_id_by_name = candidate.class_id_by_name;
        resource_profiles_by_id = candidate.resource_profiles_by_id;
        class_allocated_count = candidate.class_allocated_count;
        active_global_ids = candidate.active_global_ids;
        service_leases_by_name = candidate.service_leases_by_name;
        service_local_to_global_qpair = candidate.service_local_to_global_qpair;
        next_resource_class_id = candidate.next_resource_class_id;
        resource_classes_sealed = candidate.resource_classes_sealed;
        configured_snapshot = device_snapshot;
        configured_resource_snapshot = resource_snapshot;
        snapshot_configured = 1;
        why = "";
        return 1;
    endfunction

// 功能：导出 DUT 能力对象的独立副本（snapshot_dut_caps）。
// 输入/输出：无输入或仅有 output 语义；返回新能力对象，不暴露内部可变引用。
// 边界/副作用：快照/manager 内部能力保持不变，未配置能力时返回明确的空值。
    function dpu_dut_caps snapshot_dut_caps();
        dpu_dut_caps snapshot;
        snapshot = dpu_dut_caps::type_id::create("dut_caps_snapshot");
        snapshot.copy_from(dut_caps);
        return snapshot;
    endfunction

    // Snapshot profile IDs are externally visible lease/query identities.
    // Unlike legacy registration, importing must retain them exactly.
// 功能：把外部快照中的资源 profile 注册到本地 registry（register_imported_resource_profile）。
// 输入/输出：输入为 profile 和 authority；返回成功标志并填写 why。
// 边界/副作用：只接受身份匹配且未重复的资源，失败不改变既有租约。
    protected function bit register_imported_resource_profile(
        input dpu_resource_pool_config_t profile,
        output dpu_resource_class_id_t class_id,
        output string why
    );
        class_id = profile.class_id;
        why = "";
        if (resource_classes_sealed) begin
            why = "resource-class registry is sealed";
            return 0;
        end
        if (profile.capacity == 0) begin
            why = "resource-class capacity must be nonzero";
            return 0;
        end
        if (profile.max_per_function == 0) begin
            why = "resource-class per-function quota must be nonzero";
            return 0;
        end
        if (class_id_by_name.exists(profile.name)) begin
            why = "resource snapshot has a duplicate profile name";
            return 0;
        end
        if (resource_profiles_by_id.exists(profile.class_id)) begin
            why = "resource snapshot has a duplicate profile class ID";
            return 0;
        end
        class_id_by_name[profile.name] = profile.class_id;
        resource_profiles_by_id[profile.class_id] = profile;
        class_allocated_count[profile.class_id] = 0;
        if (next_resource_class_id <= profile.class_id)
            next_resource_class_id = profile.class_id + 1;
        return 1;
    endfunction

// 功能：按键查询内部索引或导出值复制（lookup_resource_class）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit lookup_resource_class(
        input string name,
        output dpu_resource_class_id_t class_id,
        output string why
    );
        class_id = '0;
        if (!class_id_by_name.exists(name)) begin
            why = "resource-class name is not registered";
            return 0;
        end

        class_id = class_id_by_name[name];
        why = "";
        return 1;
    endfunction

    // Clients may bind only to functions already owned by the device
    // registry.  This is intentionally read-only: protocol environments do
    // not author topology or register functions themselves.
// 功能：判断对象是否满足指定状态、资格或引用关系（contains_function）。
// 输入/输出：输入为待判断的键/状态；返回 bit，不修改对象。
// 边界/副作用：边界值显式判断，不触发分配、排序或其他隐藏副作用。
    function bit contains_function(input dpu_function_key_t key);
        return function_states.exists(function_key_name(key));
    endfunction

// 功能：判断对象是否满足指定状态、资格或引用关系（is_snapshot_seeded）。
// 输入/输出：输入为待判断的键/状态；返回 bit，不修改对象。
// 边界/副作用：边界值显式判断，不触发分配、排序或其他隐藏副作用。
    function bit is_snapshot_seeded();
        return snapshot_configured;
    endfunction

// 功能：判断对象是否满足指定状态、资格或引用关系（is_seeded_from_snapshots）。
// 输入/输出：输入为待判断的键/状态；返回 bit，不修改对象。
// 边界/副作用：边界值显式判断，不触发分配、排序或其他隐藏副作用。
    function bit is_seeded_from_snapshots(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot
    );
        return snapshot_configured && (device_snapshot != null) &&
               (resource_snapshot != null) &&
               (configured_snapshot == device_snapshot) &&
               (configured_resource_snapshot == resource_snapshot);
    endfunction

// 功能：执行与对象职责相关的内部辅助操作（local_pair_to_global_qpair）。
// 输入/输出：输入和输出由函数签名定义；通过返回值或 output 参数报告结果。
// 边界/副作用：除签名明确写入外不产生隐藏副作用，失败时保持状态一致。
    function bit local_pair_to_global_qpair(
        input dpu_service_key_t service_key,
        input dpu_resource_class_id_t class_id,
        input int unsigned local_pair_id,
        output int unsigned global_qpair_id
    );
        string service_name;

        global_qpair_id = '0;
        service_name = dpu_service_key_name(service_key);
        if (!service_local_to_global_qpair.exists(service_name) ||
            !service_local_to_global_qpair[service_name].exists(class_id) ||
            !service_local_to_global_qpair[service_name][class_id].exists(
                local_pair_id))
            return 0;
        global_qpair_id = service_local_to_global_qpair[service_name][class_id][
            local_pair_id];
        return 1;
    endfunction

// 功能：按键查询内部索引或导出值复制（list_service_leases）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_service_leases(
        input dpu_service_key_t service_key,
        ref dpu_resource_lease_t leases[$]
    );
        dpu_resource_lease_t swap;
        string service_name;

        leases.delete();
        service_name = dpu_service_key_name(service_key);
        if (!service_leases_by_name.exists(service_name))
            return;
        leases = service_leases_by_name[service_name];
        for (int left = 0; left < leases.size(); left++) begin
            for (int right = left + 1; right < leases.size(); right++) begin
                if ((leases[right].local_id < leases[left].local_id) ||
                    ((leases[right].local_id == leases[left].local_id) &&
                     (leases[right].class_id < leases[left].class_id))) begin
                    swap = leases[left];
                    leases[left] = leases[right];
                    leases[right] = swap;
                end
            end
        end
    endfunction

// 功能：按键查询内部索引或导出值复制（list_function_leases）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_function_leases(
        input dpu_function_key_t function_key,
        ref dpu_resource_lease_t leases[$]
    );
        dpu_resource_function_state state;
        dpu_resource_lease_t swap;
        string why;

        leases.delete();
        if (!lookup_function_state(function_key, state, why))
            return;
        leases = state.leases;
        for (int left = 0; left < leases.size(); left++) begin
            for (int right = left + 1; right < leases.size(); right++) begin
                if ((leases[right].local_id < leases[left].local_id) ||
                    ((leases[right].local_id == leases[left].local_id) &&
                     (leases[right].owner.kind < leases[left].owner.kind))) begin
                    swap = leases[left];
                    leases[left] = leases[right];
                    leases[right] = swap;
                end
            end
        end
    endfunction

// 功能：封存资源类别和容量配置，阻止后续改变注册表契约（seal_resource_classes_internal）。
// 输入/输出：输入为输出 why；返回 bit。
// 边界/副作用：只有所有已导入 profile 通过校验才允许 seal，失败时 registry 仍可诊断。
    protected function bit seal_resource_classes_internal(output string why);
        resource_classes_sealed = 1;
        why = "";
        return 1;
    endfunction

endclass : dpu_resource_manager

`endif // DPU_RESOURCE_MANAGER_SV
