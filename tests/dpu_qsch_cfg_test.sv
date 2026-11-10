// tests：QSCH Function→net 自动/随机映射的聚焦测试，依赖真实 DPU resolver 和 BAR map。
// 本模块持有测试配置及导出的队列值；不分配真实 ring、不伪造 PCIe 完成、不访问 DUT。
// 检查多 Host/PF/VF、不等长队列组、共享 group、所有表的内容/索引及重复查询稳定性。
module dpu_qsch_cfg_test;
	import uvm_pkg::*;
	import dpu_resource_pkg::*;
`ifdef AIP_CMDLINE_SV
	import aip_core_pkg::*;
`endif
	`include "uvm_macros.svh"

	// 将失败立即定位到关联约束；正常测试不依赖捕获或降级 UVM 报错。
	function automatic void check(input bit	ok, input string	why);
		if (!ok) `uvm_fatal("QSCH_TEST", why)
	endfunction

	// 建立两个 Host、各两个 PF 和一个 VF/每 PF；末两项分别禁用和仅 RX。
	// 全局 qid/BDF/BAR 由生产 resolver 分配，后续断言不假定具体放置编号。
	function automatic void fixture(
		output dpu_env_cfg		cfg,
		output dpu_vio_queue_t	queues[$]
	);
		dpu_configuration_resolver	resolver;
		dpu_placement_diagnostic		diagnostic;
		dpu_device_snapshot			device;
		dpu_resource_snapshot		resources;
		dpu_bar_map					map;
		dpu_vio_qpair_binding_t		pairs[$];
		string						why;

		cfg = new("qsch_cfg");
		cfg.hosts        = 2;
		cfg.pfs_per_host = 2;
		cfg.vfs_per_pf   = 1;
		cfg.reg_target   = "h0.pf0.bar0";
		if ($test$plusargs("QSCH_TEST_RANDOM")) begin
			cfg.qsch_topology = DPU_QSCH_RANDOM;
			cfg.qsch_net_id   = "random";
		end
		if ($test$plusargs("QSCH_TEST_MIXED")) begin
			cfg.qsch_net_id   = "random";
			cfg.qsch_group_id = "random";
