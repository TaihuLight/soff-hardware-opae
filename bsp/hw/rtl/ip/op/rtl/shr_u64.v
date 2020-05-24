`timescale 1ns / 1ps
// Automatically generated file; DO NOT EDIT
module shr_u64(
    input wire clk,
    input wire rstn,
    input wire enable,
    input wire [64 - 1 : 0] a,
    input wire [32 - 1 : 0] b,
    output wire [64 - 1 : 0] q
    );
reg [64 - 1 : 0] q_reg;
assign q = q_reg;
always @(posedge clk) begin
    if (enable) begin
        q_reg <= a >>> b;
    end
end
endmodule
