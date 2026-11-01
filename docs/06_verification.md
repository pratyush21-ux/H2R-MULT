# 6. Functional verification

## 6.1 Bit-overlap identity

With radix-8 digits `d_i` (weight 2³ⁱ) and radix-4 digits `r_j` (weight 2²ʲ⁺⁶):

```
Q5 net weight :  -q5 * 2^5  (from d_1)  +  q5 * 2^6  (from r_0)  =  q5 * 2^5
other bounds  :  -2^(2j+5) + 2^(2j+6) = 2^(2j+5)        for q(2j+5), j = 1..4
sign bit      :  -2 * q15 * 2^14 = -q15 * 2^15

=> sum_i d_i 2^(3i) + sum_j r_j 2^(2j+6) = Q          for every 16-bit Q
```

Overflow check: |M| ≤ 2¹⁵, |d_i| ≤ 4, |r_j| ≤ 2 gives Σ|PP| ≤ 1,431,437,312 < 2³¹, so 32-bit signed accumulation cannot overflow.

## 6.2 Checks performed

| Check | Method | Result |
|---|---|---|
| Identity above, all Q | evaluation of all 65,536 multiplier patterns | pass |
| Exact hybrid RTL, all Q | 65,536 Q × 21 multiplicands (0, ±1, 32767, −32768, 16 random) = 1,376,256 vectors | 0 mismatches |
| Exact hybrid RTL, random | 10⁶ random signed pairs | 0 mismatches |
| Streaming | new vector every clock cycle, result checked 2 cycles later | 0 mismatches |
| Approximation error bound | all 64 patterns of Q5…Q0 × 2¹⁶ multiplicands | worst case 32\|M\| |

## 6.3 Exhaustive-Q testbench pseudocode

```
FOR each M IN {0, 1, -1, 32767, -32768} + 16 random values:
    FOR Q IN -32768 .. 32767:
        drive A = M, B = Q                      // new pair every clock
        compare DUT.P (2 cycles later) with M * Q
        count mismatches
REPORT total vectors, mismatches
```

## 6.4 Hardware check

Functional correctness was additionally verified on the Basys-3 board with the Vivado ILA at 100 MHz.
