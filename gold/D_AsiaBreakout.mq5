//+------------------------------------------------------------------+
//|                                            D_AsiaBreakout.mq5    |
//|  Asia range breakout, ported from the Python/Pine strategy "D".   |
//|                                                                   |
//|  At the Asia close mark the session high and low and rest a stop   |
//|  order on each side. Whichever breaks is the trade. Target 4R,     |
//|  and trail 3 ATR behind the peak once the trade has moved 1R.      |
//|                                                                   |
//|  EVIDENCE (Python, XAUUSD M30, MetaQuotes-Demo data 2004-2026,     |
//|  257,104 bars, cost modelled at 0.025% round trip):                |
//|    3,956 trades, 47.1% win, avgR +0.074, PF 1.15, 20/23 years up   |
//|    2004-2015 (never used for any parameter choice): avgR +0.075    |
//|    2016-2026 (where the search happened):           avgR +0.072    |
//|      -> no out-of-sample degradation at all                        |
//|    direction control: avgR -0.470, p = 1.4e-107                    |
//|    deflated Sharpe 0.77 at 250 assumed trials                      |
//|                                                                   |
//|  THIS EA EXISTS TO TEST ONE THING the Python work could not:       |
//|  execution. The bar simulator has to guess intrabar ordering and   |
//|  uses an ESTIMATED 0.025% cost. Run this on "Every tick based on   |
//|  real ticks" to get real spread and real fills. If the result      |
//|  collapses, the edge was inside the cost assumption.               |
//|                                                                   |
//|  Designed for M30. Sessions are handled in UTC, not server time.   |
//+------------------------------------------------------------------+
#property copyright   "Jerry"
#property version     "1.00"
#property description "D - Asia range breakout. Bracket the Asia range, 4R target, 3 ATR trail after 1R."

#include <Trade\Trade.mqh>

//--- sessions are defined in UTC. MetaQuotes-Demo runs EET/EEST, i.e.
//--- UTC+2 in winter and UTC+3 in summer, so a fixed offset is WRONG for
//--- five months of the year. TimeGMT() handles the shift; the override is
//--- there only if a broker's GMT reporting turns out to be unreliable.
input int    InpAsiaStartUTC   = 0;      // Asia session start, UTC hour
input int    InpAsiaEndUTC     = 8;      // Asia session end / orders placed, UTC hour
input int    InpArmEndUTC      = 20;     // unfilled orders cancelled, UTC hour
input bool   InpAutoGMT        = true;   // derive server->UTC from TimeGMT()
input int    InpManualOffset   = 3;      // used only when InpAutoGMT = false

input double InpMinRangeATR    = 0.3;    // reject a range narrower than this x ATR
input double InpMaxRangeATR    = 12.0;   // reject a range wider than this x ATR
input int    InpAtrLen         = 14;

input double InpRewardR        = 4.0;    // take profit, in R
input double InpTrailAtr       = 3.0;    // trail distance, x ATR
input double InpTrailStartR    = 1.0;    // begin trailing after this many R
input double InpStopFloorAtr   = 1.0;    // stop never tighter than this x ATR
input double InpTrailStepAtr   = 0.10;   // ignore trail improvements smaller than this x ATR
input bool   InpFlatAtWindowEnd= false;  // tested: closing at the window end COSTS ~2/3 of the edge

input int    InpOffsetPoints   = 20;     // breakout offset beyond the range edge
input double InpRiskPercent    = 0.5;    // % of balance risked per trade
input ulong  InpMagicNumber    = 20260906;

CTrade   g_trade;
int      g_hAtr      = INVALID_HANDLE;
datetime g_lastBar   = 0;

double   g_asiaHi    = 0.0;
double   g_asiaLo    = 0.0;
bool     g_frozen    = false;
bool     g_valid     = false;
bool     g_placed    = false;
int      g_day       = -1;

double   g_peak      = 0.0;     // extreme reached since entry, for the trail
double   g_initStop  = 0.0;
ulong    g_posTicket = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_hAtr = iATR(_Symbol, PERIOD_CURRENT, InpAtrLen);
   if(g_hAtr == INVALID_HANDLE)
     {
      Print("FATAL: could not create ATR handle");
      return(INIT_FAILED);
     }
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);      // otherwise every modify is logged

   // log the offset actually in use -- a silent server/UTC mismatch would shift
   // every Asia range by an hour and is the single most likely way this port
   // could be wrong while still looking plausible
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double cs = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(ts > 0.0 && cs > 0.0)
     {
      double viaTick = tv / ts;          // value of a 1.0 price move, 1 lot
      if(viaTick > 0.0 && (viaTick / cs > 1.5 || cs / viaTick > 1.5))
         PrintFormat("WARNING: broker metadata inconsistent -- tick model says %.2f per $1 "
                     "but contract size says %.2f. Sizing uses OrderCalcProfit.", viaTick, cs);
     }
   PrintFormat("D_AsiaBreakout init | server=%s  GMT=%s  offset=%dh  (auto=%s)",
               TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES),
               TimeToString(TimeGMT(),     TIME_DATE|TIME_MINUTES),
               ServerToUtcHours(), (InpAutoGMT ? "yes" : "no"));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) { if(g_hAtr != INVALID_HANDLE) IndicatorRelease(g_hAtr); }

