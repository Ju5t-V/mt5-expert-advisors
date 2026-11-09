//+------------------------------------------------------------------+
//|                                             DonchianTrend_EA.mq5 |
//|              Trend-following breakout Expert Advisor (MQL5)      |
//|                                                                  |
//| Strategy                                                         |
//|   Entry : bar CLOSE breaks the N-bar Donchian channel, traded    |
//|           only in the direction of the EMA trend filter          |
//|   Exit  : ATR trailing stop only (no fixed TP, winners run)      |
//|   Size  : fixed-fractional risk (% of balance) derived from the  |
//|           actual stop distance, normalized to broker constraints |
//|   Safety: daily loss circuit breaker, max spread filter,         |
//|           optional session filter, one position at a time        |
//|                                                                  |
//| All signals are evaluated once per new bar on CLOSED data, so    |
//| there is no lookahead bias and backtests match live behaviour.   |
//| Works on both netting and hedging accounts (single position,     |
//| modify-only management).                                         |
//+------------------------------------------------------------------+
#property copyright   "2026"
#property version     "1.20"
#property description "Donchian breakout + EMA filter + ATR trailing, fixed-fractional risk"
//--- v1.10: position sizing now derives loss-per-lot from OrderCalcProfit()
//---        (v1.00 trusted TICK_VALUE/TICK_SIZE and oversized 10x on symbols
//---        whose metadata disagrees with their contract math), adds a final
//---        risk verification clamp and a one-time sizing audit log line.
//--- v1.20: adds two optional regime filters, both OFF by default:
//---        InpMinChanAtr - skip breakouts from channels narrower than
//---        X * ATR (chop filter); InpEmaTf - run the EMA trend filter on a
//---        higher timeframe (e.g. H4/D1) while entering on the signal TF.

#include <Trade\Trade.mqh>

//--- inputs -------------------------------------------------------
input group "=== Strategy ==="
input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_CURRENT;  // Signal timeframe
input int             InpDonchianPeriod = 20;              // Donchian lookback (bars)
input int             InpEmaPeriod      = 200;             // EMA trend filter period
input ENUM_TIMEFRAMES InpEmaTf          = PERIOD_CURRENT;  // EMA filter timeframe (CURRENT = signal TF)
input int             InpAtrPeriod      = 14;              // ATR period
input double          InpAtrStopMult    = 2.0;             // Initial stop = ATR x this
input double          InpAtrTrailMult   = 3.0;             // Trailing stop = ATR x this
input double          InpMinChanAtr     = 0.0;             // Min channel width in ATRs (0 = off)
input bool            InpAllowLong      = true;            // Allow long trades
input bool            InpAllowShort     = true;            // Allow short trades

input group "=== Risk management ==="
input double          InpRiskPercent    = 2.0;             // Risk per trade (% of balance)
input double          InpDailyLossPct   = 4.0;             // Daily loss circuit breaker (%)
input double          InpMaxSpreadPts   = 50;              // Max spread to enter (points)

input group "=== Session filter (server time) ==="
input bool            InpUseSessions    = false;           // Restrict entry hours
input int             InpSessionStart   = 7;               // Session start hour (0-23)
input int             InpSessionEnd     = 20;              // Session end hour (0-23)

input group "=== Misc ==="
input long            InpMagic          = 20260705;        // Magic number
input int             InpSlippagePts    = 30;              // Max slippage (points)

