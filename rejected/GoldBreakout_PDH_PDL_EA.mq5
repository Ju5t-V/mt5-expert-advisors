//+------------------------------------------------------------------+
//|                                           PDH_PDL_Breakout.mq5  |
//|                          Previous Day High/Low Breakout EA       |
//|                          Optimized for Gold (XAUUSD)             |
//|                          v3.0 — fixes: OCO, ATR trail, risk sizing, buffer, sessions       |
//+------------------------------------------------------------------+
#property copyright "PDH/PDL Breakout EA"
#property link      ""
#property version   "3.03"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>
#include <Trade\DealInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+

input group "=== Risk Management ==="
input bool   InpAutoLot        = true;            // Auto Lot Size by Risk % (recommended ON)
input double InpRiskPercent    = 2.0;             // Risk % of balance per trade (now ACCURATE via OrderCalcProfit)
input double InpManualLots     = 0.10;            // Manual Lot Size (used ONLY if Auto Lot is OFF)
input int    InpStopLossPoints = 1000;            // Stop Loss (points)
input bool   InpUseFixedTP     = false;           // Use fixed TP? false = ride the trailing stop (lets winners run)
input int    InpTakeProfitPts  = 1000;            // Take Profit (points) - used ONLY if InpUseFixedTP
input int    InpBreakoutBuffer = 50;              // Buffer past PDH/PDL before entry (points) - anti-fakeout

input group "=== Trailing Stop (ATR-based) ==="
input double InpTrailStartRR    = 1.0;            // Start trailing only after price is this many R in profit
input ENUM_TIMEFRAMES InpTrailATRTF = PERIOD_H1;  // ATR timeframe for trail distance (avoid M1)
input int    InpTrailATRPeriod  = 14;             // ATR period
input double InpTrailATRMult    = 2.0;            // Trail distance = ATR x this (wide enough to let it run)
input int    InpTrailStepPts    = 50;             // Min SL improvement before re-trailing (anti-spam)

input group "=== Safety Filters ==="
input int    InpMaxSpreadPts   = 80;              // Max Allowed Spread (points)
input int    InpOrderDelayMins = 5;               // Min minutes after midnight before arming
input bool   InpDeleteOpposite = true;            // OCO: delete opposite pending once one fills (recommended ON)
input bool   InpUseSession     = true;            // Only arm orders during sessions below (BROKER server time)
input int    InpSess1Start     = 9;               // Session 1 start hour (server)  ~London
input int    InpSess1End       = 12;              // Session 1 end hour (server)
input int    InpSess2Start     = 15;              // Session 2 start hour (server)  ~New York
input int    InpSess2End       = 19;              // Session 2 end hour (server)

input group "=== Circuit Breaker ==="
input bool   InpUseCircuitBreaker = true;          // Master switch for the circuit breaker
input double InpMaxDailyLossPct   = 6.0;           // Pause rest of day if today's loss exceeds this % (0=off)
input int    InpMaxConsecLosses   = 4;             // Pause after this many losing trades in a row (0=off)
input int    InpCooldownDays      = 3;             // Days to pause after a consecutive-loss trip

input group "=== Info Panel ==="
input int    InpPanelX         = 15;              // Panel X (px from left)
input int    InpPanelY         = 30;              // Panel Y (px from top)
input color  InpPanelBg        = C'20,24,36';     // Panel background
input color  InpHeaderColor    = C'100,181,246';  // Header text
input color  InpLabelColor     = C'176,190,197';  // Label text
input color  InpValueColor     = clrWhite;         // Value text
input color  InpProfitColor    = C'102,187,106';  // Profit / bullish
input color  InpLossColor      = C'239,83,80';    // Loss / bearish
input color  InpNeutralColor   = C'255,183,77';   // Pending / neutral

input group "=== Journal / Logging ==="
input bool   InpEnableJournal  = true;            // Enable CSV trade journal
input string InpJournalFile    = "PDH_PDL_Journal.csv"; // Journal filename
input bool   InpEnableAlerts   = false;            // Enable MT5 Alerts

input group "=== EA Settings ==="
input int    InpMagicNumber    = 202501;          // Magic Number

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade            g_trade;
CPositionInfo     g_position;
COrderInfo        g_order;
CDealInfo         g_deal;

double   g_pdh              = 0.0;
double   g_pdl              = 0.0;
double   g_point            = 0.0;
int      g_digits           = 5;
datetime g_lastDayProcessed = 0;
ulong    g_buyStopTicket    = 0;
ulong    g_sellStopTicket   = 0;
int      g_atrHandle        = INVALID_HANDLE;

