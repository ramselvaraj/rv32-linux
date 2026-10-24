module rv_alu
  import rv_pkg::*;
(
  input  alu_op_e     op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] y
);

  always_comb begin
    unique case (op)
      ALU_ADD:  y = a + b;
      ALU_SUB:  y = a - b;
      ALU_SLL:  y = a << b[4:0];
      ALU_SLT:  y = {31'b0, $signed(a) < $signed(b)};
      ALU_SLTU: y = {31'b0, a < b};
      ALU_XOR:  y = a ^ b;
      ALU_SRL:  y = a >> b[4:0];
      ALU_SRA:  y = 32'($signed(a) >>> b[4:0]);
      ALU_OR:   y = a | b;
      ALU_AND:  y = a & b;
      default:  y = '0;
    endcase
  end

endmodule