//--- globals ------------------------------------------------------
CTrade g_trade;
int    g_hEMA        = INVALID_HANDLE;
int    g_hATR        = INVALID_HANDLE;
bool   g_haltPrinted = false;

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 10.0)
     {
      Print("InpRiskPercent must be in (0, 10]. Aborting.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpDonchianPeriod < 2 || InpAtrPeriod < 2 || InpEmaPeriod < 2)
     {
      Print("Indicator periods must be >= 2. Aborting.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePts);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   ENUM_TIMEFRAMES emaTf = (InpEmaTf == PERIOD_CURRENT) ? InpTimeframe : InpEmaTf;
   g_hEMA = iMA(_Symbol, emaTf, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hATR = iATR(_Symbol, InpTimeframe, InpAtrPeriod);
   if(g_hEMA == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
     {
      Print("Failed to create indicator handles.");
      return(INIT_FAILED);
     }

   PrintFormat("DonchianTrend_EA started on %s %s | risk %.2f%% | Donchian %d | EMA %d",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()),
               InpRiskPercent, InpDonchianPeriod, InpEmaPeriod);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_hEMA != INVALID_HANDLE) IndicatorRelease(g_hEMA);
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
  }

//+------------------------------------------------------------------+
//| Main tick handler - all logic runs once per closed bar           |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsNewBar())
      return;

   // require enough history for the slowest indicator
   if(Bars(_Symbol, InpTimeframe) < InpEmaPeriod + InpDonchianPeriod + 10)
      return;

   // 1) manage the open position first (ratchet the trailing stop)
   ulong ticket = FindPosition();
   if(ticket > 0)
     {
      ManageTrailing(ticket);
      return;                       // one position at a time
     }

   // 2) daily loss circuit breaker blocks NEW entries only
   if(DailyLossBreached())
     {
      if(!g_haltPrinted)
        {
         Print("Daily loss limit reached. No new entries until the next day.");
         g_haltPrinted = true;
        }
      return;
     }
   g_haltPrinted = false;

   // 3) environment filters
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;
   if(InpUseSessions && !InSession())
      return;
   if(CurrentSpreadPoints() > InpMaxSpreadPts)
      return;

   // 4) look for a breakout signal on the just-closed bar
   CheckEntry();
  }

//+------------------------------------------------------------------+
//| True once per new bar of the signal timeframe                    |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   static datetime last = 0;
   datetime t = iTime(_Symbol, InpTimeframe, 0);
   if(t == last)
      return(false);
   last = t;
   return(true);
  }

//+------------------------------------------------------------------+
//| Read one value from an indicator buffer                          |
//+------------------------------------------------------------------+
double Ind(const int handle, const int shift)
  {
   double buf[1];
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1)
      return(EMPTY_VALUE);
   return(buf[0]);
  }

//+------------------------------------------------------------------+
//| Entry logic: Donchian breakout confirmed by EMA trend filter     |
//| Channel is built from bars 2..N+1 so the signal bar (bar 1) can  |
//| only be compared against PRIOR data - no lookahead.              |
//+------------------------------------------------------------------+
void CheckEntry()
  {
   double close1 = iClose(_Symbol, InpTimeframe, 1);
   double ema1   = Ind(g_hEMA, 1);
   double atr1   = Ind(g_hATR, 1);
   if(ema1 == EMPTY_VALUE || atr1 == EMPTY_VALUE || atr1 <= 0.0)
      return;

   int hhIdx = iHighest(_Symbol, InpTimeframe, MODE_HIGH, InpDonchianPeriod, 2);
   int llIdx = iLowest(_Symbol, InpTimeframe, MODE_LOW,  InpDonchianPeriod, 2);
   if(hhIdx < 0 || llIdx < 0)
      return;

   double donchHigh = iHigh(_Symbol, InpTimeframe, hhIdx);
   double donchLow  = iLow(_Symbol, InpTimeframe, llIdx);

   // optional chop filter: ignore breakouts from narrow, compressed channels
   if(InpMinChanAtr > 0.0 && (donchHigh - donchLow) < InpMinChanAtr * atr1)
      return;

   bool longSignal  = InpAllowLong  && close1 > donchHigh && close1 > ema1;
   bool shortSignal = InpAllowShort && close1 < donchLow  && close1 < ema1;

   if(longSignal)
      OpenTrade(ORDER_TYPE_BUY, atr1);
   else if(shortSignal)
      OpenTrade(ORDER_TYPE_SELL, atr1);
  }

