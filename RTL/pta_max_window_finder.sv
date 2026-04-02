
module pta_max_window_finder #(
    parameter DATA_WIDTH    = 16,
    parameter NUM_VALUES    = 2600, 
    parameter ADDR_WIDTH    = $clog2(NUM_VALUES)
)
(
    // input ports
    input  logic                     clk                ,
    input  logic                     rst_n              ,
    input  logic                     start_i            ,
    input  logic [DATA_WIDTH-1:0]    max_value_i        ,
    input  logic [ADDR_WIDTH-1:0]    max_addr_i         ,
    input  logic [DATA_WIDTH-1:0]    threshold_i        ,
    // data Block RAM ports 
    output logic                     mem_rd_en_o        ,
    output logic [ADDR_WIDTH-1:0]    mem_rd_addr_o      ,
    input  logic [DATA_WIDTH-1:0]    mem_rd_data_i      ,
    input  logic                     mem_rd_data_valid_i,
    // output ports 
    output logic [ADDR_WIDTH-1:0]    start_addr_o       ,
    output logic [ADDR_WIDTH-1:0]    end_addr_o         ,
    output logic [ADDR_WIDTH-1:0]    range_count_o      ,
    output logic                     range_valid_o      ,
    output logic                     done_o             ,
    output logic                     busy_o           
);
    // State-Machine enum define 
    typedef enum logic[2:0] {
        ST_IDLE         = 3'b000,
        ST_MEM_READ     = 3'b001,
        ST_MEM_WAIT     = 3'b010,
        ST_START_FIND   = 3'b011, // to find the left boundary of the window
        ST_END_FIND     = 3'b100, // to find the right boundary of the window
        ST_DONE         = 3'b101  // found the window range: hold done_o until start_i deasserts
    } mwf_state_e;
    
    // internal signals 
    logic [ADDR_WIDTH-1:0] counter_cur, counter_nxt;
    logic [ADDR_WIDTH-1:0] addr_start_cur, addr_start_nxt;
    logic [ADDR_WIDTH-1:0] addr_end_cur, addr_end_nxt;
    logic found_start_cur, found_start_nxt;
    logic found_flag_cur, found_flag_nxt;
    logic start_pulse; 
    logic start_q; 
    logic [DATA_WIDTH-1:0]    max_value_r;
    logic [ADDR_WIDTH-1:0]    max_addr_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) start_q <= 1'b0;
        else        start_q <= start_i;
    end

    assign start_pulse = start_i & ~start_q;

    // Regsiter the input max_data_i
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            max_value_r <= '0;
            max_addr_r  <= '0;
        end else if(start_pulse) begin
            max_value_r <= max_value_i;
            max_addr_r  <= max_addr_i;
        end
    end

    // State Machine 
    mwf_state_e mwf_sta_cur, mwf_sta_nxt; 
    //{{{ confirm the current state 
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            mwf_sta_cur     <= ST_IDLE; 
            counter_cur     <= '0; 
            addr_start_cur  <= '0;
            addr_end_cur    <= '0; 
            found_start_cur <= 1'b0; 
            found_flag_cur   <= 1'b0; 
        end else begin
            mwf_sta_cur     <= mwf_sta_nxt;
            counter_cur     <= counter_nxt;
            addr_start_cur  <= addr_start_nxt;
            addr_end_cur    <= addr_end_nxt;
            found_start_cur <= found_start_nxt;
            found_flag_cur   <= found_flag_nxt;
        end
    end
    //}}}
    
    logic start_meets, end_meets; 
    //{{{ confirm the next state
    always_comb begin
        mwf_sta_nxt     = mwf_sta_cur; 
        counter_nxt     = counter_cur; 
        addr_start_nxt  = addr_start_cur; 
        addr_end_nxt    = addr_end_cur; 
        found_start_nxt = found_start_cur; 
        found_flag_nxt  = found_flag_cur;
        mem_rd_en_o     = 1'b0; 
        mem_rd_addr_o   = counter_cur; 
        range_valid_o   = 1'b0;
        start_meets     = 1'b0; 
        end_meets       = 1'b0; 
        case (mwf_sta_cur)
            ST_IDLE: begin
                if(start_pulse) begin
                    mwf_sta_nxt = ST_MEM_READ;
                    counter_nxt = max_addr_i; 
                    found_start_nxt = 1'b0;
                    found_flag_nxt = 1'b0; 
                    addr_start_nxt = max_addr_i;
                end 
            end
            ST_MEM_READ: begin
                mem_rd_en_o = 1'b1;
                mwf_sta_nxt  = ST_MEM_WAIT;
            end
            ST_MEM_WAIT: begin
                if(mem_rd_data_valid_i) begin
                    mwf_sta_nxt = found_start_cur ? ST_END_FIND : ST_START_FIND;
                end
            end
            ST_START_FIND: begin
                if(!start_i) begin
                    mwf_sta_nxt = ST_IDLE;
                end else begin
                    start_meets = chk_fp16_meets_threshold(max_value_r, mem_rd_data_i, threshold_i);
                    $display("start_meets: %0d, max: %0h, data: %0h, threshold: %0h", start_meets, max_value_r, mem_rd_data_i, threshold_i);
                    if(!start_meets) begin
                        addr_start_nxt = counter_cur + 1; 
                        found_start_nxt = 1'b1;
                        counter_nxt = max_addr_r; 
                    end else if (counter_cur == 0) begin
                        addr_start_nxt = 0; 
                        found_start_nxt = 1'b1; 
                        counter_nxt = max_addr_r; 
                    end else begin
                        counter_nxt = counter_cur - 1; 
                        addr_start_nxt = counter_cur - 1;
                    end     
                    mwf_sta_nxt = ST_MEM_READ;
                end
            end 
            ST_END_FIND: begin
                if(!start_i) begin
                    mwf_sta_nxt = ST_IDLE;
                end else begin
                    end_meets = chk_fp16_meets_threshold(max_value_r, mem_rd_data_i, threshold_i);
                    $display("end_meets: %0d, max: %0h, data: %0h, threshold: %0h", end_meets, max_value_r, mem_rd_data_i, threshold_i);
                    if(!end_meets) begin
                        mwf_sta_nxt     = ST_DONE;
                        addr_end_nxt    = counter_cur - 1;
                        found_flag_nxt  = 1'b1; 
                    end else if(counter_cur == (NUM_VALUES - 1)) begin
                        mwf_sta_nxt     = ST_DONE;
                        addr_end_nxt    = NUM_VALUES - 1;
                        found_flag_nxt  = 1'b1; 
                    end else begin
                        counter_nxt     = counter_cur + 1; 
                        addr_end_nxt    = counter_cur + 1;
                        mwf_sta_nxt     = ST_MEM_READ;
                    end
                end
            end
            ST_DONE: begin
                range_valid_o = 1'b1;
                if(!start_i) begin
                    mwf_sta_nxt = ST_IDLE; 
                end
            end 

            default: mwf_sta_nxt = ST_IDLE; 
        endcase
    end
    //}}}

    assign range_count_o  = (found_flag_cur && (addr_end_cur >= addr_start_cur)) ? (addr_end_cur - addr_start_cur + 1) : 0 ; 
    assign start_addr_o   = addr_start_cur; 
    assign end_addr_o     = addr_end_cur; 

    assign done_o         = (mwf_sta_cur == ST_DONE);
    always_comb begin
        case(mwf_sta_cur)
            ST_IDLE, ST_DONE: busy_o = 1'b0;
            default:          busy_o = 1'b1;
        endcase
    end

    //{{{ Function: check whether the data meets the threshold 
    function automatic logic chk_fp16_meets_threshold(
        input logic [15:0] max_val, 
        input logic [15:0] data, 
        input logic [15:0] threshold
    ); 
        // Working variables. 
        logic [4:0]  hi_exp_raw,        lo_exp_raw;
        logic [10:0] hi_manti_full,     lo_manti_full;
        logic [4:0]  hi_exp,            lo_exp;    
        logic [4:0]  exp_diff;
        logic [10:0] lo_manti_shifted;
        logic        guard, round, sticky; 
        logic [11:0] diff;              // 12-bit to hold 11-bit subtraction
        logic [10:0] diff11;            // diff[10:0] passed into normaliser
        logic [4:0]  leading_zero;      // leading-zero count in diff11
        logic        lz_found;          
        logic [4:0]  sub_shift;         // subnormal left-shift amount <- was in inner block
        logic [4:0]  res_exp;
        logic [9:0]  res_mant;
        logic        rne_inc;           // round to nearest even
        logic [15:0] packed_bits;
        
        // max_value equals data 
        if(max_val == data) begin
            $display("equal");
            return 1'b1; 
        end

        //{{{ Unpack inputs 
        hi_exp_raw = max_val[14:10];
        lo_exp_raw = data   [14:10];
        // For subnormals (exp_raw == 0) the implicit bit is 0 
        // and the effective exponent is 1 (not 0).
        hi_manti_full = {(hi_exp_raw != 5'h00), max_val[9:0]};
        lo_manti_full = {(lo_exp_raw != 5'h00), data   [9:0]}; 
        hi_exp  = (hi_exp_raw == 5'h00) ? 5'd1 : hi_exp_raw;
        lo_exp  = (lo_exp_raw == 5'h00) ? 5'd1 : lo_exp_raw;
        //}}}

        //{{{ Align max_value & data
        exp_diff = hi_exp - lo_exp;
        lo_manti_shifted = lo_manti_full; 
        guard = 1'b0; 
        round = 1'b0; 
        sticky = 1'b0;
        if(exp_diff >= 5'd12) begin
            sticky = |lo_manti_full; 
            lo_manti_shifted = '0; 
        end else begin
            for(int i=0; i<11; i++) begin
                if(5'(i) < exp_diff) begin
                    sticky = round | sticky; 
                    round  = guard; 
                    guard  = lo_manti_shifted[0]; 
                    lo_manti_shifted = {1'b0, lo_manti_shifted[10:1]}; 
                end
            end
        end
        //}}}

        // find the leading-zero count 
        diff = {1'b0, hi_manti_full} - {1'b0, lo_manti_shifted};
        diff11 = diff[10:0]; 
        leading_zero = 5'h0; 
        lz_found = 1'b0;
        
        for (int i=10; i>=0; i--) begin
            if(!lz_found) begin
                if(diff11[i]) begin
                    lz_found = 1'b1; 
                end else begin
                    leading_zero = leading_zero + 5'h1; 
                end 
            end
        end

        // Normalise the diff to floating-point format           
        if (hi_exp > leading_zero) begin // Normal
            for(int i=0; i<11; i++) begin
                if(5'(i) < leading_zero) begin
                    diff11 = {diff11[9:0], guard}; 
                    guard   = round; 
                    round   = sticky; 
                    sticky  = 1'b0; 
                end
            end
            res_exp  = hi_exp - leading_zero;
            res_mant = diff11[9:0];   // bit[10] is the implicit 1, discarded
        end else begin // subnormal 
            sub_shift = (hi_exp >= 5'h1) ? (hi_exp - 5'h1) : 5'h0; 
            for (int i=0; i<11; i++) begin
                if(5'(i) < sub_shift) begin
                    diff11 = {diff11[9:0], guard}; 
                    guard   = round; 
                    round   = sticky; 
                    sticky  = 1'b0;
                end
            end
            res_exp  = 5'h00;
            res_mant = diff11[9:0];
        end
        
        // Round to nearest even 
        rne_inc = guard & (round | sticky | res_mant[0]); 
        packed_bits  = {1'b0, res_exp, res_mant} + {15'b0, rne_inc};

        if (packed_bits[14:10] == 5'h1F) begin
            //$display("overflow");
            return 1'b0; // overflow
        end else begin
            //$display("%b", (packed_bits <= threshold));
            return (packed_bits <= threshold);
        end
    endfunction
    //}}}
endmodule 
