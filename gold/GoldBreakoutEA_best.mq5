//+------------------------------------------------------------------+
//|                                             GoldBreakoutEA.mq5   |
//|  Previous-day high/low breakout for XAUUSD (MetaTrader 5)        |
//|                                                                  |
//|  Each trading day, at InpEntryHour (server time):                |
//|    - deletes yesterday's unfilled pending orders                 |
//|    - places a BUY STOP at the previous day's high                |
//|    - places a SELL STOP at the previous day's low                |
//|  Both orders stay active, so up to 2 trades can trigger in one   |
//|  day if both levels are tested.                                  |
//|                                                                  |
//|  Once a trade is 300 points (default) in profit, the stop loss   |
//|  is trailed aggressively 150 points (default) behind price on    |
//|  every tick.                                                     |
//|                                                                  |
//|  v1.10 changes (from Jan-Jul 2026 XAUUSD backtest):              |
//|    - InpEntryHour (default 6): orders are placed after the thin  |
//|      Asian session instead of at midnight. In testing, every     |
//|      full stop-out happened on breakouts triggered 00:00-05:59   |
//|      server time. Set to 0 for the old always-on behaviour.      |
//|    - Default SL tightened 1000 -> 500 points: losing breakouts   |
//|      almost never recovered, so the wider stop only lost more.   |
//|                                                                  |
//|  v1.20 changes (validated on 100% real ticks, Jan-Jul 2026):     |
//|    - Trail defaults 100/50 -> 300/150: on real ticks the 50-pt   |
//|      distance was consumed by tick noise within seconds; the     |
//|      wider trail netted ~27% more with the same drawdown and is  |
//|      far more robust to live-broker spreads (15-30 pts).         |
//|    - Auto lot ON by default (2% risk). Fixed 2.0 lots exceeded   |
//|      free margin on a $10k account at 1:100 after one loss.      |
//|                                                                  |
//|  v1.30 changes (after 2020-2022 stress test):                    |
//|    - All SL/TP/trail distances now scale with daily ATR(14)      |
//|      relative to InpAtrRefPts (14000 pts = 2026 calibration).    |
//|      2026 had ~$142 daily ranges vs ~$25-30 in 2020-22; fixed    |
//|      points were 5x oversized there (PF 1.01, 46% drawdown).     |
//|      Floors: SL>=200, TP>=400, start>=150, dist>=80 points.      |
//|      Set InpAtrRefPts=0 to restore fixed-point behaviour.        |
//|                                                                  |
//|  v1.31: recovery mode. When the sum of the last 10 closed        |
//|  trades is negative, risk drops to 1/10 (0.2%) until the small   |
//|  sampling trades turn net positive again. Caps regime damage     |
//|  (2020 COVID chop bled 10 of 12 months) without trying to        |
//|  predict regimes. Disable with InpRecoveryMode=false.            |
//+------------------------------------------------------------------+
#property copyright   "Jerry"
#property version     "1.31"
#property description "Previous-day high/low breakout with aggressive trailing stop"

#include <Trade\Trade.mqh>

//--- inputs
input double InpTakeProfitPts = 1000;     // Take Profit (points)
input double InpStopLossPts   = 500;      // Stop Loss (points)
input int    InpEntryHour     = 6;        // Place orders at this server hour (0 = at day open)
input double InpLotSize       = 0.1;      // Lot Size (used when Auto Lot = false)
input bool   InpAutoLot       = true;     // Auto Lot Size
input double InpRiskPercent   = 2.0;      // Risk % for Auto Lot
input double InpTrailStartPts = 300;      // Trailing Start (points)
input double InpTrailDistPts  = 150;      // Trailing Stop Distance (points)
input double InpAtrRefPts     = 14000;    // ATR reference in points for scaling (0 = fixed points)
input bool   InpRecoveryMode  = true;     // Cut risk to 1/10 while recent trades are net negative
input int    InpRecentTrades  = 10;       // Number of recent trades checked by recovery mode
input ulong  InpMagicNumber   = 20260705; // Magic Number

CTrade   trade;
datetime g_dayStart    = 0;     // opening time of the current daily bar
bool     g_placedToday = false; // whether today's orders have been placed yet
int      g_atrHandle   = INVALID_HANDLE;