// Session stats — reset each new day
int      g_sessWins         = 0;
int      g_sessLosses       = 0;
double   g_sessPnl          = 0.0;
int      g_sessTradesTotal  = 0;

// Lifetime stats — accumulate over EA run
int      g_totalWins        = 0;
int      g_totalLosses      = 0;
double   g_totalPnl         = 0.0;
int      g_totalTrades      = 0;
double   g_peakBalance      = 0.0;
double   g_dayStartBalance  = 0.0;
int      g_consecLosses     = 0;
datetime g_breakerDay       = 0;
bool     g_haltToday        = false;
datetime g_cooldownUntil    = 0;
double   g_maxDrawdown      = 0.0;

// Panel prefix for all chart objects
string   g_pfx              = "PDHL_";

// Track position count to detect closes
int      g_lastPositionCount = 0;

// Track last logged deal ticket to avoid duplicates
ulong    g_lastLoggedDeal   = 0;

//+------------------------------------------------------------------+
//| Panel layout constants                                           |
//+------------------------------------------------------------------+
#define PANEL_W   262
#define ROW_H     18
#define FONT_SIZE 8
#define FONT_FACE "Consolas"

enum EPanelRow
{
   ROW_HEADER = 0,
   ROW_SEP1,
   ROW_SYMBOL,
   ROW_PRICE,
   ROW_SPREAD,
   ROW_SEP2,
   ROW_PDH,
   ROW_PDL,
   ROW_RANGE,
   ROW_SEP3,
   ROW_BUY_STATUS,
   ROW_SELL_STATUS,
   ROW_SEP4,
   ROW_OPEN_TRADES,
   ROW_OPEN_PNL,
   ROW_TRAIL_STATUS,
   ROW_SEP5,
   ROW_SESS_TRADES,
   ROW_SESS_WL,
   ROW_SESS_PNL,
   ROW_SEP6,
   ROW_TOTAL_TRADES,
   ROW_TOTAL_WR,
   ROW_TOTAL_PNL,
   ROW_MAX_DD,
   ROW_BALANCE,
   ROW_SEP7,
   ROW_LOTS,
   ROW_SLTP,
   ROW_LAST
};

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(30);
   g_trade.SetTypeFilling(GetFillingMode());

   g_atrHandle = iATR(_Symbol, InpTrailATRTF, InpTrailATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
      Print("WARNING: ATR handle failed; trail will use a fixed fallback distance.");

   PrintFormat("PDH/PDL v3.0 | Broker server time: %s | Server-GMT offset: %+.1f h (set session hours in server time)",
               TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES),
               (double)(TimeCurrent() - TimeGMT()) / 3600.0);

   g_peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   PanelCreate();

   if(InpEnableJournal)
      JournalInit();

   EventSetTimer(1);

   JournalWrite("EA_EVENT","INIT",0,0,0,0,0,AccountInfoDouble(ACCOUNT_BALANCE),
                "EA v2.0 started | Magic="+IntegerToString(InpMagicNumber)+
                " | Symbol="+_Symbol);

   Print("PDH/PDL Breakout EA v2.0 | ",_Symbol," | Point:",g_point," Digits:",g_digits);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   PanelDelete();
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   JournalWrite("EA_EVENT","DEINIT",0,0,0,0,0,AccountInfoDouble(ACCOUNT_BALANCE),
                "EA stopped | Reason="+IntegerToString(reason));
}

//+------------------------------------------------------------------+
//| OnTimer — refresh panel every second                             |
//+------------------------------------------------------------------+
void OnTimer()
{
   PanelUpdate();
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   CheckNewDay();
   ManageTrailingStop();
   if(InpDeleteOpposite) CheckAndCancelOpposite();
   DetectPositionClose();
}

//+------------------------------------------------------------------+
//| Detect position close and update stats / journal                 |
//+------------------------------------------------------------------+
void DetectPositionClose()
{
   int currentCount = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!g_position.SelectByIndex(i))          continue;
      if(g_position.Magic()  != InpMagicNumber) continue;
      if(g_position.Symbol() != _Symbol)        continue;
      currentCount++;
   }

   if(currentCount < g_lastPositionCount)
      ScanRecentDeals();

   g_lastPositionCount = currentCount;
}

