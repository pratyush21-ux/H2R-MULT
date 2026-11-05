# 2. RTL pseudocode

Pseudocode of the hardware blocks. Bit widths follow the implementation; names are descriptive.

## 2.1 Top level

```
MODULE H2R_MULT(A[15:0], Q[15:0], clk, rst, load) -> P[31:0], done

    ON rising edge of clk:
        A_reg  <- A
        Q_reg  <- Q
        Q5_reg <- Q[5]                          // shared overlap bit, registered with Q

    PP_msb[25:0] <- RADIX4_BLOCK(A_reg, Q_reg[15:6], Q5_reg)   // exact, 5 PPs
    PP_lsb[21:0] <- RADIX8_BLOCK(A_reg, Q_reg[5:0])            // approximate, 2 PPs (v1 only)

    X[31:0] <- sign_extend(PP_msb) << 6         // align radix-4 result to weight 2^6
    Y[31:0] <- sign_extend(PP_lsb)

    IF variant == v1:
        S <- X + Y                              // exact 32-bit adder
    ELSE IF variant == v2:
        S <- X                                  // radix-8 LSB partial products omitted

    ON rising edge of clk:
        P    <- S
        done <- load
END
```

## 2.2 Radix-8 block (LSB, approximate)

```
FUNCTION RADIX8_BLOCK(M[15:0], q[5:0]) -> PP_sum[21:0]
    q_ext <- {q[5:0], 0}                        // append Q(-1) = 0

    FOR i IN 0..1:
        window <- q_ext[3i+3 : 3i]              // (b2 b1 b0 b-1)
        d      <- RADIX8_DIGIT(window)          // -4..+4

        IF |d| == 3:                            // hard multiple
            d <- sign(d) * 2                    // remap ±3M -> ±2M

        PP[i] <- GENERATE_PP(M, d)              // shift + optional negation only
    END FOR

    PP_sum <- PAA1_ADD(PP[0], PP[1] << 3)       // carry-free accumulation
    RETURN PP_sum
END

FUNCTION RADIX8_DIGIT(b2, b1, b0, b_1) -> d
    RETURN -4*b2 + 2*b1 + b0 + b_1
END

FUNCTION GENERATE_PP(M, d) -> PP
    mag <- |d|                                  // 0, 1, 2 or 4 after remapping
    CASE mag:
        0: base <- 0
        1: base <- M
        2: base <- M << 1
        4: base <- M << 2
    IF d < 0: base <- -base                     // two's complement
    RETURN base
END
```

## 2.3 Radix-4 block (MSB, exact)

```
FUNCTION RADIX4_BLOCK(M[15:0], q_hi[9:0], Q5) -> PP_sum[25:0]
    q_ext <- {q_hi[9:0], Q5}                    // Q5 is the reference bit of group 0

    FOR j IN 0..4:
        window <- q_ext[2j+2 : 2j]              // (b1 b0 b-1)
        r      <- -2*window[2] + window[1] + window[0]   // 0, ±1, ±2
        PP[j]  <- GENERATE_PP(M, r)
    END FOR

    PP_sum <- 0
    FOR j IN 0..4:
        PP_sum <- PP_sum + (PP[j] << 2j)        // exact accumulation
    RETURN PP_sum
END
```

## 2.4 PAA1 adder

```
FUNCTION PAA1_ADD(a[n-1:0], b[n-1:0]) -> s[n-1:0]
    c <- 0
    FOR bit t IN 0..n-1:
        s[t] <- a[t] OR b[t] OR c
        c    <- (a[t] OR b[t]) AND c            // always 0 when c_in = 0
    RETURN s
END
```

## 2.5 H²R-MULTv2 (minimum-hardware variant)

```
FUNCTION H2R_MULT_V2(M[15:0], Q[15:0]) -> P[31:0]
    PP_msb <- RADIX4_BLOCK(M, Q[15:6], Q[5])    // Q5 = reference bit of group 0
    P      <- sign_extend(PP_msb) << 6          // radix-8 block not instantiated
    RETURN P
END
// error: E = -M * Q_L,  Q_L = signed value of Q[5:0]  ->  |E| <= 32|M|
```

## 2.6 Exact reference (baseline)

Same structure with all approximations disabled:

```
- RADIX8_BLOCK: keep d = ±3 (generate 3M = 2M + M), accumulate with exact '+'
- final adder: exact
```

This exact hybrid design is used as the baseline in Table 6 and for the exactness check in [06_verification.md](06_verification.md).
