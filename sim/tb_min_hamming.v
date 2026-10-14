// ============================================================================
// tb_min_hamming.v - RTL testbench for the two Vitis HLS cores of min_Hamming
//
// Drives the generated Verilog of min_hamming_hls the way the ARM program does:
//   1. AXI4-Lite: write tab (0x18) and tab_size (0x20), then ap_start (0x00)
//   2. the core reads the words from "DDR" through its AXI4 master m_axi_gmem
//      (this file answers the read bursts from the array mem[])
//   3. poll ap_done (0x00, bit 1), read ap_return (0x10) [and stage (0x28)]
// The array is main.c's benchmark: N = 5,000 words from MT19937, seed 42.
//
// Compile with +define+CORE_V1 (version 1 RTL) or +define+CORE_V2 (version 2),
// and with DUMP_VCD to write waves_v1.vcd / waves_v2.vcd (run_icarus.bat).
// Signals meant for the waveform: phase (ASCII), rows, latency, result, stage.
// ============================================================================
`timescale 1ns / 1ps

module tb_min_hamming;

    parameter integer N        = 5000;           // words in tab[] (main.c)
    parameter integer SEED     = 42;             // MT19937 seed (main.c)
    parameter integer EXPECTED = 2;              // answer of the C versions
    parameter [31:0]  BASE     = 32'h1000_0000;  // address of tab[] in "DDR"
    parameter integer POLL     = 200;            // clocks between ap_done polls

    localparam integer MEM_WORDS = 8192;         // MAX_N of both cores

    // ---------------------------------------------------------------- clock
    reg ap_clk   = 1'b0;
    reg ap_rst_n = 1'b0;
    always #5 ap_clk = ~ap_clk;                  // 100 MHz, like FCLK_CLK0

    integer cycle = 0;
    always @(posedge ap_clk)
        cycle <= cycle + 1;

    // ---------------------------------------------------------------- AXI4-Lite (control)
    reg         s_axi_control_AWVALID = 1'b0;
    wire        s_axi_control_AWREADY;
    reg  [5:0]  s_axi_control_AWADDR  = 6'h0;
    reg         s_axi_control_WVALID  = 1'b0;
    wire        s_axi_control_WREADY;
    reg  [31:0] s_axi_control_WDATA   = 32'h0;
    reg  [3:0]  s_axi_control_WSTRB   = 4'hF;
    reg         s_axi_control_ARVALID = 1'b0;
    wire        s_axi_control_ARREADY;
    reg  [5:0]  s_axi_control_ARADDR  = 6'h0;
    wire        s_axi_control_RVALID;
    reg         s_axi_control_RREADY  = 1'b0;
    wire [31:0] s_axi_control_RDATA;
    wire [1:0]  s_axi_control_RRESP;
    wire        s_axi_control_BVALID;
    reg         s_axi_control_BREADY  = 1'b0;
    wire [1:0]  s_axi_control_BRESP;
    wire        interrupt;

    // ---------------------------------------------------------------- AXI4 (gmem -> HP0 -> DDR)
    wire        m_axi_gmem_AWVALID;
    wire        m_axi_gmem_AWREADY;
    wire [31:0] m_axi_gmem_AWADDR;
    wire [0:0]  m_axi_gmem_AWID;
    wire [7:0]  m_axi_gmem_AWLEN;
    wire [2:0]  m_axi_gmem_AWSIZE;
    wire [1:0]  m_axi_gmem_AWBURST;
    wire [1:0]  m_axi_gmem_AWLOCK;
    wire [3:0]  m_axi_gmem_AWCACHE;
    wire [2:0]  m_axi_gmem_AWPROT;
    wire [3:0]  m_axi_gmem_AWQOS;
    wire [3:0]  m_axi_gmem_AWREGION;
    wire [0:0]  m_axi_gmem_AWUSER;
    wire        m_axi_gmem_WVALID;
    wire        m_axi_gmem_WREADY;
    wire [31:0] m_axi_gmem_WDATA;
    wire [3:0]  m_axi_gmem_WSTRB;
    wire        m_axi_gmem_WLAST;
    wire [0:0]  m_axi_gmem_WID;
    wire [0:0]  m_axi_gmem_WUSER;
    wire        m_axi_gmem_ARVALID;
    wire        m_axi_gmem_ARREADY;
    wire [31:0] m_axi_gmem_ARADDR;
    wire [0:0]  m_axi_gmem_ARID;
    wire [7:0]  m_axi_gmem_ARLEN;
    wire [2:0]  m_axi_gmem_ARSIZE;
    wire [1:0]  m_axi_gmem_ARBURST;
    wire [1:0]  m_axi_gmem_ARLOCK;
    wire [3:0]  m_axi_gmem_ARCACHE;
    wire [2:0]  m_axi_gmem_ARPROT;
    wire [3:0]  m_axi_gmem_ARQOS;
    wire [3:0]  m_axi_gmem_ARREGION;
    wire [0:0]  m_axi_gmem_ARUSER;
    wire        m_axi_gmem_RVALID;
    wire        m_axi_gmem_RREADY;
    wire [31:0] m_axi_gmem_RDATA;
    wire        m_axi_gmem_RLAST;
    wire [0:0]  m_axi_gmem_RID   = 1'b0;
    wire [0:0]  m_axi_gmem_RUSER = 1'b0;
    wire [1:0]  m_axi_gmem_RRESP = 2'b00;        // OKAY
    wire        m_axi_gmem_BVALID;
    wire        m_axi_gmem_BREADY;
    wire [1:0]  m_axi_gmem_BRESP = 2'b00;
    wire [0:0]  m_axi_gmem_BID   = 1'b0;
    wire [0:0]  m_axi_gmem_BUSER = 1'b0;

    // ---------------------------------------------------------------- the core
    min_hamming_hls dut (
        .ap_clk(ap_clk), .ap_rst_n(ap_rst_n),
        .m_axi_gmem_AWVALID(m_axi_gmem_AWVALID), .m_axi_gmem_AWREADY(m_axi_gmem_AWREADY),
        .m_axi_gmem_AWADDR(m_axi_gmem_AWADDR), .m_axi_gmem_AWID(m_axi_gmem_AWID),
        .m_axi_gmem_AWLEN(m_axi_gmem_AWLEN), .m_axi_gmem_AWSIZE(m_axi_gmem_AWSIZE),
        .m_axi_gmem_AWBURST(m_axi_gmem_AWBURST), .m_axi_gmem_AWLOCK(m_axi_gmem_AWLOCK),
        .m_axi_gmem_AWCACHE(m_axi_gmem_AWCACHE), .m_axi_gmem_AWPROT(m_axi_gmem_AWPROT),
        .m_axi_gmem_AWQOS(m_axi_gmem_AWQOS), .m_axi_gmem_AWREGION(m_axi_gmem_AWREGION),
        .m_axi_gmem_AWUSER(m_axi_gmem_AWUSER),
        .m_axi_gmem_WVALID(m_axi_gmem_WVALID), .m_axi_gmem_WREADY(m_axi_gmem_WREADY),
        .m_axi_gmem_WDATA(m_axi_gmem_WDATA), .m_axi_gmem_WSTRB(m_axi_gmem_WSTRB),
        .m_axi_gmem_WLAST(m_axi_gmem_WLAST), .m_axi_gmem_WID(m_axi_gmem_WID),
        .m_axi_gmem_WUSER(m_axi_gmem_WUSER),
        .m_axi_gmem_ARVALID(m_axi_gmem_ARVALID), .m_axi_gmem_ARREADY(m_axi_gmem_ARREADY),
        .m_axi_gmem_ARADDR(m_axi_gmem_ARADDR), .m_axi_gmem_ARID(m_axi_gmem_ARID),
        .m_axi_gmem_ARLEN(m_axi_gmem_ARLEN), .m_axi_gmem_ARSIZE(m_axi_gmem_ARSIZE),
        .m_axi_gmem_ARBURST(m_axi_gmem_ARBURST), .m_axi_gmem_ARLOCK(m_axi_gmem_ARLOCK),
        .m_axi_gmem_ARCACHE(m_axi_gmem_ARCACHE), .m_axi_gmem_ARPROT(m_axi_gmem_ARPROT),
        .m_axi_gmem_ARQOS(m_axi_gmem_ARQOS), .m_axi_gmem_ARREGION(m_axi_gmem_ARREGION),
        .m_axi_gmem_ARUSER(m_axi_gmem_ARUSER),
        .m_axi_gmem_RVALID(m_axi_gmem_RVALID), .m_axi_gmem_RREADY(m_axi_gmem_RREADY),
        .m_axi_gmem_RDATA(m_axi_gmem_RDATA), .m_axi_gmem_RLAST(m_axi_gmem_RLAST),
        .m_axi_gmem_RID(m_axi_gmem_RID), .m_axi_gmem_RUSER(m_axi_gmem_RUSER),
        .m_axi_gmem_RRESP(m_axi_gmem_RRESP),
        .m_axi_gmem_BVALID(m_axi_gmem_BVALID), .m_axi_gmem_BREADY(m_axi_gmem_BREADY),
        .m_axi_gmem_BRESP(m_axi_gmem_BRESP), .m_axi_gmem_BID(m_axi_gmem_BID),
        .m_axi_gmem_BUSER(m_axi_gmem_BUSER),
        .s_axi_control_AWVALID(s_axi_control_AWVALID), .s_axi_control_AWREADY(s_axi_control_AWREADY),
        .s_axi_control_AWADDR(s_axi_control_AWADDR),
        .s_axi_control_WVALID(s_axi_control_WVALID), .s_axi_control_WREADY(s_axi_control_WREADY),
        .s_axi_control_WDATA(s_axi_control_WDATA), .s_axi_control_WSTRB(s_axi_control_WSTRB),
        .s_axi_control_ARVALID(s_axi_control_ARVALID), .s_axi_control_ARREADY(s_axi_control_ARREADY),
        .s_axi_control_ARADDR(s_axi_control_ARADDR),
        .s_axi_control_RVALID(s_axi_control_RVALID), .s_axi_control_RREADY(s_axi_control_RREADY),
        .s_axi_control_RDATA(s_axi_control_RDATA), .s_axi_control_RRESP(s_axi_control_RRESP),
        .s_axi_control_BVALID(s_axi_control_BVALID), .s_axi_control_BREADY(s_axi_control_BREADY),
        .s_axi_control_BRESP(s_axi_control_BRESP),
        .interrupt(interrupt)
    );

    // ---------------------------------------------------------------- "DDR": AXI4 read slave
    // Read requests are queued (the core may issue several before the data
    // comes back) and answered in order, one 32-bit beat per clock.
    reg [31:0] mem [0:MEM_WORDS-1];

    reg [31:0] rq_addr [0:15];
    reg [7:0]  rq_len  [0:15];
    reg [3:0]  rq_head  = 4'd0;
    reg [3:0]  rq_tail  = 4'd0;
    reg [4:0]  rq_count = 5'd0;
    reg [7:0]  beat     = 8'd0;

    wire        rq_push  = m_axi_gmem_ARVALID && m_axi_gmem_ARREADY;
    wire        r_fire   = m_axi_gmem_RVALID && m_axi_gmem_RREADY;
    wire        rq_pop   = r_fire && m_axi_gmem_RLAST;
    wire [31:0] rd_index = ((rq_addr[rq_head] - BASE) >> 2) + beat;

    assign m_axi_gmem_ARREADY = ap_rst_n && (rq_count < 5'd16);
    assign m_axi_gmem_RVALID  = (rq_count != 5'd0);
    assign m_axi_gmem_RDATA   = (rq_count != 5'd0) ? mem[rd_index[12:0]] : 32'h0;
    assign m_axi_gmem_RLAST   = (rq_count != 5'd0) && (beat == rq_len[rq_head]);

    always @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            rq_head  <= 4'd0;
            rq_tail  <= 4'd0;
            rq_count <= 5'd0;
            beat     <= 8'd0;
        end else begin
            if (rq_push) begin
                rq_addr[rq_tail] <= m_axi_gmem_ARADDR;
                rq_len[rq_tail]  <= m_axi_gmem_ARLEN;
                rq_tail          <= rq_tail + 4'd1;
            end
            if (r_fire) begin
                if (m_axi_gmem_RLAST) begin
                    beat    <= 8'd0;
                    rq_head <= rq_head + 4'd1;
                end else begin
                    beat <= beat + 8'd1;
                end
            end
            case ({rq_push, rq_pop})
                2'b10:   rq_count <= rq_count + 5'd1;
                2'b01:   rq_count <= rq_count - 5'd1;
                default: rq_count <= rq_count;
            endcase
        end
    end

    // The cores never write through m_axi_gmem; answer a write anyway, and flag it.
    reg bvalid_r = 1'b0;
    assign m_axi_gmem_AWREADY = 1'b1;
    assign m_axi_gmem_WREADY  = 1'b1;
    assign m_axi_gmem_BVALID  = bvalid_r;
    always @(posedge ap_clk) begin
        if (!ap_rst_n)
            bvalid_r <= 1'b0;
        else if (m_axi_gmem_WVALID && m_axi_gmem_WLAST)
            bvalid_r <= 1'b1;
        else if (m_axi_gmem_BREADY)
            bvalid_r <= 1'b0;
        if (ap_rst_n && m_axi_gmem_AWVALID)
            $display("WARNING: unexpected write burst to 0x%08h", m_axi_gmem_AWADDR);
    end

    // ---------------------------------------------------------------- AXI4-Lite master tasks
    // Called just after a rising edge; drive with <=, sample at the next edges.
    task axil_write(input [5:0] addr, input [31:0] data);
        reg aw_done, w_done;
        begin
            s_axi_control_AWADDR  <= addr;
            s_axi_control_AWVALID <= 1'b1;
            s_axi_control_WDATA   <= data;
            s_axi_control_WSTRB   <= 4'hF;
            s_axi_control_WVALID  <= 1'b1;
            s_axi_control_BREADY  <= 1'b1;
            aw_done = 1'b0;
            w_done  = 1'b0;
            while (!(aw_done && w_done)) begin
                @(posedge ap_clk);
                if (s_axi_control_AWVALID && s_axi_control_AWREADY) begin
                    aw_done = 1'b1;
                    s_axi_control_AWVALID <= 1'b0;
                end
                if (s_axi_control_WVALID && s_axi_control_WREADY) begin
                    w_done = 1'b1;
                    s_axi_control_WVALID <= 1'b0;
                end
            end
            @(posedge ap_clk);
            while (!s_axi_control_BVALID)
                @(posedge ap_clk);
            s_axi_control_BREADY <= 1'b0;
        end
    endtask

    task axil_read(input [5:0] addr, output [31:0] data);
        begin
            s_axi_control_ARADDR  <= addr;
            s_axi_control_ARVALID <= 1'b1;
            s_axi_control_RREADY  <= 1'b1;
            @(posedge ap_clk);
            while (!s_axi_control_ARREADY)
                @(posedge ap_clk);
            s_axi_control_ARVALID <= 1'b0;
            @(posedge ap_clk);
            while (!s_axi_control_RVALID)
                @(posedge ap_clk);
            data = s_axi_control_RDATA;
            s_axi_control_RREADY <= 1'b0;
        end
    endtask

    // ---------------------------------------------------------------- MT19937 (as main.c)
    reg [31:0] mt [0:623];
    integer    mt_index;

    task mt_seed(input [31:0] seed);
        integer k;
        begin
            mt[0] = seed;
            for (k = 1; k < 624; k = k + 1)
                mt[k] = 32'd1812433253 * (mt[k - 1] ^ (mt[k - 1] >> 30)) + k;
            mt_index = 624;
        end
    endtask

    task mt_next(output [31:0] value);
        integer    k;
        reg [31:0] y;
        begin
            if (mt_index == 624) begin
                for (k = 0; k < 624; k = k + 1) begin
                    y     = (mt[k] & 32'h8000_0000) | (mt[(k + 1) % 624] & 32'h7FFF_FFFF);
                    mt[k] = mt[(k + 397) % 624] ^ (y >> 1) ^ (y[0] ? 32'h9908_B0DF : 32'h0);
                end
                mt_index = 0;
            end
            y        = mt[mt_index];
            mt_index = mt_index + 1;
            y        = y ^ (y >> 11);
            y        = y ^ ((y << 7)  & 32'h9D2C_5680);
            y        = y ^ ((y << 15) & 32'hEFC6_0000);
            y        = y ^ (y >> 18);
            value    = y;
        end
    endtask

    // ---------------------------------------------------------------- observation
    // phase: which step of the core is running (shown as ASCII in the waveform)
    // rows : rows of pairs started (v1: one j_loop per word; v2: BLOCKS calls)
    reg [8*5-1:0] phase   = "IDLE ";
    integer       rows    = 0;
    integer       latency = 0;          // clocks from ap_start to ap_done
    integer       t_start = 0, t_done = 0;
    integer       t_start_ns = 0, t_done_ns = 0, t_end_ns = 0;
    reg           started = 1'b0, finished = 1'b0;
    reg           row_start_d = 1'b0;

`ifdef CORE_V1
    wire row_start = dut.grp_min_hamming_hls_Pipeline_j_loop_fu_437_ap_start;
