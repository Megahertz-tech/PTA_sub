module pta_norm_calc #(
    parameter DATA_WIDTH = 16,
    parameter NUM_VALUES = 2600,
    parameter ADDR_WIDTH = $clog2(NUM_VALUES)
)(
    input  logic                     clk                ,
    input  logic                     rst_n              ,
    input  logic                     start_i            ,
    input  logic [DATA_WIDTH-1:0]    avg_value_i        ,    
    output logic                     mem_rd_en_o        ,
    output logic [ADDR_WIDTH-1:0]    mem_rd_addr_o      ,
    input  logic [DATA_WIDTH-1:0]    mem_rd_data_i      ,
    input  logic                     mem_rd_data_valid_i,    
    output logic                     mem_wr_data_valid_o,
    output logic [DATA_WIDTH-1:0]    mem_wr_data_o      ,
    output logic                     mem_wr_en_o        ,
    output logic [ADDR_WIDTH-1:0]    mem_wr_addr_o      ,    
    output logic                     norm_valid_o       ,
    output logic                     done_o             ,
    output logic                     busy_o                 
);

    //  Local parameters
    localparam int EXP_W   = 5;
    localparam int MANT_W  = 10;
    localparam int FP_BIAS = 15;

    // Division widths
    // Dividend = mA_full << 11  (11 + 11 = 22 bits)
    // Divisor  = mB_full        (11 bits)
    localparam int DIV_W  = 22;   // dividend register width
    localparam int DVSR_W = 11;   // divisor  register width (full mantissa)
    localparam int STEP_W = $clog2(DIV_W);    // step counter width: holds 0..21

    localparam logic [DATA_WIDTH-1:0] FP_ONE  = 16'h3C00; // +1.0 in FP16
    localparam logic [DATA_WIDTH-1:0] FP_ZERO = 16'h0000; // +0.0 in FP16

    //  FSM encoding
    typedef enum logic [3:0] {
        ST_IDLE      = 4'd0,   // wait for start_i rising edge
        ST_MEM_READ  = 4'd1,   // issue one-cycle mem_rd_en_o pulse
        ST_MEM_WAIT  = 4'd2,   // stall until mem_rd_data_valid_i; latch data
        ST_PROCESS   = 4'd3,   // classify special cases, set result or arm divider
        ST_DIV_INIT  = 4'd4,   // latch dividend / divisor; clear quotient / remainder
        ST_DIVIDING  = 4'd5,   // 22-cycle restoring binary long division
        ST_ROUND     = 4'd6,   // compose FP16 result from quotient
        ST_MEM_WRITE = 4'd7,   // write result; advance address
        ST_FAIL      = 4'd8,   // when naninf_seen & result_overflow, normalization fails
        ST_DONE      = 4'd9    // hold until start_i deasserts
    } norm_state_e;

    norm_state_e norm_sta_cur, norm_sta_nxt;

    //{{{ capture the avg input
    //  Rising-edge detector for start_i
    logic start_q, start_pulse;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) start_q <= 1'b0;
        else        start_q <= start_i;
    end
    assign start_pulse = start_i & ~start_q;

    //  Latched average fields  (captured once on start_pulse)
    logic [EXP_W-1:0]  avg_exp_r;    // 5-bit biased exponent
    logic [DVSR_W-1:0] avg_full_r;   // {1'b1, mant_avg} — 11-bit full mantissa
    logic [14:0]       avg_mag_r;    // bits[14:0] for positive-FP16 magnitude compare

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            avg_exp_r  <= '0;
            avg_full_r <= DVSR_W'(11'd1024);  // safe non-zero default
            avg_mag_r  <= '0;
        end else if (start_pulse) begin
            avg_exp_r  <= avg_value_i[14:10];
            avg_full_r <= {1'b1, avg_value_i[9:0]};
            avg_mag_r  <= avg_value_i[14:0];
        end
    end
    //}}}

    //  Address counter
    logic [ADDR_WIDTH-1:0] cur_addr_r;

    //  Latched read-data fields
    //  Registered in ST_MEM_WAIT when mem_rd_data_valid_i fires.
    //  Stable and valid throughout ST_PROCESS … ST_ROUND for the current sample.
    logic [DATA_WIDTH-1:0] val_r;       // raw FP16 sample
    logic [EXP_W-1:0]      val_exp_r;   // 5-bit biased exponent
    logic [DVSR_W-1:0]     val_full_r;  // {1'b1, mant_val} — 11-bit full mantissa
    logic [14:0]           val_mag_r;   // bits[14:0] for comparison

    //  Restoring binary long-division 
    //  Dividend  = {val_full, 11'b0}    (22-bit; mA placed in [21:11])
    //  Divisor   = avg_full             (11-bit mB)
    logic [DIV_W-1:0]  div_dvnd_r;
    logic [DVSR_W-1:0] div_dvsr_r;
    logic [DIV_W-1:0]  div_quot_r;
    logic [DIV_W-1:0]  div_rem_r;
    logic [STEP_W-1:0] div_step_r;   // bit index: 21 → 0

    // Combinational divider step (used in ST_DIVIDING only)
    logic [DIV_W-1:0] div_rem_sh;
    logic             div_qbit;

    always_comb begin
        div_rem_sh = {div_rem_r[DIV_W-2:0], div_dvnd_r[div_step_r]};
        div_qbit   = (div_rem_sh >= DIV_W'(div_dvsr_r));
    end

    //{{{  Special-case classification  
    logic val_is_naninf;   // exp field all-ones
    logic val_is_zero;     // zero or denormal (exp = 0) → treated as +0.0
    logic avg_is_naninf;   // avg exp all-ones → "infinite" average
    logic val_greater_avg; // sample ≥ avg (positive FP16 magnitude compare)
    logic use_divide;      // 
    logic naninf_seen;    // if set, norm fail 

    always_comb begin
        val_is_naninf     = (val_exp_r == {EXP_W{1'b1}});
        val_is_zero       = (val_exp_r == '0);
        avg_is_naninf     = (avg_exp_r == {EXP_W{1'b1}});
        val_greater_avg   = (val_mag_r >= avg_mag_r);

        // Division only when no special case applies and avg is valid normal
        use_divide    = ~val_is_naninf     &
                          ~val_is_zero     &
                          ~avg_is_naninf   &
                          ~val_greater_avg &
                          (avg_exp_r != '0);  // guard: avg must be normal (non-zero)
        naninf_seen   = val_is_naninf | avg_is_naninf;
    end
    //}}}

    //  ROUND-state combinational logic
    //  Converts div_quot_r + stored exponents → FP16 result.
    //
    //  Quotient interpretation 
    //    Q[11]=1 → MSB at bit 11; mantissa = Q[10:1]; exp = BIAS   (15)
    //    Q[11]=0 → MSB at bit 10; mantissa = Q[9:0];  exp = BIAS−1 (14)
    //
    //  Signed 8-bit intermediate is sufficient:
    //    exp range: (1−30) + 14 = −15  to  (30−1) + 15 = 44  fits in int8.
    logic signed [7:0]   rnd_exp_raw;     // exponent before rounding carry
    logic [MANT_W-1:0]   rnd_mant;        // mantissa before rounding
    logic                rnd_rb;          // round bit (first discarded quotient bit)
    logic signed [7:0]   rnd_exp;         // exponent after rounding
    logic [MANT_W-1:0]      rnd_mant_final;     // mantissa after rounding
    logic [DATA_WIDTH-1:0]  rnd_result;         // assembled FP16
    logic                   rnd_result_overflow;// overflow flag

    always_comb begin
        rnd_result_overflow = 1'b0; 
        // decode quotient normalisation 
        if (div_quot_r[11]) begin
            // Q[11]=1: implicit-1 at bit 11; shift off → 10-bit mantissa + round bit
            rnd_mant    = div_quot_r[10:1];
            rnd_rb      = div_quot_r[0];
            rnd_exp_raw = 8'($signed({3'b0, val_exp_r})
                             - $signed({3'b0, avg_exp_r})
                             + 8'sd15);
        end else begin
            // Q[11]=0, Q[10]=1: implicit-1 at bit 10; 10-bit mantissa, no round bit
            rnd_mant    = div_quot_r[9:0];
            rnd_rb      = 1'b0;
            rnd_exp_raw = 8'($signed({3'b0, val_exp_r})
                             - $signed({3'b0, avg_exp_r})
                             + 8'sd14);
        end

        // round-to-nearest-half-up
        if (rnd_rb) begin
            if (&rnd_mant) begin  // all-ones mantissa: carry into exp
                rnd_mant_final = '0;
                rnd_exp        = rnd_exp_raw + 8'sd1;
            end else begin
                rnd_mant_final = MANT_W'(rnd_mant + 1'b1);
                rnd_exp        = rnd_exp_raw;
            end
        end else begin
            rnd_mant_final = rnd_mant;
            rnd_exp        = rnd_exp_raw;
        end

        // exponent bounds → final FP16 
        if (rnd_exp <= 8'sd0) begin
            rnd_result = FP_ZERO;       // underflow: flush to +0.0
        end else if (rnd_exp >= 8'sd31) begin
            rnd_result = FP_ONE;        // overflow:  clamp to +1.0 (should not occur)
            rnd_result_overflow = 1'b1; 
        end else begin
            rnd_result = {1'b0, rnd_exp[EXP_W-1:0], rnd_mant_final};
        end
    end

    //  Result register
    logic [DATA_WIDTH-1:0] result_r;

    //{{{  Next-state logic  
    always_comb begin
        norm_sta_nxt = norm_sta_cur;
        case (norm_sta_cur)
            ST_IDLE:
                norm_sta_nxt = start_pulse ? ST_MEM_READ : ST_IDLE;
            ST_MEM_READ: 
                norm_sta_nxt = start_i ? ST_MEM_WAIT : ST_IDLE;
            ST_MEM_WAIT:
                norm_sta_nxt = mem_rd_data_valid_i ? ST_PROCESS : ST_MEM_WAIT;
            ST_PROCESS: 
                norm_sta_nxt = naninf_seen ? ST_FAIL : (use_divide ? ST_DIV_INIT : ST_MEM_WRITE);
            ST_DIV_INIT:
                norm_sta_nxt = ST_DIVIDING;
            ST_DIVIDING:
                // Process bit [step]; transition after the final (step=0) cycle
                norm_sta_nxt = (div_step_r == '0) ? ST_ROUND : ST_DIVIDING;
            ST_ROUND: 
                norm_sta_nxt = rnd_result_overflow ? ST_FAIL : ST_MEM_WRITE;
            ST_MEM_WRITE:
                norm_sta_nxt = (cur_addr_r == ADDR_WIDTH'(NUM_VALUES-1))
                          ? ST_DONE : ST_MEM_READ;
            ST_FAIL: 
                norm_sta_nxt = start_i ? ST_IDLE : ST_FAIL; 
            ST_DONE:
              // Hold until controller deasserts start_i
              norm_sta_nxt = start_i ? ST_DONE : ST_IDLE;

            default:
              norm_sta_nxt = ST_IDLE;

        endcase
    end
    //}}}

    //  State register
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) norm_sta_cur <= ST_IDLE;
      else        norm_sta_cur <= norm_sta_nxt;
    end

    //{{{  Datapath  (sequential)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_addr_r          <= '0;
            val_r               <= '0;
            val_exp_r           <= '0;
            val_full_r          <= '0;
            val_mag_r           <= '0;
            div_dvnd_r          <= '0;
            div_dvsr_r          <= '0;
            div_quot_r          <= '0;
            div_rem_r           <= '0;
            div_step_r          <= '0;
            result_r            <= FP_ZERO;
            mem_rd_en_o         <= 1'b0;
            mem_rd_addr_o       <= '0;
            mem_wr_en_o         <= 1'b0;
            mem_wr_addr_o       <= '0;
            mem_wr_data_o       <= FP_ZERO;
            mem_wr_data_valid_o <= 1'b0;
        end else begin
            // Default: de-assert all one-cycle pulses
            mem_rd_en_o         <= 1'b0;
            mem_wr_en_o         <= 1'b0;
            mem_wr_data_valid_o <= 1'b0;

            case (norm_sta_cur)
                //  IDLE — reset address counter on each start
                ST_IDLE: begin
                    if (start_pulse)  cur_addr_r <= '0;
                end
                //  MEM_READ — issue one-cycle read request
                ST_MEM_READ: begin
                    mem_rd_en_o   <= 1'b1;
                    mem_rd_addr_o <= cur_addr_r;
                end
                //  MEM_WAIT — hold address; latch sample when valid fires
                ST_MEM_WAIT: begin
                    if (mem_rd_data_valid_i) begin
                        val_r      <= mem_rd_data_i;
                        val_exp_r  <= mem_rd_data_i[14:10];
                        val_full_r <= {1'b1, mem_rd_data_i[9:0]};
                        val_mag_r  <= mem_rd_data_i[14:0];
                    end
                end
                //  Priority:
                //    1. avg NaN/Inf → +0.0  (infinite average; nothing exceeds it)
                //    2. val NaN/Inf → +1.0  (treat as exceeding any finite average)
                //    3. val ≥ avg   → +1.0  (clamp per specification)
                //    4. val zero/denormal → +0.0
                ST_PROCESS: begin
                    if (!use_divide) begin
                        if      (avg_is_naninf)       result_r <= FP_ZERO;
                        else if (val_is_naninf)       result_r <= FP_ONE;
                        else if (val_greater_avg)     result_r <= FP_ONE;
                        else                          result_r <= FP_ZERO;  // zero / denormal
                    end
                end
                //  DIV_INIT — arm the restoring binary divider
                ST_DIV_INIT: begin
                    div_dvnd_r <= DIV_W'({val_full_r, 11'b0});
                    div_dvsr_r <= avg_full_r;
                    div_quot_r <= '0;
                    div_rem_r  <= '0;
                    div_step_r <= STEP_W'(DIV_W - 1);
                end
                //  DIVIDING — one restoring-division step per cycle
                ST_DIVIDING: begin
                    div_rem_r  <= div_qbit
                                  ? (div_rem_sh - DIV_W'(div_dvsr_r))
                                  :  div_rem_sh;
                    div_quot_r <= {div_quot_r[DIV_W-2:0], div_qbit};
                    div_step_r <= div_step_r - 1'b1;
                end
                //  ROUND — register the combinational FP16 conversion result
                ST_ROUND: begin
                    result_r <= rnd_result;
                end
                //  MEM_WRITE — assert write port for one cycle; advance address
                ST_MEM_WRITE: begin
                    mem_wr_en_o         <= 1'b1;
                    mem_wr_addr_o       <= cur_addr_r;
                    mem_wr_data_o       <= result_r;
                    mem_wr_data_valid_o <= 1'b1;

                    if (cur_addr_r != ADDR_WIDTH'(NUM_VALUES-1))
                        cur_addr_r <= cur_addr_r + 1'b1;
                end
                ST_FAIL: ;
                ST_DONE: ;
                default: ;
            endcase
      end
    end
    //}}}

    //  status outputs  (decoded from norm_sta_cur)
    assign done_o       = (norm_sta_cur == ST_DONE) | (norm_sta_cur == ST_FAIL);
    assign norm_valid_o = (norm_sta_cur == ST_DONE);

    always_comb begin
        unique case (norm_sta_cur)
            ST_IDLE, ST_DONE: busy_o = 1'b0;
            default:          busy_o = 1'b1;
        endcase
    end

endmodule : pta_norm_calc