//+------------------------------------------------------------------+
//| Scan deal history for newly closed trades                        |
//+------------------------------------------------------------------+
void ScanRecentDeals()
{
   datetime from = (g_lastDayProcessed > 0) ? g_lastDayProcessed : TimeCurrent() - 86400;
   HistorySelect(from, TimeCurrent());

   for(int i = HistoryDealsTotal()-1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)                                                    continue;
      if(HistoryDealGetInteger(ticket,DEAL_MAGIC)  != InpMagicNumber)   continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)          continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket,DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if(ticket == g_lastLoggedDeal)                                     continue;

      g_lastLoggedDeal = ticket;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                    + HistoryDealGetDouble(ticket, DEAL_SWAP)
                    + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      double closePrice = HistoryDealGetDouble(ticket,  DEAL_PRICE);
      double volume     = HistoryDealGetDouble(ticket,  DEAL_VOLUME);
      string comment    = HistoryDealGetString(ticket,  DEAL_COMMENT);
      long   dealType   = HistoryDealGetInteger(ticket, DEAL_TYPE);
      string direction  = (dealType == DEAL_TYPE_BUY) ? "BUY_CLOSE" : "SELL_CLOSE";

      g_totalTrades++;   g_sessTradesTotal++;
      g_totalPnl   += profit;
      g_sessPnl    += profit;

      if(profit >= 0) { g_totalWins++;   g_sessWins++;   }
      else            { g_totalLosses++; g_sessLosses++; }

      // Drawdown tracking
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(balance > g_peakBalance) g_peakBalance = balance;
      double dd = g_peakBalance - balance;
      if(dd > g_maxDrawdown) g_maxDrawdown = dd;

      string outcome = (profit >= 0) ? "WIN" : "LOSS";

      JournalWrite("TRADE_CLOSE", direction, closePrice, 0, 0, volume, profit, balance,
                   "Ticket="+IntegerToString((long)ticket)+
                   " | Outcome="+outcome+
                   " | Comment="+comment);

      if(InpEnableAlerts)
         Alert(_Symbol," | Trade Closed | ",outcome," | P&L: $",DoubleToString(profit,2));

      break; // one deal per tick cycle
   }
}

//+------------------------------------------------------------------+
//| New day detection — place PDH/PDL pending orders                 |
//+------------------------------------------------------------------+
void CheckNewDay()
{
   MqlDateTime dt;
   datetime    now = TimeCurrent();
   TimeToStruct(now, dt);
   datetime todayStart = now - (dt.hour*3600 + dt.min*60 + dt.sec);

   if(InpUseCircuitBreaker && todayStart != g_breakerDay)
   {
      g_breakerDay      = todayStart;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_haltToday       = false;
   }

   if(g_lastDayProcessed == todayStart) return;

   int elapsedMins = (int)((now - todayStart) / 60);
   if(elapsedMins < InpOrderDelayMins) return;

   // Only arm during the chosen session windows (avoids the midnight/rollover spread blowout)
   if(InpUseSession && !IsSessionActive()) return;

   if(InpUseCircuitBreaker)
   {
      if(g_haltToday) return;                       // daily-loss pause (resets next day)
      if(TimeCurrent() < g_cooldownUntil) return;   // consecutive-loss cooldown
   }

   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPts)
   {
      Print("Spread too wide (",spread," pts). Waiting...");
      return;
   }

   MqlRates bars[];
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, bars) != 1)
   { Print("ERROR: Cannot fetch D1 data."); return; }

   g_pdh = bars[0].high;
   g_pdl = bars[0].low;
   g_lastDayProcessed = todayStart;

   // Reset session stats
   g_sessWins = 0; g_sessLosses = 0;
   g_sessPnl  = 0; g_sessTradesTotal = 0;

   Print("New Day | PDH:",DoubleToString(g_pdh,g_digits),
         " | PDL:",DoubleToString(g_pdl,g_digits));

   JournalWrite("DAY_OPEN","NEW_DAY",g_pdh,g_pdl,0,
                InpAutoLot ? CalcAutoLot() : InpManualLots,
                0, AccountInfoDouble(ACCOUNT_BALANCE),
                "Spread="+DoubleToString(spread,0)+"pts"+
                " | Delay="+IntegerToString(elapsedMins)+"min");

   CancelAllPendingOrders();

   double lots = NormalizeLots(InpAutoLot ? CalcAutoLot() : InpManualLots);
   if(lots <= 0) { Print("ERROR: Invalid lot size."); return; }

   double sl     = InpStopLossPoints  * g_point;
   double tp     = InpUseFixedTP ? (InpTakeProfitPts * g_point) : 0.0;
   double buffer = InpBreakoutBuffer  * g_point;

   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long   stopsL = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minD   = ((double)stopsL + 5.0) * g_point;

   // --- BUY STOP at PDH + buffer ---
   double bEntry = NormalizeDouble(g_pdh + buffer, g_digits);
   double bSL    = NormalizeDouble(bEntry - sl, g_digits);
   double bTP    = (tp > 0) ? NormalizeDouble(bEntry + tp, g_digits) : 0.0;

   if(bEntry > ask + minD &&
      g_trade.BuyStop(lots, bEntry, _Symbol, bSL, bTP, ORDER_TIME_DAY, 0, "PDH BuyStop"))
   {
      g_buyStopTicket = g_trade.ResultOrder();
      JournalWrite("ORDER_PLACED","BUY_STOP",bEntry,bSL,bTP,lots,0,
                   AccountInfoDouble(ACCOUNT_BALANCE),
                   "Ticket="+IntegerToString((long)g_buyStopTicket));
      Print("Buy Stop #",g_buyStopTicket," | E:",bEntry," SL:",bSL," TP:",bTP," L:",lots);
   }
   else if(bEntry <= ask + minD)
      Print("Skip BuyStop: price already above PDH+buffer.");
   else Print("ERROR BuyStop: ",g_trade.ResultRetcodeDescription());

   // --- SELL STOP at PDL - buffer ---
   double sEntry = NormalizeDouble(g_pdl - buffer, g_digits);
   double sSL    = NormalizeDouble(sEntry + sl, g_digits);
   double sTP    = (tp > 0) ? NormalizeDouble(sEntry - tp, g_digits) : 0.0;

   if(sEntry < bid - minD &&
      g_trade.SellStop(lots, sEntry, _Symbol, sSL, sTP, ORDER_TIME_DAY, 0, "PDL SellStop"))
   {
      g_sellStopTicket = g_trade.ResultOrder();
      JournalWrite("ORDER_PLACED","SELL_STOP",sEntry,sSL,sTP,lots,0,
                   AccountInfoDouble(ACCOUNT_BALANCE),
                   "Ticket="+IntegerToString((long)g_sellStopTicket));
      Print("Sell Stop #",g_sellStopTicket," | E:",sEntry," SL:",sSL," TP:",sTP," L:",lots);
   }
   else if(sEntry >= bid - minD)
      Print("Skip SellStop: price already below PDL-buffer.");
   else Print("ERROR SellStop: ",g_trade.ResultRetcodeDescription());

   if(InpEnableAlerts)
      Alert(_Symbol," | New Orders | PDH:",DoubleToString(g_pdh,g_digits),
            " PDL:",DoubleToString(g_pdl,g_digits));
}

