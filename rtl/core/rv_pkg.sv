package rv_pkg;

  typedef enum logic [3:0] {
    ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU,
    ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR,  ALU_AND
  } alu_op_e;

  typedef enum logic [1:0] {
    PRIV_U = 2'b00,
    PRIV_S = 2'b01,
    PRIV_M = 2'b11
  } priv_e;

  typedef enum logic [1:0] { OPA_RS1, OPA_PC, OPA_ZERO } opa_sel_e;
  typedef enum logic [1:0] { OPB_RS2, OPB_IMM, OPB_FOUR } opb_sel_e;
  typedef enum logic [1:0] { ACC_X, ACC_R, ACC_W } acc_e;

  // Synchronous exception causes
  localparam logic [4:0] EXC_INSN_MISALIGNED  = 5'd0;
  localparam logic [4:0] EXC_INSN_ACCESS      = 5'd1;
  localparam logic [4:0] EXC_ILLEGAL          = 5'd2;
  localparam logic [4:0] EXC_BREAKPOINT       = 5'd3;
  localparam logic [4:0] EXC_LOAD_MISALIGNED  = 5'd4;
  localparam logic [4:0] EXC_LOAD_ACCESS      = 5'd5;
  localparam logic [4:0] EXC_STORE_MISALIGNED = 5'd6;
  localparam logic [4:0] EXC_STORE_ACCESS     = 5'd7;
  localparam logic [4:0] EXC_ECALL_U          = 5'd8;
  localparam logic [4:0] EXC_ECALL_S          = 5'd9;
  localparam logic [4:0] EXC_ECALL_M          = 5'd11;
  localparam logic [4:0] EXC_INSN_PAGE        = 5'd12;
  localparam logic [4:0] EXC_LOAD_PAGE        = 5'd13;
  localparam logic [4:0] EXC_STORE_PAGE       = 5'd15;

  // Interrupt causes
  localparam logic [4:0] IRQ_SSI = 5'd1;
  localparam logic [4:0] IRQ_MSI = 5'd3;
  localparam logic [4:0] IRQ_STI = 5'd5;
  localparam logic [4:0] IRQ_MTI = 5'd7;
  localparam logic [4:0] IRQ_SEI = 5'd9;
  localparam logic [4:0] IRQ_MEI = 5'd11;

  // CSR addresses
  localparam logic [11:0] CSR_SSTATUS    = 12'h100;
  localparam logic [11:0] CSR_SIE        = 12'h104;
  localparam logic [11:0] CSR_STVEC      = 12'h105;
  localparam logic [11:0] CSR_SCOUNTEREN = 12'h106;
  localparam logic [11:0] CSR_SSCRATCH   = 12'h140;
  localparam logic [11:0] CSR_SEPC       = 12'h141;
  localparam logic [11:0] CSR_SCAUSE     = 12'h142;
  localparam logic [11:0] CSR_STVAL      = 12'h143;
  localparam logic [11:0] CSR_SIP        = 12'h144;
  localparam logic [11:0] CSR_SATP       = 12'h180;
  localparam logic [11:0] CSR_MSTATUS    = 12'h300;
  localparam logic [11:0] CSR_MISA       = 12'h301;
  localparam logic [11:0] CSR_MEDELEG    = 12'h302;
  localparam logic [11:0] CSR_MIDELEG    = 12'h303;
  localparam logic [11:0] CSR_MIE        = 12'h304;
  localparam logic [11:0] CSR_MTVEC      = 12'h305;
  localparam logic [11:0] CSR_MCOUNTEREN = 12'h306;
  localparam logic [11:0] CSR_MSTATUSH   = 12'h310;
  localparam logic [11:0] CSR_MCOUNTINHIBIT = 12'h320;
  localparam logic [11:0] CSR_MSCRATCH   = 12'h340;
  localparam logic [11:0] CSR_MEPC       = 12'h341;
  localparam logic [11:0] CSR_MCAUSE     = 12'h342;
  localparam logic [11:0] CSR_MTVAL      = 12'h343;
  localparam logic [11:0] CSR_MIP        = 12'h344;
  localparam logic [11:0] CSR_MCYCLE     = 12'hB00;
  localparam logic [11:0] CSR_MINSTRET   = 12'hB02;
  localparam logic [11:0] CSR_MCYCLEH    = 12'hB80;
  localparam logic [11:0] CSR_MINSTRETH  = 12'hB82;
  localparam logic [11:0] CSR_CYCLE      = 12'hC00;
  localparam logic [11:0] CSR_TIME       = 12'hC01;
  localparam logic [11:0] CSR_INSTRET    = 12'hC02;
  localparam logic [11:0] CSR_CYCLEH     = 12'hC80;
  localparam logic [11:0] CSR_TIMEH      = 12'hC81;
  localparam logic [11:0] CSR_INSTRETH   = 12'hC82;
  localparam logic [11:0] CSR_MVENDORID  = 12'hF11;
  localparam logic [11:0] CSR_MARCHID    = 12'hF12;
  localparam logic [11:0] CSR_MIMPID     = 12'hF13;
  localparam logic [11:0] CSR_MHARTID    = 12'hF14;
  localparam logic [11:0] CSR_MCONFIGPTR = 12'hF15;

  // Decoded instruction control
  typedef struct packed {
    logic        illegal;
    alu_op_e     alu_op;
    opa_sel_e    opa;
    opb_sel_e    opb;
    logic [31:0] imm;
    logic        rs1_used;
    logic        rs2_used;
    logic        rd_we;
    logic        is_branch;
    logic        is_jal;
    logic        is_jalr;
    logic        is_load;
    logic        is_store;
    logic        is_amo;
    logic        is_lr;
    logic        is_sc;
    logic [2:0]  funct3;
    logic [4:0]  funct5;
    logic        is_md;
    logic        is_csr;
    logic        is_ecall;
    logic        is_ebreak;
    logic        is_mret;
    logic        is_sret;
    logic        is_wfi;
    logic        is_sfence;
    logic        is_fencei;
  } ctrl_t;

  // Sv32 PTE flag layout: {D, A, G, U, X, W, R, V}
  // Permission check for a cached translation. priv_u: effective privilege is U.
  function automatic logic pte_ok(input logic [7:0] f, input acc_e acc,
                                  input logic priv_u, input logic sum, input logic mxr);
    logic ok;
    case (acc)
      ACC_X:   ok = f[3];
      ACC_R:   ok = f[1] | (mxr & f[3]);
      default: ok = f[2];
    endcase
    if (priv_u)    ok = ok & f[4];
    else if (f[4]) ok = ok & (acc != ACC_X) & sum;
    if (!f[6])                 ok = 1'b0;   // Svade: A must be set
    if (acc == ACC_W && !f[7]) ok = 1'b0;   //        D must be set for stores
    return ok;
  endfunction

endpackage