`else
    wire row_start = dut.grp_min_hamming_hls_Pipeline_BLOCKS_fu_1094_ap_start;
`endif

    always @(posedge ap_clk) begin
        row_start_d <= row_start;
        if (row_start && !row_start_d)
            rows <= rows + 1;
`ifdef CORE_V1
        if (dut.grp_min_hamming_hls_Pipeline_copy_loop_fu_413_ap_start) phase <= "COPY ";
        if (dut.grp_min_hamming_hls_Pipeline_j_loop_fu_437_ap_start)    phase <= "PAIRS";
`else
        if (dut.grp_min_hamming_hls_Pipeline_LOAD_fu_950_ap_start)      phase <= "LOAD ";
        if (dut.grp_radix_sort_fu_940_ap_start)                         phase <= "SORT ";
        if (dut.grp_min_hamming_hls_Pipeline_BUILD_fu_1024_ap_start)    phase <= "BUILD";
        if (dut.grp_min_hamming_hls_Pipeline_STEP2_fu_1057_ap_start)    phase <= "STEP2";
        if (dut.grp_min_hamming_hls_Pipeline_BLOCKS_fu_1094_ap_start)   phase <= "PAIRS";
`endif
        if (!started && dut.ap_start) begin
            started    <= 1'b1;
            t_start    <= cycle;
            t_start_ns <= $time;
        end
        if (started && !finished && dut.ap_done) begin
            finished  <= 1'b1;
            t_done    <= cycle;
            t_done_ns <= $time;
            latency   <= cycle - t_start;
            phase     <= "DONE ";
        end
    end

    // ---------------------------------------------------------------- test
    reg [31:0] ctrl, result, stage;
    integer    i, errors;

`ifdef DUMP_VCD
    // Waveform file for Icarus Verilog (compile with -DDUMP_VCD); plot_waves.py
    // draws the report figure from it. QuestaSim does not use this block.
    initial begin