//+------------------------------------------------------------------+
//| Open a market position with ATR-based stop and risk-based size   |
//+------------------------------------------------------------------+
void OpenTrade(const ENUM_ORDER_TYPE type, const double atr)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double stopDist = InpAtrStopMult * atr;

   // respect the broker's minimum stop distance (plus spread buffer)
   double minDist = (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 2) * _Point;
   double spread  = ask - bid;
   if(stopDist < minDist + spread)
      stopDist = minDist + spread;

   double price = (type == ORDER_TYPE_BUY) ? ask : bid;
   double sl    = (type == ORDER_TYPE_BUY)
                  ? NormalizeDouble(ask - stopDist, _Digits)
                  : NormalizeDouble(bid + stopDist, _Digits);

   double lots = CalcLots(type, price, sl);
   if(lots <= 0.0)
     {
      Print("Position sizing returned 0 lots. Trade skipped.");
      return;
     }

   bool ok = false;
   if(type == ORDER_TYPE_BUY)
      ok = g_trade.Buy(lots, _Symbol, 0.0, sl, 0.0, "DonchianTrend");
   else
      ok = g_trade.Sell(lots, _Symbol, 0.0, sl, 0.0, "DonchianTrend");

   if(!ok)
      PrintFormat("Order failed: retcode=%u (%s)",
                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Fixed-fractional position sizing (v1.10)                         |
//| lots = (balance * risk%) / (loss per 1.0 lot at the stop)        |
//|                                                                  |
//| Loss per lot comes from OrderCalcProfit(), i.e. the terminal's   |
//| own profit engine, NOT from tick metadata. v1.00 used            |
//| TICK_VALUE/TICK_SIZE and oversized 10x on symbols whose metadata |
//| disagrees with their actual contract math (MetaQuotes-Demo gold  |
//| among them). Tick math remains only as a fallback, and the final |
//| size is re-verified against the risk budget before returning.    |
//+------------------------------------------------------------------+
double CalcLots(const ENUM_ORDER_TYPE type, const double entryPrice, const double slPrice)
  {
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double stopDist  = MathAbs(entryPrice - slPrice);
   if(stopDist <= 0.0 || riskMoney <= 0.0)
      return(0.0);

   // source of truth: what does 1.0 lot actually lose from entry to SL?
   double lossPerLot = 0.0;
   double p = 0.0;
   if(OrderCalcProfit(type, _Symbol, 1.0, entryPrice, slPrice, p) && MathAbs(p) > 0.0)
      lossPerLot = MathAbs(p);
   else
     {
      // fallback only: tick metadata
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0.0 || tickValue <= 0.0)
         return(0.0);
      lossPerLot = stopDist / tickSize * tickValue;
     }
   if(lossPerLot <= 0.0)
      return(0.0);

   double lots = riskMoney / lossPerLot;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0)
      step = (vMin > 0.0) ? vMin : 0.01;

   lots = MathFloor(lots / step + 1e-9) * step;

   // if even the minimum lot risks more than the budget, skip the trade
   if(lots < vMin)
      return(0.0);
   if(lots > vMax)
      lots = vMax;

   // verification clamp: recompute the worst case at the chosen size and
   // shrink if it still exceeds the budget (bad metadata, rounding,
   // exotic contract specs - whatever the cause, this catches it)
   double check = 0.0;
   if(OrderCalcProfit(type, _Symbol, lots, entryPrice, slPrice, check) &&
      MathAbs(check) > riskMoney * 1.02)
     {
      lots = lots * (riskMoney / MathAbs(check));
      lots = MathFloor(lots / step + 1e-9) * step;
      if(lots < vMin)
         return(0.0);
     }

   // margin check: shrink until the position fits in 80% of free margin
   double margin = 0.0;
   if(!OrderCalcMargin(type, _Symbol, lots, entryPrice, margin))
      return(0.0);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   while(lots >= vMin && margin > freeMargin * 0.8)
     {
      lots -= step;
      if(lots < vMin)
         return(0.0);
      if(!OrderCalcMargin(type, _Symbol, lots, entryPrice, margin))
         return(0.0);
     }

   lots = NormalizeDouble(lots, VolumeDigits(step));

   // one-time sizing audit so a broken symbol spec shows up in the first
   // lines of the journal instead of in the equity curve
   static bool audited = false;
   if(!audited)
     {
      audited = true;
      PrintFormat("SIZING AUDIT: balance=%.2f riskMoney=%.2f stopDist=%.5f lossPerLot(1.0)=%.2f -> lots=%.2f | tickSize=%.5f tickValue=%.5f contract=%.2f",
                  balance, riskMoney, stopDist, lossPerLot, lots,
                  SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE),
                  SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE),
                  SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE));
     }
   return(lots);
  }

