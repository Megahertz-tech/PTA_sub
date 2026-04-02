module pta_max_avg #(
    parameter int DATA_WIDTH  = 16,              // must be 16 (IEEE 754 FP16)
    parameter int NUM_VALUES  = 2600,
    parameter int ADDR_WIDTH  = $clog2(NUM_VALUES),
    parameter int WINDOW_SIZE = 20               // maximum runtime window width
)(
    input  logic                  clk                   ,
    input  logic                  rst_n                 ,

    input  logic                  start_i               ,         

    input  logic [ADDR_WIDTH-1:0] max_addr_i            ,      
    input  logic [ADDR_WIDTH-1:0] range_start_i         ,   
    input  logic [ADDR_WIDTH-1:0] range_end_i           ,     
    input  logic [ADDR_WIDTH-1:0] window_size_i         ,   

    output logic                  mem_rd_en_o           ,      
    output logic [ADDR_WIDTH-1:0] mem_rd_addr_o         ,   
    input  logic [DATA_WIDTH-1:0] mem_rd_data_i         ,   
    input  logic                  mem_rd_data_valid_i   , 

    output logic [DATA_WIDTH-1:0] window_avg_o          ,    
    output logic [ADDR_WIDTH-1:0] window_start_o        ,  
    output logic [ADDR_WIDTH-1:0] window_end_o          ,    
    output logic                  window_avg_valid_o        ,   
    output logic                  done_o                ,           
    output logic                  busy_o                    
);

    //  Internal parameter
    // FRAC_BITS = 24 for any positive 16bit normal or denormal floating-point number, there will be no lost precision when converting the float-point to fixed-point representation. 
    localparam int FRAC_BITS   = 24;  // fractional bits in unsigned Q fixed-point
    localparam int ACCUM_WIDTH = 48;  // accumulator / divider register width

    localparam int EXP_WIDTH   = 5;
    localparam int MANT_WIDTH  = 10;
    localparam int FP_BIAS = 15;

    // Divider step counter
    localparam int STEP_WIDTH = $clog2(ACCUM_WIDTH) + 1;   // 7 for ACCUM_WIDTH=48

    // Sample counter
    localparam int CNT_WIDTH  = $clog2(WINDOW_SIZE + 1);   // 5 for WINDOW_SIZE=20

    //  FSM state encoding
    typedef enum logic [3:0] {
        ST_IDLE     = 4'd0,  // wait for start_i rising edge
        ST_CALC_WIN = 4'd1,  // calculate and register window boundaries (1 cycle)
        ST_MEM_READ = 4'd2,  // issue one-cycle mem_rd_en_o pulse
        ST_MEM_WAIT = 4'd3,  // stall until mem_rd_data_valid_i
        ST_ACCUM    = 4'd4,  // convert FP16->fixed, accumulate; --> loop or proceed
        ST_DIV_INIT = 4'd5,  // latch dividend/divisor, clear quotient/remainder
        ST_DIVIDING = 4'd6,  // ACCUM_WIDTH-cycle restoring binary long division
        ST_CONVERT  = 4'd7,  // fixed-point quotient -> FP16 output register
        ST_DONE     = 4'd8   // success: hold done_o until start_i deasserts
    } state_e;

    state_e avg_sta_cur, avg_sta_nxt;

    //  Rising-edge detector for start_i  (level -> internal pulse)
    logic start_q, start_pulse;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) start_q <= 1'b0;
        else        start_q <= start_i;
    end
    assign start_pulse = start_i & ~start_q;

    //  Input capture registers
    //  Latched on start_pulse so upstream can change inputs freely once busy.
    logic [ADDR_WIDTH-1:0] max_addr_r;
    logic [ADDR_WIDTH-1:0] range_start_r;
    logic [ADDR_WIDTH-1:0] range_end_r;
    logic [ADDR_WIDTH-1:0] window_size_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            max_addr_r    <= '0;
            range_start_r <= '0;
            range_end_r   <= '0;
            window_size_r <= ADDR_WIDTH'(1);
        end else if (start_pulse) begin
            max_addr_r    <= max_addr_i;
            range_start_r <= range_start_i;
            range_end_r   <= range_end_i;
            // Clamp window_size to [1, WINDOW_SIZE]:
            //  = 0 would cause divide-by-zero; > WINDOW_SIZE violates parameter.
            if (window_size_i == '0)
                window_size_r <= ADDR_WIDTH'(1);
            else if (window_size_i > ADDR_WIDTH'(WINDOW_SIZE))
                window_size_r <= ADDR_WIDTH'(WINDOW_SIZE);
            else
                window_size_r <= window_size_i;
        end
    end

    //  Window-boundary combinational logic  (uses registered inputs)
    //  place floor(window_size/2) samples BEFORE max_addr, remainder AFTER, then clamp to [range_start, range_end].
    //  This guarantees max_addr is always inside the resulting window.
    logic [ADDR_WIDTH-1:0] half;
    logic [ADDR_WIDTH-1:0] calc_s;    // computed window start
    logic [ADDR_WIDTH:0]   tent_e;    // tentative end (extra bit detects wrap)
    logic [ADDR_WIDTH-1:0] calc_e;    // computed window end

    always_comb begin
        half = window_size_r >> 1;
        // Left boundary: clamp to range_start on underflow
        if (max_addr_r >= range_start_r + half)
            calc_s = max_addr_r - half;
        else
            calc_s = range_start_r;
        // Right boundary: clamp to range_end on overflow
        tent_e = {1'b0, calc_s} + {1'b0, window_size_r} - 1;
        if (tent_e[ADDR_WIDTH] || tent_e[ADDR_WIDTH-1:0] > range_end_r)
            calc_e = range_end_r;
        else
            calc_e = tent_e[ADDR_WIDTH-1:0];
    end

    //  Function: FP16 -> unsigned Q(ACCUM_WIDTH).(FRAC_BITS) fixed-point
    //  Positive values only (sign bit always 0).
    //  NaN / Infinity -> 0 (when called, check nan_seen_r first).
    //  For FRAC_BITS = 24 and normal numbers: shift = exp - 1  in [0, 29].
    //{{{
    function automatic [ACCUM_WIDTH-1:0] fp16_to_fix (
        input logic [DATA_WIDTH-1:0] fp
    );

        logic [EXP_WIDTH-1:0]       exp;
        logic [MANT_WIDTH-1:0]      manti;
        logic [MANT_WIDTH:0]        manti_full;        // 11-bit with implicit leading 1
        logic [ACCUM_WIDTH-1:0] result;
        int                     shift;

        exp = fp[14:10];
        manti = fp[ 9: 0];
        result = '0;
        
        // NaN or ±Infinity 
        if (exp == {EXP_WIDTH{1'b1}}) begin
            result = '0; 
        end 
        // Normal 
        else if (exp > 0) begin
            manti_full = {1'b1, manti};
            shift = int'(exp) + FRAC_BITS - 25; 
            if(shift >= 0) begin
                result = ACCUM_WIDTH'(manti_full) <<  shift;
            end else begin
                result = ACCUM_WIDTH'(manti_full) >>  (-shift);
            end
        end
        // Denormal or ±0.0
        else begin
            if(manti == 0) begin
                result = '0; 
            end else begin
                shift = FRAC_BITS - 24;
                if(shift >= 0) begin
                    result = ACCUM_WIDTH'(manti) <<  shift;
                end else begin
                    result = ACCUM_WIDTH'(manti) >>  (-shift);
                end
            end 
        end
        
        return result;
      
    endfunction
    //}}}

    //  Function: unsigned Q(ACCUM_WIDTH).(FRAC_BITS) fixed-point -> FP16
    //  Overflow  -> +Infinity  (exp all-ones, mantissa zero)
    //  Underflow -> +0.0
      //{{{
      function automatic [DATA_WIDTH-1:0] fix_to_fp16 (
          input logic [ACCUM_WIDTH-1:0] val
      );
          int                     lead_one;
          int                     exp_unbias, exp_bias;
          logic [ACCUM_WIDTH-1:0] aligned;
          logic [MANT_WIDTH-1:0]  manti;
          logic                   round;
          logic [EXP_WIDTH-1:0]   exp;
          logic [DATA_WIDTH-1:0]  result;

          // Priority-encode MSB: iterate low->high; last write wins = highest set bit.
          lead_one = -1;
          for (int i = 0; i < ACCUM_WIDTH; i++) begin
              if (val[i]) lead_one = i;
          end
          // Zero
          if (lead_one < 0) begin
              result = '0;    
          end else begin
              exp_unbias    = lead_one - FRAC_BITS;
              exp_bias      = exp_unbias + FP_BIAS;
              // overflow: +Infinity
              if (exp_bias >= 31) begin
                  result = {1'b0, {EXP_WIDTH{1'b1}}, {MANT_WIDTH{1'b0}} };   
              end 
              // underflow: +0.0
              else if (exp_bias <= 0) begin
                  result = '0;
              end 
              // regular 
              else begin
                  exp     = EXP_WIDTH'(unsigned'(exp_bias));
                  aligned = val << (ACCUM_WIDTH - 1 - lead_one);
                  manti   = aligned[ACCUM_WIDTH-2 -: MANT_WIDTH];
                  round   = aligned[ACCUM_WIDTH - 2 - MANT_WIDTH];
                  
                  // round up: handle mantissa carry-out into exponent
                  if (round) begin                  
                      if (&manti) begin
                          manti = '0;
                          exp = exp + 1'b1;
                          if (exp == {EXP_WIDTH{1'b1}})
                              result = {1'b0, {EXP_WIDTH{1'b1}}, {MANT_WIDTH{1'b0}} };  // rounded to +Inf
                          else
                              result = {1'b0, exp, manti};
                      end else begin
                          result = {1'b0, exp, manti + 1'b1};
                      end
                  end else begin
                      result = {1'b0, exp, manti};
                  end
              end
          end
          
          return result;

      endfunction
      //}}}
    
    //  Datapath registers
    
    logic [ADDR_WIDTH-1:0]  win_s_r;       // registered window start
    logic [ADDR_WIDTH-1:0]  win_e_r;       // registered window end
    logic [ADDR_WIDTH-1:0]  cur_addr_r;    // current SRAM read pointer

    logic [ACCUM_WIDTH-1:0] accum_r;       // fixed-point running sum
    logic [CNT_WIDTH-1:0]   sample_cnt_r;  // count of valid (non-NaN/Inf) samples
    logic                   nan_seen_r;    // at least one NaN/Inf was skipped

    logic [ACCUM_WIDTH-1:0] dv_dividend_r; // latched dividend (accumulator)
    logic [CNT_WIDTH-1:0]   dv_divisor_r;  // latched divisor  (sample_cnt)
    logic [ACCUM_WIDTH-1:0] dv_quotient_r; // accumulating quotient (MSB-first)
    logic [ACCUM_WIDTH-1:0] dv_remainder_r;// partial remainder
    logic [STEP_WIDTH-1:0]  dv_step_r;     // bit index: ACCUM_WIDTH-1 down to 0

    //  Divider: combinational one-step signals  (used inside ST_DIVIDING)
    //  Restoring binary long division, MSB-first:
    //    remainder_shiftifted = { remainder[N-2:0], dividend[step] }
    //    quotient_bit = (remainder_shiftifted >= divisor)
    //    if quotient_bit: remainder <- remainder_shiftifted - divisor
    //    else:            remainder <- remainder_shiftifted
    logic [ACCUM_WIDTH-1:0] div_remainder_shift;
    logic                   div_quotient_bit;

    always_comb begin
        div_remainder_shift = {dv_remainder_r[ACCUM_WIDTH-2:0], dv_dividend_r[dv_step_r]};
        div_quotient_bit   = (div_remainder_shift >= ACCUM_WIDTH'(dv_divisor_r));
    end

    //  Next-state logic  
    always_comb begin
        avg_sta_nxt = avg_sta_cur;
        case (avg_sta_cur)
            ST_IDLE    : avg_sta_nxt = start_pulse             ? ST_CALC_WIN : ST_IDLE;
            ST_CALC_WIN: avg_sta_nxt = ST_MEM_READ;
            ST_MEM_READ: avg_sta_nxt = ST_MEM_WAIT;
            ST_MEM_WAIT: avg_sta_nxt = mem_rd_data_valid_i     ? ST_ACCUM    : ST_MEM_WAIT;
            ST_ACCUM   : avg_sta_nxt = (cur_addr_r == win_e_r) ? ST_DIV_INIT : ST_MEM_READ;
            ST_DIV_INIT: avg_sta_nxt = ST_DIVIDING;
            ST_DIVIDING: avg_sta_nxt = (dv_step_r == '0)       ? ST_CONVERT  : ST_DIVIDING;
            ST_CONVERT : avg_sta_nxt = ST_DONE;
            ST_DONE    : avg_sta_nxt = start_i                 ? ST_DONE     : ST_IDLE;
            default    : avg_sta_nxt = ST_IDLE;
        endcase
    end

    //  State register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) avg_sta_cur <= ST_IDLE;
        else        avg_sta_cur <= avg_sta_nxt;
    end

    //  Datapath  (sequential)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_s_r        <= '0;
            win_e_r        <= '0;
            cur_addr_r     <= '0;
            accum_r        <= '0;
            sample_cnt_r   <= '0;
            nan_seen_r     <= 1'b0;
            dv_dividend_r  <= '0;
            dv_divisor_r   <= '0;
            dv_quotient_r  <= '0;
            dv_remainder_r <= '0;
            dv_step_r      <= '0;
            mem_rd_en_o    <= 1'b0;
            mem_rd_addr_o  <= '0;
            window_avg_o   <= '0;
            window_start_o <= '0;
            window_end_o   <= '0;
        end else begin
            mem_rd_en_o <= 1'b0;   // default: de-assert; overridden in ST_MEM_READ only

            case (avg_sta_cur)
                ST_IDLE: begin
                    if (start_pulse) begin
                        accum_r      <= '0;
                        sample_cnt_r <= '0;
                        nan_seen_r   <= 1'b0;
                    end
                end
                ST_CALC_WIN: begin
                    win_s_r        <= calc_s;
                    win_e_r        <= calc_e;
                    cur_addr_r     <= calc_s;
                    window_start_o <= calc_s;
                    window_end_o   <= calc_e;
                end
                ST_MEM_READ: begin
                    mem_rd_en_o       <= 1'b1;
                    mem_rd_addr_o     <= cur_addr_r;
                end
                ST_MEM_WAIT: ;
                ST_ACCUM: begin
                    if (mem_rd_data_i[14:10] == {EXP_WIDTH{1'b1}}) begin
                        nan_seen_r      <= 1'b1;          // NaN or +/-Inf: exclude, record
                    end else begin
                        accum_r         <= accum_r + fp16_to_fix(mem_rd_data_i);
                        sample_cnt_r    <= sample_cnt_r + 1'b1;
                    end
                    // Advance read pointer for the next fetch (if more samples remain)
                    if (cur_addr_r != win_e_r)
                        cur_addr_r      <= cur_addr_r + 1'b1;
                end
                ST_DIV_INIT: begin
                    dv_dividend_r     <= accum_r;
                    dv_divisor_r      <= (sample_cnt_r == '0) ? CNT_WIDTH'(1) : sample_cnt_r;
                    dv_quotient_r     <= '0;
                    dv_remainder_r    <= '0;
                    dv_step_r         <= STEP_WIDTH'(ACCUM_WIDTH - 1);   // begin at MSB of dividend
                end
                ST_DIVIDING: begin
                    dv_remainder_r    <= div_quotient_bit
                                          ? (div_remainder_shift - ACCUM_WIDTH'(dv_divisor_r))
                                          :  div_remainder_shift;
                    dv_quotient_r     <= {dv_quotient_r[ACCUM_WIDTH-2:0], div_quotient_bit};
                    dv_step_r         <= dv_step_r - 1'b1;
                end
                ST_CONVERT: begin
                    window_avg_o      <= fix_to_fp16(dv_quotient_r);
                end
                ST_DONE: ;
                default: ;
            endcase
        end
    end

    // status outputs  (decoded directly from current state)
    always_comb begin
        case (avg_sta_cur)
            ST_IDLE, ST_DONE: busy_o = 1'b0;
            default:          busy_o = 1'b1;
        endcase
    end

    assign done_o             = (avg_sta_cur == ST_DONE);
    assign window_avg_valid_o = (avg_sta_cur == ST_DONE) && (!nan_seen_r);

endmodule : pta_max_avg

