/*
 * 所属层次：src/ 配置解析入口层。
 * 文件职责：把 authoring 配置交给设备解析器，统一把解析结果映射为配置状态和冻结快照。
 * 主要依赖：dpu_device_cfg、dpu_device_resolver、dpu_device_snapshot。
 * 所有权与生命周期：只读配置并生成新的快照；失败时不修改调用方配置，也不发布半成品快照。
 */
`ifndef DPU_CONFIGURATION_RESOLVER_SV
`define DPU_CONFIGURATION_RESOLVER_SV

// Candidate-only coordinator for the declarative device/resource pipeline.
// Caller-owned configurations and previously published snapshots are never
// modified; output handles are assigned only after both snapshots freeze.
// 设计原因：将校验、解析或计划构建从 authoring 对象中隔离，保证输出规则集中且可复用。
// 职责与所有权：该类通常是无状态服务；输入由调用方拥有，输出快照/计划在成功返回后交给调用方。
// 生命周期/失败边界：调用方必须遵守公开接口的状态前置条件；非法输入通过返回值或诊断路径报告。
class dpu_configuration_resolver extends uvm_object;
    `uvm_object_utils(dpu_configuration_resolver)

    dpu_placement_normalizer placement_normalizer;
    dpu_device_resolver device_resolver;
    dpu_resource_resolver resource_resolver;

// 功能：构造并初始化对象（new）。
// 输入/输出：输入为构造参数（通常是 UVM 名称或键值）；无返回值。
// 边界/副作用：不访问硬件；集合、错误状态和可选字段必须清空，避免复用泄漏旧状态。
    function new(string name = "dpu_configuration_resolver");
        super.new(name);
        placement_normalizer = dpu_placement_normalizer::type_id::create(
            {name, "_normalizer"});
        device_resolver = dpu_device_resolver::type_id::create(
            {name, "_device_resolver"});
        resource_resolver = dpu_resource_resolver::type_id::create(
            {name, "_resource_resolver"});
    endfunction

// 功能：将 authoring 配置解析为可消费的冻结快照或资源结果（resolve）。
// 输入/输出：输入为配置/计划及输出对象；成功返回 1，失败返回 0 并填写 why/diagnostic。
// 边界/副作用：失败不得发布半成品结果，也不得反向修改输入配置。
    function bit resolve(
        input dpu_device_cfg device_cfg,
        input dpu_resource_placement_cfg placement_cfg,
        output dpu_device_snapshot device_snapshot,
        output dpu_resource_snapshot resource_snapshot,
        output dpu_placement_diagnostic diagnostic
    );
        dpu_device_cfg normalized_cfg;
        dpu_normalized_placement_plan normalized_plan;
        dpu_device_snapshot candidate_device;
        dpu_resource_snapshot candidate_resource;
        string why;

        device_snapshot = null;
        resource_snapshot = null;
        diagnostic = dpu_placement_diagnostic::type_id::create(
            {get_name(), "_diagnostic"});
        diagnostic.clear();

        if (!placement_normalizer.normalize(device_cfg, placement_cfg,
                                            normalized_cfg, normalized_plan,
                                            diagnostic)) begin
            return 0;
        end
        if (!device_resolver.resolve(normalized_cfg, candidate_device, why)) begin
            diagnostic.set_device_resolution_failure(why);
            return 0;
        end
        if (!resource_resolver.resolve(candidate_device, normalized_plan,
                                       candidate_resource, diagnostic)) begin
            return 0;
        end
        if ((candidate_device == null) || !candidate_device.is_frozen() ||
            (candidate_resource == null) || !candidate_resource.is_frozen()) begin
            diagnostic.set(DPU_PLACE_STAGE_CROSS_SNAPSHOT,
                           DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH,
                           "coordinator produced an unfrozen snapshot");
            return 0;
        end
        if (!candidate_resource.references_device_snapshot(candidate_device)) begin
            diagnostic.set(DPU_PLACE_STAGE_CROSS_SNAPSHOT,
                           DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH,
                           "resource snapshot does not reference candidate device snapshot");
            return 0;
        end
        device_snapshot = candidate_device;
        resource_snapshot = candidate_resource;
        diagnostic.clear();
        return 1;
    endfunction
endclass : dpu_configuration_resolver

`endif // DPU_CONFIGURATION_RESOLVER_SV