//+------------------------------------------------------------------+
//| Aggressive trailing stop                                         |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(!IsMarketOpen()) return;   // don't attempt SL modifications during the daily break / weekend

   double atr     = GetTrailATR();
   double trlDist = (atr > 0) ? atr * InpTrailATRMult
                              : InpStopLossPoints * g_point * 0.5; // sane fallback, not 50pt
   double startD  = InpStopLossPoints * g_point * InpTrailStartRR;                 // 1R cushion
   double stepD   = InpTrailStepPts * g_point;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!g_position.SelectByIndex(i))          continue;
      if(g_position.Magic()  != InpMagicNumber) continue;
      if(g_position.Symbol() != _Symbol)        continue;

      double entry = g_position.PriceOpen();
      double curSL = g_position.StopLoss();
      double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(g_position.PositionType() == POSITION_TYPE_BUY)
      {
         if(bid - entry < startD) continue;                  // wait until +1R in profit
         double newSL = NormalizeDouble(bid - trlDist, g_digits);
         if(newSL > curSL + stepD && newSL >= entry)         // meaningful move, never below entry
            g_trade.PositionModify(g_position.Ticket(), newSL, g_position.TakeProfit());
      }
      else if(g_position.PositionType() == POSITION_TYPE_SELL)
      {
         if(entry - ask < startD) continue;
         double newSL = NormalizeDouble(ask + trlDist, g_digits);
         if((curSL == 0.0 || newSL < curSL - stepD) && newSL <= entry)
            g_trade.PositionModify(g_position.Ticket(), newSL, g_position.TakeProfit());
      }
   }
}

//+------------------------------------------------------------------+
//| Read latest ATR value for the trail                              |
//+------------------------------------------------------------------+
double GetTrailATR()
{
   if(g_atrHandle == INVALID_HANDLE) return 0.0;
   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) <= 0) return 0.0;
   return buf[0];
}

