// tests：独立 DPU 核心字段宽度与公共配置发布合同；只依赖 uvm_pkg/dpu_resource_pkg。
// 复用默认 PF0 authoring 和正式 resolver 建立单 qpair 快照，覆盖同源检查及失败原子性。
// 所有配置/快照由本模块持有至测试结束；不引入 PCIe/VIO，不分配 Host memory 或发送 DUT 请求。
module dpu_table_types_test;
	import uvm_pkg::*;
	import dpu_resource_pkg::*;
	`include "uvm_macros.svh"

	// 从同一 authoring 解析独立冻结结果，避免伪造内部快照状态；任何准备失败立即结束测试。
	function automatic void resolve_fixture(
		input dpu_env_cfg			cfg,
		output dpu_device_snapshot	device,
		output dpu_resource_snapshot	resources,
		output dpu_bar_map			map
	);
		dpu_configuration_resolver	resolver;
		dpu_placement_diagnostic		diagnostic;
		string						why;

		resolver = new("resolver");
		if (!resolver.resolve(cfg.device_cfg, cfg.placement_cfg, device, resources, diagnostic))
			`uvm_fatal("DPU_TABLE_TYPES", {"fixture resolution failed: ", diagnostic.message})
		map = new("map");
		if (!map.initialize(device, 1, why) || !map.freeze(why))
			`uvm_fatal("DPU_TABLE_TYPES", {"fixture BAR map failed: ", why})
	endfunction

	// 每个失败调用前保存可见发布值；输入可能是另一份快照，失败后不能替换旧句柄或泄漏生成消息。
	// 分组数量和冻结目标也必须保留，保证后续类别仍消费原来成功发布的配置。
	function automatic void expect_rejected(
		input dpu_env_cfg			cfg,
		input dpu_device_snapshot	device,
		input dpu_resource_snapshot	resources,
		input dpu_bar_map			map,
		input string				label_text
	);
		dpu_device_snapshot		old_device;
		dpu_resource_snapshot	old_resources;
		dpu_bar_map				old_map;
		dpu_msix_message_t		old_messages[$];
		dpu_msix_message_t		old_frozen_messages[$];
		bit						old_ready;
		int						old_group_count;
		string					old_target;
		string					why;

		old_device          = cfg.device_snapshot;
		old_resources       = cfg.resource_snapshot;
		old_map             = cfg.bar_map;
		old_messages        = cfg.messages;
		old_frozen_messages = cfg.frozen_messages;
		old_ready           = cfg.runtime_ready;
		old_group_count     = cfg.frozen_bar_groups.size();
		old_target          = cfg.frozen_reg_target;
		if (cfg.publish(device, resources, map, why) || why == "")
			`uvm_fatal("DPU_TABLE_TYPES", {label_text, ": publication unexpectedly accepted or no diagnostic"})
		if (cfg.device_snapshot != old_device || cfg.resource_snapshot != old_resources ||
			cfg.bar_map != old_map || cfg.runtime_ready != old_ready ||
			cfg.messages.size() != old_messages.size() ||
			cfg.frozen_messages.size() != old_frozen_messages.size() ||
			cfg.frozen_bar_groups.size() != old_group_count || cfg.frozen_reg_target != old_target)
			`uvm_fatal("DPU_TABLE_TYPES", {label_text, ": failed publication changed visible state"})
		foreach (old_messages[i]) begin
			if (cfg.messages[i] !== old_messages[i])
				`uvm_fatal("DPU_TABLE_TYPES", {label_text, ": failed publication changed message input"})
		end
		foreach (old_frozen_messages[i]) begin
			if (cfg.frozen_messages[i] !== old_frozen_messages[i])
				`uvm_fatal("DPU_TABLE_TYPES", {label_text, ": failed publication changed frozen message"})
		end
	endfunction

	// 真实分组缺少 BAR 成员时在消息生成后失败；同一 cfg 修正输入后必须仍能正常发布和重试。
	// 再发布使用同设备的新 BAR map，能发现失败路径提前替换 map 的回归。
	function automatic void test_publication();
		dpu_env_cfg				cfg;
		dpu_device_snapshot		device;
		dpu_device_snapshot		other_device;
		dpu_device_snapshot		unfrozen_device;
		dpu_resource_snapshot	resources;
		dpu_resource_snapshot	other_resources;
		dpu_resource_snapshot	unfrozen_resources;
		dpu_bar_map				map;
		dpu_bar_map				other_map;
		dpu_bar_map				retry_map;
		dpu_bar_map				unfrozen_map;
		dpu_vio_service_t		service;
		dpu_vio_qpair_binding_t	pairs[$];
		dpu_msix_message_t		message;
		dpu_bar_group_policy_t	group;
		string					owner_name;
		string					why;

		cfg = new("publication_cfg");
		cfg.load_params();
		service.service_key = '{
			function_key: cfg.device_cfg.functions[0].key,
			service_kind: DPU_SERVICE_VIO_NET,
			service_instance_id: 0
		};
		service.enabled     = 1;
		service.tx_enable   = 0;
		service.rx_enable   = 0;
		service.msix_enable = 0;
		service.qpairs      = 1;
		cfg.add_vio_service(service);
		resolve_fixture(cfg, device, resources, map);
		resolve_fixture(cfg, other_device, other_resources, other_map);
		resources.list_vio_bindings(pairs);
		if (pairs.size() != 1)
			`uvm_fatal("DPU_TABLE_TYPES", "publication fixture requires exactly one qpair")

		// 模板在 materialize_messages 时才变成 catalog；失败不得让该临时条目进入 cfg.messages。
		message.owner         = pairs[0].service_key.function_key;
		message.local_vector  = pairs[0].local_msix_vector_id;
		message.global_vector = pairs[0].global_msix_vector_id;
		message.address       = 64'hfee0_0000;
		message.data          = 32'h40;
		message.masked        = 0;
		owner_name = dpu_function_key_name(message.owner);
		cfg.message_templates[owner_name][message.local_vector] = message;

		unfrozen_device    = new("unfrozen_device");
		unfrozen_resources = new("unfrozen_resources");
		unfrozen_map       = new("unfrozen_map");
		expect_rejected(cfg, unfrozen_device, resources, map, "unfrozen device");
		expect_rejected(cfg, device, unfrozen_resources, map, "unfrozen resources");
		expect_rejected(cfg, device, resources, unfrozen_map, "unfrozen BAR map");
		expect_rejected(cfg, device, other_resources, map, "resource snapshot identity");
		expect_rejected(cfg, device, resources, other_map, "BAR snapshot identity");

		group.name = "pf0_atomic_group";
		group.functions.push_back(message.owner);
		cfg.bar_group_policies.push_back(group);
		expect_rejected(cfg, device, resources, map, "first publication incomplete BAR group");
		cfg.bar_group_policies[0].bar_ids.push_back(0);
		if (!cfg.publish(device, resources, map, why))
			`uvm_fatal("DPU_TABLE_TYPES", {"publication retry failed: ", why})
		if (!cfg.runtime_ready || cfg.messages.size() != 1 || cfg.frozen_messages.size() != 1 ||
			cfg.frozen_bar_groups.size() != 1 || cfg.frozen_messages[0] !== message)
			`uvm_fatal("DPU_TABLE_TYPES", "successful publication lost generated values")

		retry_map = new("retry_map");
		if (!retry_map.initialize(device, 2, why) || !retry_map.freeze(why))
			`uvm_fatal("DPU_TABLE_TYPES", {"retry map preparation failed: ", why})
		cfg.bar_group_policies[0].bar_ids.delete();
		cfg.reg_target = "h0.pf0.bar0";
		expect_rejected(cfg, device, resources, retry_map, "repeat publication incomplete BAR group");
		cfg.bar_group_policies[0].bar_ids.push_back(0);
		cfg.messages[0].address = message.address + 1;
		expect_rejected(cfg, device, resources, retry_map, "repeat publication invalid message");
		cfg.messages[0] = message;
		if (!cfg.publish(device, resources, retry_map, why) || cfg.bar_map != retry_map ||
			cfg.frozen_reg_target != cfg.reg_target)
			`uvm_fatal("DPU_TABLE_TYPES", {"repaired publication did not commit: ", why})
	endfunction

	initial begin
		dpu_env_cfg	cfg;

		if ($bits(dpu_bdf_entry_t) != 32 ||
			$bits(dpu_msix_linear_entry_t) != 64 ||
			$bits(dpu_vtx_entry_t) != 128 ||
			$bits(dpu_vrx_entry_t) != 128 ||
			$bits(dpu_vio_notify_entry_t) != 128) begin
			`uvm_fatal("DPU_TABLE_TYPES", "hardware table widths changed")
		end
		cfg = new("cfg");
		if (cfg.device_cfg == null || cfg.placement_cfg == null)
			`uvm_fatal("DPU_TABLE_TYPES", "DPU authoring inputs missing")
		test_publication();
		$display("DPU_TABLE_TYPES_PASS");
		$finish;
	end
endmodule