//+------------------------------------------------------------------+
//| Hours to subtract from server time to reach UTC.                  |
//+------------------------------------------------------------------+
int ServerToUtcHours()
  {
   if(!InpAutoGMT) return(InpManualOffset);
   int d = (int)MathRound((double)(TimeCurrent() - TimeGMT()) / 3600.0);
   if(d < -12 || d > 14) return(InpManualOffset);   // implausible -> fall back
   return(d);
  }

datetime UtcNow() { return(TimeCurrent() - (datetime)(ServerToUtcHours() * 3600)); }

//+------------------------------------------------------------------+
double Atr()
  {
   double buf[];
   if(CopyBuffer(g_hAtr, 0, 0, 2, buf) < 2) return(0.0);
   return(buf[1]);          // last CLOSED bar, never the forming one
  }

//+------------------------------------------------------------------+
//| Lots for a given stop distance at InpRiskPercent of balance.      |
//+------------------------------------------------------------------+
double LotsFor(double stopDistance)
  {
   if(stopDistance <= 0.0) return(0.0);

   // Ask the TERMINAL what a 1.00-lot loss would actually be, rather than
   // deriving it from SYMBOL_TRADE_TICK_VALUE. On MetaQuotes-Demo that field is
   // 0.1 for XAUUSD while the contract size is 100, i.e. it disagrees with the
   // broker's own P&L model by 10x. Sizing off it made every trade ten times
   // too large -- 5% risk instead of 0.5% - and turned a 15% drawdown into 88%.
   // OrderCalcProfit uses the same model the tester books with, so it cannot
   // drift from reality this way.
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(price <= 0.0) price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lossOneLot = 0.0;
   if(!OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, price, price - stopDistance, lossOneLot))
      return(0.0);
   lossOneLot = MathAbs(lossOneLot);
   if(lossOneLot <= 0.0) return(0.0);

   double risk = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double lots = risk / lossOneLot;

   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   if(lots < minLot) return(0.0);        // cannot be sized -> skip, never round up
   if(lots > maxLot) lots = maxLot;
   return(NormalizeDouble(lots, 2));
  }

//+------------------------------------------------------------------+
void DeletePendings()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      g_trade.OrderDelete(tk);
     }
  }

bool HasPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| MT5 has no OCA group. The moment one side fills the other must be |
//| removed, or a reversal inside the same bar can fill both and the  |
//| backtest quietly books a hedge that was never intended.           |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && trans.symbol == _Symbol)
      if(HasPosition()) DeletePendings();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime bt = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(bt == g_lastBar) return;
   g_lastBar = bt;

   // Trail once per BAR. The Python simulator behind the evidence updates the
   // trail at each bar close; doing it per tick is a different strategy, and it
   // produced thousands of sub-cent stop modifications (a 256 MB tester log)
   // that no broker would accept.
   ManageOpenPosition();

   MqlDateTime u;
   TimeToStruct(UtcNow(), u);

   // --- new UTC day: reset everything
   if(u.day != g_day)
     {
      g_day    = u.day;
      g_asiaHi = 0.0;
      g_asiaLo = 0.0;
      g_frozen = false;
      g_valid  = false;
      g_placed = false;
     }

   double hi = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double lo = iLow (_Symbol, PERIOD_CURRENT, 1);
   MqlDateTime up;
   TimeToStruct(UtcNow() - PeriodSeconds(PERIOD_CURRENT), up);   // the bar that just closed

   // --- accumulate the Asia range from CLOSED bars only
   if(!g_frozen && up.hour >= InpAsiaStartUTC && up.hour < InpAsiaEndUTC)
     {
      if(g_asiaHi == 0.0 || hi > g_asiaHi) g_asiaHi = hi;
      if(g_asiaLo == 0.0 || lo < g_asiaLo) g_asiaLo = lo;
     }

   // --- freeze at the Asia close and latch the range/ATR verdict in the SAME
   //     instant. Re-testing it later was a real bug in the first version: the
   //     range is fixed but ATR keeps moving, so the filter switched itself off.
   if(!g_frozen && u.hour >= InpAsiaEndUTC && g_asiaHi > 0.0 && g_asiaLo > 0.0)
     {
      g_frozen = true;
      double a = Atr();
      if(a > 0.0)
        {
         double ratio = (g_asiaHi - g_asiaLo) / a;
         g_valid = (ratio >= InpMinRangeATR && ratio <= InpMaxRangeATR);
        }
     }

   // --- place the bracket once
   if(g_frozen && g_valid && !g_placed && !HasPosition() &&
      u.hour >= InpAsiaEndUTC && u.hour < InpArmEndUTC)
      PlaceBracket();

   // --- cancel anything unfilled at the window end. The POSITION is left to
   //     run: flattening here was tested and cost about two thirds of the edge.
   if(u.hour >= InpArmEndUTC)
     {
      DeletePendings();
      if(InpFlatAtWindowEnd && HasPosition())
         g_trade.PositionClose(_Symbol);
     }
  }