`ifdef AIP_CMDLINE_SV
			cfg.qsch_net_id = "[0:5]";
`endif
		end
		if ($test$plusargs("QSCH_TEST_MANUAL")) cfg.qsch_topology = DPU_QSCH_MANUAL;
		cfg.load_params();
		foreach (cfg.device_cfg.functions[f]) begin
			dpu_function_key_t		owner;
			dpu_function_policy_t	fp;
			dpu_vio_service_t		service;
			dpu_vio_policy_t		policy;

			owner = cfg.device_cfg.functions[f].key;
			if ($test$plusargs("QSCH_TEST_FIXED")) begin
				cfg.qsch_inputs[dpu_function_key_name(owner)] = '{
					net_id: $sformatf("%0d", 100 + f),
					group_id: $sformatf("%0d", 200 + 2*owner.host_id + f%2),
					dpt: $sformatf("%0d", f%2 ? cfg.qsch_eth_ports + 1-owner.host_id : 0)
				};
			end
			// 后出现的 Function 固定占用 5/0，其余窄域随机请求必须避开它。
			if ($test$plusargs("QSCH_TEST_MIXED") && f == 4)
				cfg.qsch_inputs[dpu_function_key_name(owner)] = '{net_id: "5", group_id: "0", dpt: ""};
			fp = '{key: owner, mode: DPU_HOST_EP, intel_vf: -1, default: 0};
			fp.vport = f;
			cfg.function_policies[dpu_function_key_name(owner)] = fp;
			service.service_key = '{function_key: owner, service_kind: DPU_SERVICE_VIO_NET,
				service_instance_id: 0};
			service.enabled     = f != 6;
			service.tx_enable   = f != 7;
			service.rx_enable   = f == 7;
			service.msix_enable = 0;
			service.qpairs      = 1 + f % 3;
			cfg.add_vio_service(service);
			policy = '{service_key: service.service_key, prefetch_ram: "", default: 0};
			policy.notify_net_pair5 = 1;
			policy.cos             = f % 8;
			policy.net_base        = 64 + f;
			policy.net_stride      = 0;
			policy.group_id        = owner.host_id * 16 + 15;
			policy.eth_ports       = 8;
			cfg.vio_policies[dpu_service_key_name(service.service_key)] = policy;
		end
		resolver = new("resolver");
		check(resolver.resolve(cfg.device_cfg, cfg.placement_cfg, device, resources, diagnostic),
			{"resolve: ", diagnostic.message});
		map = new("map");
		check(map.initialize(device, 1, why) && map.freeze(why), {"BAR map: ", why});
		check(cfg.publish(device, resources, map, why), {"publish: ", why});
		resources.list_vio_bindings(pairs);
		foreach (pairs[p]) begin
			dpu_vio_queue_t	queue;
			dpu_vio_service_t	service;
			dpu_bar_target_t	target;

			service = cfg.services[dpu_service_key_name(pairs[p].service_key)];
			check(map.resolve_function(pairs[p].service_key.function_key, 0, target, why), why);
			queue.snapshot         = device;
			queue.service_key      = pairs[p].service_key;
			queue.qpair            = pairs[p];
			queue.generation       = 1;
			queue.virtio_mode      = 1;
			queue.msix_enable      = 0;
			queue.tx_mode          = service.tx_enable;
			queue.local_qid        = queue.tx_mode ? pairs[p].tx_local_virtqueue_id : pairs[p].rx_local_virtqueue_id;
			queue.queue_size       = 256;
			queue.allocated_qpairs = service.qpairs;
			queue.desc_iova        = 64'h1000_0000 + p * 'h10000;
			queue.notify_address   = target.bar_lease.base;
			queue.notify_bar_base  = target.bar_lease.base;
			queue.notify_bar_size  = target.bar_lease.size;
			queues.push_back(queue);
		end
	endfunction

	// 独立核对表链：Q2TC→N2G→G2P，控制表地址也必须随实际 net_id 改变。
	// 固定例检查明确常数，范围例由独立 EXPECT 参数给边界；不只与 cfg 缓存互相比较。
	function automatic void verify_tables(input dpu_env_cfg	cfg, input dpu_vio_queue_t	queues[$]);
		dpu_cfg_scope		selection;
		dpu_function_key_t	functions[$];
		int unsigned		bars[$];
		dpu_table_kind_e		kinds[$] = '{DPU_TABLE_Q2TC, DPU_TABLE_N2G, DPU_TABLE_G2P,
			DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT};
		dpu_table_item_t		rows[$];
		dpu_table_item_t		again[$];
		int unsigned		net_for_function[string];
		string				owner_for_net[int unsigned];
		int unsigned		group_for_net[int unsigned];
		dpu_qsch_g2p_entry_t	entry_for_group[int unsigned];
		int unsigned		group_for_route[string];
		int unsigned		counts[dpu_table_kind_e];
		int unsigned		tx_count;
		int unsigned		net_low = 0;
		int unsigned		net_high = 1023;
		int unsigned		group_low = 0;
		int unsigned		group_high = 1023;
		int					expected_dpt = -1;
		string				why;

		void'($value$plusargs("QSCH_EXPECT_NET_LOW=%d", net_low));
		void'($value$plusargs("QSCH_EXPECT_NET_HIGH=%d", net_high));
		void'($value$plusargs("QSCH_EXPECT_GROUP_LOW=%d", group_low));
		void'($value$plusargs("QSCH_EXPECT_GROUP_HIGH=%d", group_high));
		void'($value$plusargs("QSCH_EXPECT_DPT=%d", expected_dpt));
		selection = new("all_qsch", cfg.device_snapshot, functions, bars);
		tx_count = 0;
		check(cfg.queue_records(selection, kinds, rows, why), why);
		check(cfg.set_queues(queues, why), {"repeat export: ", why});
		check(cfg.queue_records(selection, kinds, again, why), why);
		check(rows.size() == again.size(), "repeat export changed record count");
		foreach (rows[i]) begin
			check(rows[i] === again[i], "repeat query/export changed random mapping");
			check(cfg.remember_record(rows[i], why), why);
			if (rows[i].ctx.kind == DPU_TABLE_Q2TC) begin
				dpu_qsch_q2tc_entry_t	entry;
				string					name;
				int unsigned			expected_id;

				entry = dpu_qsch_q2tc_entry_t'(rows[i].entry);
				name  = dpu_function_key_name(rows[i].owner);
				check(rows[i].binding.tx_mode && entry.valid, "RX or invalid Q2TC entry");
				check(rows[i].ctx.table_index == rows[i].binding.qpair.global_qpair_id,
					"Q2TC index is not the allocated global qpair");
				check(entry.net_id >= net_low && entry.net_id <= net_high, "net outside requested bounds");
				if (net_for_function.exists(name))
					check(net_for_function[name] == entry.net_id, "one Function split across multiple nets");
				if (owner_for_net.exists(entry.net_id))
					check(owner_for_net[entry.net_id] == name, "different Functions share a net");
				net_for_function[name] = entry.net_id;
				owner_for_net[entry.net_id] = name;
				check(cfg.device_snapshot.get_global_function_id(rows[i].owner, expected_id, why), why);
				check(entry.cos == expected_id % 8, "Q2TC lost service COS");
				if ($test$plusargs("QSCH_TEST_FIXED"))
					check(entry.net_id == 100 + expected_id, "fixed Function net was randomized");
				else if ($test$plusargs("QSCH_TEST_MIXED") && expected_id == 4)
					check(entry.net_id == 5, "random request consumed reserved fixed net");
				else if (cfg.qsch_topology == DPU_QSCH_AUTO && cfg.qsch_net_id == "" &&
					(!cfg.qsch_inputs.exists(name) || cfg.qsch_inputs[name].net_id == ""))
					check(entry.net_id == expected_id, "AUTO net differs from frozen Function ID");
			end
		end
		check(net_for_function.num() == 6, "disabled/RX-only Function generated a net");
		foreach (queues[q]) if (queues[q].tx_mode) tx_count++;
		foreach (cfg.records[key]) begin
			dpu_table_item_t	row;
			int unsigned		net_id;
			bit [63:0]			offset;

			row    = cfg.records[key];
			net_id = net_for_function[dpu_function_key_name(row.owner)];
			counts[row.ctx.kind]++;
			case (row.ctx.kind)
				DPU_TABLE_Q2TC: offset = 'hb10000;
				DPU_TABLE_N2G: begin
					dpu_qsch_n2g_entry_t	entry;

					entry  = dpu_qsch_n2g_entry_t'(row.entry);
					offset = 'hb12000;
					check(entry.valid && row.ctx.table_index == net_id, "N2G not indexed by Q2TC net_id");
					group_for_net[net_id] = entry.group_id;
				end
				DPU_TABLE_G2P: begin
					offset = 'hb14000;
					entry_for_group[row.ctx.table_index] = dpu_qsch_g2p_entry_t'(row.entry);
				end
				DPU_TABLE_SPWRR: begin
					offset = 'hb16000;
					check(row.ctx.table_index == net_id && row.entry == cfg.qsch_spwrr,
						"SPWRR not indexed by Q2TC net_id");
				end
				DPU_TABLE_TC_WEIGHT: begin
					offset = 'hb18000;
					check(row.ctx.table_index == net_id && row.entry == cfg.qsch_tc_weight,
						"TC_WEIGHT not indexed by Q2TC net_id");
				end
			endcase
			check(row.ctx.byte_offset == offset + 4 * row.ctx.table_index,
				"QSCH MMIO offset does not match table index");
		end
		foreach (cfg.device_cfg.functions[f]) begin
			dpu_function_key_t	owner;
			dpu_qsch_g2p_entry_t	entry;
			string				name;
			string				route;
			int unsigned		group_id;

			owner = cfg.device_cfg.functions[f].key;
			name = dpu_function_key_name(owner);
			if (!net_for_function.exists(name)) continue;
			group_id = group_for_net[net_for_function[name]];
			check(group_id >= group_low && group_id <= group_high, "group outside requested bounds");
			check(entry_for_group.exists(group_id), "N2G points at missing G2P");
			entry = entry_for_group[group_id];
			check(entry.valid && entry.lvl2_id == owner.host_id, "lvl2 changed from source Host");
			if (cfg.qsch_topology == DPU_QSCH_MANUAL)
				check(entry.dpt == 8 + owner.host_id, "manual node mapping changed");
			else if (cfg.qsch_dpt == "0" &&
				(!cfg.qsch_inputs.exists(name) || cfg.qsch_inputs[name].dpt == ""))
				check(entry.dpt == 0, "default destination is not ETH0");
			if (expected_dpt >= 0) check(entry.dpt == expected_dpt, "explicit dpt did not reach G2P");
			if ($test$plusargs("QSCH_TEST_FIXED")) begin
				check(group_id == 200 + 2*owner.host_id + f%2, "fixed group was randomized");
				check(entry.dpt == (f%2 ? cfg.qsch_eth_ports + 1-owner.host_id : 0), "node mapping differs");
			end else if ($test$plusargs("QSCH_TEST_MIXED") && f == 4)
				check(group_id == 0, "global random group masked Function fixed group");
			route = $sformatf("h%0d.dpt%0d", owner.host_id, entry.dpt);
			if (group_for_route.exists(route)) check(group_for_route[route] == group_id, "route group not shared");
			group_for_route[route] = group_id;
		end
		check(counts[DPU_TABLE_Q2TC] == tx_count && counts[DPU_TABLE_N2G] == 6 &&
			counts[DPU_TABLE_G2P] == group_for_route.num() && counts[DPU_TABLE_SPWRR] == 6 &&
			counts[DPU_TABLE_TC_WEIGHT] == 6, "table count differs from active Functions/routes");
		if ($test$plusargs("QSCH_TEST_FIXED")) check(group_for_route.num() == 4, "different destinations merged");
	endfunction

	// 正例覆盖默认、固定/随机和参数覆盖；负例通过生产返回值检查，不屏蔽 UVM fatal。
	// 重载候选保持输入、清除旧映射；释放/无 TX 时不能残留调度状态。
	initial begin
		dpu_env_cfg			cfg;
		dpu_env_cfg			candidate;
		dpu_vio_queue_t		queues[$];
		dpu_vio_queue_t		empty[$];
		string				why;

		fixture(cfg, queues);
		if ($test$plusargs("QSCH_TEST_REJECT")) begin
			check(!cfg.set_queues(queues, why) && why != "" && cfg.qsch_nets.num() == 0,
				"invalid request accepted or partial topology published");
			$display("DPU_QSCH_REJECT_PASS: %s", why);
			$finish;
		end
		check(cfg.set_queues(queues, why), why);
		verify_tables(cfg, queues);