//+------------------------------------------------------------------+
//| Cancel opposite pending when one fills                           |
//+------------------------------------------------------------------+
void CheckAndCancelOpposite()
{
   bool buyFilled  = !PendingOrderExists(g_buyStopTicket)  && g_buyStopTicket  != 0;
   bool sellFilled = !PendingOrderExists(g_sellStopTicket) && g_sellStopTicket != 0;
   bool buyOpen    =  PositionExistsByMagic(POSITION_TYPE_BUY);
   bool sellOpen   =  PositionExistsByMagic(POSITION_TYPE_SELL);

   if(buyFilled && buyOpen && PendingOrderExists(g_sellStopTicket))
   {
      if(g_trade.OrderDelete(g_sellStopTicket))
      {
         JournalWrite("ORDER_CANCELLED","SELL_STOP",0,0,0,0,0,0,
                      "Cancelled — Buy already open. Ticket="+
                      IntegerToString((long)g_sellStopTicket));
         g_sellStopTicket = 0;
      }
   }
   else if(sellFilled && sellOpen && PendingOrderExists(g_buyStopTicket))
   {
      if(g_trade.OrderDelete(g_buyStopTicket))
      {
         JournalWrite("ORDER_CANCELLED","BUY_STOP",0,0,0,0,0,0,
                      "Cancelled — Sell already open. Ticket="+
                      IntegerToString((long)g_buyStopTicket));
         g_buyStopTicket = 0;
      }
   }
}

//+------------------------------------------------------------------+
//|                                                                  |
//|   INFO PANEL — Chart object rendering                            |
//|                                                                  |
//+------------------------------------------------------------------+

void PanelCreate()
{
   // Background rectangle
   string bg = g_pfx+"BG";
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,  InpPanelX);
   ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,  InpPanelY);
   ObjectSetInteger(0,bg,OBJPROP_XSIZE,      PANEL_W);
   ObjectSetInteger(0,bg,OBJPROP_YSIZE,      (ROW_LAST+1)*ROW_H+10);
   ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,    InpPanelBg);
   ObjectSetInteger(0,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,bg,OBJPROP_COLOR,      C'50,60,80');
   ObjectSetInteger(0,bg,OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0,bg,OBJPROP_BACK,       false);
   ObjectSetInteger(0,bg,OBJPROP_SELECTABLE, false);

   for(int r = 0; r < ROW_LAST; r++)
   {
      int y = InpPanelY + 6 + r * ROW_H;

      string lbl = g_pfx+"L"+IntegerToString(r);
      ObjectCreate(0,lbl,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,lbl,OBJPROP_XDISTANCE, InpPanelX+8);
      ObjectSetInteger(0,lbl,OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0,lbl,OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0,lbl,OBJPROP_COLOR,     InpLabelColor);
      ObjectSetInteger(0,lbl,OBJPROP_FONTSIZE,  FONT_SIZE);
      ObjectSetString (0,lbl,OBJPROP_FONT,      FONT_FACE);
      ObjectSetInteger(0,lbl,OBJPROP_SELECTABLE,false);
      ObjectSetString (0,lbl,OBJPROP_TEXT,      "");

      string val = g_pfx+"V"+IntegerToString(r);
      ObjectCreate(0,val,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,val,OBJPROP_XDISTANCE, InpPanelX+PANEL_W-8);
      ObjectSetInteger(0,val,OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0,val,OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0,val,OBJPROP_ANCHOR,    ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0,val,OBJPROP_COLOR,     InpValueColor);
      ObjectSetInteger(0,val,OBJPROP_FONTSIZE,  FONT_SIZE);
      ObjectSetString (0,val,OBJPROP_FONT,      FONT_FACE);
      ObjectSetInteger(0,val,OBJPROP_SELECTABLE,false);
      ObjectSetString (0,val,OBJPROP_TEXT,      "");
   }
   PanelUpdate();
}

void PanelRow(int row, string label, string value, color vc=clrNONE)
{
   ObjectSetString(0, g_pfx+"L"+IntegerToString(row), OBJPROP_TEXT, label);
   ObjectSetString(0, g_pfx+"V"+IntegerToString(row), OBJPROP_TEXT, value);
   ObjectSetInteger(0,g_pfx+"L"+IntegerToString(row), OBJPROP_COLOR, InpLabelColor);
   color c = (vc==clrNONE) ? InpValueColor : vc;
   ObjectSetInteger(0,g_pfx+"V"+IntegerToString(row), OBJPROP_COLOR, c);
}

void PanelSep(int row, string txt="")
{
   string s = (txt=="") ? "────────────────────────────" : "── "+txt+" ──";
   ObjectSetString (0,g_pfx+"L"+IntegerToString(row),OBJPROP_TEXT, s);
   ObjectSetString (0,g_pfx+"V"+IntegerToString(row),OBJPROP_TEXT, "");
   ObjectSetInteger(0,g_pfx+"L"+IntegerToString(row),OBJPROP_COLOR,C'55,65,85');
}