//+------------------------------------------------------------------+
//| Decimal places implied by the volume step (0.01 -> 2, 1.0 -> 0)  |
//+------------------------------------------------------------------+
int VolumeDigits(double step)
  {
   int d = 0;
   while(d < 8 && MathAbs(step - NormalizeDouble(step, d)) > 1e-10)
      d++;
   return(d);
  }

//+------------------------------------------------------------------+
//| Find this EA's open position on this symbol (0 if none)          |
//+------------------------------------------------------------------+
ulong FindPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return(ticket);
     }
   return(0);
  }

//+------------------------------------------------------------------+
//| Chandelier-style ATR trailing stop, evaluated on closed bars.    |
//| The stop only ever ratchets in the trade's favour.               |
//+------------------------------------------------------------------+
void ManageTrailing(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return;

   double atr1   = Ind(g_hATR, 1);
   double close1 = iClose(_Symbol, InpTimeframe, 1);
   if(atr1 == EMPTY_VALUE || atr1 <= 0.0)
      return;

   long   type    = PositionGetInteger(POSITION_TYPE);
   double curSL   = PositionGetDouble(POSITION_SL);
   double curTP   = PositionGetDouble(POSITION_TP);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minDist = (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 2) * _Point;

   if(type == POSITION_TYPE_BUY)
     {
      double newSL = NormalizeDouble(close1 - InpAtrTrailMult * atr1, _Digits);
      if((curSL == 0.0 || newSL > curSL + _Point * 0.5) && newSL < bid - minDist)
        {
         if(!g_trade.PositionModify(ticket, newSL, curTP))
            PrintFormat("Trail modify failed: retcode=%u (%s)",
                        g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
        }
     }
   else if(type == POSITION_TYPE_SELL)
     {
      double newSL = NormalizeDouble(close1 + InpAtrTrailMult * atr1, _Digits);
      if((curSL == 0.0 || newSL < curSL - _Point * 0.5) && newSL > ask + minDist)
        {
         if(!g_trade.PositionModify(ticket, newSL, curTP))
            PrintFormat("Trail modify failed: retcode=%u (%s)",
                        g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Realized P/L of this EA's deals since server midnight            |
//| (profit + swap + commission, filtered by magic and symbol)       |
//+------------------------------------------------------------------+
double TodayRealizedPL()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime dayStart = StructToTime(dt);

   if(!HistorySelect(dayStart, TimeCurrent() + 60))
      return(0.0);

   double pl = 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong dTicket = HistoryDealGetTicket(i);
      if(dTicket == 0)
         continue;
      if(HistoryDealGetInteger(dTicket, DEAL_MAGIC) != InpMagic)
         continue;
      if(HistoryDealGetString(dTicket, DEAL_SYMBOL) != _Symbol)
         continue;

      pl += HistoryDealGetDouble(dTicket, DEAL_PROFIT)
          + HistoryDealGetDouble(dTicket, DEAL_SWAP)
          + HistoryDealGetDouble(dTicket, DEAL_COMMISSION);
     }
   return(pl);
  }

//+------------------------------------------------------------------+
//| True when today's loss (realized + floating) >= the daily limit  |
//+------------------------------------------------------------------+
bool DailyLossBreached()
  {
   double realized = TodayRealizedPL();

   double floating = 0.0;
   ulong ticket = FindPosition();
   if(ticket > 0 && PositionSelectByTicket(ticket))
      floating = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

   double dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE) - realized;
   if(dayStartBalance <= 0.0)
      return(false);

   double lossPct = -(realized + floating) / dayStartBalance * 100.0;
   return(lossPct >= InpDailyLossPct);
  }

//+------------------------------------------------------------------+
//| Session filter in broker/server time, supports overnight wrap    |
//+------------------------------------------------------------------+
bool InSession()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpSessionStart <= InpSessionEnd)
      return(dt.hour >= InpSessionStart && dt.hour < InpSessionEnd);
   return(dt.hour >= InpSessionStart || dt.hour < InpSessionEnd);
  }

//+------------------------------------------------------------------+
//| Current spread in points                                         |
//+------------------------------------------------------------------+
double CurrentSpreadPoints()
  {
   return((SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
           SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point);
  }
//+------------------------------------------------------------------+