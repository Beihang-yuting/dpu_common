// dpu_common public short names.
// These aliases keep the canonical names available for existing users while
// making env/config/sequence declarations easier to read.

// Runtime objects.
typedef dpu_env_cfg		dpu_cfg;
typedef dpu_device_cfg		dpu_dev_cfg;
typedef dpu_device_snapshot	dpu_dev_snap;
typedef dpu_resource_snapshot	dpu_res_snap;
typedef dpu_resource_manager	dpu_res_mgr;
typedef dpu_device_env		dpu_dev_env;
typedef dpu_bar_map		dpu_bars;
typedef dpu_dut_caps		dpu_caps;

// Device identity and resource values.
typedef dpu_function_key_t	dpu_func_key_t;
typedef dpu_service_key_t	dpu_svc_key_t;
typedef dpu_pcie_function_id_t	dpu_pcie_id_t;
typedef dpu_host_info_t		dpu_host_t;
typedef dpu_bar_pair_lease_t	dpu_bar_lease_t;

// Public table-selection and layout values.
typedef dpu_cfg_scope		dpu_scope;
typedef dpu_table_item_t	dpu_table_t;
typedef dpu_table_layout_t	dpu_layout_t;

// Packed hardware entries.
typedef dpu_vtx_entry_t	dpu_vtx_t;
typedef dpu_vrx_entry_t	dpu_vrx_t;
typedef dpu_vio_notify_entry_t	dpu_notify_t;
typedef dpu_qsch_q2tc_entry_t	dpu_q2tc_t;
typedef dpu_qsch_n2g_entry_t	dpu_n2g_t;
typedef dpu_qsch_g2p_entry_t	dpu_g2p_t;