void PanelHead(int row, string txt)
{
   ObjectSetString (0,g_pfx+"L"+IntegerToString(row),OBJPROP_TEXT,    txt);
   ObjectSetString (0,g_pfx+"V"+IntegerToString(row),OBJPROP_TEXT,    "");
   ObjectSetInteger(0,g_pfx+"L"+IntegerToString(row),OBJPROP_COLOR,   InpHeaderColor);
   ObjectSetInteger(0,g_pfx+"L"+IntegerToString(row),OBJPROP_FONTSIZE,FONT_SIZE+1);
}

void PanelUpdate()
{
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   // Header
   PanelHead(ROW_HEADER, "  PDH/PDL BREAKOUT EA  v2.0");
   PanelSep(ROW_SEP1);

   // Market info
   PanelRow(ROW_SYMBOL, "Symbol",  _Symbol);
   PanelRow(ROW_PRICE,  "Price",   DoubleToString(bid,g_digits));
   color sColor = (spread > InpMaxSpreadPts) ? InpLossColor : InpProfitColor;
   PanelRow(ROW_SPREAD, "Spread",  DoubleToString(spread,0)+" pts", sColor);
   PanelSep(ROW_SEP2,"LEVELS");

   // PDH / PDL
   string pdhStr = (g_pdh > 0) ? DoubleToString(g_pdh,g_digits) : "Waiting...";
   string pdlStr = (g_pdl > 0) ? DoubleToString(g_pdl,g_digits) : "Waiting...";
   double range  = (g_pdh>0 && g_pdl>0) ? (g_pdh-g_pdl)/g_point : 0;
   PanelRow(ROW_PDH,  "Prev Day High", pdhStr, InpProfitColor);
   PanelRow(ROW_PDL,  "Prev Day Low",  pdlStr, InpLossColor);
   PanelRow(ROW_RANGE,"Day Range", (range>0) ? DoubleToString(range,0)+" pts":"—");
   PanelSep(ROW_SEP3,"ORDERS");

   // Order status
   string buyStr="None"; color buyC=InpLabelColor;
   string selStr="None"; color selC=InpLabelColor;

   if(PendingOrderExists(g_buyStopTicket))
      { buyStr="PENDING  #"+IntegerToString((long)g_buyStopTicket); buyC=InpNeutralColor; }
   else if(PositionExistsByMagic(POSITION_TYPE_BUY))
      { buyStr="● ACTIVE"; buyC=InpProfitColor; }

   if(PendingOrderExists(g_sellStopTicket))
      { selStr="PENDING  #"+IntegerToString((long)g_sellStopTicket); selC=InpNeutralColor; }
   else if(PositionExistsByMagic(POSITION_TYPE_SELL))
      { selStr="● ACTIVE"; selC=InpLossColor; }

   PanelRow(ROW_BUY_STATUS,  "Buy Stop  (PDH)", buyStr, buyC);
   PanelRow(ROW_SELL_STATUS, "Sell Stop (PDL)", selStr, selC);
   PanelSep(ROW_SEP4,"OPEN POSITIONS");

   // Open P&L + trailing status
   int    openCount = 0;
   double openPnl   = 0.0;
   bool   trailActive = false;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!g_position.SelectByIndex(i))          continue;
      if(g_position.Magic()  != InpMagicNumber) continue;
      if(g_position.Symbol() != _Symbol)        continue;
      openCount++;
      openPnl += g_position.Profit() + g_position.Swap();
      double entry = g_position.PriceOpen();
      double pnlPts= (g_position.PositionType()==POSITION_TYPE_BUY)
                     ? (bid-entry)/g_point : (entry-bid)/g_point;
      if(pnlPts >= InpStopLossPoints * InpTrailStartRR) trailActive = true;
   }

   color pnlC = (openPnl>=0) ? InpProfitColor : InpLossColor;
   PanelRow(ROW_OPEN_TRADES,"Open Trades",  IntegerToString(openCount));
   PanelRow(ROW_OPEN_PNL,  "Floating P&L", "$"+DoubleToString(openPnl,2), pnlC);

   string tStr = (openCount==0)?"—":(trailActive?"✔ Active":"Waiting");
   color  tC   = trailActive ? InpProfitColor : InpNeutralColor;
   PanelRow(ROW_TRAIL_STATUS,"Trail Stop", tStr, tC);
   PanelSep(ROW_SEP5,"TODAY");

   // Session stats
   color sPnlC = (g_sessPnl>=0) ? InpProfitColor : InpLossColor;
   PanelRow(ROW_SESS_TRADES,"Trades Today",  IntegerToString(g_sessTradesTotal));
   PanelRow(ROW_SESS_WL,   "W / L  Today",
            IntegerToString(g_sessWins)+" / "+IntegerToString(g_sessLosses));
   PanelRow(ROW_SESS_PNL,  "P&L Today","$"+DoubleToString(g_sessPnl,2), sPnlC);
   PanelSep(ROW_SEP6,"ALL TIME");

   // Lifetime stats
   double wr    = (g_totalTrades>0) ? (double)g_totalWins/g_totalTrades*100.0 : 0.0;
   color wrC    = (wr>=50) ? InpProfitColor : InpLossColor;
   color tPnlC  = (g_totalPnl>=0) ? InpProfitColor : InpLossColor;
   color ddC    = (g_maxDrawdown>0) ? InpLossColor : InpLabelColor;
   PanelRow(ROW_TOTAL_TRADES,"Trades (W/L)",
            IntegerToString(g_totalWins)+"W / "+IntegerToString(g_totalLosses)+"L");
   PanelRow(ROW_TOTAL_WR,  "Win Rate",      DoubleToString(wr,1)+"%", wrC);
   PanelRow(ROW_TOTAL_PNL, "Total P&L",    "$"+DoubleToString(g_totalPnl,2), tPnlC);
   PanelRow(ROW_MAX_DD,    "Max Drawdown", "$"+DoubleToString(g_maxDrawdown,2), ddC);
   PanelRow(ROW_BALANCE,   "Balance",      "$"+DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2));
   PanelSep(ROW_SEP7,"SETTINGS");

   // Config summary
   string lotsStr = InpAutoLot
      ? "Auto ("+DoubleToString(InpRiskPercent,1)+"% risk)"
      : DoubleToString(InpManualLots,2)+" lots";
   PanelRow(ROW_LOTS,"Lot Size", lotsStr);
   PanelRow(ROW_SLTP,"SL / TP",
            IntegerToString(InpStopLossPoints)+" / "+
            (InpUseFixedTP ? IntegerToString(InpTakeProfitPts)+" pts" : "Trail"));

   ChartRedraw(0);
}

