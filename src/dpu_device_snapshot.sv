/*
 * 所属层次：src/ 设备解析结果快照层。
 * 文件职责：保存解析后的 Host、function、BAR、service 和 AF 期望值，并在 freeze 后提供只读查询。
 * 主要依赖：dpu_device_types、dpu_dut_caps、dpu_placement_types。
 * 所有权与生命周期：冻结前由 resolver 填充，冻结后内部索引和字段不可变；查询接口只返回值复制。
 */
`ifndef DPU_DEVICE_SNAPSHOT_SV
`define DPU_DEVICE_SNAPSHOT_SV

// 设计原因：把跨阶段解析结果和派生索引封装起来，避免消费者直接依赖可变配置。
// 职责与所有权：对象在 freeze 前填充并拥有内部副本，freeze 后只读，查询者只能获得值复制。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_device_snapshot extends uvm_object;
    `uvm_object_utils(dpu_device_snapshot)

    protected bit m_frozen;
    protected bit m_has_caps;
    protected bit m_has_expected_af;
    protected dpu_dut_caps m_dut_caps;
    protected dpu_function_key_t m_functions[string];
    protected dpu_pcie_function_id_t m_pcie_ids[string];
    // The real AF allocates a global function slot before programming the
    // pre-requester tables.  Freeze assigns the same deterministic first-fit
    // namespace to the canonical function order so later register builders
    // never invent an ID while lowering a plan.
    protected int unsigned m_global_function_ids[string];
    protected dpu_function_key_t m_reverse_functions[string];
    protected dpu_bar_pair_lease_t m_bars[string];
    protected dpu_pcie_domain_key_t m_bar_domains[string];
    protected dpu_function_key_t m_bar_functions[string];
    protected dpu_service_key_t m_services[string];
    protected dpu_function_key_t m_service_owners[string];
    protected dpu_host_info_t m_hosts[string];
    protected dpu_function_key_t m_expected_af;
    protected string m_host_order[$];
    protected string m_function_order[$];
    protected string m_bar_order[$];
    protected string m_service_order[$];

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_device_snapshot");
        super.new(name);
        m_frozen = 0;
        m_has_caps = 0;
        m_has_expected_af = 0;
        m_global_function_ids.delete();
    endfunction

// 功能：比较两个键或范围，提供确定性的排序或兼容性判定（function_less）。
// 输入/输出：输入为两个值语义对象；返回 bit，不修改输入。
// 边界/副作用：比较规则必须覆盖 domain/owner 和边界值，保证排序与资源冲突检查使用同一语义。
    protected function bit function_less(
        input dpu_function_key_t lhs,
        input dpu_function_key_t rhs
    );
        if (lhs.host_id != rhs.host_id)
            return lhs.host_id < rhs.host_id;
        if (lhs.pf_id != rhs.pf_id)
            return lhs.pf_id < rhs.pf_id;
        if (lhs.kind != rhs.kind)
            return lhs.kind < rhs.kind;
        return lhs.vf_id < rhs.vf_id;
    endfunction

// 功能：比较两个键或范围，提供确定性的排序或兼容性判定（host_less）。
// 输入/输出：输入为两个值语义对象；返回 bit，不修改输入。
// 边界/副作用：比较规则必须覆盖 domain/owner 和边界值，保证排序与资源冲突检查使用同一语义。
    protected function bit host_less(
        input dpu_host_info_t lhs,
        input dpu_host_info_t rhs
    );
        return lhs.host_id < rhs.host_id;
    endfunction

// 功能：比较两个键或范围，提供确定性的排序或兼容性判定（service_less）。
// 输入/输出：输入为两个值语义对象；返回 bit，不修改输入。
// 边界/副作用：比较规则必须覆盖 domain/owner 和边界值，保证排序与资源冲突检查使用同一语义。
    protected function bit service_less(
        input dpu_service_key_t lhs,
        input dpu_service_key_t rhs
    );
        if (function_less(lhs.function_key, rhs.function_key))
            return 1;
        if (function_less(rhs.function_key, lhs.function_key))
            return 0;
        if (lhs.service_kind != rhs.service_kind)
            return lhs.service_kind < rhs.service_kind;
        return lhs.service_instance_id < rhs.service_instance_id;
    endfunction

// 功能：判断对象是否满足指定状态、资格或引用关系（mutable）。
// 输入/输出：输入为待判断的键/状态；返回 bit，不修改对象。
// 边界/副作用：边界值显式判断，不触发分配、排序或其他隐藏副作用。
    protected function bit mutable(output string why);
        if (m_frozen) begin
            why = "snapshot is frozen";
            return 0;
        end
        why = "";
        return 1;
    endfunction

// 功能：判断对象是否满足指定状态、资格或引用关系（queryable）。
// 输入/输出：输入为待判断的键/状态；返回 bit，不修改对象。
// 边界/副作用：边界值显式判断，不触发分配、排序或其他隐藏副作用。
    protected function bit queryable(output string why);
        if (!m_frozen) begin
            why = "snapshot is not frozen";
            return 0;
        end
        why = "";
        return 1;
    endfunction

// 功能：按键查询内部索引或导出值复制（lookup_bar_address）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    protected function bit lookup_bar_address(
        input dpu_pcie_domain_key_t domain,
        input bit [63:0] address,
        output dpu_bar_address_match_t match
    );
        foreach (m_bar_order[index]) begin
            string bar_name;

            bar_name = m_bar_order[index];
            if (m_bars.exists(bar_name) &&
                m_bar_domains.exists(bar_name) &&
                m_bar_functions.exists(bar_name) &&
                dpu_same_domain_key(m_bar_domains[bar_name], domain) &&
                (address >= m_bars[bar_name].base) &&
                ((address - m_bars[bar_name].base) < m_bars[bar_name].size)) begin
                match.function_key = m_bar_functions[bar_name];
                match.role = m_bars[bar_name].role;
                match.bar_base = m_bars[bar_name].base;
                match.bar_size = m_bars[bar_name].size;
                match.offset = address - m_bars[bar_name].base;
                return 1;
            end
        end
        return 0;
    endfunction

// 功能：查询对象是否已经完成冻结生命周期阶段（is_frozen）。
// 输入/输出：无输入；返回 bit，不修改对象。
// 边界/副作用：只反映内部生命周期标志，不代替 validate/freeze。
    function bit is_frozen();
        return m_frozen;
    endfunction

// 功能：设置对象的配置字段、依赖对象或错误上下文（set_dut_caps）。
// 输入/输出：输入为新值或外部对象；通常无返回值，字段写入当前对象。
// 边界/副作用：必须尊重冻结边界；外部对象按约定借用或复制。
    function bit set_dut_caps(input dpu_dut_caps caps, output string why);
        if (!mutable(why))
            return 0;
        if (caps == null) begin
            why = "snapshot DUT capabilities are null";
            return 0;
        end
        m_dut_caps = dpu_dut_caps::type_id::create({get_name(), "_caps"});
        m_dut_caps.copy_from(caps);
        m_has_caps = 1;
        return 1;
    endfunction

    // 添加一个 Host 的值副本。Host ID 是快照中的稳定索引；空名称派生为
    // host_<id>，保证查询结果始终具有人类可读名称。
// 功能：向对象加入配置项、绑定或寄存器操作（add_host）。
// 输入/输出：输入为待加入值；成功返回 1/无返回值，失败返回 why 或记录诊断。
// 边界/副作用：加入前检查重复键、所有权和冻结状态，失败不得留下半写入元素。
    function bit add_host(
        input dpu_host_info_t host,
        output string why
    );
        string host_name;
        dpu_host_info_t stored_host;

        if (!mutable(why))
            return 0;
        host_name = dpu_host_key_name(host.host_id);
        if (m_hosts.exists(host_name)) begin
            why = {"snapshot duplicate Host ", host_name};
            return 0;
        end
        if ((host.address_width == 0) || (host.address_width > 64)) begin
            why = {"snapshot invalid address width for Host ", host_name};
            return 0;
        end
        if (host.has_gpa_aperture && (host.gpa_base >= host.gpa_limit)) begin
            why = {"snapshot invalid GPA aperture for Host ", host_name};
            return 0;
        end
        stored_host = host;
        if (stored_host.name.len() == 0)
            stored_host.name = $sformatf("host_%0d", host.host_id);
        m_hosts[host_name] = stored_host;
        m_host_order.push_back(host_name);
        return 1;
    endfunction

// 功能：向对象加入配置项、绑定或寄存器操作（add_function）。
// 输入/输出：输入为待加入值；成功返回 1/无返回值，失败返回 why 或记录诊断。
// 边界/副作用：加入前检查重复键、所有权和冻结状态，失败不得留下半写入元素。
    function bit add_function(
        input dpu_function_key_t key,
        input dpu_pcie_function_id_t pcie_id,
        output string why
    );
        string function_name;
        string pcie_name;

        if (!mutable(why))
            return 0;
        function_name = dpu_function_key_name(key);
        pcie_name = dpu_pcie_function_id_name(pcie_id);
        if (m_functions.exists(function_name)) begin
            why = {"snapshot duplicate function ", function_name};
            return 0;
        end
        if (m_reverse_functions.exists(pcie_name)) begin
            why = {"snapshot duplicate PCIe ID ", pcie_name};
            return 0;
        end
        if (key.host_id != pcie_id.domain.host_id) begin
            why = {"snapshot function/domain host mismatch ", function_name};
            return 0;
        end
        m_functions[function_name] = key;
        m_pcie_ids[function_name] = pcie_id;
        m_reverse_functions[pcie_name] = key;
        m_function_order.push_back(function_name);
        return 1;
    endfunction

// 功能：向对象加入配置项、绑定或寄存器操作（add_bar）。
// 输入/输出：输入为待加入值；成功返回 1/无返回值，失败返回 why 或记录诊断。
// 边界/副作用：加入前检查重复键、所有权和冻结状态，失败不得留下半写入元素。
    function bit add_bar(
        input dpu_function_key_t key,
        input dpu_bar_pair_lease_t bar,
        output string why
    );
        string function_name;
        string bar_name;
        bit [63:0] bar_end;

        if (!mutable(why))
            return 0;
        function_name = dpu_function_key_name(key);
        bar_name = dpu_function_bar_key_name(key, bar.role);
        if (!m_functions.exists(function_name)) begin
            why = {"snapshot BAR has unknown function ", function_name};
            return 0;
        end
        if (m_bars.exists(bar_name)) begin
            why = {"snapshot duplicate BAR ", bar_name};
            return 0;
        end
        if ((bar.size == 0) || (bar.base > (64'hffff_ffff_ffff_ffff - bar.size))) begin
            why = {"snapshot BAR has invalid interval ", bar_name};
            return 0;
        end
        bar_end = bar.base + bar.size;
        foreach (m_bar_order[index]) begin
            string other_name;
            bit [63:0] other_end;

            other_name = m_bar_order[index];
            if (dpu_same_domain_key(m_bar_domains[other_name],
                                    m_pcie_ids[function_name].domain)) begin
                other_end = m_bars[other_name].base + m_bars[other_name].size;
                if ((bar.base < other_end) &&
                    (m_bars[other_name].base < bar_end)) begin
                    why = {"snapshot same-domain BAR overlap ", bar_name};
                    return 0;
                end
            end
        end
        m_bars[bar_name] = bar;
        m_bar_domains[bar_name] = m_pcie_ids[function_name].domain;
        m_bar_functions[bar_name] = key;
        m_bar_order.push_back(bar_name);
        return 1;
    endfunction

// 功能：向对象加入配置项、绑定或寄存器操作（add_service）。
// 输入/输出：输入为待加入值；成功返回 1/无返回值，失败返回 why 或记录诊断。
// 边界/副作用：加入前检查重复键、所有权和冻结状态，失败不得留下半写入元素。
    function bit add_service(
        input dpu_service_key_t service,
        output string why
    );
        string function_name;
        string service_name;

        if (!mutable(why))
            return 0;
        function_name = dpu_function_key_name(service.function_key);
        service_name = dpu_service_key_name(service);
        if (!m_functions.exists(function_name)) begin
            why = {"snapshot service has unknown function ", service_name};
            return 0;
        end
        if (m_services.exists(service_name)) begin
            why = {"snapshot duplicate service ", service_name};
            return 0;
        end
        m_services[service_name] = service;
        m_service_owners[service_name] = service.function_key;
        m_service_order.push_back(service_name);
        return 1;
    endfunction

// 功能：设置对象的配置字段、依赖对象或错误上下文（set_expected_af）。
// 输入/输出：输入为新值或外部对象；通常无返回值，字段写入当前对象。
// 边界/副作用：必须尊重冻结边界；外部对象按约定借用或复制。
    function bit set_expected_af(
        input dpu_function_key_t key,
        output string why
    );
        if (!mutable(why))
            return 0;
        if (!m_functions.exists(dpu_function_key_name(key))) begin
            why = {"snapshot AF has unknown function ",
                   dpu_function_key_name(key)};
            return 0;
        end
        m_expected_af = key;
        m_has_expected_af = 1;
        return 1;
    endfunction

// 功能：按稳定键整理集合并重建派生索引（sort_indexes）。
// 输入/输出：输入为内部或引用传入的数组；无返回值，排序结果写回数组/索引。
// 边界/副作用：只改变表示顺序，不改变元素语义，保证快照和计划确定性。
    protected function void sort_indexes();
        string swap_name;

        for (int left = 0; left < m_host_order.size(); left++) begin
            for (int right = left + 1; right < m_host_order.size(); right++) begin
                if (host_less(m_hosts[m_host_order[right]],
                              m_hosts[m_host_order[left]])) begin
                    swap_name = m_host_order[left];
                    m_host_order[left] = m_host_order[right];
                    m_host_order[right] = swap_name;
                end
            end
        end
        for (int left = 0; left < m_function_order.size(); left++) begin
            for (int right = left + 1; right < m_function_order.size(); right++) begin
                if (function_less(m_functions[m_function_order[right]],
                                  m_functions[m_function_order[left]])) begin
                    swap_name = m_function_order[left];
                    m_function_order[left] = m_function_order[right];
                    m_function_order[right] = swap_name;
                end
            end
        end
        for (int left = 0; left < m_bar_order.size(); left++) begin
            for (int right = left + 1; right < m_bar_order.size(); right++) begin
                dpu_function_key_t left_key;
                dpu_function_key_t right_key;
                bit should_swap;

                left_key = m_bar_functions[m_bar_order[left]];
                right_key = m_bar_functions[m_bar_order[right]];
                should_swap = function_less(right_key, left_key) ||
                    (!function_less(left_key, right_key) &&
                     !function_less(right_key, left_key) &&
                     (m_bars[m_bar_order[right]].role <
                      m_bars[m_bar_order[left]].role));
                if (should_swap) begin
                    swap_name = m_bar_order[left];
                    m_bar_order[left] = m_bar_order[right];
                    m_bar_order[right] = swap_name;
                end
            end
        end
        for (int left = 0; left < m_service_order.size(); left++) begin
            for (int right = left + 1; right < m_service_order.size(); right++) begin
                if (service_less(m_services[m_service_order[right]],
                                 m_services[m_service_order[left]])) begin
                    swap_name = m_service_order[left];
                    m_service_order[left] = m_service_order[right];
                    m_service_order[right] = swap_name;
                end
            end
        end
    endfunction

// 功能：完成索引重建、排序和一致性校验，并把可变对象转换为只读快照（freeze）。
// 输入/输出：输入为当前未冻结对象；返回 bit，失败通过 why/diagnostic 说明。
// 边界/副作用：冻结成功后所有写入接口必须拒绝修改。
    function bit freeze(output string why);
        bit function_names[string];
        bit bar_names[string];
        bit service_names[string];
        string af_name;
        string af_bar_name;

        if (!mutable(why))
            return 0;
        if (!m_has_caps || (m_dut_caps == null)) begin
            why = "snapshot has no DUT capabilities";
            return 0;
        end
        if (!m_has_expected_af) begin
            why = "snapshot has no expected AF";
            return 0;
        end
        if (m_host_order.size() != m_hosts.num()) begin
            why = "snapshot Host index cardinality mismatch";
            return 0;
        end
        foreach (m_host_order[index]) begin
            string host_name;

            host_name = m_host_order[index];
            if (!m_hosts.exists(host_name) ||
                (dpu_host_key_name(m_hosts[host_name].host_id) != host_name) ||
                (m_hosts[host_name].address_width == 0) ||
                (m_hosts[host_name].address_width > 64) ||
                (m_hosts[host_name].has_gpa_aperture &&
                 (m_hosts[host_name].gpa_base >= m_hosts[host_name].gpa_limit))) begin
                why = {"snapshot Host properties are invalid ", host_name};
                return 0;
            end
        end
        if ((m_function_order.size() != m_functions.num()) ||
            (m_pcie_ids.num() != m_functions.num()) ||
            (m_reverse_functions.num() != m_functions.num())) begin
            why = "snapshot PCIe index cardinality mismatch";
            return 0;
        end
        foreach (m_function_order[index]) begin
            string function_name;
            string pcie_name;

            function_name = m_function_order[index];
            if (function_names.exists(function_name) ||
                !m_functions.exists(function_name) ||
                !m_pcie_ids.exists(function_name)) begin
                why = {"snapshot function has no PCIe ID ", function_name};
                return 0;
            end
            function_names[function_name] = 1;
            if (dpu_function_key_name(m_functions[function_name]) !=
                function_name) begin
                why = {"snapshot function index key mismatch ", function_name};
                return 0;
            end
            pcie_name = dpu_pcie_function_id_name(m_pcie_ids[function_name]);
            if (!m_reverse_functions.exists(pcie_name) ||
                !dpu_same_function_key(m_reverse_functions[pcie_name],
                                       m_functions[function_name])) begin
                why = {"snapshot PCIe indexes disagree ", function_name};
                return 0;
            end
        end
        if ((m_bar_order.size() != m_bars.num()) ||
            (m_bar_domains.num() != m_bars.num()) ||
            (m_bar_functions.num() != m_bars.num())) begin
            why = "snapshot BAR index cardinality mismatch";
            return 0;
        end
        foreach (m_bar_order[index]) begin
            string bar_name;
            string owner_name;
            bit owner_matches_key;

            bar_name = m_bar_order[index];
            if (bar_names.exists(bar_name) || !m_bars.exists(bar_name) ||
                !m_bar_domains.exists(bar_name) ||
                !m_bar_functions.exists(bar_name)) begin
                why = {"snapshot BAR index cardinality mismatch ", bar_name};
                return 0;
            end
            bar_names[bar_name] = 1;
            owner_name = dpu_function_key_name(m_bar_functions[bar_name]);
            if (!m_functions.exists(owner_name) ||
                !m_pcie_ids.exists(owner_name)) begin
                why = {"snapshot BAR owning function mismatch ", bar_name};
                return 0;
            end
            owner_matches_key = 0;
            foreach (m_function_order[function_index]) begin
                string candidate_owner_name;

                candidate_owner_name = m_function_order[function_index];
                if (dpu_function_bar_key_name(
                        m_functions[candidate_owner_name],
                        m_bars[bar_name].role) == bar_name) begin
                    owner_matches_key = 1;
                    if (!dpu_same_function_key(
                            m_bar_functions[bar_name],
                            m_functions[candidate_owner_name])) begin
                        why = {"snapshot BAR owning function mismatch ",
                               bar_name};
                        return 0;
                    end
                    break;
                end
            end
            if (!owner_matches_key) begin
                why = {"snapshot BAR key identity mismatch ", bar_name};
                return 0;
            end
            if (!dpu_same_domain_key(m_bar_domains[bar_name],
                                     m_pcie_ids[owner_name].domain)) begin
                why = {"snapshot BAR owning domain mismatch ", bar_name};
                return 0;
            end
            if ((m_bars[bar_name].size == 0) ||
                (m_bars[bar_name].base >
                 (64'hffff_ffff_ffff_ffff - m_bars[bar_name].size))) begin
                why = {"snapshot BAR interval is invalid ", bar_name};
                return 0;
            end
        end
        for (int left = 0; left < m_bar_order.size(); left++) begin
            string left_name;
            bit [63:0] left_end;

            left_name = m_bar_order[left];
            left_end = m_bars[left_name].base + m_bars[left_name].size;
            for (int right = left + 1; right < m_bar_order.size(); right++) begin
                string right_name;
                bit [63:0] right_end;

                right_name = m_bar_order[right];
                right_end = m_bars[right_name].base +
                    m_bars[right_name].size;
                if (dpu_same_domain_key(m_bar_domains[left_name],
                                        m_bar_domains[right_name]) &&
                    (m_bars[left_name].base < right_end) &&
                    (m_bars[right_name].base < left_end)) begin
                    why = {"snapshot BAR interval overlap ", left_name,
                           " and ", right_name};
                    return 0;
                end
            end
        end
        foreach (m_bar_order[index]) begin
            string bar_name;
            bit [63:0] bar_last;
            dpu_bar_address_match_t match;

            bar_name = m_bar_order[index];
            bar_last = m_bars[bar_name].base + m_bars[bar_name].size - 1;
            if (!lookup_bar_address(m_bar_domains[bar_name],
                                    m_bars[bar_name].base, match)) begin
                why = {"snapshot BAR base address round-trip missing ",
                       bar_name};
                return 0;
            end
            if (
                !dpu_same_function_key(match.function_key,
                                       m_bar_functions[bar_name]) ||
                (match.role != m_bars[bar_name].role) ||
                (match.bar_base != m_bars[bar_name].base) ||
                (match.bar_size != m_bars[bar_name].size) ||
                (match.offset != 0)) begin
                why = {"snapshot BAR base address round-trip mismatch ",
                       bar_name};
                return 0;
            end
            if (!lookup_bar_address(m_bar_domains[bar_name], bar_last,
                                    match)) begin
                why = {"snapshot BAR last address round-trip missing ",
                       bar_name};
                return 0;
            end
            if (
                !dpu_same_function_key(match.function_key,
                                       m_bar_functions[bar_name]) ||
                (match.role != m_bars[bar_name].role) ||
                (match.bar_base != m_bars[bar_name].base) ||
                (match.bar_size != m_bars[bar_name].size) ||
                (match.offset != (m_bars[bar_name].size - 1))) begin
                why = {"snapshot BAR last address round-trip mismatch ",
                       bar_name};
                return 0;
            end
        end
        if ((m_service_order.size() != m_services.num()) ||
            (m_service_owners.num() != m_services.num())) begin
            why = "snapshot service index cardinality mismatch";
            return 0;
        end
        foreach (m_service_order[index]) begin
            string service_name;

            service_name = m_service_order[index];
            if (service_names.exists(service_name) ||
                !m_services.exists(service_name) ||
                !m_service_owners.exists(service_name) ||
                !m_functions.exists(dpu_function_key_name(
                    m_services[service_name].function_key)) ||
                (dpu_service_key_name(m_services[service_name]) !=
                 service_name) ||
                !dpu_same_function_key(m_service_owners[service_name],
                                       m_services[service_name].function_key)) begin
                why = {"snapshot service indexes disagree ", service_name};
                return 0;
            end
            service_names[service_name] = 1;
        end
        af_name = dpu_function_key_name(m_expected_af);
        af_bar_name = dpu_function_bar_key_name(m_expected_af,
                                                DPU_BAR_DEVICE_MEMORY);
        if ((m_expected_af.host_id > 7) ||
            (m_expected_af.kind != DPU_FUNCTION_PF) ||
            (m_expected_af.pf_id != 0) || (m_expected_af.vf_id != 0) ||
            !m_functions.exists(af_name)) begin
            why = {"snapshot expected AF is not an eligible PF0 ", af_name};
            return 0;
        end
        if (!m_bars.exists(af_bar_name) ||
            (m_bars[af_bar_name].role != DPU_BAR_DEVICE_MEMORY) ||
            (m_bars[af_bar_name].even_bar_id != 0)) begin
            why = {"selected AF requires resolved BAR0 device memory ", af_name};
            return 0;
        end
        sort_indexes();
        m_global_function_ids.delete();
        foreach (m_function_order[index])
            m_global_function_ids[m_function_order[index]] = index;
        m_frozen = 1;
        why = "";
        return 1;
    endfunction

// 功能：按键查询内部索引或导出值复制（get_pcie_id）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit get_pcie_id(
        input dpu_function_key_t key,
        output dpu_pcie_function_id_t pcie_id,
        output string why
    );
        string function_name;

        pcie_id = '{default:'0};
        if (!queryable(why))
            return 0;
        function_name = dpu_function_key_name(key);
        if (!m_pcie_ids.exists(function_name)) begin
            why = {"unknown snapshot function ", function_name};
            return 0;
        end
        pcie_id = m_pcie_ids[function_name];
        return 1;
    endfunction

// 功能：按键查询内部索引或导出值复制（get_global_function_id）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit get_global_function_id(
        input dpu_function_key_t key,
        output int unsigned global_function_id,
        output string why
    );
        string function_name;

        global_function_id = 0;
        if (!queryable(why))
            return 0;
        function_name = dpu_function_key_name(key);
        if (!m_global_function_ids.exists(function_name)) begin
            why = {"unknown snapshot global function ID ", function_name};
            return 0;
        end
        global_function_id = m_global_function_ids[function_name];
        why = "";
        return 1;
    endfunction

// 功能：按键查询内部索引或导出值复制（find_function）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit find_function(
        input dpu_pcie_function_id_t pcie_id,
        output dpu_function_key_t key,
        output string why
    );
        string pcie_name;

        key.host_id = 0;
        key.pf_id = 0;
        key.kind = DPU_FUNCTION_PF;
        key.vf_id = 0;
        if (!queryable(why))
            return 0;
        pcie_name = dpu_pcie_function_id_name(pcie_id);
        if (!m_reverse_functions.exists(pcie_name)) begin
            why = {"unknown snapshot PCIe ID ", pcie_name};
            return 0;
        end
        key = m_reverse_functions[pcie_name];
        return 1;
    endfunction

// 功能：按键查询内部索引或导出值复制（get_bar）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit get_bar(
        input dpu_function_key_t key,
        input dpu_bar_role_e role,
        output dpu_bar_pair_lease_t bar,
        output string why
    );
        string bar_name;

        bar.role = DPU_BAR_DEVICE_MEMORY;
        bar.even_bar_id = 0;
        bar.base = '0;
        bar.size = '0;
        if (!queryable(why))
            return 0;
        bar_name = dpu_function_bar_key_name(key, role);
        if (!m_bars.exists(bar_name)) begin
            why = {"unknown snapshot BAR ", bar_name};
            return 0;
        end
        bar = m_bars[bar_name];
        return 1;
    endfunction

// 功能：按键查询内部索引或导出值复制（list_bars）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit list_bars(
        input dpu_function_key_t key,
        ref dpu_bar_pair_lease_t bars[$],
        output string why
    );
        bars.delete();
        if (!queryable(why))
            return 0;
        if (!m_functions.exists(dpu_function_key_name(key))) begin
            why = {"unknown snapshot function ", dpu_function_key_name(key)};
            return 0;
        end
        foreach (m_bar_order[index]) begin
            string bar_name;

            bar_name = m_bar_order[index];
            if (dpu_same_function_key(m_bar_functions[bar_name], key))
                bars.push_back(m_bars[bar_name]);
        end
        return 1;
    endfunction

// 功能：把 function 的 BAR-relative offset 解析为已分配的绝对地址（resolve_bar_address）。
// 输入/输出：输入为 function key、BAR ID 和相对 offset/width；返回 bit 和 output 地址。
// 边界/副作用：检查 BAR 存在、宽度和加法溢出；越界不得返回部分地址。
    function bit resolve_bar_address(
        input dpu_pcie_domain_key_t domain,
        input bit [63:0] address,
        output dpu_bar_address_match_t match,
        output string why
    );
        match.function_key.host_id = 0;
        match.function_key.pf_id = 0;
        match.function_key.kind = DPU_FUNCTION_PF;
        match.function_key.vf_id = 0;
        match.role = DPU_BAR_DEVICE_MEMORY;
        match.bar_base = '0;
        match.bar_size = '0;
        match.offset = '0;
        if (!queryable(why))
            return 0;
        if (lookup_bar_address(domain, address, match))
            return 1;
        why = $sformatf("no BAR contains %s address %016h",
                        dpu_pcie_domain_key_name(domain), address);
        return 0;
    endfunction

// 功能：按键查询内部索引或导出值复制（get_service_owner）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit get_service_owner(
        input dpu_service_key_t service,
        output dpu_function_key_t owner,
        output string why
    );
        string service_name;

        owner.host_id = 0;
        owner.pf_id = 0;
        owner.kind = DPU_FUNCTION_PF;
        owner.vf_id = 0;
        if (!queryable(why))
            return 0;
        service_name = dpu_service_key_name(service);
        if (!m_service_owners.exists(service_name)) begin
            why = {"unknown snapshot service ", service_name};
            return 0;
        end
        owner = m_service_owners[service_name];
        return 1;
    endfunction

    // 返回冻结快照中的 Host 总数；未冻结时不暴露配置内容。
// 功能：统计快照中的 Host 总数或启用 Host 数量（host_count）。
// 输入/输出：无输入；返回当前冻结快照的计数，不修改索引。
// 边界/副作用：计数只基于逻辑 Host，不把 PCIe 物理拓扑或未冻结临时项混入结果。
    function int unsigned host_count();
        if (!m_frozen)
            return 0;
        return m_host_order.size();
    endfunction

    // 返回 enabled Host 数量。数量始终从冻结后的 Host 数组派生，避免
    // 引入一个可能与动态配置数组不一致的独立 num_hosts 字段。
// 功能：统计快照中的 Host 总数或启用 Host 数量（enabled_host_count）。
// 输入/输出：无输入；返回当前冻结快照的计数，不修改索引。
// 边界/副作用：计数只基于逻辑 Host，不把 PCIe 物理拓扑或未冻结临时项混入结果。
    function int unsigned enabled_host_count();
        int unsigned count;

        count = 0;
        if (!m_frozen)
            return count;
        foreach (m_host_order[index]) begin
            if (m_hosts[m_host_order[index]].enabled)
                count++;
        end
        return count;
    endfunction

// 功能：按键查询内部索引或导出值复制（lookup_host）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit lookup_host(
        input int unsigned host_id,
        output dpu_host_info_t host,
        output string why
    );
        string host_name;

        host.host_id = 0;
        host.enabled = 0;
        host.name = "";
        host.address_width = 0;
        host.has_gpa_aperture = 0;
        host.gpa_base = '0;
        host.gpa_limit = '0;
        if (!queryable(why))
            return 0;
        host_name = dpu_host_key_name(host_id);
        if (!m_hosts.exists(host_name)) begin
            why = {"unknown snapshot Host ", host_name};
            return 0;
        end
        host = m_hosts[host_name];
        why = "";
        return 1;
    endfunction

// 功能：按键查询内部索引或导出值复制（list_hosts）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_hosts(ref dpu_host_info_t hosts[$]);
        hosts.delete();
        if (!m_frozen)
            return;
        foreach (m_host_order[index])
            hosts.push_back(m_hosts[m_host_order[index]]);
    endfunction

// 功能：按键查询内部索引或导出值复制（list_functions）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_functions(ref dpu_function_key_t keys[$]);
        keys.delete();
        if (!m_frozen)
            return;
        foreach (m_function_order[index])
            keys.push_back(m_functions[m_function_order[index]]);
    endfunction

// 功能：按键查询内部索引或导出值复制（list_services）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function void list_services(
        input dpu_service_kind_e kind,
        ref dpu_service_key_t keys[$]
    );
        keys.delete();
        if (!m_frozen)
            return;
        foreach (m_service_order[index]) begin
            if (m_services[m_service_order[index]].service_kind == kind)
                keys.push_back(m_services[m_service_order[index]]);
        end
    endfunction

// 功能：按键查询内部索引或导出值复制（get_expected_af）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit get_expected_af(
        output dpu_function_key_t key,
        output dpu_bar_pair_lease_t bar0,
        output string why
    );
        key.host_id = 0;
        key.pf_id = 0;
        key.kind = DPU_FUNCTION_PF;
        key.vf_id = 0;
        bar0.role = DPU_BAR_DEVICE_MEMORY;
        bar0.even_bar_id = 0;
        bar0.base = '0;
        bar0.size = '0;
        if (!queryable(why))
            return 0;
        key = m_expected_af;
        bar0 = m_bars[dpu_function_bar_key_name(
            m_expected_af, DPU_BAR_DEVICE_MEMORY)];
        return 1;
    endfunction

// 功能：导出 DUT 能力对象的独立副本（snapshot_dut_caps）。
// 输入/输出：无输入或仅有 output 语义；返回新能力对象，不暴露内部可变引用。
// 边界/副作用：快照/manager 内部能力保持不变，未配置能力时返回明确的空值。
    function dpu_dut_caps snapshot_dut_caps();
        dpu_dut_caps caps_copy;

        if (!m_frozen || (m_dut_caps == null))
            return null;
        caps_copy = dpu_dut_caps::type_id::create({get_name(), "_caps_copy"});
        caps_copy.copy_from(m_dut_caps);
        return caps_copy;
    endfunction
endclass : dpu_device_snapshot

`endif // DPU_DEVICE_SNAPSHOT_SV
