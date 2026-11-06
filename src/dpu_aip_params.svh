/*
 * 所属层次：src/ authoring 参数加载的文本宏层。
 * 文件职责：补足旧 aip_int 的无符号负值检查，并检测集合是否具有显式覆盖。
 * 主要依赖：先编译 aip_core_pkg，再由 dpu_resource_pkg 在 AIP_CMDLINE_SV 下包含。
 * 所有权与生命周期：无全局状态；临时变量只在调用方 load_params 的块中存活。
 * 集合没有覆盖时不调用 AIP 的容器重建接口，避免清空当前默认值；检测不消费 RNG。
 */
`ifndef DPU_AIP_PARAMS_SVH
`define DPU_AIP_PARAMS_SVH

// 旧标量解析器允许负值转换为无符号数；此处在唯一一次抽样之前拒绝负数字面量。
// 整数表达式里的减号只用于负数（inc/dec 的步长必须为正），因此不会拒绝合法运算。
// 位宽及所有候选的格式仍由真实 aip_int API 校验，公开参数名由 NAME 决定。
`define DPU_AIP_UINT(PATH, TYPE, NAME, DEFAULT) \
    begin \
        string	_dpu_raw; \
        _dpu_raw = aip_cmdline#(TYPE)::get_cmdline_string(`"NAME`", PATH); \
        if (aip_str::str_find(_dpu_raw, "-") >= 0) \
            $fatal(1, "DPU_PARAMS: %s.%s requires an unsigned value: %s", PATH, `"NAME`", _dpu_raw); \
        `aip_int(PATH, TYPE, NAME, DEFAULT) \
    end

// 精确匹配集合本身、索引或控制字段；同时支持 AIP 的完整路径和无路径叶名回退。
// FOUND 由调用方声明。仅枚举当前 CLI/override 的键，不求值，不创建或复制业务对象。
`define DPU_AIP_SCAN(PATH, NAME, FOUND, CHECK_UNSIGNED) \
    begin \
        string	_dpu_args[$]; \
        string	_dpu_keys[$]; \
        string	_dpu_roots[$]; \
        string	_dpu_key; \
        string	_dpu_suffix; \
        string	_dpu_value; \
        bit	_dpu_match; \
        uvm_cmdline_processor	_dpu_clp; \
        FOUND = 0; \
        _dpu_roots.push_back({PATH, ".", NAME}); \
        _dpu_roots.push_back(NAME); \
        _dpu_clp = aip_cmdline_source::get(); \
        _dpu_clp.get_plusargs(_dpu_args); \
        aip_cmdline_override::get_keys(_dpu_keys); \
        foreach (_dpu_args[_dpu_i]) begin \
            int	_dpu_eq; \
            _dpu_eq = aip_str::str_find(_dpu_args[_dpu_i], "="); \
            if (_dpu_eq > 1) _dpu_keys.push_back(_dpu_args[_dpu_i].substr(1, _dpu_eq-1)); \
        end \
        foreach (_dpu_keys[_dpu_i]) begin \
            _dpu_key = _dpu_keys[_dpu_i]; \
            foreach (_dpu_roots[_dpu_j]) begin \
                int	_dpu_n; \
                _dpu_n = _dpu_roots[_dpu_j].len(); \
                _dpu_match = (_dpu_key == _dpu_roots[_dpu_j]); \
                if (_dpu_key.len() > _dpu_n && _dpu_key.substr(0, _dpu_n-1) == _dpu_roots[_dpu_j] && \
                         (_dpu_key[_dpu_n] == "." || _dpu_key[_dpu_n] == "[")) _dpu_match = 1; \
                if (_dpu_match) begin \
                    FOUND = 1; \
                    if (CHECK_UNSIGNED) begin \
                        _dpu_suffix = (_dpu_key.len() == _dpu_n) ? "" : _dpu_key.substr(_dpu_n); \
                        _dpu_value = aip_cmdline#(int)::get_cmdline_string({NAME, _dpu_suffix}, PATH); \
                        if (aip_str::str_find(_dpu_value, "-") >= 0) \
                            $fatal(1, "DPU_PARAMS: %s.%s%s contains a negative unsigned input: %s", PATH, NAME, _dpu_suffix, _dpu_value); \
                    end \
                end \
            end \
        end \
    end
// 存在性检查只读键；无符号集合预检还拒绝整体/索引/each 中的负值。
// 预检重新查询获胜值，因此被合法 override 覆盖的旧 CLI 文本不会误报；不执行随机求值。
`define DPU_AIP_PRESENT(PATH, NAME, FOUND) \
    `DPU_AIP_SCAN(PATH, NAME, FOUND, 0)

`define DPU_AIP_UNSIGNED_QUEUE(PATH, NAME) \
    begin \
        bit	_dpu_present; \
        `DPU_AIP_SCAN(PATH, NAME, _dpu_present, 1) \
    end
`endif // DPU_AIP_PARAMS_SVH