void PanelDelete()
{
   ObjectsDeleteAll(0, g_pfx);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//|                                                                  |
//|   TRADE JOURNAL — CSV file logger                                |
//|                                                                  |
//+------------------------------------------------------------------+

void JournalInit()
{
   // Try to open existing file
   int h = FileOpen(InpJournalFile, FILE_READ|FILE_CSV);
   if(h == INVALID_HANDLE)
   {
      // Doesn't exist — create with header
      h = FileOpen(InpJournalFile, FILE_WRITE|FILE_CSV|FILE_ANSI);
      if(h == INVALID_HANDLE)
      { Print("ERROR: Cannot create journal: ",InpJournalFile); return; }
      FileWrite(h,
         "Timestamp",
         "EventType",
         "Direction",
         "Price_Entry",
         "Price_SL",
         "Price_TP",
         "Volume_Lots",
         "PnL_USD",
         "Balance_USD",
         "Notes"
      );
      FileClose(h);
      Print("Journal created: ",
            TerminalInfoString(TERMINAL_DATA_PATH),"\\MQL5\\Files\\",InpJournalFile);
   }
   else
   {
      FileClose(h);
      Print("Journal found (appending): ",InpJournalFile);
   }
}

void JournalWrite(string eventType,
                  string direction,
                  double priceEntry,
                  double priceSL,
                  double priceTP,
                  double volumeLots,
                  double pnl,
                  double balance,
                  string notes)
{
   if(!InpEnableJournal) return;

   int h = FileOpen(InpJournalFile, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(h == INVALID_HANDLE)
   { Print("ERROR: Cannot open journal for writing."); return; }

   FileSeek(h, 0, SEEK_END);

   FileWrite(h,
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
      eventType,
      direction,
      (priceEntry > 0) ? DoubleToString(priceEntry, g_digits) : "",
      (priceSL    > 0) ? DoubleToString(priceSL,    g_digits) : "",
      (priceTP    > 0) ? DoubleToString(priceTP,     g_digits) : "",
      (volumeLots > 0) ? DoubleToString(volumeLots,  2)        : "",
      (pnl        !=0) ? DoubleToString(pnl,         2)        : "",
      (balance    > 0) ? DoubleToString(balance,     2)        : "",
      notes
   );

   FileClose(h);
}

//+------------------------------------------------------------------+
//| Utility Functions                                                |
//+------------------------------------------------------------------+

double CalcAutoLot()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt = balance * (InpRiskPercent / 100.0);
   if(riskAmt <= 0.0) return InpManualLots;

   // Ask the broker exactly what 1.0 lot loses over the SL distance (real contract maths).
   double entry   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double slPrice = entry - InpStopLossPoints * g_point;
   double lossOneLot = 0.0;

   if(OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, entry, slPrice, lossOneLot))
      lossOneLot = MathAbs(lossOneLot);
   else
   {
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tv > 0 && ts > 0) lossOneLot = InpStopLossPoints * g_point / ts * tv;
   }

   if(lossOneLot <= 0.0) return InpManualLots;
   return riskAmt / lossOneLot;
}