// today's volatility-scaled distances (points); refreshed when orders are placed
double   g_slPts, g_tpPts, g_trailStartPts, g_trailDistPts;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(20);

   g_slPts         = InpStopLossPts;
   g_tpPts         = InpTakeProfitPts;
   g_trailStartPts = InpTrailStartPts;
   g_trailDistPts  = InpTrailDistPts;

   if(InpAtrRefPts > 0)
   {
      g_atrHandle = iATR(_Symbol, PERIOD_D1, 14);
      if(g_atrHandle == INVALID_HANDLE)
         Print("iATR handle failed - falling back to fixed points");
   }
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Scale SL/TP/trail with current daily ATR relative to the         |
//| reference. Floors keep distances above spread/tick noise.        |
//+------------------------------------------------------------------+
void RefreshScaledDistances()
{
   double scale = 1.0;
   if(InpAtrRefPts > 0 && g_atrHandle != INVALID_HANDLE)
   {
      double buf[1];
      if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) == 1 && buf[0] > 0.0)
         scale = MathMax(0.1, MathMin(2.0, (buf[0] / _Point) / InpAtrRefPts));
   }
   g_slPts         = MathMax(200.0, InpStopLossPts   * scale);
   g_tpPts         = MathMax(400.0, InpTakeProfitPts * scale);
   g_trailStartPts = MathMax(150.0, InpTrailStartPts * scale);
   g_trailDistPts  = MathMax(80.0,  InpTrailDistPts  * scale);
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(dayStart == 0)
      return; // daily history not loaded yet

   // new trading day -> clear yesterday's unfilled orders
   if(dayStart != g_dayStart)
   {
      g_dayStart    = dayStart;
      g_placedToday = false;
      DeletePendingOrders();
   }

   // place today's orders once the entry hour is reached
   if(!g_placedToday)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour >= InpEntryHour)
      {
         g_placedToday = true;
         PlaceDailyOrders();
      }
   }

   ManageTrailing();
}

