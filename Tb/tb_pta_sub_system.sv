`timescale 1ns/1ps

import fp16_pkg::*; 

module tb_pta_sub_system(); 
    localparam DECIMAL_BITS = 24; 
    localparam INT_BITS     = 8; 
    localparam TOTAL_BITS   = INT_BITS + DECIMAL_BITS; 
    localparam NUM_VALUES   = 2600; 
    localparam DATA_WIDTH   = 16; 
    localparam ADDR_WIDTH   = $clog2(NUM_VALUES);
    localparam THRESHOLD    = 16'h3400; //0.25
    localparam WINDOW_SIZE  = 20; 

    bit clk, rst_n;
    logic [DATA_WIDTH-1:0] fp16[0:NUM_VALUES-1]; //BRAM  

    //{{{ clk & rst_n 
    always # (5ns) clk = ~clk; 
    initial begin
        # (21ns); 
        rst_n = 1'b1; 
        # (10ns); 
        rst_n = 1'b0; 
        # (20ns); 
        rst_n = 1'b1;
    end
    //}}}
    //{{{ initial BRAM 
    real r; 
    bit[7:0] d; 
    initial begin
        # 1ns;
        foreach(fp16[i]) begin
            fp16[i] = '0; 
        end 
        # 1ns;
        for(int i=6; i<40; i++) begin
            d = $urandom_range(99, 90); 
            r = d / 100.0; 
            fp16[i] = real_to_fp16(r);
            $display("%0h : %0h\n", i, fp16[i]);
        end
        //fp16[50] = 16'b0111_1100_0000_0000; // insert a +Infinity
    end
    //}}}
    //{{{ BRAM write & read 
    logic                     wr_en;
    logic [ADDR_WIDTH-1:0]    wr_addr;
    logic [DATA_WIDTH-1:0]    wr_data;
    logic                     wr_data_valid;

    logic                     rd_en;
    logic [ADDR_WIDTH-1:0]    rd_addr;
    logic [DATA_WIDTH-1:0]    rd_data; 
    logic                     rd_data_valid; 
    
    initial begin
        # 5ns;
        forever begin
            if(!rst_n) begin
                rd_data         = '0; 
                rd_data_valid   = 1'b0;
                wait(rst_n); 
            end else begin
                @(posedge clk); 
                if(rd_en) begin
                    #1ns;
                    if(rd_addr < NUM_VALUES) begin
                        rd_data_valid   = 1'b1; 
                        rd_data         = fp16[rd_addr]; 
                    end
                end else begin
                    #1ns;
                    rd_data_valid   = 1'b0;
                    rd_data         = (rd_addr < NUM_VALUES)? fp16[rd_addr]: 16'hFFFF; 
                end
                if(wr_en) begin
                    #1ns;
                    fp16[wr_addr]  = wr_data; 
                end 
            end    
        end
    end
    //}}}
    logic pta_sub_start; 
    logic max_done, max_valid; 
    logic [DATA_WIDTH-1:0] max_value; 
    logic norm_done, norm_valid;
    logic all_done;
    logic success; 

    pta_max_norm_sub_system #(
        .DATA_WIDTH (DATA_WIDTH),   
        .NUM_VALUES (NUM_VALUES),   
        .WINDOW_SIZE(WINDOW_SIZE),   
        .THRESHOLD  (THRESHOLD)   
    ) u_sub_system (
        .clk            (clk), 
        .rst_n          (rst_n), 
        .start_i        (pta_sub_start),                                         
        .rd_en_o        (rd_en), 
        .rd_addr_o      (rd_addr), 
        .rd_data_i      (rd_data), 
        .rd_data_valid_i(rd_data_valid),
        .wr_en_o        (wr_en),
        .wr_addr_o      (wr_addr),
        .wr_data_o      (wr_data),
        .wr_data_valid_o(wr_data_valid),
        .avg_max_done_o (max_done), 
        .avg_max_value_o(max_value), 
        .avg_max_valid_o(max_valid),
        .norm_done_o    (norm_done),
        .norm_valid_o   (norm_valid),
        .all_done_o     (all_done),
        .success_o      (success)
    ); 

    initial begin
        pta_sub_start = 1'b0; 
        # 80ns;
        pta_sub_start = 1'b1; 
        fork 
            # 500us; 
            wait(norm_done);
        join_any
        assert(max_done) else $display("max NOT Done!!!!\n");
        assert(norm_done) else $display("norm NOT Done!!!!\n");
        # 100ns; 
        $finish(); 
    end

endmodule 