`ifdef CORE_V1
        $dumpfile("waves_v1.vcd");
`else
        $dumpfile("waves_v2.vcd");
`endif
        $dumpvars(0, ap_rst_n, phase, rows, latency, result, stage,
                  dut.ap_start, dut.ap_done, dut.ap_return,
                  s_axi_control_AWVALID, s_axi_control_AWADDR, s_axi_control_WVALID,
                  s_axi_control_WDATA, s_axi_control_BVALID,
                  s_axi_control_ARVALID, s_axi_control_ARADDR,
                  s_axi_control_RVALID, s_axi_control_RDATA,
                  m_axi_gmem_ARVALID, m_axi_gmem_ARADDR, m_axi_gmem_ARLEN,
                  m_axi_gmem_RVALID, m_axi_gmem_RDATA, m_axi_gmem_RLAST);
`ifndef CORE_V1
        $dumpvars(0, ap_clk);   // clock only for version 2 (the short run)
`endif
    end
`endif

    initial begin
        result = 32'h0;
        stage  = 32'h0;
        errors = 0;

        // main.c's benchmark array
        mt_seed(SEED);
        for (i = 0; i < N; i = i + 1)
            mt_next(mem[i]);
        for (i = N; i < MEM_WORDS; i = i + 1)
            mem[i] = 32'h0;
        $display("tab[0] = 0x%08h, tab[%0d] = 0x%08h, tab[%0d] = 0x%08h",
                 mem[0], 263, mem[263], 3180, mem[3180]);

        repeat (10) @(posedge ap_clk);
        ap_rst_n <= 1'b1;
        repeat (10) @(posedge ap_clk);

        // what XMin_hamming_hls_Set_tab, _Set_tab_size and _Start do on the ARM
        axil_write(6'h18, BASE);
        axil_write(6'h20, N);
        axil_write(6'h00, 32'h1);

        // poll ap_done, but only every POLL clocks so that the trace stays readable
        ctrl = 32'h0;
        while (!ctrl[1]) begin
            repeat (POLL) @(posedge ap_clk);
            axil_read(6'h00, ctrl);
        end
        axil_read(6'h10, result);
`ifndef CORE_V1
        axil_read(6'h28, stage);
`endif
        repeat (20) @(posedge ap_clk);
        t_end_ns = $time;

        if (result != EXPECTED) begin
            errors = errors + 1;
            $display("FAIL: min distance %0d, expected %0d", result, EXPECTED);
        end
`ifdef CORE_V1
        $display("RESULT core=v1 N=%0d distance=%0d latency=%0d cycles (%0.3f ms at 100 MHz) rows=%0d t_start=%0d ns t_done=%0d ns t_end=%0d ns errors=%0d",
                 N, result, latency, latency / 100000.0, rows, t_start_ns, t_done_ns, t_end_ns, errors);
`else
        $display("RESULT core=v2 N=%0d distance=%0d stage=%0d latency=%0d cycles (%0.3f ms at 100 MHz) rows=%0d t_start=%0d ns t_done=%0d ns t_end=%0d ns errors=%0d",
                 N, result, stage, latency, latency / 100000.0, rows, t_start_ns, t_done_ns, t_end_ns, errors);
`endif
        $display("%s", errors == 0 ? "TEST PASSED" : "TEST FAILED");
        $finish;
    end

endmodule