//+------------------------------------------------------------------+
void PlaceBracket()
  {
   double a = Atr();
   if(a <= 0.0) return;

   double point = _Point;
   double off   = InpOffsetPoints * point;
   double up    = NormalizeDouble(g_asiaHi + off, _Digits);
   double dn    = NormalizeDouble(g_asiaLo - off, _Digits);

   // stop = the opposite edge, floored at InpStopFloorAtr ATR
   double slUp  = NormalizeDouble(MathMin(g_asiaLo, up - InpStopFloorAtr * a), _Digits);
   double slDn  = NormalizeDouble(MathMax(g_asiaHi, dn + InpStopFloorAtr * a), _Digits);
   double rUp   = up - slUp;
   double rDn   = slDn - dn;
   if(rUp <= 0.0 || rDn <= 0.0) return;

   double tpUp  = NormalizeDouble(up + InpRewardR * rUp, _Digits);
   double tpDn  = NormalizeDouble(dn - InpRewardR * rDn, _Digits);

   // a pending order must sit at least SYMBOL_TRADE_STOPS_LEVEL away
   long   lvl   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minD  = lvl * point;
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double lotUp = LotsFor(rUp);
   double lotDn = LotsFor(rDn);

   bool okUp = (lotUp > 0.0 && up - ask >= minD);
   bool okDn = (lotDn > 0.0 && bid - dn >= minD);
   if(!okUp && !okDn) return;

   if(okUp) g_trade.BuyStop (lotUp, up, _Symbol, slUp, tpUp, ORDER_TIME_GTC, 0, "D asia up");
   if(okDn) g_trade.SellStop(lotDn, dn, _Symbol, slDn, tpDn, ORDER_TIME_GTC, 0, "D asia dn");
   g_placed = true;
  }

//+------------------------------------------------------------------+
//| Trail InpTrailAtr ATR behind the peak, but only once the trade    |
//| has moved InpTrailStartR in favour. Before that the original stop |
//| stands, so a position is not shaken out before proving anything.  |
//| The stop is never moved against the position.                     |
//+------------------------------------------------------------------+
void ManageOpenPosition()
  {
   if(!PositionSelect(_Symbol)) { g_posTicket = 0; g_peak = 0.0; return; }
   if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) return;

   ulong  tk    = (ulong)PositionGetInteger(POSITION_TICKET);
   double open  = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl    = PositionGetDouble(POSITION_SL);
   double tp    = PositionGetDouble(POSITION_TP);
   long   type  = PositionGetInteger(POSITION_TYPE);

   if(tk != g_posTicket)          // new position -> seed the trail state
     {
      g_posTicket = tk;
      g_peak      = open;
      g_initStop  = sl;
     }

   double a = Atr();
   if(a <= 0.0 || g_initStop == 0.0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   long   lvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minD= lvl * _Point;

   if(type == POSITION_TYPE_BUY)
     {
      double risk = open - g_initStop;
      if(risk <= 0.0) return;
      double bh = iHigh(_Symbol, PERIOD_CURRENT, 1);
      if(bh > g_peak) g_peak = bh;
      if((g_peak - open) / risk < InpTrailStartR) return;
      double want = NormalizeDouble(g_peak - InpTrailAtr * a, _Digits);
      double step = MathMax(InpTrailStepAtr * a, 10 * _Point);
      if(want > sl + step && want < bid - minD)
         g_trade.PositionModify(tk, want, tp);
     }
   else
     {
      double risk = g_initStop - open;
      if(risk <= 0.0) return;
      double bl = iLow(_Symbol, PERIOD_CURRENT, 1);
      if(g_peak == 0.0 || bl < g_peak) g_peak = bl;
      if((open - g_peak) / risk < InpTrailStartR) return;
      double want = NormalizeDouble(g_peak + InpTrailAtr * a, _Digits);
      double step = MathMax(InpTrailStepAtr * a, 10 * _Point);
      if((sl == 0.0 || want < sl - step) && want > ask + minD)
         g_trade.PositionModify(tk, want, tp);
     }
  }
//+------------------------------------------------------------------+
