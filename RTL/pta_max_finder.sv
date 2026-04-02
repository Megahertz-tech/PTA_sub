/*  Module: pta_max_finder 
    
    Find the maximum from `NUM_VALUES` `DATA_WIDTH`-bit float-point number sets (for example 2600 16-bit float-point samples.) 

    Parameters: 
        DATA_WIDTH - float-point number precision 
        NUM_VALUES - number of the float-point number sets
*/

module pta_max_finder #(
    parameter DATA_WIDTH = 16,
    parameter NUM_VALUES = 2600, 
    parameter ADDR_WIDTH = $clog2(NUM_VALUES)
)(
    // input ports 
    input  logic                     clk          ,
    input  logic                     rst_n        ,
    input  logic                     start_i      ,
    input  logic                     data_valid_i ,
    input  logic [DATA_WIDTH-1:0]    data_i       ,
    input  logic                     data_last_i  ,
    output logic                     rd_en_o      ,
    output  logic [ADDR_WIDTH-1:0]   rd_addr_o    ,
    // max output 
    output logic [DATA_WIDTH-1:0]    max_value_o  ,
    output logic [ADDR_WIDTH-1:0]    max_addr_o   ,
    output logic                     max_valid_o  , // when ST_DONE && (!naninf_seen) 
    // state output 
    output logic                     done_o       ,
    output logic                     busy_o           
);

    // state-machine enum define 
    typedef enum logic [2:0] {
        ST_IDLE     = 3'h0, 
        ST_MEM_READ = 3'h1,
        ST_MEM_WAIT = 3'h2,
        ST_COMPARE  = 3'h3,
        //ST_PROCESS, // compare two fp16 value
        ST_DONE     = 3'h4     // complete: hold done_o until start_i deasserts
    } mf_state_e;
    
    // internal signal 
    logic [DATA_WIDTH-1:0] max_cur, max_nxt;
    logic [ADDR_WIDTH-1:0] addr_counter_cur, addr_counter_nxt;
    logic [ADDR_WIDTH-1:0] max_addr_cur, max_addr_nxt;
    logic                  naninf_seen_cur, naninf_seen_nxt; // NaN & Infinity flag

    // Function: fp16_compare
    // float-point comparision functon
    //{{{  
    function automatic logic fp16_compare(input logic [15:0] a, b);
        logic [15:0] a_abs, b_abs;
        logic        a_sign, b_sign;
        
        // check NaN
        if ((a[14:10] == 5'b11111 && a[9:0] != 0) || 
            (b[14:10] == 5'b11111 && b[9:0] != 0)) begin
            return 1'b0;
        end
        
        a_sign = a[15];
        b_sign = b[15];
        a_abs = {1'b0, a[14:0]};
        b_abs = {1'b0, b[14:0]};
        
        // check Value-0
        if ((a_abs == 0) && (b_abs == 0)) return 1'b0;
        // check value's sign
        if (a_sign != b_sign) return b_sign;
        
        // If both values are positive or negative, check absolute value
        if (!a_sign) return a_abs > b_abs;
        else return a_abs < b_abs;
    endfunction
    //}}}

    // State Machine 
    mf_state_e      mf_sta_cur, mf_sta_nxt; 
    // confirm current state 
    always_ff @(posedge clk or negedge rst_n) begin 
        if(!rst_n) begin
            mf_sta_cur          <= ST_IDLE;
            max_cur             <= 16'h0; 
            max_addr_cur        <= '0;
            addr_counter_cur    <= '0; 
            naninf_seen_cur     <= 1'b0;
        end else begin
            mf_sta_cur          <= mf_sta_nxt;
            max_cur             <= max_nxt;
            max_addr_cur        <= max_addr_nxt;
            addr_counter_cur    <= addr_counter_nxt;
            naninf_seen_cur     <= naninf_seen_nxt;
        end
    end
    // confirm next state 
    always_comb begin 
        mf_sta_nxt      = mf_sta_cur;
        max_nxt         = max_cur;
        max_addr_nxt    = max_addr_cur;
        addr_counter_nxt= addr_counter_cur; 
        naninf_seen_nxt = naninf_seen_cur;
        max_value_o     = max_cur; 
        max_addr_o      = max_addr_cur;
        max_valid_o     = 1'b0;
        rd_en_o         = 1'b0; 
        rd_addr_o       = addr_counter_cur;
        case (mf_sta_cur) 
            ST_IDLE: begin
                if(start_i) begin 
                    mf_sta_nxt          = ST_MEM_READ; 
                    addr_counter_nxt    = '0; 
                    max_nxt             = 16'h0;
                    max_addr_nxt        =  '0;
                end 
            end
            ST_MEM_READ: begin
                rd_en_o     = 1'b1;
                mf_sta_nxt  = ST_MEM_WAIT;
            end
            ST_MEM_WAIT: begin
                if(data_valid_i) begin
                    mf_sta_nxt = ST_COMPARE;
                end
            end
            ST_COMPARE: begin
                if (!start_i) begin
                    mf_sta_nxt      = ST_IDLE; 
                end else if (data_i[14:10] == 5'b1_1111) begin
                    naninf_seen_nxt = 1'b1; 
                    mf_sta_nxt      = ST_DONE;
                end else begin
                    if(fp16_compare(data_i, max_cur)) begin
                        max_nxt         = data_i;
                        max_addr_nxt    = addr_counter_cur; 
                    end
                    if(data_last_i || (addr_counter_cur == (NUM_VALUES - 1))) begin
                        addr_counter_nxt = NUM_VALUES - 1; 
                        mf_sta_nxt       = ST_DONE; 
                    end else begin
                        addr_counter_nxt = addr_counter_cur + 1; 
                        mf_sta_nxt       = ST_MEM_READ;
                    end
                end
            end
            /*
            ST_PROCESS: begin
                busy_o = 1'b1;
                if(!start_i) begin
                    mf_sta_nxt = ST_IDLE; 
                end else begin
                    rd_en_o = 1'b1; 
                    if(data_valid_i) begin
                        if(data_i[14:10] == 5'b1_1111) begin
                            naninf_seen_nxt = 1'b1; 
                            mf_sta_nxt = ST_DONE;
                        end else begin
                            if(fp16_compare(data_i, max_cur)) begin
                                max_nxt         = data_i;
                                max_addr_nxt    = addr_counter_cur; 
                            end
                            if(data_last_i || (addr_counter_cur == (NUM_VALUES - 1))) begin
                                addr_counter_nxt = NUM_VALUES - 1; 
                                mf_sta_nxt = ST_DONE; 
                            end else begin
                                addr_counter_nxt = addr_counter_cur + 1; 
                            end
                        end
                    end
                end
            end 
            */
            ST_DONE: begin
                max_valid_o = naninf_seen_cur ? 1'b0 : 1'b1; 
                if(!start_i) begin 
                    mf_sta_nxt = ST_IDLE; 
                end 
            end 
            default: mf_sta_nxt = ST_IDLE;
        endcase 
    end
    
    assign done_o = (mf_sta_cur == ST_DONE); 
    always_comb begin
        case(mf_sta_cur)
            ST_MEM_READ, ST_MEM_WAIT, ST_COMPARE: begin
                busy_o = 1'b1;
            end
            default: busy_o = 1'b0; 
        endcase
    end

endmodule
