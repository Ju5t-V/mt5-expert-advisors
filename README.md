# MetaTrader 5 Expert Advisors

MQL5 Expert Advisors I designed and backtested, organized by market.

```
gold/            XAUUSD
nasdaq/          US100 / Nasdaq
forex/           FX pairs
rejected/        Strategies that were backtested and failed (kept for the record)
testing-tools/   MT5-native replay and order-tester harnesses for validating strategy logic
```

| EA | Idea |
|---|---|
| `gold/GoldBreakoutEA`, `gold/GoldBreakoutEA_best` | Previous-day high/low breakout using stop orders. This is the best-performing baseline. |
| `gold/GoldBreakoutRetestEA` | Breakout and retest variant |
| `gold/OneBarGoldEA`, `gold/OneBarBreakoutEA` | One-candle breakout trades with ATR-scaled stops |
| `gold/D_AsiaBreakout` | Asian-session range breakout |
| `nasdaq/GoldenCrossNasdaq` | 50/200 moving-average trend filter |
| `nasdaq/IntradayMomentumEA`, `ITSM_nolunch`, `NasdaqBT_h*` | Intraday time-series momentum studies |
| `nasdaq/Scalp_k15`, `Scalp_k20` | Short-horizon scalping variants |
| `forex/AlexG_StructureEA(_v2)` | Mechanized H4 market-structure continuation on EURUSD |
| `forex/AOI_MeanReversionEA` | Area-of-interest mean reversion |
| `rejected/` | PDH/PDL M1 variants, a Donchian trend EA, and an order-flow scalper |

Install by copying a `.mq5` file into `MQL5/Experts/` and compiling it in MetaEditor. The full research behind these EAs is in [quant-trading-research](https://github.com/Ju5t-V/quant-trading-research).

## Status
🟡 Research collection. Every EA was backtested in the MT5 Strategy Tester.

> ⚠️ Research and educational code only. Not financial advice. Backtests are not a promise of future results.
