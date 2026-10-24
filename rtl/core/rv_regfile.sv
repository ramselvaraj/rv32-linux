module rv_regfile (
  input  logic        clk,
  input  logic [4:0]  rs1_addr,
  input  logic [4:0]  rs2_addr,
  output logic [31:0] rs1_data,
  output logic [31:0] rs2_data,
  input  logic        we,
  input  logic [4:0]  rd_addr,
  input  logic [31:0] rd_data
);

  logic [31:0] regs [1:31];

  always_ff @(posedge clk)
    if (we && rd_addr != 5'd0) regs[rd_addr] <= rd_data;

  // Write-through bypass so a same-cycle WB->ID read sees the new value.
  always_comb begin
    rs1_data = '0;
    rs2_data = '0;
    if (rs1_addr != 5'd0) rs1_data = (we && rd_addr == rs1_addr) ? rd_data : regs[rs1_addr];
    if (rs2_addr != 5'd0) rs2_data = (we && rd_addr == rs2_addr) ? rd_data : regs[rs2_addr];
  end

endmodule
