// Multiply (2 cycles) and restoring divide (34 cycles) for the X stage.
// req is a level held by the pipeline while it sits in X; ack releases the result.
module rv_muldiv (
  input  logic        clk,
  input  logic        rst,
  input  logic        req,
  input  logic [2:0]  funct3,
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        ack,
  input  logic        kill,
  output logic        done,
  output logic [31:0] result
);

  typedef enum logic [1:0] { S_IDLE, S_MUL, S_DIV, S_DONE } state_e;

  state_e       state_q;
  logic [2:0]   f3_q;
  logic [31:0]  a_q, b_q;

  // multiply
  logic signed [32:0] a_ext, b_ext;
  logic signed [65:0] prod;
  logic [31:0]        mul_res;

  assign a_ext   = {(f3_q == 3'b011) ? 1'b0 : a_q[31], a_q};
  assign b_ext   = {(f3_q == 3'b001) ? b_q[31] : 1'b0, b_q};
  assign prod    = a_ext * b_ext;
  assign mul_res = (f3_q == 3'b000) ? prod[31:0] : prod[63:32];

  // divide
  logic        div_signed, neg_q, neg_r, by_zero;
  logic [31:0] dvd_abs, dvs_abs;
  logic [31:0] rem_q, quo_q, dvs_q;
  logic [5:0]  cnt_q;
  logic [32:0] shifted;
  logic [31:0] res_q;

  // operands are taken from the live inputs when the op is latched, so the
  // signedness must come from funct3 as well (f3_q still holds the previous op)
  assign div_signed = ~funct3[0];                     // DIV/REM are signed
  assign dvd_abs    = (div_signed && a[31]) ? -a : a;
  assign dvs_abs    = (div_signed && b[31]) ? -b : b;
  assign shifted    = {rem_q, quo_q[31]};

  always_ff @(posedge clk) begin
    if (rst || kill) begin
      state_q <= S_IDLE;
    end else begin
      case (state_q)
        S_IDLE: if (req) begin
          f3_q <= funct3;
          a_q  <= a;
          b_q  <= b;
          if (!funct3[2]) state_q <= S_MUL;
          else begin
            state_q <= S_DIV;
            rem_q   <= 32'd0;
            quo_q   <= dvd_abs;
            dvs_q   <= dvs_abs;
            cnt_q   <= 6'd0;
            by_zero <= (b == 32'd0);
            neg_q   <= (funct3[1] == 1'b0) && !funct3[0] && (a[31] ^ b[31]) && (b != 32'd0);
            neg_r   <= (funct3[1] == 1'b1) && !funct3[0] && a[31];
          end
        end
        S_MUL: if (ack) state_q <= S_IDLE;
        S_DIV: begin
          if (shifted >= {1'b0, dvs_q}) begin
            rem_q <= shifted[31:0] - dvs_q;
            quo_q <= {quo_q[30:0], 1'b1};
          end else begin
            rem_q <= shifted[31:0];
            quo_q <= {quo_q[30:0], 1'b0};
          end
          cnt_q <= cnt_q + 6'd1;
          if (cnt_q == 6'd31) state_q <= S_DONE;
        end
        S_DONE: if (ack) state_q <= S_IDLE;
        default: state_q <= S_IDLE;
      endcase
    end
  end

  always_comb begin
    if (f3_q[1]) res_q = neg_r ? -rem_q : rem_q;        // REM / REMU
    else         res_q = by_zero ? 32'hFFFF_FFFF : (neg_q ? -quo_q : quo_q);
  end

  assign done   = (state_q == S_MUL) || (state_q == S_DONE);
  assign result = (state_q == S_MUL) ? mul_res : res_q;

endmodule
