
package fp16_pkg;

    //{{{ Convert reat type to fp16
    // Bit-level access to a 64-bit double (real) 
    localparam int SIGN_BIT_F64   = 63;
    localparam int EXP_HI_F64     = 62;
    localparam int EXP_LO_F64     = 52;
    localparam int EXP_BIAS_F64   = 1023;
    localparam int EXP_BIAS_F16   = 15;
    localparam int MANT_BITS_F64  = 52;
    localparam int MANT_BITS_F16  = 10;

    // fp16 exponent special values
    localparam logic [4:0] EXP_INF_F16  = 5'b11111;
    localparam logic [4:0] EXP_ZERO_F16 = 5'b00000;

    // Function: real_to_fp16
    // round to nearest even 
    function automatic logic [15:0] real_to_fp16(input real r);
    // unpack the double 
    logic [63:0] bits64;
    logic        sign;
    logic [10:0] exp64;         // raw biased exponent (11 bits)
    logic [51:0] mant64;        // significand fraction bits
    int          exp_unbiased;  // true exponent (signed)
    int          exp16;         // re-biased for fp16

    // Working variables for rounding
    logic [10:0] mant_shifted;  // 10 mantissa bits + 1 guard bit
    logic        guard, round_bit, sticky;
    logic [9:0]  mant16;
    logic [4:0]  exp16_bits;
    logic [15:0] result;

    // Extract fields from the 64-bit representation 
    bits64      = $realtobits(r);
    sign        = bits64[SIGN_BIT_F64];
    exp64       = bits64[EXP_HI_F64 : EXP_LO_F64];
    mant64      = bits64[MANT_BITS_F64-1 : 0];
    //$display("r       : %0f", r);
    //$display("F64-sign: %0d", sign);
    //$display("F64-exp : 0x-%0h | %0d", exp64, exp64);
    //$display("Fr4-man : 0x-%0h", mant64);

    //{{{ Handle special values 
    // NaN: exponent all-ones AND non-zero mantissa
    if (exp64 == 11'h7FF && mant64 != '0) begin
      result = {sign, EXP_INF_F16, 10'b10_0000_0000}; // quiet NaN
      return result;
    end

    // Infinity: exponent all-ones AND zero mantissa
    if (exp64 == 11'h7FF && mant64 == '0) begin
      result = {sign, EXP_INF_F16, 10'b00_0000_0000}; // ±Inf
      return result;
    end

    // Zero (±0)
    if (exp64 == '0 && mant64 == '0) begin
      result = {sign, 15'b0};
      return result;
    end
    //}}}

    //{{{ Re-bias fp16 
    if (exp64 == '0) begin
        // fp64 subnormal input: treat as denormalized, exp = -1022
        exp_unbiased = -1022;
    end else begin
        exp_unbiased = int'(exp64) - EXP_BIAS_F64;
        //$display("r: %f, exp64: %0d, EXP_BIAS_F64: %0d", r, int`(exp64), EXP_BIAS_F64);
    end
    //$display("unbiased exp: %d", exp_unbiased);
    exp16 = exp_unbiased + EXP_BIAS_F16;
    //$display("----------F16----------");
    //$display(" F16-exp : 0x-%0h | %0d", exp16, exp16);
    // Overflow : ±Inf
    if (exp16 >= 31) begin
        result = {sign, EXP_INF_F16, 10'b00_0000_0000};
        return result;
    end
    //}}}

    //{{{ Normal numbers: 1 <= exp16 <= 30
    // Mantissa: take top 10 bits of mant64, apply round-to-nearest-even
    if (exp16 >= 1) begin
        mant16    = mant64[51:42];          // top 10 bits
        guard     = mant64[41];             // guard bit
        sticky    = |mant64[40:0];          // sticky = OR of remaining bits
        round_bit = guard & (sticky | mant16[0]); // round-to-nearest-even

        // Check if rounding caused mantissa overflow (0x3FF -> 0x400)
        if((mant16 == 10'h3FF) && round_bit) begin
            mant16 = '0;
            exp16  = exp16 + 1;
            // Re-check overflow after round-up
            if (exp16 >= 31) begin
              result = {sign, EXP_INF_F16, 10'b00_0000_0000};
              return result;
            end
        end 
        mant16 = mant16 + {9'b0, round_bit};
        exp16_bits = $unsigned(exp16);
        result = {sign, exp16_bits, mant16};
        //$display("exp16_bits: 0x-%0h", exp16_bits);
        return result;
    end
    //}}}

    //{{{ Subnormal numbers: exp16 <= 0
    // shift_amount = 1 - exp16  (ranges 1..24 for representable subnormals; >= 25 flushes to zero)
    begin
        int shift_amount;
        logic [10:0] full_mant; // 1 (implicit) + 10 bits
        logic [10:0] shifted_mant;

        shift_amount = 1 - exp16;   

        if (shift_amount > 11) begin
            // Too small to represent even as a subnormal → flush to ±0
            result = {sign, 15'b0};
            return result;
        end

        // Reconstruct full significand with implicit leading 1
        // Use top 10 bits of fp64 mantissa
        full_mant = {1'b1, mant64[51:42]};  // 11 bits

        // Shift right; capture guard and sticky for rounding
        shifted_mant = full_mant >> shift_amount;
        guard        = (shift_amount <= 11) ?
                         full_mant[shift_amount - 1] : 1'b0;
        // Sticky: any bit below the guard position
        sticky = 1'b0;
        for (int i = 0; i < shift_amount - 1; i++) begin
            sticky = sticky | full_mant[i];
        end
        sticky = sticky | (|mant64[41:0]); // include lower fp64 bits

        round_bit = guard & (sticky | shifted_mant[0]);
        shifted_mant = shifted_mant + {10'b0, round_bit};

        mant16 = shifted_mant[9:0];
        result = {sign, EXP_ZERO_F16, mant16};
        return result;
    end
    //}}}

    endfunction
    //}}}




endpackage 
