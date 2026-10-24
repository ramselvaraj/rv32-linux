module rv_decode
  import rv_pkg::*;
(
  input  logic [31:0] insn,
  output ctrl_t       c
);

  logic [6:0]  opcode;
  logic [2:0]  f3;
  logic [6:0]  f7;
  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
  logic        bad;

  assign opcode = insn[6:0];
  assign f3     = insn[14:12];
  assign f7     = insn[31:25];

  assign imm_i = {{20{insn[31]}}, insn[31:20]};
  assign imm_s = {{20{insn[31]}}, insn[31:25], insn[11:7]};
  assign imm_b = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
  assign imm_u = {insn[31:12], 12'b0};
  assign imm_j = {{11{insn[31]}}, insn[31], insn[19:12], insn[20], insn[30:21], 1'b0};

  always_comb begin
    c        = '0;
    bad      = 1'b0;
    c.alu_op = ALU_ADD;
    c.opa    = OPA_RS1;
    c.opb    = OPB_IMM;
    c.imm    = imm_i;
    c.funct3 = f3;
    c.funct5 = insn[31:27];

    case (opcode)
      7'b0110111: begin  // LUI
        c.opa = OPA_ZERO; c.imm = imm_u; c.rd_we = 1'b1;
      end
      7'b0010111: begin  // AUIPC
        c.opa = OPA_PC; c.imm = imm_u; c.rd_we = 1'b1;
      end
      7'b1101111: begin  // JAL
        c.is_jal = 1'b1; c.opa = OPA_PC; c.opb = OPB_FOUR; c.imm = imm_j; c.rd_we = 1'b1;
      end
      7'b1100111: begin  // JALR
        if (f3 == 3'b000) begin
          c.is_jalr = 1'b1; c.rs1_used = 1'b1; c.opa = OPA_PC; c.opb = OPB_FOUR; c.rd_we = 1'b1;
        end else bad = 1'b1;
      end
      7'b1100011: begin  // BRANCH
        c.is_branch = 1'b1; c.rs1_used = 1'b1; c.rs2_used = 1'b1; c.imm = imm_b;
        if (f3 == 3'b010 || f3 == 3'b011) bad = 1'b1;
      end
      7'b0000011: begin  // LOAD
        c.is_load = 1'b1; c.rs1_used = 1'b1; c.rd_we = 1'b1;
        if (f3 == 3'b011 || f3 == 3'b110 || f3 == 3'b111) bad = 1'b1;
      end
      7'b0100011: begin  // STORE
        c.is_store = 1'b1; c.rs1_used = 1'b1; c.rs2_used = 1'b1; c.imm = imm_s;
        if (f3 > 3'b010) bad = 1'b1;
      end
      7'b0010011: begin  // OP-IMM
        c.rs1_used = 1'b1; c.rd_we = 1'b1;
        case (f3)
          3'b000: c.alu_op = ALU_ADD;
          3'b010: c.alu_op = ALU_SLT;
          3'b011: c.alu_op = ALU_SLTU;
          3'b100: c.alu_op = ALU_XOR;
          3'b110: c.alu_op = ALU_OR;
          3'b111: c.alu_op = ALU_AND;
          3'b001: begin
            c.alu_op = ALU_SLL;
            if (f7 != 7'b0000000) bad = 1'b1;
          end
          default: begin  // 3'b101
            c.alu_op = f7[5] ? ALU_SRA : ALU_SRL;
            if (f7 != 7'b0000000 && f7 != 7'b0100000) bad = 1'b1;
          end
        endcase
      end
      7'b0110011: begin  // OP
        c.rs1_used = 1'b1; c.rs2_used = 1'b1; c.rd_we = 1'b1; c.opb = OPB_RS2;
        if (f7 == 7'b0000001) begin
          c.is_md = 1'b1;
        end else if (f7 == 7'b0000000 || (f7 == 7'b0100000 && (f3 == 3'b000 || f3 == 3'b101))) begin
          case (f3)
            3'b000: c.alu_op = f7[5] ? ALU_SUB : ALU_ADD;
            3'b001: c.alu_op = ALU_SLL;
            3'b010: c.alu_op = ALU_SLT;
            3'b011: c.alu_op = ALU_SLTU;
            3'b100: c.alu_op = ALU_XOR;
            3'b101: c.alu_op = f7[5] ? ALU_SRA : ALU_SRL;
            3'b110: c.alu_op = ALU_OR;
            default: c.alu_op = ALU_AND;
          endcase
        end else bad = 1'b1;
      end
      7'b0101111: begin  // AMO
        if (f3 == 3'b010) begin
          c.rs1_used = 1'b1; c.rd_we = 1'b1; c.imm = 32'd0;
          case (insn[31:27])
            5'b00010: begin
              c.is_lr = 1'b1;
              if (insn[24:20] != 5'd0) bad = 1'b1;
            end
            5'b00011: begin c.is_sc = 1'b1; c.rs2_used = 1'b1; end
            5'b00001, 5'b00000, 5'b00100, 5'b01100, 5'b01000,
            5'b10000, 5'b10100, 5'b11000, 5'b11100: begin
              c.is_amo = 1'b1; c.rs2_used = 1'b1;
            end
            default: bad = 1'b1;
          endcase
        end else bad = 1'b1;
      end
      7'b0001111: begin  // MISC-MEM
        if (f3 == 3'b000)      c.is_fencei = 1'b0;  // FENCE: no-op
        else if (f3 == 3'b001) c.is_fencei = 1'b1;
        else                   bad = 1'b1;
      end
      7'b1110011: begin  // SYSTEM
        if (f3 == 3'b000) begin
          if      (insn == 32'h0000_0073) c.is_ecall  = 1'b1;
          else if (insn == 32'h0010_0073) c.is_ebreak = 1'b1;
          else if (insn == 32'h3020_0073) c.is_mret   = 1'b1;
          else if (insn == 32'h1020_0073) c.is_sret   = 1'b1;
          else if (insn == 32'h1050_0073) c.is_wfi    = 1'b1;
          else if (f7 == 7'b0001001 && insn[11:7] == 5'd0) c.is_sfence = 1'b1;
          else bad = 1'b1;
        end else if (f3 == 3'b100) begin
          bad = 1'b1;
        end else begin
          c.is_csr = 1'b1; c.rd_we = 1'b1; c.rs1_used = ~f3[2];
        end
      end
      default: bad = 1'b1;
    endcase

    if (bad) begin
      c         = '0;
      c.alu_op  = ALU_ADD;
      c.illegal = 1'b1;
    end
  end

endmodule
