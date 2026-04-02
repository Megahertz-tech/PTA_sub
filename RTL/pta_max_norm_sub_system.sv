
module pta_max_norm_sub_system #(
    parameter DATA_WIDTH        = 16, 
    parameter NUM_VALUES        = 2600,
    parameter ADDR_WIDTH        = $clog2(NUM_VALUES), 
    parameter WINDOW_SIZE       = 20, 
    parameter THRESHOLD         = 16'h3400 // 0.25
)(
    input  logic                     clk            ,
    input  logic                     rst_n          ,
    input  logic                     start_i        ,
    
    //BRAM read & write 
    output logic                     rd_en_o        ,
    output logic [ADDR_WIDTH-1:0]    rd_addr_o      ,
    input  logic [DATA_WIDTH-1:0]    rd_data_i      ,
    input  logic                     rd_data_valid_i,

    output logic                     wr_en_o        ,
    output logic [ADDR_WIDTH-1:0]    wr_addr_o      ,
    output logic [DATA_WIDTH-1:0]    wr_data_o      , 
    output logic                     wr_data_valid_o,
    
    // output 
    output logic                     avg_max_done_o ,
    output logic [DATA_WIDTH-1:0]    avg_max_value_o,
    output logic                     avg_max_valid_o,   
    output logic                     norm_done_o    ,
    output logic                     norm_valid_o   , 
    output logic                     all_done_o     ,
    output logic                     success_o
);
    // State Machine enum define 
    typedef enum logic [2:0] {
        IDLE        = 3'h0, 
        FIND_MAX    = 3'h1, 
        FIND_WINDOW = 3'h2, 
        AVG_CALC    = 3'h3, 
        NORM_CALC   = 3'h4, 
        FAIL        = 3'h5,
        ALL_DONE    = 3'h6 
    } mn_state_e; 

    // internal signal 
    logic max_finder_start;
    logic max_finder_data_valid;
    logic [DATA_WIDTH-1:0] max_finder_data;
    logic                  max_finder_rd_en;
    logic [ADDR_WIDTH-1:0] max_finder_rd_addr;
    logic max_finder_done, max_finder_busy; 
    logic [DATA_WIDTH-1:0] max_value_int; 
    logic [ADDR_WIDTH-1:0] max_addr_int; 
    logic max_valid_int; 


    logic max_window_finder_start; 
    logic max_window_finder_done, max_window_finder_busy; 
    logic [ADDR_WIDTH-1:0] max_window_start_addr_int; 
    logic [ADDR_WIDTH-1:0] max_window_end_addr_int; 
    logic [ADDR_WIDTH-1:0] max_window_range_count_int; 
    logic max_window_range_count_valid_int; 
    logic [DATA_WIDTH-1:0] max_window_finder_rd_data;
    logic [ADDR_WIDTH-1:0] max_window_finder_rd_addr; 
    logic max_window_finder_rd_en; 
    logic max_window_finder_rd_data_valid; 
    
    logic max_avg_start; 
    logic max_avg_rd_en; 
    logic [DATA_WIDTH-1:0] max_avg_rd_data;
    logic [ADDR_WIDTH-1:0] max_avg_rd_addr;
    logic max_avg_rd_data_valid; 
    logic [DATA_WIDTH-1:0] max_avg; 
    logic [ADDR_WIDTH-1:0] max_avg_start_addr;
    logic [ADDR_WIDTH-1:0] max_avg_end_addr;
    logic max_avg_valid; 
    logic max_avg_done; 

    logic norm_start; 
    logic norm_rd_en, norm_rd_data_valid; 
    logic [DATA_WIDTH-1:0] norm_rd_data;
    logic [ADDR_WIDTH-1:0] norm_rd_addr;
    logic norm_wr_en, norm_wr_data_valid; 
    logic [DATA_WIDTH-1:0] norm_wr_data; 
    logic [ADDR_WIDTH-1:0] norm_wr_addr; 
    logic norm_valid, norm_done; 


    /* State Machine */
    mn_state_e      mn_sta_cur, mn_sta_nxt; 
    //{{{ Confirm current state 
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            mn_sta_cur <= IDLE; 
        end else begin
            mn_sta_cur <= mn_sta_nxt; 
        end 
    end 
    //}}}

    assign max_finder_start         = (mn_sta_cur !== IDLE) && start_i;
    assign max_window_finder_start  = max_valid_int && start_i;
    assign max_avg_start            = max_valid_int && max_window_range_count_valid_int && start_i;
    assign norm_start               = max_avg_valid && start_i;
    //{{{ Confirm next state 
    always_comb begin
        mn_sta_nxt = mn_sta_cur;
        all_done_o = 1'b0; 
        success_o  = 1'b0;

        case (mn_sta_cur) 
            IDLE: begin
                if(start_i) begin
                    mn_sta_nxt = FIND_MAX; 
                end 
            end
            FIND_MAX: begin
                if(!start_i) begin
                    mn_sta_nxt = IDLE; 
                end else if(max_finder_done) begin
                    if(max_valid_int && (max_value_int[14:10] != 5'h0)) begin // guard: max_value must be normal because the max denormal fp16 is too small (about 6.10e-5 )
                        mn_sta_nxt = FIND_WINDOW; 
                    end else begin
                        mn_sta_nxt = FAIL;
                    end
                end
            end 
            FIND_WINDOW: begin 
                if(!start_i) begin
                    mn_sta_nxt = IDLE; 
                end else if(max_window_finder_done) begin
                    if(max_window_range_count_valid_int) begin
                        mn_sta_nxt = AVG_CALC;
                    end else begin
                        mn_sta_nxt = FAIL;
                    end
                end
            end 
            AVG_CALC: begin
                 if(!start_i) begin
                    mn_sta_nxt = IDLE; 
                end else if (max_avg_done) begin
                    if(max_avg_valid) begin
                        mn_sta_nxt = NORM_CALC; 
                    end else begin
                        mn_sta_nxt = FAIL;
                    end
                end
            end
            NORM_CALC: begin
                 if(!start_i) begin
                    mn_sta_nxt = IDLE; 
                end else if (norm_done) begin
                    mn_sta_nxt = ALL_DONE; 
                end
            end
            FAIL: begin
                all_done_o = 1'b1;
                if(!start_i) begin
                    mn_sta_nxt = IDLE; 
                end 
            end
            ALL_DONE: begin
                all_done_o = 1'b1;
                success_o  = 1'b1;
                if(!start_i) begin
                    mn_sta_nxt = IDLE; 
                end
            end 
        endcase 
    end 
    //}}}
    //{{{ pta_max_finder 
    pta_max_finder#(
        .DATA_WIDTH(DATA_WIDTH),  
        .NUM_VALUES(NUM_VALUES)  
    ) u_pta_max_finder(
        .clk         (clk), 
        .rst_n       (rst_n), 
        .start_i     (max_finder_start), 
        .data_valid_i(max_finder_data_valid), 
        .data_i      (max_finder_data), 
        .rd_en_o     (max_finder_rd_en),
        .rd_addr_o   (max_finder_rd_addr),
        .data_last_i (1'b0), 
        .max_value_o (max_value_int), 
        .max_addr_o  (max_addr_int), 
        .max_valid_o (max_valid_int), 
        .done_o      (max_finder_done), 
        .busy_o      (max_finder_busy) 
    );
    //}}}
    assign avg_max_done_o  = max_avg_done; 
    assign avg_max_value_o = max_avg; 
    assign avg_max_valid_o = max_avg_valid; 
    assign norm_done_o     = norm_done;
    assign norm_valid_o    = norm_valid;
    //{{{ pta_max_window_finder 
    pta_max_window_finder#(
        .DATA_WIDTH(DATA_WIDTH),  
        .NUM_VALUES(NUM_VALUES)  
    ) u_max_window_finder (
        .clk          (clk),
        .rst_n        (rst_n),
        .start_i      (max_window_finder_start),
        .max_value_i  (max_value_int),
        .max_addr_i   (max_addr_int),
        .threshold_i  (THRESHOLD),
        .mem_rd_en_o  (max_window_finder_rd_en),
        .mem_rd_addr_o(max_window_finder_rd_addr),
        .mem_rd_data_i(max_window_finder_rd_data),
        .mem_rd_data_valid_i(max_window_finder_rd_data_valid),
        .start_addr_o (max_window_start_addr_int),
        .end_addr_o   (max_window_end_addr_int),
        .range_count_o(max_window_range_count_int),
        .range_valid_o(max_window_range_count_valid_int),
        .done_o       (max_window_finder_done),
        .busy_o       () 
    ); 
    //}}}
    //{{{ pta_max_avg 
    pta_max_avg #(
        .DATA_WIDTH     (DATA_WIDTH ), 
        .NUM_VALUES     (NUM_VALUES ), 
        .ADDR_WIDTH     (ADDR_WIDTH ), 
        .WINDOW_SIZE    (WINDOW_SIZE) 
    ) u_max_avg (
        .clk                   (clk             ),
        .rst_n                 (rst_n           ),                                
        .start_i               (max_avg_start   ),                                 
        .max_addr_i            (max_addr_int    ), 
        .range_start_i         (max_window_start_addr_int), 
        .range_end_i           (max_window_end_addr_int), 
        .window_size_i         (WINDOW_SIZE),                                 
        .mem_rd_en_o           (max_avg_rd_en), 
        .mem_rd_addr_o         (max_avg_rd_addr), 
        .mem_rd_data_i         (max_avg_rd_data), 
        .mem_rd_data_valid_i   (max_avg_rd_data_valid),                                 
        .window_avg_o          (max_avg), 
        .window_start_o        (max_avg_start_addr), 
        .window_end_o          (max_avg_end_addr), 
        .window_avg_valid_o    (max_avg_valid), 
        .done_o                (max_avg_done), 
        .busy_o                ()  
    );
    //}}}
    //{{{ pta_norm_calc
    pta_norm_calc #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_VALUES(NUM_VALUES)
    ) u_norm_calc (
        .clk                (clk),
        .rst_n              (rst_n),
        .start_i            (norm_start),
        .avg_value_i        (max_avg),
        .mem_rd_en_o        (norm_rd_en),
        .mem_rd_addr_o      (norm_rd_addr),
        .mem_rd_data_i      (norm_rd_data),
        .mem_rd_data_valid_i(norm_rd_data_valid),
        .mem_wr_data_valid_o(norm_wr_data_valid),
        .mem_wr_data_o      (norm_wr_data),
        .mem_wr_en_o        (norm_wr_en),
        .mem_wr_addr_o      (norm_wr_addr),
        .norm_valid_o       (norm_valid),
        .done_o             (norm_done),
        .busy_o             () 
    );
    //}}}
    //{{{
    always_comb begin
        rd_en_o     = 1'b0; 
        rd_addr_o   = '0; 
        wr_en_o     = 1'b0; 
        wr_addr_o   = '0; 
        wr_data_o   = '0; 
        wr_data_valid_o = 1'b0;
        if(mn_sta_cur == FIND_MAX) begin
            rd_en_o = max_finder_rd_en; 
            rd_addr_o = max_finder_rd_addr;
        end else if(mn_sta_cur == FIND_WINDOW) begin
            rd_en_o = max_window_finder_rd_en;
            rd_addr_o = max_window_finder_rd_addr; 
        end else if (mn_sta_cur == AVG_CALC) begin 
            rd_en_o = max_avg_rd_en;
            rd_addr_o = max_avg_rd_addr; 
        end else if (mn_sta_cur == NORM_CALC) begin
            rd_en_o     = norm_rd_en;
            rd_addr_o   = norm_rd_addr;
            wr_en_o     = norm_wr_en; 
            wr_addr_o   = norm_wr_addr; 
            wr_data_o   = norm_wr_data;
            wr_data_valid_o = norm_wr_data_valid; 
        end
    end 
    always_comb begin
        max_finder_data_valid   = 1'b0; 
        max_finder_data         = '0;
        max_window_finder_rd_data_valid = 1'b0;
        max_window_finder_rd_data       = '0;
        max_avg_rd_data_valid   = 1'b0; 
        max_avg_rd_data         = '0;
        norm_rd_data_valid      = 1'b0;
        norm_rd_data            = '0; 
        if(mn_sta_cur == FIND_MAX) begin
            max_finder_data_valid   = rd_data_valid_i; 
            max_finder_data         = rd_data_i; 
        end else if (mn_sta_cur == FIND_WINDOW) begin
            max_window_finder_rd_data_valid = rd_data_valid_i;
            max_window_finder_rd_data       = rd_data_i;        
        end else if (mn_sta_cur == AVG_CALC) begin 
            max_avg_rd_data_valid   = rd_data_valid_i;
            max_avg_rd_data         = rd_data_i;      
        end else if (mn_sta_cur == NORM_CALC) begin
            norm_rd_data_valid      = rd_data_valid_i;
            norm_rd_data            = rd_data_i;      
        end
    end 

    //}}}
    
endmodule 

