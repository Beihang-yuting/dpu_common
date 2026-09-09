/*
 * 所属层次：src/ 寄存器计划依赖分析层。
 * 文件职责：收集寄存器操作，校验依赖图和 commit group，并生成稳定的拓扑执行顺序。
 * 主要依赖：dpu_reg_op、dpu_reg_plan_types。
 * 所有权与生命周期：plan 拥有 operation 副本；freeze 后操作列表和排序结果不可变。
 */
`ifndef DPU_REG_PLAN_SV
`define DPU_REG_PLAN_SV

// 设计原因：把跨阶段解析结果和派生索引封装起来，避免消费者直接依赖可变配置。
// 职责与所有权：对象在 freeze 前填充并拥有内部副本，freeze 后只读，查询者只能获得值复制。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_reg_plan extends uvm_object;
    `uvm_object_utils(dpu_reg_plan)

    local dpu_reg_op operations_by_id[string];
    local string ordered_ids[$];
    local bit frozen;

    typedef bit dpu_reg_string_set_t[string];
    typedef dpu_reg_string_set_t dpu_reg_string_set_map_t[string];
    typedef int unsigned dpu_reg_indegree_map_t[string];
    typedef string dpu_reg_string_map_t[string];
    typedef dpu_reg_string_set_t dpu_reg_ready_map_t[int unsigned];

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_reg_plan");
        super.new(name);
        ordered_ids.delete();
        frozen = 0;
    endfunction

// 功能：查询当前对象的计数、状态或最近错误文本（operation_count）。
// 输入/输出：无输入；返回值语义结果，不修改对象。
// 边界/副作用：空集合或尚未执行时返回定义明确的默认值。
    function int unsigned operation_count();
        return operations_by_id.num();
    endfunction

    // Return defensive copies of all operations currently held by the plan.
    // This is intentionally available before freeze so a higher-level plan
    // builder can compose an existing bootstrap plan without sharing mutable
    // operation handles.  Callers that need lifecycle order should use
    // ordered_operations() after freeze().
// 功能：按键查询内部索引或导出值复制（list_operations）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit list_operations(
        ref dpu_reg_op operations[$],
        output string why
    );
        dpu_reg_op copied;
        string op_id;

        operations.delete();
        why = "";
        if (operations_by_id.first(op_id)) begin
            do begin
                if (!copy_operation(
                        operations_by_id[op_id], op_id, copied, why)) begin
                    operations.delete();
                    return 0;
                end
                operations.push_back(copied);
            end while (operations_by_id.next(op_id));
        end
        return 1;
    endfunction

// 功能：查询对象是否已经完成冻结生命周期阶段（is_frozen）。
// 输入/输出：无输入；返回 bit，不修改对象。
// 边界/副作用：只反映内部生命周期标志，不代替 validate/freeze。
    function bit is_frozen();
        return frozen;
    endfunction

    // Dynamic operation subtypes are preserved through copy_op(). A subtype
    // that owns object-handle extension fields must deep-copy those fields in
    // do_copy(); the plan can only invoke the dynamic clone and verify its ID.
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
                "failed to copy register operation %s", expected_id);
            return 0;
        end

        copied = source.copy_op(expected_id);
        if (copied == null) begin
            why = $sformatf(
                "failed to copy register operation %s", expected_id);
            return 0;
        end
        if (copied.op_id != expected_id) begin
            why = $sformatf(
                "register operation copy ID %s does not match expected ID %s",
                copied.op_id, expected_id);
            copied = null;
            return 0;
        end
        return 1;
    endfunction

// 功能：向对象加入配置项、绑定或寄存器操作（add_operation）。
// 输入/输出：输入为待加入值；成功返回 1/无返回值，失败返回 why 或记录诊断。
// 边界/副作用：加入前检查重复键、所有权和冻结状态，失败不得留下半写入元素。
    function bit add_operation(
        input dpu_reg_op operation,
        output string why
    );
        dpu_reg_op copied;

        why = "";
        if (frozen) begin
            why = "register plan is frozen";
            return 0;
        end
        if (operation == null) begin
            why = "cannot add a null register operation";
            return 0;
        end
        if (operation.op_id == "") begin
            why = "register operation ID must not be empty";
            return 0;
        end
        if (operations_by_id.exists(operation.op_id)) begin
            why = $sformatf(
                "duplicate register operation ID %s", operation.op_id);
            return 0;
        end

        if (!copy_operation(operation, operation.op_id, copied, why))
            return 0;
        operations_by_id[operation.op_id] = copied;
        return 1;
    endfunction

// 功能：按键查询内部索引或导出值复制（find_operation）。
// 输入/输出：输入为逻辑键/索引和 output/ref 参数；返回命中状态或查询值。
// 边界/副作用：查询不改变冻结状态；未命中时返回明确失败而不伪造结果。
    function bit find_operation(
        input string op_id,
        output dpu_reg_op operation
    );
        string ignored_why;

        operation = null;
        if (!operations_by_id.exists(op_id))
            return 0;
        return copy_operation(
            operations_by_id[op_id], op_id, operation, ignored_why);
    endfunction

// 功能：分析寄存器依赖图并生成稳定拓扑顺序（analyze_plan）。
// 输入/输出：输入为 operation 集合；输出排序数组和 why，返回 bit。
// 边界/副作用：检测未知依赖、环和重复 ID，分析阶段不执行硬件副作用。
    local function bit analyze_plan(
        ref dpu_reg_indegree_map_t indegree,
        ref dpu_reg_string_set_map_t outgoing_edges,
        ref dpu_reg_string_set_map_t dependency_edges,
        ref dpu_reg_string_set_map_t producers_by_group,
        ref dpu_reg_string_map_t commit_id_by_group,
        output string why
    );
        dpu_reg_string_set_t seen_dependencies;
        bit dependency_found;
        string op_id;
        string dependency_id;
        string producer_id;
        string group_id;

        indegree.delete();
        outgoing_edges.delete();
        dependency_edges.delete();
        producers_by_group.delete();
        commit_id_by_group.delete();
        why = "";
        if (!operations_by_id.first(op_id)) begin
            why = "register plan contains no operations";
            return 0;
        end

        // String-index associative arrays traverse lexically with first/next,
        // so validation error selection is deterministic without sorting.
        do begin
            if (!operations_by_id[op_id].validate(why))
                return 0;

            indegree[op_id] = 0;
            seen_dependencies.delete();
            foreach (operations_by_id[op_id].dependencies[index]) begin
                dependency_id = operations_by_id[op_id].dependencies[index];
                if (dependency_id == op_id) begin
                    why = $sformatf(
                        "operation %s depends on itself", op_id);
                    return 0;
                end
                if (seen_dependencies.exists(dependency_id)) begin
                    why = $sformatf(
                        "operation %s repeats dependency %s",
                        op_id, dependency_id);
                    return 0;
                end
                seen_dependencies[dependency_id] = 1;
                if (!operations_by_id.exists(dependency_id)) begin
                    why = $sformatf(
                        "operation %s depends on unknown operation %s",
                        op_id, dependency_id);
                    return 0;
                end
                dependency_edges[op_id][dependency_id] = 1;
                outgoing_edges[dependency_id][op_id] = 1;
                indegree[op_id]++;
            end

            group_id = operations_by_id[op_id].commit_group;
            if ((group_id != "") &&
                (operations_by_id[op_id].phase == DPU_REG_PHASE_TABLE) &&
                (operations_by_id[op_id].kind == DPU_REG_OP_MMIO_WRITE)) begin
                producers_by_group[group_id][op_id] = 1;
            end

            if (operations_by_id[op_id].kind == DPU_REG_OP_COMMIT) begin
                if (group_id == "") begin
                    why = $sformatf(
                        "operation %s commit group must not be empty", op_id);
                    return 0;
                end

                // A commit group identifies one atomic producer batch/epoch,
                // not a permanent hardware block. Later builders must assign
                // a unique group for every commit operation they generate.
                if (commit_id_by_group.exists(group_id)) begin
                    why = $sformatf(
                        {"commit group %s is used by multiple commit ",
                         "operations %s and %s"},
                        group_id, commit_id_by_group[group_id], op_id);
                    return 0;
                end
                commit_id_by_group[group_id] = op_id;
            end
        end while (operations_by_id.next(op_id));

        // Every nonempty producer epoch must terminate in its unique commit.
        // Traverse group and producer string indexes lexically so the missing
        // commit diagnostic is deterministic without adding quadratic work.
        if (producers_by_group.first(group_id)) begin
            do begin
                if (!commit_id_by_group.exists(group_id)) begin
                    if (!producers_by_group[group_id].first(producer_id)) begin
                        why = "register plan producer traversal failed";
                        return 0;
                    end
                    why = $sformatf(
                        {"commit group %s has producer %s but no commit ",
                         "operation"}, group_id, producer_id);
                    return 0;
                end
            end while (producers_by_group.next(group_id));
        end

        // Commit coverage is indexed by batch ID and direct dependency edge.
        // Unique commit groups make the aggregate traversal O(V + E).
        if (operations_by_id.first(op_id)) begin
            do begin
                if (operations_by_id[op_id].kind == DPU_REG_OP_COMMIT) begin
                    group_id = operations_by_id[op_id].commit_group;
                    if (!producers_by_group.exists(group_id)) begin
                        why = $sformatf(
                            {"operation %s has no table producer in commit ",
                             "group %s"}, op_id, group_id);
                        return 0;
                    end
                    if (!producers_by_group[group_id].first(producer_id)) begin
                        why = $sformatf(
                            {"operation %s has no table producer in commit ",
                             "group %s"}, op_id, group_id);
                        return 0;
                    end

                    do begin
                        dependency_found = 0;
                        if (dependency_edges.exists(op_id)) begin
                            dependency_found =
                                dependency_edges[op_id].exists(producer_id);
                        end
                        if (!dependency_found) begin
                            why = $sformatf(
                                {"operation %s does not depend on commit-group ",
                                 "producer %s"}, op_id, producer_id);
                            return 0;
                        end
                    end while (
                        producers_by_group[group_id].next(producer_id));
                end
            end while (operations_by_id.next(op_id));
        end
        return 1;
    endfunction

// 功能：分析寄存器依赖图并生成稳定拓扑顺序（build_topological_order）。
// 输入/输出：输入为 operation 集合；输出排序数组和 why，返回 bit。
// 边界/副作用：检测未知依赖、环和重复 ID，分析阶段不执行硬件副作用。
    local function bit build_topological_order(
        ref string result[$],
        ref dpu_reg_indegree_map_t indegree,
        ref dpu_reg_string_set_map_t outgoing_edges,
        output string why
    );
        dpu_reg_ready_map_t ready_by_phase;
        int unsigned ready_phase;
        string op_id;
        string candidate_id;
        string dependent_id;

        result.delete();
        ready_by_phase.delete();
        why = "";

        if (operations_by_id.first(op_id)) begin
            do begin
                if (indegree[op_id] == 0) begin
                    ready_phase = operations_by_id[op_id].phase;
                    ready_by_phase[ready_phase][op_id] = 1;
                end
            end while (operations_by_id.next(op_id));
        end

        while (result.size() < operations_by_id.num()) begin
            if (!ready_by_phase.first(ready_phase)) begin
                result.delete();
                why = "register plan contains a dependency cycle";
                return 0;
            end
            if (!ready_by_phase[ready_phase].first(candidate_id)) begin
                result.delete();
                why = "register plan ready-set traversal failed";
                return 0;
            end

            ready_by_phase[ready_phase].delete(candidate_id);
            if (ready_by_phase[ready_phase].num() == 0)
                ready_by_phase.delete(ready_phase);
            result.push_back(candidate_id);

            if (outgoing_edges.exists(candidate_id)) begin
                if (outgoing_edges[candidate_id].first(dependent_id)) begin
                    do begin
                        indegree[dependent_id]--;
                        if (indegree[dependent_id] == 0) begin
                            ready_phase =
                                operations_by_id[dependent_id].phase;
                            ready_by_phase[ready_phase][dependent_id] = 1;
                        end
                    end while (
                        outgoing_edges[candidate_id].next(dependent_id));
                end
            end
        end
        return 1;
    endfunction

// 功能：分析寄存器依赖图并生成稳定拓扑顺序（analyze_and_order）。
// 输入/输出：输入为 operation 集合；输出排序数组和 why，返回 bit。
// 边界/副作用：检测未知依赖、环和重复 ID，分析阶段不执行硬件副作用。
    local function bit analyze_and_order(
        ref string result[$],
        output string why
    );
        dpu_reg_indegree_map_t indegree;
        dpu_reg_string_set_map_t outgoing_edges;
        dpu_reg_string_set_map_t dependency_edges;
        dpu_reg_string_set_map_t producers_by_group;
        dpu_reg_string_map_t commit_id_by_group;

        if (!analyze_plan(
            indegree, outgoing_edges, dependency_edges,
            producers_by_group, commit_id_by_group, why)) begin
            result.delete();
            return 0;
        end
        return build_topological_order(
            result, indegree, outgoing_edges, why);
    endfunction

// 功能：校验对象字段之间的约束和跨字段不变量（validate）。
// 输入/输出：输入为当前对象状态；返回 bit，并在 why 中给出首个失败原因。
// 边界/副作用：只读检查；空键、越界、重复项或不一致组合必须拒绝。
    function bit validate(output string why);
        string validation_order[$];

        return analyze_and_order(validation_order, why);
    endfunction

// 功能：完成索引重建、排序和一致性校验，并把可变对象转换为只读快照（freeze）。
// 输入/输出：输入为当前未冻结对象；返回 bit，失败通过 why/diagnostic 说明。
// 边界/副作用：冻结成功后所有写入接口必须拒绝修改。
    function bit freeze(output string why);
        string new_order[$];

        why = "";
        if (frozen)
            return 1;
        if (!analyze_and_order(new_order, why))
            return 0;

        ordered_ids = new_order;
        frozen = 1;
        return 1;
    endfunction

// 功能：导出 freeze 后已经完成依赖排序的寄存器操作副本（ordered_operations）。
// 输入/输出：输入为 output 数组；返回是否可导出，不改变计划。
// 边界/副作用：只有冻结且分析成功的计划允许导出；调用方不能通过返回数组修改内部操作。
    function bit ordered_operations(
        ref dpu_reg_op operations[$],
        output string why
    );
        dpu_reg_op copied;

        operations.delete();
        why = "";
        if (!frozen) begin
            why = "register plan must be frozen before retrieving order";
            return 0;
        end

        foreach (ordered_ids[index]) begin
            if (!copy_operation(
                operations_by_id[ordered_ids[index]], ordered_ids[index],
                copied, why)) begin
                operations.delete();
                return 0;
            end
            operations.push_back(copied);
        end
        return 1;
    endfunction
endclass : dpu_reg_plan

`endif // DPU_REG_PLAN_SV
