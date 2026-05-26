// simple_fifo.v — small AXI4-Lite FIFO with push/pop at the same address.
//
// Register map (S_AXI Lite, byte-addressable, 32-bit data):
//   0x00  W: push 32-bit value into the FIFO (no-op if full)
//   0x00  R: pop 32-bit value from the FIFO (returns 0 if empty)
//   0x04  R: count   — number of entries currently in the FIFO
//   0x08  R: status  — bit 0=empty, bit 1=full
//   0x0C  W: writing any value clears the FIFO (wp = rp = 0)
//
// Userspace can treat each "64-bit word" as two consecutive 32-bit pushes
// (LSB first, then MSB) and two consecutive 32-bit pops in the same order;
// internal storage stays 32-bit which keeps the AXI Lite path simple.
//
// 256-entry depth (DEPTH_BITS=8). All state is updated in a SINGLE always
// block — early versions had two always blocks both writing `rp`, which
// either silently wins one driver in synthesis or generates broken logic.

`timescale 1ns / 1ps

module simple_fifo #(
    parameter integer DEPTH_BITS = 8,
    parameter integer DATA_W     = 32,
    parameter integer ADDR_W     = 5
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire                s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                s_axi_aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    input  wire [ADDR_W-1:0]   s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
    input  wire [2:0]          s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  wire                s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output reg                 s_axi_awready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  wire [DATA_W-1:0]   s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  wire [DATA_W/8-1:0] s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  wire                s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output reg                 s_axi_wready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output reg  [1:0]          s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output reg                 s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  wire                s_axi_bready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  wire [ADDR_W-1:0]   s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
    input  wire [2:0]          s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  wire                s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output reg                 s_axi_arready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output reg  [DATA_W-1:0]   s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output reg  [1:0]          s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output reg                 s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  wire                s_axi_rready
);

    localparam DEPTH = (1 << DEPTH_BITS);

    reg [DATA_W-1:0]    mem [0:DEPTH-1];
    reg [DEPTH_BITS:0]  wp;
    reg [DEPTH_BITS:0]  rp;

    wire empty = (wp == rp);
    wire full  = (wp[DEPTH_BITS-1:0] == rp[DEPTH_BITS-1:0]) &&
                 (wp[DEPTH_BITS] != rp[DEPTH_BITS]);
    wire [DEPTH_BITS:0] count = wp - rp;

    reg [ADDR_W-1:0]  aw_latched;
    reg [ADDR_W-1:0]  ar_latched;
    reg [DATA_W-1:0]  w_data_latched;
    reg               aw_taken, w_taken, ar_taken;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            // ---- write side ----
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            aw_taken      <= 1'b0;
            w_taken       <= 1'b0;
            // ---- read side ----
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            s_axi_rdata   <= {DATA_W{1'b0}};
            ar_taken      <= 1'b0;
            // ---- pointers ----
            wp            <= {(DEPTH_BITS+1){1'b0}};
            rp            <= {(DEPTH_BITS+1){1'b0}};
        end else begin
            // -------- AW handshake --------
            if (s_axi_awvalid && s_axi_awready) begin
                aw_latched    <= s_axi_awaddr;
                aw_taken      <= 1'b1;
                s_axi_awready <= 1'b0;
            end else if (!aw_taken && !s_axi_awready) begin
                s_axi_awready <= 1'b1;
            end

            // -------- W handshake --------
            if (s_axi_wvalid && s_axi_wready) begin
                w_data_latched <= s_axi_wdata;
                w_taken        <= 1'b1;
                s_axi_wready   <= 1'b0;
            end else if (!w_taken && !s_axi_wready) begin
                s_axi_wready <= 1'b1;
            end

            // -------- B emit + write-side state mutation --------
            if (aw_taken && w_taken && !s_axi_bvalid) begin
                case (aw_latched[3:2])
                    2'b00: begin              // 0x00 W: push
                        if (!full) begin
                            mem[wp[DEPTH_BITS-1:0]] <= w_data_latched;
                            wp <= wp + 1;
                        end
                    end
                    2'b11: begin              // 0x0C W: reset both pointers
                        wp <= {(DEPTH_BITS+1){1'b0}};
                        rp <= {(DEPTH_BITS+1){1'b0}};
                    end
                    default: ;                // 0x04 / 0x08 W: ignored
                endcase
                s_axi_bresp  <= 2'b00;
                s_axi_bvalid <= 1'b1;
                aw_taken     <= 1'b0;
                w_taken      <= 1'b0;
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            // -------- AR handshake --------
            if (s_axi_arvalid && s_axi_arready) begin
                ar_latched    <= s_axi_araddr;
                ar_taken      <= 1'b1;
                s_axi_arready <= 1'b0;
            end else if (!ar_taken && !s_axi_arready) begin
                s_axi_arready <= 1'b1;
            end

            // -------- R emit + read-side state mutation --------
            if (ar_taken && !s_axi_rvalid) begin
                case (ar_latched[3:2])
                    2'b00: begin              // 0x00 R: pop
                        if (!empty) begin
                            s_axi_rdata <= mem[rp[DEPTH_BITS-1:0]];
                            rp <= rp + 1;
                        end else begin
                            s_axi_rdata <= {DATA_W{1'b0}};
                        end
                    end
                    2'b01:                    // 0x04 R: count
                        s_axi_rdata <= {{(DATA_W-(DEPTH_BITS+1)){1'b0}}, count};
                    2'b10:                    // 0x08 R: status
                        s_axi_rdata <= {{(DATA_W-2){1'b0}}, full, empty};
                    default:                  // 0x0C R: 0
                        s_axi_rdata <= {DATA_W{1'b0}};
                endcase
                s_axi_rresp  <= 2'b00;
                s_axi_rvalid <= 1'b1;
                ar_taken     <= 1'b0;
            end
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

endmodule