double NormalizeLots(double lots)
{
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stp  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots/stp)*stp;
   lots = MathMax(lots,minL);
   lots = MathMin(lots,maxL);
   return NormalizeDouble(lots,2);
}

void CancelAllPendingOrders()
{
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      if(!g_order.SelectByIndex(i))          continue;
      if(g_order.Magic()  != InpMagicNumber) continue;
      if(g_order.Symbol() != _Symbol)        continue;
      ulong t = g_order.Ticket();
      if(g_trade.OrderDelete(t))
         Print("Cancelled stale order: #",t);
   }
   g_buyStopTicket = 0; g_sellStopTicket = 0;
}

bool PendingOrderExists(ulong ticket)
{
   if(ticket==0) return false;
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      if(!g_order.SelectByIndex(i))   continue;
      if(g_order.Ticket()==ticket)    return true;
   }
   return false;
}

bool PositionExistsByMagic(ENUM_POSITION_TYPE posType)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(!g_position.SelectByIndex(i))          continue;
      if(g_position.Magic()  != InpMagicNumber) continue;
      if(g_position.Symbol() != _Symbol)        continue;
      if(g_position.PositionType()==posType)    return true;
   }
   return false;
}

ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   uint f = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((f & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((f & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Session window check (BROKER server time)                        |
//+------------------------------------------------------------------+
bool IsSessionActive()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   int h = t.hour;
   bool in1 = (h >= InpSess1Start && h < InpSess1End);
   bool in2 = (h >= InpSess2Start && h < InpSess2End);
   return (in1 || in2);
}

//+------------------------------------------------------------------+
//| True only when the symbol is tradeable and inside a trade session |
//| (suppresses SL-modify attempts during the daily maintenance break)|
//+------------------------------------------------------------------+
bool IsMarketOpen()
{
   if((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
      return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   ENUM_DAY_OF_WEEK dow = (ENUM_DAY_OF_WEEK)dt.day_of_week;
   int nowSec = dt.hour * 3600 + dt.min * 60 + dt.sec;

   datetime from, to;
   for(uint s = 0; SymbolInfoSessionTrade(_Symbol, dow, s, from, to); s++)
   {
      int f = (int)((long)from % 86400);
      int t2 = (int)((long)to % 86400);
      if(t2 == 0) t2 = 86400;
      if(nowSec >= f && nowSec < t2) return true;
   }
   return false;
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Circuit breaker: evaluate each closed trade                      |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(!InpUseCircuitBreaker) return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC)  != InpMagicNumber) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL)  != _Symbol)        return;
   long de = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(de != DEAL_ENTRY_OUT && de != DEAL_ENTRY_OUT_BY) return;   // closing deals only

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(profit < 0.0)      g_consecLosses++;
   else if(profit > 0.0) g_consecLosses = 0;

   // daily-loss breaker -> pause rest of today
   if(InpMaxDailyLossPct > 0.0 && g_dayStartBalance > 0.0)
   {
      double dayLoss = g_dayStartBalance - AccountInfoDouble(ACCOUNT_BALANCE);
      if(dayLoss >= g_dayStartBalance * InpMaxDailyLossPct / 100.0)
      {
         g_haltToday = true;
         CancelAllPendingOrders();
         Print("CIRCUIT BREAKER: daily loss limit (", DoubleToString(InpMaxDailyLossPct,1),
               "%) hit. Paused until next day.");
      }
   }

   // consecutive-loss breaker -> pause for a cooldown
   if(InpMaxConsecLosses > 0 && g_consecLosses >= InpMaxConsecLosses)
   {
      g_cooldownUntil = (datetime)(TimeCurrent() + (long)InpCooldownDays * 86400);
      g_consecLosses  = 0;
      CancelAllPendingOrders();
      Print("CIRCUIT BREAKER: ", InpMaxConsecLosses, " losses in a row. Paused for ",
            InpCooldownDays, " day(s).");
   }
}