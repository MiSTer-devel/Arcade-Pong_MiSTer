//============================================================================
//  Arcade: Atari Pong (1972) for MiSTer
//
//  Port to MiSTer
//  Copyright (C) 2017 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [45:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	output [11:0] VIDEO_ARX,
	output [11:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler

	// Use framebuffer from DDRAM (USE_FB=1 in qsf)
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of 16 bytes.
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,    // 1 - signed audio samples, 0 - unsigned

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT
);

assign VGA_F1    = 0;
assign VGA_SCALER= 0;
assign USER_OUT  = '1;
assign LED_USER  = ioctl_download;
assign LED_DISK  = 0;
assign LED_POWER = 0;

assign {FB_EN,FB_FORMAT,FB_WIDTH,FB_HEIGHT,FB_BASE,FB_STRIDE,FB_FORCE_BLANK,FB_PAL_CLK,FB_PAL_ADDR,FB_PAL_DOUT,FB_PAL_WR} = '0;
assign {DDRAM_CLK,DDRAM_BURSTCNT,DDRAM_ADDR,DDRAM_RD,DDRAM_DIN,DDRAM_BE,DDRAM_WE} = '0;

wire [1:0] ar = status[15:14];

assign VIDEO_ARX = (!ar) ? 8'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 8'd3 : 12'd0;

`include "build_id.v" 
localparam CONF_STR = {
	"A.PONG;;",
	"-;",
	"H0OEF,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O35,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"O8,Max Points,11,15;",
	"O9A,Control P1,Y,X,Inv-X,Paddle;",
	"OBC,Control P2,Y,X,Inv-X,Paddle;",
	"-;",
	"R0,Reset;",
	"J1,Start;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys, clk_vid;
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys), // 7.159mhz
	.outclk_1(clk_vid), // 57.273mhz
	.locked(pll_locked)
);

///////////////////////////////////////////////////

wire [31:0] status;
wire  [1:0] buttons;
wire        forced_scandoubler;
wire        direct_video;

wire        ioctl_download;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;

wire [10:0] ps2_key;

wire [15:0] joystick_0, joystick_1;
wire [15:0] joystick_analog_0;
wire [15:0] joystick_analog_1;
wire  [7:0] paddle_0;
wire  [7:0] paddle_1;

wire [15:0] joy = joystick_0 | joystick_1;

wire [21:0] gamma_bus;

hps_io #(.STRLEN($size(CONF_STR)>>3)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.conf_str(CONF_STR),

	.buttons(buttons),
	.status(status),
	.status_menumask(direct_video),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_analog_0(joystick_analog_0),
	.joystick_analog_1(joystick_analog_1),	
	.paddle_0(paddle_0),
	.paddle_1(paddle_1),
	.ps2_key(ps2_key)
);

wire       pressed = ps2_key[9];
wire [8:0] code    = ps2_key[8:0];
always @(posedge clk_sys) begin
	reg old_state;
	old_state <= ps2_key[10];
	
	if(old_state != ps2_key[10]) begin
		casex(code)
			// JPAC/IPAC/MAME Style Codes
			'h005: btn_one_player  <= pressed; // F1
			'h006: btn_two_players <= pressed; // F2
			'h016: btn_start_1     <= pressed; // 1
			'h01E: btn_start_2     <= pressed; // 2
			'h02E: btn_coin_1      <= pressed; // 5
			'h036: btn_coin_2      <= pressed; // 6
		endcase
	end
end

reg btn_one_player  = 0;
reg btn_two_players = 0;
reg btn_start_1=0;
reg btn_start_2=0;
reg btn_coin_1=0;
reg btn_coin_2=0;

wire m_start1 = btn_one_player  | btn_start_1 | joy[4];
wire m_start2 = btn_two_players | btn_start_2;
wire m_start  = m_start1 | m_start2;

wire hblank, vblank;
wire hs, vs;
wire [3:0] r,g,b;

reg ce_pix;
always @(posedge clk_vid) begin
	reg [2:0] div;
	
	div <= div + 1'd1;
	ce_pix <= !div; 
end

arcade_video #(375, 12) arcade_video
(
	.*,

	.clk_video(clk_vid),

	.RGB_in({r,g,b}),
	.HBlank(hblank),
	.VBlank(vblank),
	.HSync(hs),
	.VSync(vs),
	.fx(status[5:3])
);

wire audio;
assign AUDIO_L = {~audio, 12'd0};
assign AUDIO_R = AUDIO_L;
assign AUDIO_S = 0;

wire [7:0] paddle1_vpos = (!status[10:09]) ? (joystick_analog_0[15:8] + 8'h80) : (status[10:09] == 1) ? (joystick_analog_0[7:0] + 8'h80) : (status[10:09] == 2) ? (joystick_analog_0[7:0] ^ 8'h7F) : paddle_0;
wire [7:0] paddle2_vpos = (!status[12:11]) ? (joystick_analog_1[15:8] + 8'h80) : (status[12:11] == 1) ? (joystick_analog_1[7:0] + 8'h80) : (status[12:11] == 2) ? (joystick_analog_1[7:0] ^ 8'h7F) : paddle_1;

pong pong
(
	.clk7_159(clk_sys),
	.coin_sw(m_start|btn_coin_1|btn_coin_2|status[0]|buttons[1]),
	.dip_sw(status[8]),
	.paddle1_vpos(paddle1_vpos),
	.paddle2_vpos(paddle2_vpos),

	.r(r),
	.g(g),
	.b(b),
	.hsync(hs),
	.vsync(vs),
	.hblank(hblank),
	.vblank(vblank),

	.sound_out(audio)
);

endmodule
