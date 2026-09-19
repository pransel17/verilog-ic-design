/*
 * Hill Racer - a tiny VGA hill-climb game for Tiny Tapeout
 * Random hills, parallax scenery, tilting car, HUD, game-over banner
 * Keyboard/gamepad: Right/Up/A/B = gas, Left = brake,
 *                   Down/Start/Select/A/B = restart after game over
 * Buttons: ui_in[0] = gas, ui_in[1] = restart
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_vga_glyph_mode(
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    assign uio_out = 8'd0;
    assign uio_oe  = 8'd0;

    // ---------------- VGA timing 640x480 ----------------
    reg [9:0] hpos;
    reg [9:0] vpos;

    always @(posedge clk) begin
        if (!rst_n) begin
            hpos <= 10'd0;
            vpos <= 10'd0;
        end else if (hpos == 10'd799) begin
            hpos <= 10'd0;
            if (vpos == 10'd524) vpos <= 10'd0;
            else                 vpos <= vpos + 10'd1;
        end else begin
            hpos <= hpos + 10'd1;
        end
    end

    wire hsync      = ~((hpos >= 10'd656) && (hpos < 10'd752));
    wire vsync      = ~((vpos >= 10'd490) && (vpos < 10'd492));
    wire display_on = (hpos < 10'd640) && (vpos < 10'd480);

    // ---------------- Gamepad Pmod decoder (keyboard arrows) ----------------
    // ui_in[4] = latch, ui_in[5] = clock, ui_in[6] = data
    reg [1:0]  d_sync;
    reg [1:0]  c_sync;
    reg [1:0]  l_sync;
    reg        c_prev;
    reg        l_prev;
    reg [11:0] shift_reg;
    reg [11:0] pad_reg;

    always @(posedge clk) begin
        if (!rst_n) begin
            d_sync    <= 2'b00;
            c_sync    <= 2'b00;
            l_sync    <= 2'b00;
            c_prev    <= 1'b0;
            l_prev    <= 1'b0;
            shift_reg <= 12'hFFF;
            pad_reg   <= 12'hFFF;
        end else begin
            d_sync <= {d_sync[0], ui_in[6]};
            c_sync <= {c_sync[0], ui_in[5]};
            l_sync <= {l_sync[0], ui_in[4]};
            c_prev <= c_sync[1];
            l_prev <= l_sync[1];
            if (l_sync[1] & ~l_prev)
                pad_reg <= shift_reg;
            if (c_sync[1] & ~c_prev)
                shift_reg <= {shift_reg[10:0], d_sync[1]};
        end
    end

    // All ones = no controller connected
    wire        pad_on = (pad_reg != 12'hFFF);
    wire [11:0] pad    = pad_on ? pad_reg : 12'd0;
    // Bit order: B Y Select Start Up Down Left Right A X L R
    wire pad_b      = pad[11];
    wire pad_select = pad[9];
    wire pad_start  = pad[8];
    wire pad_up     = pad[7];
    wire pad_down   = pad[6];
    wire pad_left   = pad[5];
    wire pad_right  = pad[4];
    wire pad_a      = pad[3];

    wire gas_in   = ui_in[0] | pad_right | pad_up | pad_a | pad_b;
    wire brake_in = pad_left;
    wire rst_in   = ui_in[1] | pad_down | pad_start | pad_select | pad_a | pad_b;

    // ---------------- Random terrain ----------------
    // Pseudo-random 6-bit value for a 128px block corner
    function [5:0] hash;
        input [8:0] idx;
        input [7:0] sd;
        reg [15:0] v;
        begin
            v = {7'd0, idx} * 16'h9E37 + {8'd0, sd} * 16'h1B87;
            v = v ^ {7'd0, v[15:7]};
            v = v * 16'h85EB;
            v = v ^ {8'd0, v[15:8]};
            hash = v[10:5];
        end
    endfunction

    // Corner height: even corners are low (0..15), odd corners are high (32..47)
    function [5:0] corner;
        input [8:0] idx;
        input [7:0] sd;
        reg [5:0] hv;
        begin
            hv = hash(idx, sd);
            corner = idx[0] ? {2'b10, hv[3:0]} : {2'b00, hv[3:0]};
        end
    endfunction

    // Ground height (screen y) at a world x: smooth blend between
    // corner heights that are 128px apart
    function [9:0] terr;
        input [15:0] wx;
        input [7:0]  sd;
        reg [5:0] h0;
        reg [5:0] h1;
        reg signed [8:0]  d;
        reg signed [16:0] p;
        reg signed [16:0] q;
        reg signed [16:0] hs;
        begin
            h0 = corner(wx[15:7], sd);
            h1 = corner(wx[15:7] + 9'd1, sd);
            d  = $signed({3'b000, h1}) - $signed({3'b000, h0});
            p  = d * $signed({1'b0, wx[6:0]});
            q  = p >>> 7;
            hs = $signed({11'd0, h0}) + q;
            terr = 10'd420 - {4'd0, hs[5:0]};
        end
    endfunction

    // ---------------- Drawing helper functions ----------------
    // Cloud shape: 0 = none, 1 = white, 2 = shaded underside
    function [1:0] cloud_shape;
        input [9:0] rx;
        input [9:0] ry;
        begin
            cloud_shape = 2'd0;
            if ((rx < 10'd72 && ry >= 10'd12 && ry < 10'd24) ||
                (rx >= 10'd8  && rx < 10'd32 && ry >= 10'd6  && ry < 10'd12) ||
                (rx >= 10'd26 && rx < 10'd56 && ry < 10'd12))
                cloud_shape = (ry >= 10'd20) ? 2'd2 : 2'd1;
        end
    endfunction

    // Divide by 3 (0..20 -> 0..6)
    function [2:0] div3;
        input [4:0] v;
        begin
            if      (v < 5'd3)  div3 = 3'd0;
            else if (v < 5'd6)  div3 = 3'd1;
            else if (v < 5'd9)  div3 = 3'd2;
            else if (v < 5'd12) div3 = 3'd3;
            else if (v < 5'd15) div3 = 3'd4;
            else if (v < 5'd18) div3 = 3'd5;
            else                div3 = 3'd6;
        end
    endfunction

    // 5x7 font for "GAME OVER": 0=G 1=A 2=M 3=E 4=space 5=O 6=V 7=E 8=R
    function [4:0] glyph_row;
        input [3:0] ci;
        input [2:0] r;
        begin
            glyph_row = 5'b00000;
            case (ci)
                4'd0: case (r)
                    3'd0: glyph_row = 5'b01110;
                    3'd1: glyph_row = 5'b10001;
                    3'd2: glyph_row = 5'b10000;
                    3'd3: glyph_row = 5'b10111;
                    3'd4: glyph_row = 5'b10001;
                    3'd5: glyph_row = 5'b10001;
                    default: glyph_row = 5'b01111;
                endcase
                4'd1: case (r)
                    3'd0: glyph_row = 5'b01110;
                    3'd1: glyph_row = 5'b10001;
                    3'd2: glyph_row = 5'b10001;
                    3'd3: glyph_row = 5'b11111;
                    3'd4: glyph_row = 5'b10001;
                    3'd5: glyph_row = 5'b10001;
                    default: glyph_row = 5'b10001;
                endcase
                4'd2: case (r)
                    3'd0: glyph_row = 5'b10001;
                    3'd1: glyph_row = 5'b11011;
                    3'd2: glyph_row = 5'b10101;
                    3'd3: glyph_row = 5'b10101;
                    3'd4: glyph_row = 5'b10001;
                    3'd5: glyph_row = 5'b10001;
                    default: glyph_row = 5'b10001;
                endcase
                4'd3, 4'd7: case (r)
                    3'd0: glyph_row = 5'b11111;
                    3'd1: glyph_row = 5'b10000;
                    3'd2: glyph_row = 5'b10000;
                    3'd3: glyph_row = 5'b11110;
                    3'd4: glyph_row = 5'b10000;
                    3'd5: glyph_row = 5'b10000;
                    default: glyph_row = 5'b11111;
                endcase
                4'd5: case (r)
                    3'd0: glyph_row = 5'b01110;
                    3'd1: glyph_row = 5'b10001;
                    3'd2: glyph_row = 5'b10001;
                    3'd3: glyph_row = 5'b10001;
                    3'd4: glyph_row = 5'b10001;
                    3'd5: glyph_row = 5'b10001;
                    default: glyph_row = 5'b01110;
                endcase
                4'd6: case (r)
                    3'd0: glyph_row = 5'b10001;
                    3'd1: glyph_row = 5'b10001;
                    3'd2: glyph_row = 5'b10001;
                    3'd3: glyph_row = 5'b10001;
                    3'd4: glyph_row = 5'b10001;
                    3'd5: glyph_row = 5'b01010;
                    default: glyph_row = 5'b00100;
                endcase
                4'd8: case (r)
                    3'd0: glyph_row = 5'b11110;
                    3'd1: glyph_row = 5'b10001;
                    3'd2: glyph_row = 5'b10001;
                    3'd3: glyph_row = 5'b11110;
                    3'd4: glyph_row = 5'b10100;
                    3'd5: glyph_row = 5'b10010;
                    default: glyph_row = 5'b10001;
                endcase
                default: glyph_row = 5'b00000;
            endcase
        end
    endfunction

    // ---------------- Game state ----------------
    reg [15:0] scroll;     // world position of the screen's left edge
    reg [3:0]  acc;        // sub-pixel accumulator
    reg [5:0]  spd;        // speed 0..63
    reg [7:0]  fuel;
    reg [3:0]  frame;
    reg [5:0]  last_can;   // index of last collected can
    reg [7:0]  seed;       // terrain seed (new one each restart)
    reg [7:0]  rnd;        // free-running counter used to pick the seed

    wire tick  = (hpos == 10'd0) && (vpos == 10'd480);
    wire over  = (fuel == 8'd0) && (spd == 6'd0);
    wire gas   = gas_in && !brake_in && (fuel != 8'd0) && !over;
    wire brake = brake_in && !over;

    // Ground under the wheels
    wire [9:0] gyR = terr(scroll + 16'd150, seed);
    wire [9:0] gyF = terr(scroll + 16'd190, seed);

    wire signed [10:0] sl = $signed({1'b0, gyR}) - $signed({1'b0, gyF});
    wire up   = (sl >  11'sd5);   // front is higher than rear -> uphill
    wire down = (sl < -11'sd5);

    reg signed [8:0] delta;
    always @* begin
        if (brake) begin
            delta = -9'sd3;
        end else if (gas) begin
            if (up)        delta = 9'sd1;
            else if (down) delta = 9'sd3;
            else           delta = 9'sd2;
        end else begin
            if (up)        delta = -9'sd2;
            else if (down) delta = 9'sd0;
            else           delta = -9'sd1;
        end
    end

    wire signed [8:0] spd_s   = {3'b000, spd};
    wire signed [8:0] s_sum   = spd_s + delta;
    wire [5:0] spd_next = s_sum[8] ? 6'd0 :
                          (s_sum > 9'sd63) ? 6'd63 : s_sum[5:0];

    wire [6:0] sum = {3'b000, acc} + {1'b0, spd};

    // Fuel can pickup at the car's world position
    wire [15:0] wxc = scroll + 16'd170;
    wire can_hit = (wxc[9:5] == 5'd16) && (wxc[15:10] != last_can);

    always @(posedge clk) begin
        if (!rst_n) begin
            rnd <= 8'd0;
        end else begin
            rnd <= rnd + 8'd1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            scroll   <= 16'd0;
            acc      <= 4'd0;
            spd      <= 6'd0;
            fuel     <= 8'd255;
            frame    <= 4'd0;
            last_can <= 6'h3F;
            seed     <= 8'd5;
        end else if (over && rst_in) begin
            scroll   <= 16'd0;
            acc      <= 4'd0;
            spd      <= 6'd0;
            fuel     <= 8'd255;
            frame    <= 4'd0;
            last_can <= 6'h3F;
            seed     <= rnd;          // new random track
        end else if (tick && !over) begin
            frame  <= frame + 4'd1;
            spd    <= spd_next;
            scroll <= scroll + {13'd0, sum[6:4]};
            acc    <= sum[3:0];

            if (fuel != 8'd0) begin
                if (gas ? (frame[1:0] == 2'b00) : (frame == 4'd0))
                    fuel <= fuel - 8'd1;
            end

            if (can_hit) begin
                fuel     <= (fuel > 8'd127) ? 8'd255 : (fuel + 8'd128);
                last_can <= wxc[15:10];
            end
        end
    end

    // ---------------- Scenery geometry ----------------
    wire chk = hpos[0] ^ vpos[0];       // checkerboard for dithering

    wire [15:0] wxp = scroll + {6'd0, hpos};
    wire [9:0]  gy  = terr(wxp, seed);
    wire [9:0]  depth = vpos - gy;

    wire ground = (vpos >= gy);
    wire tuft   = (vpos < gy) && (vpos + 10'd4 >= gy) &&
                  ((wxp[4:1] == 4'd5) || (wxp[4:1] == 4'd12));
    wire pebble = ((wxp[3:0] == 4'd3) && (vpos[3:0] == 4'd9)) ||
                  ((wxp[4:0] == 5'd20) && (vpos[2:0] == 3'd2));
    wire speck  = ((wxp[2:0] == 3'd6) && (vpos[1:0] == 2'd1)) ||
                  ((wxp[3:0] == 4'd12) && (vpos[2:0] == 3'd6));

    // Sun
    wire [9:0]  sun_ax = (hpos >= 10'd520) ? (hpos - 10'd520) : (10'd520 - hpos);
    wire [9:0]  sun_ay = (vpos >= 10'd72)  ? (vpos - 10'd72)  : (10'd72 - vpos);
    wire [20:0] sun_r2 = sun_ax * sun_ax + sun_ay * sun_ay;

    // Clouds (half speed, repeat every 1024 px)
    wire [15:0] cxp = {1'b0, scroll[15:1]} + {6'd0, hpos};
    wire [9:0]  cx  = cxp[9:0];
    wire [1:0] cs1 = cloud_shape(cx - 10'd100, vpos - 10'd50);
    wire [1:0] cs2 = cloud_shape(cx - 10'd420, vpos - 10'd100);
    wire [1:0] cs3 = cloud_shape(cx - 10'd760, vpos - 10'd70);
    wire [1:0] cshape = (cs1 != 2'd0) ? cs1 : ((cs2 != 2'd0) ? cs2 : cs3);

    // Far mountains (quarter speed)
    wire [9:0] mx   = scroll[11:2] + hpos;
    wire [7:0] mt   = mx[8] ? ~mx[7:0] : mx[7:0];
    wire [4:0] mt2  = mx[5] ? ~mx[4:0] : mx[4:0];
    wire [9:0] mtop = 10'd334 - {4'd0, mt[7:2]} + {8'd0, mt2[4:3]};
    wire mount = (vpos >= mtop);
    wire snow  = mount && (mtop < 10'd290) && (vpos < mtop + 10'd10);

    // Mid hills (half speed)
    wire [9:0] hx   = scroll[10:1] + hpos + 10'd137;
    wire [6:0] ht   = hx[7] ? ~hx[6:0] : hx[6:0];
    wire [9:0] htop = 10'd354 - {5'd0, ht[6:2]};

    // ---------------- Fuel can ----------------
    wire [9:0] gc  = terr({wxp[15:5], 5'd16}, seed);   // ground at can centre
    wire       can_cell = (wxp[9:5] == 5'd16) && (wxp[15:10] != last_can);
    wire       can_zone = can_cell && (vpos < gc) && (vpos + 10'd20 >= gc);
    wire [9:0] cyc = gc - vpos;
    wire [4:0] cxl = wxp[4:0];
    wire can_body = can_zone && (cxl >= 5'd8) && (cxl < 5'd24) &&
                    (cyc >= 10'd1) && (cyc < 10'd15);
    wire can_edge = can_body && ((cxl == 5'd8) || (cxl == 5'd23) ||
                                 (cyc == 10'd1) || (cyc == 10'd14));
    wire can_strp = can_body && (cyc >= 10'd6) && (cyc < 10'd9);
    wire can_cap  = can_zone && (cxl >= 5'd12) && (cxl < 5'd18) &&
                    (cyc >= 10'd15) && (cyc < 10'd18);
    wire can_hnd  = can_zone && (cxl >= 5'd18) && (cxl < 5'd23) &&
                    (cyc >= 10'd15) && (cyc < 10'd17);

    // ---------------- Car geometry (tilts with the slope) ----------------
    wire [9:0] cyR = gyR - 10'd7;     // wheel centres
    wire [9:0] cyF = gyF - 10'd7;

    wire signed [11:0] s_whl = $signed({2'b00, cyF}) - $signed({2'b00, cyR});
    wire signed [11:0] dxp   = $signed({2'b00, hpos}) - 12'sd150;
    wire signed [23:0] prod  = s_whl * dxp * 12'sd13;
    wire signed [23:0] yoff  = prod >>> 9;
    wire [13:0] lineY = {4'b0000, cyR} + yoff[13:0];
    wire [13:0] kk    = lineY - {4'b0000, vpos};    // height above axle line
    wire        above = ~kk[13];
    wire [13:0] hp14  = {4'b0000, hpos};

    wire body_raw = above && (hpos >= 10'd138) && (hpos < 10'd202) &&
                    (kk >= 14'd2) && (kk < 14'd14);
    wire corner_cut = ((hpos < 10'd140) || (hpos >= 10'd200)) &&
                      ((kk < 14'd4) || (kk >= 14'd12));
    wire body   = body_raw && !corner_cut;
    wire stripe = body && (hpos >= 10'd144) && (hpos < 10'd196) &&
                  (kk >= 14'd8) && (kk < 14'd10);
    wire tail   = above && (hpos >= 10'd138) && (hpos < 10'd142) &&
                  (kk >= 14'd7) && (kk < 14'd11);
    wire head   = above && (hpos >= 10'd198) && (hpos < 10'd202) &&
                  (kk >= 14'd7) && (kk < 14'd11);

    wire cab    = above && (kk >= 14'd14) && (kk < 14'd26) &&
                  (hp14 >= (14'd138 + kk)) && ((hp14 + kk) < 14'd204);
    wire window = cab && (kk >= 14'd16) && (kk < 14'd25) &&
                  (hp14 >= (14'd141 + kk)) && ((hp14 + kk) < 14'd201);
    wire pillar = window && (hpos >= 10'd170) && (hpos < 10'd173);

    wire smoke  = gas && above && (hpos >= 10'd124) && (hpos < 10'd138) &&
                  (kk >= 14'd3) && (kk < 14'd9) &&
                  (hpos[1] ^ kk[1] ^ frame[2]);

    // Round wheels
    wire [9:0] axR = (hpos >= 10'd150) ? (hpos - 10'd150) : (10'd150 - hpos);
    wire [9:0] ayR = (vpos >= cyR)     ? (vpos - cyR)     : (cyR - vpos);
    wire [20:0] r2R = axR * axR + ayR * ayR;
    wire [9:0] axF = (hpos >= 10'd190) ? (hpos - 10'd190) : (10'd190 - hpos);
    wire [9:0] ayF = (vpos >= cyF)     ? (vpos - cyF)     : (cyF - vpos);
    wire [20:0] r2F = axF * axF + ayF * ayF;
    wire spokeR = scroll[2] ? ((axR == 10'd0) || (ayR == 10'd0)) : (axR == ayR);
    wire spokeF = scroll[2] ? ((axF == 10'd0) || (ayF == 10'd0)) : (axF == ayF);

    // ---------------- Scene colour ----------------
    // Colour = {R1,R0,G1,G0,B1,B0}
    reg [5:0] sc;
    always @* begin
        // sky gradient with dithered band edges
        if      (vpos < 10'd66)  sc = 6'b00_01_11;
        else if (vpos < 10'd70)  sc = chk ? 6'b00_10_11 : 6'b00_01_11;
        else if (vpos < 10'd136) sc = 6'b00_10_11;
        else if (vpos < 10'd140) sc = chk ? 6'b01_10_11 : 6'b00_10_11;
        else if (vpos < 10'd206) sc = 6'b01_10_11;
        else if (vpos < 10'd210) sc = chk ? 6'b01_11_11 : 6'b01_10_11;
        else if (vpos < 10'd276) sc = 6'b01_11_11;
        else if (vpos < 10'd280) sc = chk ? 6'b10_11_11 : 6'b01_11_11;
        else if (vpos < 10'd346) sc = 6'b10_11_11;
        else if (vpos < 10'd350) sc = chk ? 6'b11_11_11 : 6'b10_11_11;
        else                     sc = 6'b11_11_11;

        // sun and glow
        if (sun_r2 < 21'd600)                   sc = 6'b11_11_00;
        else if (sun_r2 < 21'd1100 && chk)      sc = 6'b11_11_10;

        // clouds
        if (cshape == 2'd1) sc = 6'b11_11_11;
        if (cshape == 2'd2) sc = 6'b10_10_11;

        // mountains and snow caps
        if (mount) sc = mx[8] ? 6'b00_01_10 : 6'b01_01_10;
        if (snow)  sc = 6'b11_11_11;

        // mid hills
        if (vpos >= htop) sc = (vpos < htop + 10'd3) ? 6'b00_11_01 : 6'b00_10_01;

        // ground
        if (ground) begin
            if (vpos < gy + 10'd2)      sc = 6'b01_11_00;   // bright grass edge
            else if (vpos < gy + 10'd6) sc = 6'b00_10_00;   // grass
            else begin
                sc = (depth < 10'd44) ? 6'b10_01_00 : 6'b01_00_00;  // soil layers
                if (speck)  sc = (depth < 10'd44) ? 6'b01_00_00 : 6'b00_00_00;
                if (pebble) sc = 6'b11_10_01;
            end
        end
        if (tuft) sc = 6'b00_11_00;

        // fuel can
        if (can_body) sc = 6'b11_10_00;
        if (can_strp) sc = 6'b11_11_11;
        if (can_edge) sc = 6'b01_00_00;
        if (can_cap || can_hnd) sc = 6'b01_01_01;

        // exhaust smoke
        if (smoke) sc = 6'b10_10_10;

        // car body
        if (body)                   sc = 6'b11_00_00;
        if (body && kk < 14'd4)     sc = 6'b10_00_00;
        if (stripe)                 sc = 6'b11_11_11;
        if (tail)                   sc = 6'b11_10_00;
        if (head)                   sc = 6'b11_11_00;
        if (cab)                    sc = 6'b11_00_00;
        if (cab && kk == 14'd25)    sc = 6'b11_01_01;
        if (window)                 sc = 6'b01_11_11;
        if (pillar)                 sc = 6'b11_00_00;

        // wheels
        if (r2R < 21'd50) sc = 6'b00_00_00;
        if (r2R < 21'd22) sc = 6'b10_10_10;
        if (r2R < 21'd22 && spokeR) sc = 6'b11_11_11;
        if (r2R < 21'd5)  sc = 6'b01_01_01;
        if (r2F < 21'd50) sc = 6'b00_00_00;
        if (r2F < 21'd22) sc = 6'b10_10_10;
        if (r2F < 21'd22 && spokeF) sc = 6'b11_11_11;
        if (r2F < 21'd5)  sc = 6'b01_01_01;
    end

    // Game-over tint: boost red, dim green and blue
    wire [5:0] tinted = over ? {sc[5:4] | 2'b10, 1'b0, sc[3], 1'b0, sc[1]} : sc;

    // ---------------- HUD ----------------
    wire panel  = (hpos >= 10'd8)  && (hpos < 10'd282) &&
                  (vpos >= 10'd8)  && (vpos < 10'd68);

    // fuel bar
    wire [9:0] fx = hpos - 10'd16;
    wire fb_out = (hpos >= 10'd14) && (hpos < 10'd274) &&
                  (vpos >= 10'd14) && (vpos < 10'd30);
    wire fb_in  = (hpos >= 10'd16) && (hpos < 10'd272) &&
                  (vpos >= 10'd16) && (vpos < 10'd28);
    wire fuel_fill = fb_in && (fx[7:0] < fuel);
    wire fuel_low  = (fuel < 8'd64);
    wire fuel_mid  = (fuel < 8'd128);
    wire fuel_hi   = (vpos < 10'd20);     // top highlight row

    // distance blocks
    wire [9:0] dx = hpos - 10'd16;
    wire hud_dist = (hpos >= 10'd16) && (hpos < 10'd272) &&
                    (vpos >= 10'd34) && (vpos < 10'd46) &&
                    (dx[3:0] < 4'd12) && (dx[7:4] < scroll[13:10]);

    // speed bar
    wire [9:0] sfx = hpos - 10'd16;
    wire sb_out = (hpos >= 10'd14) && (hpos < 10'd274) &&
                  (vpos >= 10'd50) && (vpos < 10'd62);
    wire sb_in  = (hpos >= 10'd16) && (hpos < 10'd272) &&
                  (vpos >= 10'd52) && (vpos < 10'd60);
    wire spd_fill = sb_in && (sfx < {2'b00, spd, 2'b00});

    // ---------------- GAME OVER banner ----------------
    wire banner = over && (hpos >= 10'd236) && (hpos < 10'd404) &&
                  (vpos >= 10'd196) && (vpos < 10'd244);
    wire banner_edge = banner && ((hpos < 10'd238) || (hpos >= 10'd402) ||
                                  (vpos < 10'd198) || (vpos >= 10'd242));

    wire [9:0] tx   = hpos - 10'd248;
    wire [9:0] ty   = vpos - 10'd210;
    wire [3:0] tci  = tx[7:4];
    wire [2:0] tcol = div3({1'b0, tx[3:0]});
    wire [2:0] trow = div3(ty[4:0]);
    wire [4:0] grow = glyph_row(tci, trow);
    wire       tbit = (tcol < 3'd5) ? grow[3'd4 - tcol] : 1'b0;
    wire text_on = over && (hpos >= 10'd248) && (hpos < 10'd392) &&
                   (vpos >= 10'd210) && (vpos < 10'd231) && tbit;

    // ---------------- Final colour ----------------
    reg [5:0] rgb;
    always @* begin
        rgb = tinted;

        if (panel)
            rgb = chk ? 6'b00_00_01
                      : {1'b0, tinted[5], 1'b0, tinted[3], 1'b0, tinted[1]};

        if (fb_out) rgb = 6'b11_11_11;
        if (fb_in)  rgb = 6'b00_00_00;
        if (fuel_fill)
            rgb = fuel_low ? (fuel_hi ? 6'b11_01_01 : 6'b11_00_00) :
                  fuel_mid ? (fuel_hi ? 6'b11_11_01 : 6'b11_11_00) :
                             (fuel_hi ? 6'b01_11_01 : 6'b00_11_00);

        if (hud_dist)
            rgb = (vpos < 10'd36) ? 6'b11_10_11 : 6'b11_01_10;

        if (sb_out) rgb = 6'b11_11_11;
        if (sb_in)  rgb = 6'b00_00_00;
        if (spd_fill)
            rgb = (vpos < 10'd54) ? 6'b01_11_11 : 6'b00_11_11;

        if (banner)      rgb = 6'b10_00_00;
        if (banner_edge) rgb = 6'b11_11_11;
        if (text_on)     rgb = 6'b11_11_11;
    end

    wire [5:0] RGB = display_on ? rgb : 6'b000000;

    // TinyVGA PMOD
    assign uo_out = {hsync, RGB[0], RGB[2], RGB[4], vsync, RGB[1], RGB[3], RGB[5]};

    wire _unused = &{ena, uio_in, ui_in[7], ui_in[3:2], pad_on, 1'b0};

endmodule