`ifdef AIP_CMDLINE_SV
		if ($test$plusargs("QSCH_TEST_RELOAD")) begin
			aip_cmdline_override::set_val("dpu.qsch.net_id", "[700:705]");
			aip_cmdline_override::set_val("dpu.qsch.group_id", "[80:81]");
			aip_cmdline_override::set_val("dpu.qsch.dpt", "1");
		end
`endif
		check(cfg.make_runtime_candidate(candidate, why), why);
		if (!$test$plusargs("QSCH_TEST_RELOAD"))
		check(candidate.qsch_topology == cfg.qsch_topology && candidate.qsch_dpt == cfg.qsch_dpt &&
			candidate.qsch_net_id == cfg.qsch_net_id && candidate.qsch_group_id == cfg.qsch_group_id &&
			candidate.qsch_eth_ports == cfg.qsch_eth_ports && candidate.qsch_inputs == cfg.qsch_inputs,
			"runtime reload lost topology inputs");
		cfg.apply_runtime_candidate(candidate);
		check(cfg.qsch_nets.num() == 0, "reload retained old generated mapping");
		check(cfg.set_queues(queues, why), {"reloaded generation: ", why});
		if ($test$plusargs("QSCH_TEST_RELOAD")) begin
			foreach (cfg.qsch_nets[name])
				check(cfg.qsch_nets[name].net_id inside {[700:705]} &&
					cfg.qsch_nets[name].group_id inside {[80:81]} && cfg.qsch_nets[name].dpt == 1,
					"runtime candidate did not consume current AIP overrides");
			verify_tables(cfg, queues);
		end
		cfg.clear_host_queues(0);
		foreach (cfg.qsch_nets[name]) check(cfg.qsch_nets[name].owner.host_id != 0, "release retained Host net");
		cfg.qsch_mode = 99;
		cfg.qsch_net_id = "1024";
		check(cfg.set_queues(empty, why) && cfg.qsch_nets.num() == 0,
			"empty queues unexpectedly require QSCH");
		$display("DPU_QSCH_CFG_PASS");
		$finish;
	end
endmodule
