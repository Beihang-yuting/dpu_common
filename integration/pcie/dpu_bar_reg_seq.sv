// integration/pcie：供 AIP reg_acc 使用的 PF0 BAR0 相对地址访问 sequence。
// 继承 pcie_tl_reg_seq 的命令字段；依赖 dpu_cfg 中真实 BAR registry 和 RC sequencer。
// cfg 由用户赋值或从启动 sequencer 的 dpu_cfg 获取；本类借用句柄，不分配或配置 DUT 资源。
// addr 始终是 Host0/PF0 BAR0 内偏移，完整请求先检查范围，再交原生 seq 发送 Memory TLP。
// 每次执行清空输出；失败通过 status/error_msg 返回 Tcl，不 fatal、不累加修改 addr。
class dpu_bar_reg_seq extends pcie_tl_reg_seq;
	`uvm_object_utils(dpu_bar_reg_seq)

	dpu_env_cfg	cfg;

	// 保留原寄存器命令默认宽度和 byte skip-mask 语义。
	extern function new(string	name = "dpu_bar_reg_seq");
	// 解析真实 BAR0 基址和 Host0 RC，原样传递读写字段并回传结果；不启动 DUT 配置流程。
	extern virtual task body();
endclass

// 输入默认值沿用 pcie_tl_reg_seq，cfg 初始为空便于直接使用已有 dpu_cfg 注册。
function dpu_bar_reg_seq::new(string	name);
	super.new(name);
endfunction

// 整个 len 范围在发送前校验，包括 masked 字节；posted 写成功仅表示发送完成。
// 显式 new 原生子 seq，避免用户把父类 factory override 到本类后递归创建包装层。
task dpu_bar_reg_seq::body();
	dpu_bar_target_t				target;
	bit [63:0]						absolute_address;
	pcie_tl_reg_seq					request;
	dpu_pcie_bar_map				map;

	uvm_sequencer #(pcie_tl_tlp)	sequencer;

	rdata     = '0;
	status    = PCIE_RW_OK;
	error_msg = "";
	issued_tlps.delete();
	if (!validate_request()) return;
	status = PCIE_RW_ERR;
	if (cfg == null) begin
		if (m_sequencer == null) begin
			error_msg = "PF0 BAR0 access requires cfg or a sequencer with dpu_cfg";
			return;
		end
		if (!uvm_config_db#(dpu_env_cfg)::get(m_sequencer, "", "dpu_cfg", cfg) || cfg == null) begin
			error_msg = "PCIe sequencer has no dpu_cfg";
			return;
		end
	end
	if (cfg.bar_map == null) begin
		error_msg = "PF0 BAR0 registry has not been published";
		return;
	end
	if (!cfg.bar_map.resolve_name("h0.pf0.bar0", target, error_msg)) return;
	if (!cfg.bar_map.check_range(target, addr, len, absolute_address, error_msg)) return;
	if (!$cast(map, cfg.bar_map) || map == null) begin
		error_msg = "DPU cfg has no PCIe BAR map";
		return;
	end
	if (!map.get_sequencer(target, sequencer, error_msg)) return;

	`uvm_info("PROJECT_REG_ACC",
			  $sformatf(
				  "h0.pf0.bar0 base=0x%016h + offset=0x%016h = address=0x%016h len=%0d write=%0b",
				  target.bar_lease.base, addr, absolute_address, len, is_write), UVM_LOW)
	request                 = new("pf0_bar0_request");
	request.is_write        = is_write;
	request.addr            = absolute_address;
	request.len             = len;
	request.mask            = mask;
	request.wdata           = wdata;
	request.rb_timeout_ns   = rb_timeout_ns;
	request.check_read_data = check_read_data;
	request.start(sequencer, this);
	rdata       = request.rdata;
	status      = request.status;
	error_msg   = request.error_msg;
	issued_tlps = request.issued_tlps;
endtask