//+------------------------------------------------------------------+
//| Place buy stop at previous day high, sell stop at previous low   |
//+------------------------------------------------------------------+
void PlaceDailyOrders()
{
   double prevHigh = iHigh(_Symbol, PERIOD_D1, 1);
   double prevLow  = iLow(_Symbol, PERIOD_D1, 1);
   if(prevHigh <= 0.0 || prevLow <= 0.0)
      return;

   RefreshScaledDistances();

   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = StopsLevelPoints() * _Point;

   bool     canExpire = CanUseSpecifiedExpiry();
   datetime expiry    = g_dayStart + PeriodSeconds(PERIOD_D1);
   ENUM_ORDER_TYPE_TIME timeType = canExpire ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;

   double lots = CalcLots();
   if(lots <= 0.0)
   {
      Print("Lot calculation failed - no orders placed");
      return;
   }

   //--- buy stop at previous day's high
   double entry = NormalizeDouble(prevHigh, _Digits);
   if(entry >= ask + minDist)
   {
      double sl = NormalizeDouble(entry - g_slPts * _Point, _Digits);
      double tp = NormalizeDouble(entry + g_tpPts * _Point, _Digits);
      if(!trade.BuyStop(lots, entry, _Symbol, sl, tp, timeType,
                        canExpire ? expiry : 0, "PDH breakout"))
         PrintFormat("BuyStop @%.2f failed: %u %s",
                     entry, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
   else
      PrintFormat("Buy stop skipped: price already at/above previous day high %.2f (ask %.2f)",
                  prevHigh, ask);

   //--- sell stop at previous day's low
   entry = NormalizeDouble(prevLow, _Digits);
   if(entry <= bid - minDist)
   {
      double sl = NormalizeDouble(entry + g_slPts * _Point, _Digits);
      double tp = NormalizeDouble(entry - g_tpPts * _Point, _Digits);
      if(!trade.SellStop(lots, entry, _Symbol, sl, tp, timeType,
                         canExpire ? expiry : 0, "PDL breakout"))
         PrintFormat("SellStop @%.2f failed: %u %s",
                     entry, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
   else
      PrintFormat("Sell stop skipped: price already at/below previous day low %.2f (bid %.2f)",
                  prevLow, bid);
}

//+------------------------------------------------------------------+
//| Aggressive trailing stop, checked on every tick                  |
//+------------------------------------------------------------------+
void ManageTrailing()
{
   double minDist = StopsLevelPoints() * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
      {
         double profitPts = (bid - open) / _Point;
         if(profitPts < g_trailStartPts)
            continue;
         double newSL = bid - g_trailDistPts * _Point;
         newSL = MathMin(newSL, bid - minDist); // respect broker minimum stop distance
         newSL = NormalizeDouble(newSL, _Digits);
         if(curSL == 0.0 || newSL > curSL + _Point / 2.0) // only ever move SL up
            trade.PositionModify(ticket, newSL, tp);
      }
      else // POSITION_TYPE_SELL
      {
         double profitPts = (open - ask) / _Point;
         if(profitPts < g_trailStartPts)
            continue;
         double newSL = ask + g_trailDistPts * _Point;
         newSL = MathMax(newSL, ask + minDist);
         newSL = NormalizeDouble(newSL, _Digits);
         if(curSL == 0.0 || newSL < curSL - _Point / 2.0) // only ever move SL down
            trade.PositionModify(ticket, newSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
//| Delete this EA's unfilled stop orders on this symbol             |
//+------------------------------------------------------------------+
void DeletePendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagicNumber)
         continue;

      long type = OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
         trade.OrderDelete(ticket);
   }
}

//+------------------------------------------------------------------+
//| Fixed lots, or auto lots risking InpRiskPercent of balance       |
//+------------------------------------------------------------------+
double CalcLots()
{
   double lots = InpLotSize;
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(InpAutoLot)
   {
      // exact money lost per 1.0 lot if the SL is hit, using the broker's own
      // calculation (tick-value fields proved unreliable on some feeds)
      double lossPerLot = 0.0;
      if(!OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, ask,
                          ask - g_slPts * _Point, lossPerLot) || lossPerLot >= 0.0)
      {
         Print("Auto lot: OrderCalcProfit failed - no orders placed");
         return(0.0);
      }
      double riskPct = InpRiskPercent;
      if(InpRecoveryMode && RecentClosedTradesPL(InpRecentTrades) < 0.0)
         riskPct /= 10.0; // losing streak: keep sampling the market at minimal size
      double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0;
      lots = riskMoney / MathAbs(lossPerLot);
   }

   // never request more than 40% of free margin per order (two orders/day)
   double marginPerLot = 0.0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, ask, marginPerLot) && marginPerLot > 0.0)
   {
      double maxLots = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.4 / marginPerLot;
      if(lots > maxLots)
      {
         PrintFormat("Lot size %.2f exceeds margin allowance, reduced to %.2f", lots, maxLots);
         lots = maxLots;
      }
   }

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep > 0.0)
      lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot)
      return(0.0); // cannot trade the broker minimum within the risk limit
   lots = MathMin(maxLot, lots);
   return(NormalizeDouble(lots, 2));
}

//+------------------------------------------------------------------+
//| Summed P/L of this EA's last N closed trades on this symbol      |
//+------------------------------------------------------------------+
double RecentClosedTradesPL(int n)
{
   if(!HistorySelect(0, TimeCurrent() + 60))
      return(0.0);
   double sum = 0.0;
   int    counted = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0 && counted < n; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != (long)InpMagicNumber)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;
      sum += HistoryDealGetDouble(ticket, DEAL_PROFIT)
           + HistoryDealGetDouble(ticket, DEAL_SWAP)
           + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      counted++;
   }
   return(sum);
}

//+------------------------------------------------------------------+
double StopsLevelPoints()
{
   return((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL));
}

//+------------------------------------------------------------------+
//| Does the broker allow pending orders with a specific expiry?     |
//+------------------------------------------------------------------+
bool CanUseSpecifiedExpiry()
{
   long modes = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   return((modes & SYMBOL_EXPIRATION_SPECIFIED) != 0);
}
//+------------------------------------------------------------------+
