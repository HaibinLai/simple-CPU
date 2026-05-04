// RV32I - 32位基础整数指令集（完整版本）
const rv32i = {
    name: "RV32I - 基础整数指令集",
    description: "RISC-V 32位基础整数指令集，包含算术、逻辑、内存访问和控制流指令（40条指令）",
    instructions: [
        // ========== 算术指令 ==========
        {
            name: "ADD",
            format: "ADD rd, rs1, rs2",
            encoding: "0000000 rs2[4:0] rs1[4:0] 000 rd[4:0] 0110011",
            description: "将两个寄存器的值相加",
            operation: [
                "1. 读取寄存器rs1和rs2的值",
                "2. 执行32位有符号加法运算", 
                "3. 将结果写入寄存器rd",
                "4. 溢出时结果被截断"
            ],
            usage: ["rd = rs1 + rs2", "基本算术运算", "地址计算"],
            examples: ["ADD x1, x2, x3  # x1 = x2 + x3"],
            exceptions: "无异常产生",
            useCases: ["基本算术", "地址计算", "数组索引"],
            note: "最基本的算术运算指令"
        },
        {
            name: "SUB", 
            format: "SUB rd, rs1, rs2",
            encoding: "0100000 rs2[4:0] rs1[4:0] 000 rd[4:0] 0110011",
            description: "从第一个寄存器值中减去第二个寄存器值",
            operation: [
                "1. 读取寄存器rs1和rs2的值",
                "2. 执行32位减法：rs1 - rs2",
                "3. 将结果写入寄存器rd"
            ],
            usage: ["rd = rs1 - rs2", "减法运算", "指针运算"],
            examples: ["SUB x1, x2, x3  # x1 = x2 - x3"],
            exceptions: "无异常产生",
            useCases: ["基本算术", "指针运算", "比较运算"],
            note: "减法运算，注意操作数顺序"
        },
        {
            name: "ADDI",
            format: "ADDI rd, rs1, imm",
            encoding: "imm[11:0] rs1[4:0] 000 rd[4:0] 0010011",
            description: "寄存器值与12位立即数相加",
            operation: [
                "1. 读取寄存器rs1的值",
                "2. 将12位立即数符号扩展到32位",
                "3. 执行加法运算：rs1 + imm",
                "4. 将结果写入寄存器rd"
            ],
            usage: ["rd = rs1 + imm", "立即数范围：-2048到2047"],
            examples: ["ADDI sp, sp, -16  # 栈指针调整", "ADDI t0, zero, 42  # 加载常数42"],
            exceptions: "无异常产生",
            useCases: ["加载常数", "栈指针调整", "地址偏移"],
            note: "最常用指令之一，可加载小常数"
        },

        // ========== 逻辑指令 ==========
        {
            name: "AND",
            format: "AND rd, rs1, rs2", 
            encoding: "0000000 rs2[4:0] rs1[4:0] 111 rd[4:0] 0110011",
            description: "按位与运算",
            operation: [
                "1. 读取寄存器rs1和rs2的值",
                "2. 对每一位执行逻辑与运算",
                "3. 将结果写入寄存器rd"
            ],
            usage: ["rd = rs1 & rs2", "位掩码操作", "清除特定位"],
            examples: ["AND x1, x2, x3  # 按位与运算"],
            exceptions: "无异常产生",
            useCases: ["位掩码", "清除位", "位运算优化"],
            note: "基本逻辑运算"
        },
        {
            name: "OR",
            format: "OR rd, rs1, rs2",
            encoding: "0000000 rs2[4:0] rs1[4:0] 110 rd[4:0] 0110011", 
            description: "按位或运算",
            operation: [
                "1. 读取寄存器rs1和rs2的值",
                "2. 对每一位执行逻辑或运算",
                "3. 将结果写入寄存器rd"
            ],
            usage: ["rd = rs1 | rs2", "设置特定位", "组合位标志"],
            examples: ["OR x1, x2, x3  # 按位或运算"],
            exceptions: "无异常产生",
            useCases: ["设置位", "组合标志", "位运算"],
            note: "用于设置位标志"
        },
        {
            name: "XOR",
            format: "XOR rd, rs1, rs2",
            encoding: "0000000 rs2[4:0] rs1[4:0] 100 rd[4:0] 0110011",
            description: "按位异或运算", 
            operation: [
                "1. 读取寄存器rs1和rs2的值",
                "2. 对每一位执行逻辑异或运算",
                "3. 将结果写入寄存器rd"
            ],
            usage: ["rd = rs1 ^ rs2", "翻转位", "寄存器清零（自异或）"],
            examples: ["XOR x1, x2, x3  # 异或运算", "XOR x1, x1, x1  # 清零x1"],
            exceptions: "无异常产生", 
            useCases: ["翻转位", "简单加密", "寄存器清零"],
            note: "XOR a,a,a可清零寄存器"
        },
        {
            name: "ANDI",
            format: "ANDI rd, rs1, imm",
            encoding: "imm[11:0] rs1[4:0] 111 rd[4:0] 0010011",
            description: "寄存器值与立即数按位与",
            operation: [
                "1. 读取寄存器rs1的值", 
                "2. 将12位立即数符号扩展",
                "3. 执行按位与运算",
                "4. 将结果写入寄存器rd"
            ],
            usage: ["rd = rs1 & imm", "位掩码操作", "提取位域"],
            examples: ["ANDI x1, x2, 0xFF  # 保留低8位"],
            exceptions: "无异常产生",
            useCases: ["位掩码", "提取位域", "对齐检查"],
            note: "常用于快速位操作"
        },
        {
            name: "ORI", 
            format: "ORI rd, rs1, imm",
            encoding: "imm[11:0] rs1[4:0] 110 rd[4:0] 0010011",
            description: "寄存器值与立即数按位或",
            operation: [
                "1. 读取寄存器rs1的值",
                "2. 将12位立即数符号扩展", 
                "3. 执行按位或运算",
                "4. 将结果写入寄存器rd"
            ],
            usage: ["rd = rs1 | imm", "设置特定位", "加载常数"],
            examples: ["ORI x1, x2, 1  # 设置最低位"],
            exceptions: "无异常产生",
            useCases: ["设置位", "加载常数", "位标志"],
            note: "可用于设置位或加载常数"
        },
        {
            name: "XORI",
            format: "XORI rd, rs1, imm", 
            encoding: "imm[11:0] rs1[4:0] 100 rd[4:0] 0010011",
            description: "寄存器值与立即数按位异或",
            operation: [
                "1. 读取寄存器rs1的值",
                "2. 将12位立即数符号扩展",
                "3. 执行按位异或运算", 
                "4. 将结果写入寄存器rd"
            ],
            usage: ["rd = rs1 ^ imm", "翻转位", "按位取反（imm=-1）"],
            examples: ["XORI x1, x2, -1  # 按位取反"],
            exceptions: "无异常产生",
            useCases: ["翻转位", "按位取反", "简单位运算"],
            note: "XORI rd,rs1,-1等效于按位取反"
        },

        // ========== 移位指令 ==========
        {
            name: "SLL",
            format: "SLL rd, rs1, rs2",
            encoding: "0000000 rs2[4:0] rs1[4:0] 001 rd[4:0] 0110011",
            description: "逻辑左移",
            operation: [
                "1. 读取寄存器rs1的值",
                "2. 读取rs2的低5位作为移位数",
                "3. 执行逻辑左移",
                "4. 将结果写入rd"
            ],
            usage: ["rd = rs1 << rs2[4:0]", "移位数0-31", "乘以2的幂"],
            examples: ["SLL x1, x2, x3  # x1 = x2 << x3"],
            exceptions: "无异常产生",
            useCases: ["乘以2的幂", "位域操作", "地址计算"],
            note: "左移一位等于乘以2"
        },
        {
            name: "SRL",
            format: "SRL rd, rs1, rs2",
            encoding: "0000000 rs2[4:0] rs1[4:0] 101 rd[4:0] 0110011", 
            description: "逻辑右移",
            operation: [
                "1. 读取寄存器rs1的值",
                "2. 读取rs2的低5位作为移位数",
                "3. 执行逻辑右移（零填充）",
                "4. 将结果写入rd"
            ],
            usage: ["rd = rs1 >> rs2[4:0]", "零填充", "除以2的幂"],
            examples: ["SRL x1, x2, x3  # 逻辑右移"],
            exceptions: "无异常产生",
            useCases: ["除以2的幂", "无符号右移", "位域提取"],
            note: "逻辑右移，高位补零"
        },
        {
            name: "SRA",
            format: "SRA rd, rs1, rs2",
            encoding: "0100000 rs2[4:0] rs1[4:0] 101 rd[4:0] 0110011",
            description: "算术右移",
            operation: [
                "1. 读取寄存器rs1的值",
                "2. 读取rs2的低5位作为移位数", 
                "3. 执行算术右移（符号填充）",
                "4. 将结果写入rd"
            ],
            usage: ["rd = rs1 >>> rs2[4:0]", "符号填充", "有符号除法"],
            examples: ["SRA x1, x2, x3  # 算术右移"],
            exceptions: "无异常产生",
            useCases: ["有符号除法", "符号保持", "算术运算"],
            note: "算术右移，保持符号位"
        },
        {
            name: "SLLI",
            format: "SLLI rd, rs1, imm",
            encoding: "0000000 imm[4:0] rs1[4:0] 001 rd[4:0] 0010011",
            description: "立即数逻辑左移",
            operation: [
                "1. 读取寄存器rs1的值",
                "2. 使用5位立即数作为移位数",
                "3. 执行逻辑左移",
                "4. 将结果写入rd"
            ],
            usage: ["rd = rs1 << imm[4:0]", "移位数0-31", "快速乘法"],
            examples: ["SLLI x1, x2, 3  # 左移3位"],
            exceptions: "无异常产生", 
            useCases: ["快速乘法", "地址计算", "位对齐"],
            note: "高效的移位运算"
        },
        {
            name: "SRLI",
            format: "SRLI rd, rs1, imm",
            encoding: "0000000 imm[4:0] rs1[4:0] 101 rd[4:0] 0010011",
            description: "立即数逻辑右移",
            operation: [
                "1. 读取寄存器rs1的值",
                "2. 使用5位立即数作为移位数",
                "3. 执行逻辑右移（零填充）",
                "4. 将结果写入rd"
            ],
            usage: ["rd = rs1 >> imm[4:0]", "零填充", "快速除法"],
            examples: ["SRLI x1, x2, 4  # 右移4位"],
            exceptions: "无异常产生",
            useCases: ["快速除法", "位域提取", "数据对齐"],
            note: "高效的无符号右移"
        },
        {
            name: "SRAI",
            format: "SRAI rd, rs1, imm",
            encoding: "0100000 imm[4:0] rs1[4:0] 101 rd[4:0] 0010011",
            description: "立即数算术右移", 
            operation: [
                "1. 读取寄存器rs1的值",
                "2. 使用5位立即数作为移位数",
                "3. 执行算术右移（符号填充）",
                "4. 将结果写入rd"
            ],
            usage: ["rd = rs1 >>> imm[4:0]", "符号填充", "有符号除法"],
            examples: ["SRAI x1, x2, 2  # 算术右移2位"],
            exceptions: "无异常产生",
            useCases: ["有符号除法", "符号扩展", "算术运算"],
            note: "保持符号的右移运算"
        },

        // ========== 比较指令 ==========
        {
            name: "SLT",
            format: "SLT rd, rs1, rs2",
            encoding: "0000000 rs2[4:0] rs1[4:0] 010 rd[4:0] 0110011",
            description: "有符号比较小于",
            operation: [
                "1. 读取寄存器rs1和rs2的值",
                "2. 执行有符号比较：rs1 < rs2",
                "3. 如果rs1 < rs2则rd=1，否则rd=0"
            ],
            usage: ["rd = (rs1 < rs2) ? 1 : 0", "有符号比较"],
            examples: ["SLT x1, x2, x3  # x1 = (x2 < x3)"],
            exceptions: "无异常产生",
            useCases: ["条件判断", "分支条件", "最值比较"],
            note: "有符号数比较"
        },
        {
            name: "SLTU",
            format: "SLTU rd, rs1, rs2", 
            encoding: "0000000 rs2[4:0] rs1[4:0] 011 rd[4:0] 0110011",
            description: "无符号比较小于",
            operation: [
                "1. 读取寄存器rs1和rs2的值",
                "2. 执行无符号比较：rs1 < rs2", 
                "3. 如果rs1 < rs2则rd=1，否则rd=0"
            ],
            usage: ["rd = (rs1 < rs2) ? 1 : 0", "无符号比较"],
            examples: ["SLTU x1, x2, x3  # 无符号比较"],
            exceptions: "无异常产生",
            useCases: ["无符号比较", "地址比较", "指针运算"],
            note: "无符号数比较"
        },
        {
            name: "SLTI",
            format: "SLTI rd, rs1, imm",
            encoding: "imm[11:0] rs1[4:0] 010 rd[4:0] 0010011",
            description: "有符号立即数比较小于",
            operation: [
                "1. 读取寄存器rs1的值",
                "2. 将立即数符号扩展",
                "3. 执行有符号比较：rs1 < imm",
                "4. 结果写入rd"
            ],
            usage: ["rd = (rs1 < imm) ? 1 : 0", "与常数比较"],
            examples: ["SLTI x1, x2, 100  # x1 = (x2 < 100)"],
            exceptions: "无异常产生",
            useCases: ["常数比较", "范围检查", "条件设置"],
            note: "与立即数的有符号比较"
        },
        {
            name: "SLTIU",
            format: "SLTIU rd, rs1, imm",
            encoding: "imm[11:0] rs1[4:0] 011 rd[4:0] 0010011",
            description: "无符号立即数比较小于",
            operation: [
                "1. 读取寄存器rs1的值",
                "2. 将立即数符号扩展后作无符号比较",
                "3. 执行无符号比较：rs1 < imm",
                "4. 结果写入rd"
            ],
            usage: ["rd = (rs1 < imm) ? 1 : 0", "无符号常数比较"],
            examples: ["SLTIU x1, x2, 100  # 无符号比较"],
            exceptions: "无异常产生",
            useCases: ["无符号比较", "地址范围检查"],
            note: "无符号立即数比较"
        },

        // ========== 加载指令 ==========
        {
            name: "LW",
            format: "LW rd, offset(rs1)",
            encoding: "offset[11:0] rs1[4:0] 010 rd[4:0] 0000011",
            description: "加载32位字",
            operation: [
                "1. 计算地址：rs1 + offset",
                "2. 从内存读取32位数据",
                "3. 写入寄存器rd",
                "4. 地址必须4字节对齐"
            ],
            usage: ["加载32位数据", "地址需要4字节对齐"],
            examples: ["LW x1, 0(sp)  # 从栈加载", "LW x2, 100(x3)  # 偏移加载"],
            exceptions: "地址对齐异常，访问故障",
            useCases: ["变量访问", "数组元素", "结构体字段"],
            note: "最常用的加载指令"
        },
        {
            name: "LH",
            format: "LH rd, offset(rs1)",
            encoding: "offset[11:0] rs1[4:0] 001 rd[4:0] 0000011",
            description: "加载16位半字（符号扩展）",
            operation: [
                "1. 计算地址：rs1 + offset",
                "2. 从内存读取16位数据",
                "3. 符号扩展到32位",
                "4. 写入寄存器rd"
            ],
            usage: ["加载16位有符号数据", "自动符号扩展"],
            examples: ["LH x1, 0(x2)  # 加载半字"],
            exceptions: "地址对齐异常，访问故障",
            useCases: ["16位数据", "短整型", "节省内存"],
            note: "加载半字并符号扩展"
        },
        {
            name: "LHU",
            format: "LHU rd, offset(rs1)", 
            encoding: "offset[11:0] rs1[4:0] 101 rd[4:0] 0000011",
            description: "加载16位半字（零扩展）",
            operation: [
                "1. 计算地址：rs1 + offset",
                "2. 从内存读取16位数据",
                "3. 零扩展到32位",
                "4. 写入寄存器rd"
            ],
            usage: ["加载16位无符号数据", "自动零扩展"],
            examples: ["LHU x1, 0(x2)  # 加载无符号半字"],
            exceptions: "地址对齐异常，访问故障", 
            useCases: ["无符号16位数据", "字符数据"],
            note: "加载半字并零扩展"
        },
        {
            name: "LB",
            format: "LB rd, offset(rs1)",
            encoding: "offset[11:0] rs1[4:0] 000 rd[4:0] 0000011",
            description: "加载8位字节（符号扩展）",
            operation: [
                "1. 计算地址：rs1 + offset",
                "2. 从内存读取8位数据", 
                "3. 符号扩展到32位",
                "4. 写入寄存器rd"
            ],
            usage: ["加载8位有符号数据", "自动符号扩展"],
            examples: ["LB x1, 0(x2)  # 加载字节"],
            exceptions: "访问故障",
            useCases: ["字节数据", "字符处理", "有符号字节"],
            note: "加载字节并符号扩展"
        },
        {
            name: "LBU",
            format: "LBU rd, offset(rs1)",
            encoding: "offset[11:0] rs1[4:0] 100 rd[4:0] 0000011",
            description: "加载8位字节（零扩展）",
            operation: [
                "1. 计算地址：rs1 + offset",
                "2. 从内存读取8位数据",
                "3. 零扩展到32位", 
                "4. 写入寄存器rd"
            ],
            usage: ["加载8位无符号数据", "自动零扩展"],
            examples: ["LBU x1, 0(x2)  # 加载无符号字节"],
            exceptions: "访问故障",
            useCases: ["无符号字节", "字符数据", "二进制数据"],
            note: "加载字节并零扩展"
        },

        // ========== 存储指令 ==========
        {
            name: "SW",
            format: "SW rs2, offset(rs1)",
            encoding: "offset[11:5] rs2[4:0] rs1[4:0] 010 offset[4:0] 0100111",
            description: "存储32位字",
            operation: [
                "1. 计算地址：rs1 + offset",
                "2. 将rs2的32位值写入内存",
                "3. 地址必须4字节对齐"
            ],
            usage: ["存储32位数据", "地址需要4字节对齐"],
            examples: ["SW x1, 0(sp)  # 存储到栈", "SW x2, 100(x3)  # 偏移存储"],
            exceptions: "地址对齐异常，访问故障",
            useCases: ["变量存储", "数组赋值", "结构体更新"],
            note: "最常用的存储指令"
        },
        {
            name: "SH",
            format: "SH rs2, offset(rs1)",
            encoding: "offset[11:5] rs2[4:0] rs1[4:0] 001 offset[4:0] 0100111",
            description: "存储16位半字",
            operation: [
                "1. 计算地址：rs1 + offset",
                "2. 将rs2的低16位写入内存",
                "3. 地址必须2字节对齐"
            ],
            usage: ["存储16位数据", "只存储低16位"],
            examples: ["SH x1, 0(x2)  # 存储半字"],
            exceptions: "地址对齐异常，访问故障",
            useCases: ["16位数据", "短整型", "节省存储"],
            note: "存储寄存器的低16位"
        },
        {
            name: "SB",
            format: "SB rs2, offset(rs1)",
            encoding: "offset[11:5] rs2[4:0] rs1[4:0] 000 offset[4:0] 0100111", 
            description: "存储8位字节",
            operation: [
                "1. 计算地址：rs1 + offset",
                "2. 将rs2的低8位写入内存"
            ],
            usage: ["存储8位数据", "只存储低8位"],
            examples: ["SB x1, 0(x2)  # 存储字节"],
            exceptions: "访问故障",
            useCases: ["字节数据", "字符存储", "二进制数据"],
            note: "存储寄存器的低8位"
        },

        // ========== 分支指令 ==========
        {
            name: "BEQ",
            format: "BEQ rs1, rs2, offset",
            encoding: "offset[12|10:5] rs2[4:0] rs1[4:0] 000 offset[4:1|11] 1100011",
            description: "相等时分支",
            operation: [
                "1. 比较rs1和rs2的值",
                "2. 如果相等，PC = PC + offset",
                "3. 否则继续下一条指令",
                "4. offset为12位，2字节对齐"
            ],
            usage: ["if (rs1 == rs2) 跳转", "条件分支"],
            examples: ["BEQ x1, x2, loop  # 相等时跳转到loop"],
            exceptions: "无异常产生",
            useCases: ["循环控制", "条件判断", "相等比较"],
            note: "最常用的分支指令"
        },
        {
            name: "BNE", 
            format: "BNE rs1, rs2, offset",
            encoding: "offset[12|10:5] rs2[4:0] rs1[4:0] 001 offset[4:1|11] 1100011",
            description: "不等时分支",
            operation: [
                "1. 比较rs1和rs2的值",
                "2. 如果不等，PC = PC + offset",
                "3. 否则继续下一条指令"
            ],
            usage: ["if (rs1 != rs2) 跳转", "不等分支"],
            examples: ["BNE x1, zero, continue  # 非零时继续"],
            exceptions: "无异常产生",
            useCases: ["循环退出", "错误检查", "不等比较"],
            note: "用于不等条件判断"
        },
        {
            name: "BLT",
            format: "BLT rs1, rs2, offset",
            encoding: "offset[12|10:5] rs2[4:0] rs1[4:0] 100 offset[4:1|11] 1100011",
            description: "有符号小于时分支",
            operation: [
                "1. 有符号比较rs1和rs2",
                "2. 如果rs1 < rs2，PC = PC + offset",
                "3. 否则继续下一条指令"
            ],
            usage: ["if (rs1 < rs2) 跳转", "有符号比较"],
            examples: ["BLT x1, x2, less  # x1<x2时跳转"],
            exceptions: "无异常产生",
            useCases: ["有符号比较", "数值排序", "范围检查"],
            note: "有符号数小于比较"
        },
        {
            name: "BGE",
            format: "BGE rs1, rs2, offset",
            encoding: "offset[12|10:5] rs2[4:0] rs1[4:0] 101 offset[4:1|11] 1100011",
            description: "有符号大于等于时分支",
            operation: [
                "1. 有符号比较rs1和rs2",
                "2. 如果rs1 >= rs2，PC = PC + offset", 
                "3. 否则继续下一条指令"
            ],
            usage: ["if (rs1 >= rs2) 跳转", "有符号比较"],
            examples: ["BGE x1, x2, greater  # x1>=x2时跳转"],
            exceptions: "无异常产生", 
            useCases: ["有符号比较", "边界检查", "条件执行"],
            note: "有符号数大于等于比较"
        },
        {
            name: "BLTU",
            format: "BLTU rs1, rs2, offset",
            encoding: "offset[12|10:5] rs2[4:0] rs1[4:0] 110 offset[4:1|11] 1100011",
            description: "无符号小于时分支",
            operation: [
                "1. 无符号比较rs1和rs2",
                "2. 如果rs1 < rs2，PC = PC + offset",
                "3. 否则继续下一条指令"
            ],
            usage: ["if (rs1 < rs2) 跳转", "无符号比较"],
            examples: ["BLTU x1, x2, below  # 无符号小于"],
            exceptions: "无异常产生",
            useCases: ["无符号比较", "地址比较", "指针运算"],
            note: "无符号数小于比较"
        },
        {
            name: "BGEU",
            format: "BGEU rs1, rs2, offset", 
            encoding: "offset[12|10:5] rs2[4:0] rs1[4:0] 111 offset[4:1|11] 1100011",
            description: "无符号大于等于时分支",
            operation: [
                "1. 无符号比较rs1和rs2",
                "2. 如果rs1 >= rs2，PC = PC + offset",
                "3. 否则继续下一条指令"
            ],
            usage: ["if (rs1 >= rs2) 跳转", "无符号比较"],
            examples: ["BGEU x1, x2, above  # 无符号大于等于"],
            exceptions: "无异常产生",
            useCases: ["无符号比较", "地址范围", "指针检查"],
            note: "无符号数大于等于比较"
        },

        // ========== 跳转指令 ==========
        {
            name: "JAL",
            format: "JAL rd, offset",
            encoding: "offset[20|10:1|11|19:12] rd[4:0] 1101111",
            description: "跳转并链接",
            operation: [
                "1. 将PC+4保存到rd寄存器",
                "2. PC = PC + offset",
                "3. offset为20位，2字节对齐"
            ],
            usage: ["无条件跳转", "函数调用", "保存返回地址"],
            examples: ["JAL ra, function  # 调用函数", "JAL x0, label  # 无条件跳转"],
            exceptions: "无异常产生",
            useCases: ["函数调用", "无条件跳转", "循环跳转"],
            note: "可实现函数调用和无条件跳转"
        },
        {
            name: "JALR",
            format: "JALR rd, offset(rs1)",
            encoding: "offset[11:0] rs1[4:0] 000 rd[4:0] 1100111",
            description: "跳转寄存器并链接",
            operation: [
                "1. 计算目标地址：rs1 + offset",
                "2. 将PC+4保存到rd寄存器",
                "3. PC = (rs1 + offset) & ~1",
                "4. 地址最低位清零"
            ],
            usage: ["间接跳转", "函数返回", "动态跳转"],
            examples: ["JALR ra, 0(t0)  # 间接调用", "JALR x0, 0(ra)  # 函数返回"],
            exceptions: "无异常产生",
            useCases: ["函数返回", "间接跳转", "动态调用"],
            note: "支持间接跳转和函数返回"
        },

        // ========== 上位立即数指令 ==========
        {
            name: "LUI",
            format: "LUI rd, imm",
            encoding: "imm[31:12] rd[4:0] 0110111",
            description: "加载上位立即数",
            operation: [
                "1. 将20位立即数放置在rd的高20位",
                "2. 低12位清零",
                "3. rd = imm << 12"
            ],
            usage: ["加载大常数的高位部分", "与ADDI配合加载32位常数"],
            examples: ["LUI x1, 0x12345  # x1 = 0x12345000"],
            exceptions: "无异常产生",
            useCases: ["加载大常数", "地址计算", "常数构造"],
            note: "与ADDI配合可加载任意32位常数"
        },
        {
            name: "AUIPC",
            format: "AUIPC rd, imm",
            encoding: "imm[31:12] rd[4:0] 0010111", 
            description: "PC相对加载上位立即数",
            operation: [
                "1. 将20位立即数左移12位",
                "2. 与当前PC相加",
                "3. rd = PC + (imm << 12)"
            ],
            usage: ["PC相对地址计算", "位置无关代码"],
            examples: ["AUIPC x1, 0x1000  # x1 = PC + 0x1000000"],
            exceptions: "无异常产生", 
            useCases: ["PC相对寻址", "位置无关代码", "GOT访问"],
            note: "用于位置无关代码和PC相对寻址"
        },

        // ========== 系统指令 ==========
        {
            name: "ECALL",
            format: "ECALL",
            encoding: "000000000000 00000 000 00000 1110011",
            description: "环境调用",
            operation: [
                "1. 产生环境调用异常",
                "2. 转移到异常处理程序",
                "3. 用于系统调用"
            ],
            usage: ["系统调用", "陷入内核", "请求服务"],
            examples: ["ECALL  # 系统调用"],
            exceptions: "环境调用异常",
            useCases: ["系统调用", "内核接口", "操作系统服务"],
            note: "用于从用户态调用系统服务"
        },
        {
            name: "EBREAK",
            format: "EBREAK", 
            encoding: "000000000001 00000 000 00000 1110011",
            description: "环境断点",
            operation: [
                "1. 产生断点异常",
                "2. 转移到异常处理程序",
                "3. 用于调试"
            ],
            usage: ["调试断点", "程序暂停", "调试器接口"],
            examples: ["EBREAK  # 断点"],
            exceptions: "断点异常",
            useCases: ["调试断点", "程序调试", "异常测试"],
            note: "用于调试和程序断点"
        },
        {
            name: "FENCE",
            format: "FENCE pred, succ",
            encoding: "0000 pred[3:0] succ[3:0] 00000 000 00000 0001111",
            description: "内存屏障指令",
            operation: [
                "1. 确保内存操作的顺序",
                "2. pred指定前序操作类型",
                "3. succ指定后续操作类型",
                "4. 保证内存一致性"
            ],
            usage: ["内存屏障", "多核同步", "内存顺序"],
            examples: ["FENCE  # 完整内存屏障"],
            exceptions: "无异常产生",
            useCases: ["多核同步", "内存屏障", "原子操作"],
            note: "确保内存操作的可见性和顺序"
        }
    ]
};

// 导出模块
if (typeof module !== 'undefined' && module.exports) {
    module.exports = rv32i;
} else if (typeof window !== 'undefined') {
    window.rv32i = rv32i;
}