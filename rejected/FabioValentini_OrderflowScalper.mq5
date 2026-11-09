//+------------------------------------------------------------------+
//|                              FabioValentini_OrderflowScalper.mq5 |
//|                                                                  |
//|  Order-flow scalping EA inspired by Fabio Valentini's publicly   |
//|  documented methodology (Auction Market Theory + order flow).    |
//|                                                                  |
//|  The model implements his 3-step process:                        |
//|    1. DIRECTION  - who is in control (CVD slope + VWAP side)     |
//|    2. LOCATION   - price at a key level (LVN of the session      |
//|                    profile, VWAP, prior-day VAH/VAL)             |
//|    3. AGGRESSION - order-flow trigger at the level:              |
//|                    * delta flip through zero                     |
//|                    * stacked footprint imbalances (diagonal      |
//|                      bid/ask imbalance on >= N adjacent levels)  |
//|                    * absorption (volume > k x average, range     |
//|                      < k x ATR, close rejecting the level)       |
//|                                                                  |
//|  Two trade models (as in his playbook):                          |
//|    A. TREND continuation - market out of balance (outside prior  |
//|       day value area), pullback into an LVN / VWAP, entry with   |
//|       aggression in trend direction. Fixed-R target.             |
//|    B. MEAN REVERSION - failed breakout of the prior-day value    |
//|       area (poke beyond VAH/VAL that closes back inside) with    |
//|       opposing aggression. Target = Point of Control.            |
//|    C. Optional Opening-Range Breakout (off by default).          |
//|                                                                  |
//|  Risk framework (his documented numbers):                        |
//|    - 0.25% risk per trade, minimum 2:1 reward-to-risk            |
//|    - hard stop after 3 consecutive losses in a day               |
//|    - daily loss limit, max trades per session                    |
//|    - break-even + 50% scale-out at +1R, ATR trail after +1.5R    |
//|    - "scratch" exit if flow pressure dies within a few bars      |
//|    - trades only inside the configured session window            |
//|                                                                  |
//|  IMPORTANT NOTES                                                 |
//|  * True order flow needs tick data with aggressor flags          |
//|    (TICK_FLAG_BUY/SELL) and real volume - i.e. exchange-traded   |
//|    futures (NQ/MNQ/ES etc. on an exchange-connected MT5).        |
//|    On forex/CFD symbols the EA falls back to the tick rule       |
//|    (uptick = buy, downtick = sell, volume = 1 per tick). That    |
//|    is an approximation - lower InpImbMinVolume (3-5) there.      |
//|  * Session times are SERVER time. Defaults assume a UTC+3        |
//|    broker in US summer time (NY cash open 16:30). Adjust!        |
//|  * Backtest with "Every tick based on real ticks" only.          |
//|  * This is an educational implementation of publicly described   |
//|    concepts - not Valentini's actual discretionary execution.    |
//|    Forward-test on demo before risking money.                    |
//+------------------------------------------------------------------+
#property copyright "2026"
#property link      ""
#property version   "1.00"
#property description "Order-flow scalper based on Fabio Valentini's published methodology:"
#property description "Auction Market Theory, volume profile (POC/VAH/VAL/LVN), VWAP, CVD,"
#property description "footprint stacked imbalances, absorption, delta flips."
#property description "Best on index futures with real tick flags. Session times are server time."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== General ==="
input long   InpMagic            = 20260705;  // Magic number
input int    InpSlippagePoints   = 20;        // Max slippage (points)
input bool   InpVerboseLog       = true;      // Verbose logging

input group "=== Session window (SERVER time) ==="
input int    InpSessStartHour    = 16;        // Session start hour
input int    InpSessStartMin     = 30;        // Session start minute
input int    InpSessEndHour      = 19;        // Session end hour
input int    InpSessEndMin       = 30;        // Session end minute
input int    InpNoEntryFinalMin  = 15;        // No new entries in final N minutes
input bool   InpCloseAtSessEnd   = true;      // Flatten at session end
input int    InpWarmupMinutes    = 15;        // Flow warm-up before session (minutes)

input group "=== Models ==="
input bool   InpUseTrendModel    = true;      // A: Trend continuation (LVN/VWAP pullback)
input bool   InpUseMeanReversion = true;      // B: Failed VA breakout -> POC
input bool   InpUseORB           = false;     // C: Opening range breakout
input int    InpORBMinutes       = 30;        // ORB window (minutes)
input double InpORBVolMult       = 1.5;       // ORB min volume vs average

input group "=== Order flow ==="
input double InpImbalanceRatio   = 3.0;       // Footprint diagonal imbalance ratio
input int    InpStackedLevels    = 3;         // Stacked imbalances required (adjacent levels)
input double InpImbMinVolume     = 15.0;      // Min volume per level for an imbalance
input double InpAbsVolMult       = 2.0;       // Absorption: volume > k x average
input double InpAbsRangeATR      = 0.30;      // Absorption: range < k x ATR
input double InpDeltaFlipMult    = 1.0;       // Delta flip: |delta| >= k x avg |delta|
input int    InpCVDSlopeBars     = 5;         // CVD slope lookback (bars)
input int    InpFlowAvgBars      = 20;        // Averaging window for volume/delta
input int    InpMinFlowBars      = 6;         // Min flow bars before trading

input group "=== Order flow quality ==="
input bool   InpUseQuoteDelta    = true;      // Classify trades vs bid/ask quotes (Lee-Ready)
input bool   InpAbsDirectional   = true;      // Absorption must show opposing delta
input bool   InpUseEffortResult  = true;      // MR: trapped-trader (effort vs result) trigger
input bool   InpUseCVDDiv        = false;     // MR: require CVD divergence at the poke
input int    InpCVDDivBars       = 10;        // CVD divergence lookback (bars)
input double InpMinVolBurst      = 0.0;       // Trend: signal bar volume >= k x avg (0=off)

input group "=== Volume profile / levels ==="
input int    InpProfileRows      = 24;        // Profile rows
input double InpValueAreaPct     = 70.0;      // Value area %
input double InpLVNThresholdPct  = 40.0;      // LVN: row vol < % of avg row vol
input double InpLevelTolATR      = 0.30;      // Level proximity tolerance (x ATR)

input group "=== Risk & trade management ==="
input double InpRiskPercent      = 0.25;      // Risk per trade (% of equity)
input double InpMinRR            = 2.0;       // Minimum reward:risk to take a trade
input double InpFixedRR          = 2.0;       // Trend/ORB target (R multiple)
input bool   InpMRFixedRRFallback= false;     // MR: fall back to fixed RR if POC too close
input int    InpStopBufferTicks  = 2;         // Stop buffer beyond level (ticks)
input double InpMinStopATR       = 0.75;      // Min stop distance (x ATR)
input double InpMinStopSpreadMult= 4.0;       // Min stop distance (x spread)
input double InpBreakEvenR       = 1.0;       // Move stop to BE at +N R
input bool   InpScaleOutHalf     = false;     // Close 50% at break-even level
input double InpTrailStartR      = 1.5;       // Start trailing at +N R
input double InpTrailATRMult     = 1.0;       // Trail distance (x ATR)
input int    InpScratchBars      = 3;         // Scratch if no progress after N bars
input int    InpMaxTradesPerDay  = 10;        // Max trades per day
input int    InpMaxConsecLosses  = 3;         // Stop after N consecutive losses
input double InpDailyLossPct     = 1.0;       // Daily loss limit (% of balance, 0=off)
input double InpDailyProfitPct   = 0.0;       // Daily profit stop (% of balance, 0=off)
input int    InpMaxSpreadPoints  = 0;         // Max spread in points (0=off)
input int    InpATRPeriod        = 14;        // ATR period (M1)

//+------------------------------------------------------------------+
//| Data structures                                                  |
//+------------------------------------------------------------------+
struct BarFlow
  {
   datetime          time;           // bar open time
   bool              valid;          // tick data was available
   double            buyVol;         // aggressive buy volume
   double            sellVol;        // aggressive sell volume
   double            totalVol;
   double            delta;          // buyVol - sellVol
   int               stackedBuyImb;  // max run of adjacent buy imbalances
   int               stackedSellImb; // max run of adjacent sell imbalances
  };

struct VolumeProfile
  {
   bool              valid;
   double            low;            // profile low price
   double            rowSize;
   int               rows;
   double            vol[];          // volume per row
   double            poc;            // point of control price
   double            vah;            // value area high
   double            val;            // value area low
   double            totalVol;
   double            lvn[];          // LVN center prices
   int               lvnCount;
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade         g_trade;
int            g_atrHandle   = INVALID_HANDLE;
datetime       g_lastM1Bar   = 0;

// order-flow state (rebuilt each day / on restart)
BarFlow        g_flow[];
int            g_flowCount   = 0;
double         g_cvd         = 0.0;
double         g_cvdHist[];
datetime       g_lastFlowBar = 0;
datetime       g_flowDay     = 0;
bool           g_flagsSeen   = false;
bool           g_flagsWarned = false;

// levels
VolumeProfile  g_prior;              // prior-day profile
VolumeProfile  g_sess;               // developing session profile
datetime       g_priorBuiltFor = 0;
double         g_vwap        = 0.0;

// opening range
bool           g_orReady     = false;
double         g_orHigh      = 0.0;
double         g_orLow       = 0.0;
bool           g_orbLongDone = false;
bool           g_orbShortDone= false;

// open-position bookkeeping
double         g_entryPrice  = 0.0;
double         g_riskDist    = 0.0;
int            g_barsInTrade = 0;
bool           g_partialDone = false;
bool           g_beDone      = false;

// daily stats
int            g_tradesToday = 0;
double         g_dailyPnL    = 0.0;
int            g_consecLosses= 0;

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
datetime DayStart(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t,dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   return StructToTime(dt);
  }

datetime SessionStart(datetime day) { return day + InpSessStartHour*3600 + InpSessStartMin*60; }
datetime SessionEnd(datetime day)   { return day + InpSessEndHour*3600   + InpSessEndMin*60;   }
datetime CollectStart(datetime day) { return SessionStart(day) - InpWarmupMinutes*60;          }

double TickSizeOf()
  {
   double ts = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(ts<=0.0) ts=_Point;
   return ts;
  }

double TickPriceOf(const MqlTick &t)
  {
   if(t.last>0.0) return t.last;
   if(t.bid >0.0) return t.bid;
   return t.ask;
  }

double GetATR()
  {
   double b[1];
   if(CopyBuffer(g_atrHandle,0,1,1,b)!=1) return 0.0;
   return b[0];
  }

double NormalizeVolume(double lots)
  {
   double step = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step<=0.0) step=vmin>0.0?vmin:0.01;
   lots = MathFloor(lots/step+1e-9)*step;
   if(lots<vmin) return 0.0;
   if(lots>vmax) lots=vmax;
   return lots;
  }

//+------------------------------------------------------------------+
//| Volume profile construction (from M1 bars)                       |
//+------------------------------------------------------------------+
bool BuildProfileRange(datetime from, datetime to, VolumeProfile &vp)
  {
   vp.valid=false;
   vp.lvnCount=0;
   if(to<from) return false;

   MqlRates rates[];
   int n = CopyRates(_Symbol,PERIOD_M1,from,to,rates);
   if(n<3) return false;

   double hi=-DBL_MAX, lo=DBL_MAX;
   bool useReal=false;
   for(int i=0;i<n;i++)
     {
      if(rates[i].high>hi) hi=rates[i].high;
      if(rates[i].low <lo) lo=rates[i].low;
      if(rates[i].real_volume>0) useReal=true;
     }
   if(hi<=lo) return false;

   int rows = InpProfileRows;
   if(rows<10)  rows=10;
   if(rows>200) rows=200;
   double rowSize=(hi-lo)/rows;
   double ts=TickSizeOf();
   if(rowSize<ts)
     {
      rowSize=ts;
      rows=(int)MathCeil((hi-lo)/rowSize);
      if(rows<1) rows=1;
      if(rows>2000) return false;
     }

   ArrayResize(vp.vol,rows);
   ArrayInitialize(vp.vol,0.0);
   vp.low=lo; vp.rowSize=rowSize; vp.rows=rows; vp.totalVol=0.0;

   for(int i=0;i<n;i++)
     {
      double v = useReal ? (double)rates[i].real_volume : (double)rates[i].tick_volume;
      if(v<=0.0) continue;
      double bh=rates[i].high, bl=rates[i].low;
      double brange=bh-bl;
      vp.totalVol+=v;
      if(brange<=0.0)
        {
         int r=(int)((bl-lo)/rowSize);
         if(r<0) r=0; if(r>=rows) r=rows-1;
         vp.vol[r]+=v;
         continue;
        }
      int r0=(int)((bl-lo)/rowSize);
      int r1=(int)((bh-lo)/rowSize);
      if(r0<0) r0=0; if(r1>=rows) r1=rows-1;
      for(int r=r0;r<=r1;r++)
        {
         double rBot=lo+r*rowSize, rTop=rBot+rowSize;
         double ov=MathMin(rTop,bh)-MathMax(rBot,bl);
         if(ov>0.0) vp.vol[r]+=v*ov/brange;
        }
     }
   if(vp.totalVol<=0.0) return false;

   // --- POC
   int pocRow=0;
   for(int r=1;r<rows;r++)
      if(vp.vol[r]>vp.vol[pocRow]) pocRow=r;
   vp.poc=lo+(pocRow+0.5)*rowSize;

   // --- value area (expand from POC)
   double vaPct=InpValueAreaPct;
   if(vaPct<50.0) vaPct=50.0;
   if(vaPct>95.0) vaPct=95.0;
   double target=vp.totalVol*vaPct/100.0;
   double covered=vp.vol[pocRow];
   int up=pocRow, dn=pocRow;
   while(covered<target && (up<rows-1 || dn>0))
     {
      double vu=(up<rows-1)?vp.vol[up+1]:-1.0;
      double vd=(dn>0)     ?vp.vol[dn-1]:-1.0;
      if(vu>=vd) { up++; covered+=vu; }
      else       { dn--; covered+=vd; }
     }
   vp.vah=lo+(up+1)*rowSize;
   vp.val=lo+dn*rowSize;

   // --- LVN zones (interior local minima below threshold)
   int first=-1,last=-1;
   for(int r=0;r<rows;r++)
      if(vp.vol[r]>0.0) { if(first<0) first=r; last=r; }
   ArrayResize(vp.lvn,0);
   vp.lvnCount=0;
   if(first>=0 && last-first>=5)
     {
      double avgRow=vp.totalVol/(last-first+1);
      double thr=avgRow*InpLVNThresholdPct/100.0;
      bool flag[];
      ArrayResize(flag,rows);
      for(int r=0;r<rows;r++) flag[r]=false;
      for(int r=first+2;r<=last-2;r++)
         if(vp.vol[r]<=thr && vp.vol[r]<=vp.vol[r-1] && vp.vol[r]<=vp.vol[r+1])
            flag[r]=true;
      // merge adjacent flagged rows into zones, store zone centers
      int r=first;
      while(r<=last)
        {
         if(flag[r])
           {
            int z0=r;
            while(r+1<=last && flag[r+1]) r++;
            int z1=r;
            double center=lo+((z0+z1)/2.0+0.5)*rowSize;
            int k=vp.lvnCount;
            ArrayResize(vp.lvn,k+1);
            vp.lvn[k]=center;
            vp.lvnCount=k+1;
           }
         r++;
        }
     }

   vp.valid=true;
   return true;
  }

double NearestLVN(const VolumeProfile &vp, double price)
  {
   if(!vp.valid || vp.lvnCount<1) return 0.0;
   double best=0.0, bestD=DBL_MAX;
   for(int i=0;i<vp.lvnCount;i++)
     {
      double d=MathAbs(price-vp.lvn[i]);
      if(d<bestD) { bestD=d; best=vp.lvn[i]; }
     }
   return best;
  }

//+------------------------------------------------------------------+
//| Session VWAP from M1 bars                                        |
//+------------------------------------------------------------------+
double CalcSessionVWAP(datetime from, datetime to)
  {
   MqlRates rates[];
   int n=CopyRates(_Symbol,PERIOD_M1,from,to,rates);
   if(n<1) return 0.0;
   bool useReal=false;
   for(int i=0;i<n;i++)
      if(rates[i].real_volume>0) { useReal=true; break; }
   double sumPV=0.0,sumV=0.0;
   for(int i=0;i<n;i++)
     {
      double v=useReal?(double)rates[i].real_volume:(double)rates[i].tick_volume;
      if(v<=0.0) continue;
      double tp=(rates[i].high+rates[i].low+rates[i].close)/3.0;
      sumPV+=tp*v;
      sumV +=v;
     }
   return (sumV>0.0)?sumPV/sumV:0.0;
  }

//+------------------------------------------------------------------+
//| Per-bar order flow from ticks (footprint, delta)                 |
//+------------------------------------------------------------------+
bool ComputeBarFlow(datetime barTime, BarFlow &bf)
  {
   bf.time=barTime;
   bf.valid=false;
   bf.buyVol=0.0; bf.sellVol=0.0; bf.totalVol=0.0; bf.delta=0.0;
   bf.stackedBuyImb=0; bf.stackedSellImb=0;

   datetime t1=barTime+PeriodSeconds(PERIOD_M1);
   MqlTick ticks[];
   int n=CopyTicksRange(_Symbol,ticks,COPY_TICKS_ALL,(ulong)barTime*1000,(ulong)t1*1000-1);
   if(n<=0) return false;

   double ts=TickSizeOf();

   // pass 1: does this feed carry real trade ticks (last price / volume)?
   // If yes, only executions count as volume - quote updates are ignored.
   bool hasTrades=false;
   for(int i=0;i<n;i++)
      if(ticks[i].last>0.0 && (ticks[i].volume>0 || ticks[i].volume_real>0.0
         || (ticks[i].flags & (TICK_FLAG_LAST|TICK_FLAG_VOLUME|TICK_FLAG_BUY|TICK_FLAG_SELL))!=0))
        { hasTrades=true; break; }

   // pass 2: price level bounds over the relevant price stream
   long minL=LONG_MAX, maxL=LONG_MIN;
   for(int i=0;i<n;i++)
     {
      double p = hasTrades ? ticks[i].last : TickPriceOf(ticks[i]);
      if(p<=0.0) continue;
      long L=(long)MathRound(p/ts);
      if(L<minL) minL=L;
      if(L>maxL) maxL=L;
     }
   if(minL>maxL) return false;
   int nl=(int)(maxL-minL+1);
   if(nl<1 || nl>20000) return false;   // sanity (news spike / bad data)

   double buyV[],sellV[];
   ArrayResize(buyV,nl);  ArrayInitialize(buyV,0.0);
   ArrayResize(sellV,nl); ArrayInitialize(sellV,0.0);

   // pass 3: classify aggressor and accumulate per level
   // priority: exchange flags > quote rule (Lee-Ready) > tick rule
   double prevP=0.0;
   double curBid=0.0, curAsk=0.0;
   double qEps=ts*0.25;
   int    lastDir=0;
   for(int i=0;i<n;i++)
     {
      if(ticks[i].bid>0.0) curBid=ticks[i].bid;
      if(ticks[i].ask>0.0) curAsk=ticks[i].ask;

      double p;
      double vol;
      if(hasTrades)
        {
         // executions only
         if(ticks[i].last<=0.0) continue;
         bool isTrade=(ticks[i].volume>0 || ticks[i].volume_real>0.0
                      || (ticks[i].flags & (TICK_FLAG_LAST|TICK_FLAG_VOLUME|TICK_FLAG_BUY|TICK_FLAG_SELL))!=0);
         if(!isTrade) continue;
         p=ticks[i].last;
         vol=ticks[i].volume_real>0.0 ? ticks[i].volume_real
            : (ticks[i].volume>0 ? (double)ticks[i].volume : 1.0);
        }
      else
        {
         p=TickPriceOf(ticks[i]);
         if(p<=0.0) continue;
         vol=1.0;
        }
      int idx=(int)((long)MathRound(p/ts)-minL);
      if(idx<0) idx=0; if(idx>=nl) idx=nl-1;

      bool isBuy =((ticks[i].flags & TICK_FLAG_BUY) !=0);
      bool isSell=((ticks[i].flags & TICK_FLAG_SELL)!=0);
      if(isBuy||isSell) g_flagsSeen=true;

      if(!isBuy && !isSell && hasTrades && InpUseQuoteDelta && curBid>0.0 && curAsk>curBid)
        {
         // quote rule: trade at/above ask = aggressive buy, at/below bid = sell
         if(p>=curAsk-qEps)      isBuy=true;
         else if(p<=curBid+qEps) isSell=true;
        }

      if(isBuy && isSell)
        {
         buyV[idx] +=vol*0.5; sellV[idx]+=vol*0.5;
         bf.buyVol +=vol*0.5; bf.sellVol+=vol*0.5;
        }
      else if(isBuy)
        {
         buyV[idx]+=vol; bf.buyVol+=vol;
        }
      else if(isSell)
        {
         sellV[idx]+=vol; bf.sellVol+=vol;
        }
      else
        {
         // tick rule fallback
         int dir=lastDir;
         if(prevP>0.0)
           {
            if(p>prevP) dir= 1;
            else if(p<prevP) dir=-1;
           }
         if(dir>0)      { buyV[idx] +=vol; bf.buyVol +=vol; }
         else if(dir<0) { sellV[idx]+=vol; bf.sellVol+=vol; }
         else           { buyV[idx]+=vol*0.5; sellV[idx]+=vol*0.5;
                          bf.buyVol+=vol*0.5; bf.sellVol+=vol*0.5; }
         lastDir=dir;
        }
      prevP=p;
     }

   bf.totalVol=bf.buyVol+bf.sellVol;
   bf.delta   =bf.buyVol-bf.sellVol;

   // stacked diagonal imbalances (classic footprint logic):
   //  buy  imbalance at level i : askVol(i)  >= ratio x bidVol(i-1)
   //  sell imbalance at level i : bidVol(i)  >= ratio x askVol(i+1)
   int run=0;
   for(int i=1;i<nl;i++)
     {
      double own=buyV[i], opp=sellV[i-1];
      bool imb=(own>=InpImbMinVolume) && (opp<=0.0 || own>=InpImbalanceRatio*opp);
      run = imb ? run+1 : 0;
      if(run>bf.stackedBuyImb) bf.stackedBuyImb=run;
     }
   run=0;
   for(int i=nl-2;i>=0;i--)
     {
      double own=sellV[i], opp=buyV[i+1];
      bool imb=(own>=InpImbMinVolume) && (opp<=0.0 || own>=InpImbalanceRatio*opp);
      run = imb ? run+1 : 0;
      if(run>bf.stackedSellImb) bf.stackedSellImb=run;
     }

   bf.valid=true;
   return true;
  }

//+------------------------------------------------------------------+
//| Flow history management                                          |
//+------------------------------------------------------------------+
void AppendFlow(const BarFlow &bf)
  {
   int n=ArraySize(g_flow);
   ArrayResize(g_flow,n+1,512);
   g_flow[n]=bf;
   g_cvd+=bf.delta;
   ArrayResize(g_cvdHist,n+1,512);
   g_cvdHist[n]=g_cvd;
   g_flowCount=n+1;
  }

void ResetDailyState(datetime day)
  {
   ArrayResize(g_flow,0);
   ArrayResize(g_cvdHist,0);
   g_flowCount=0;
   g_cvd=0.0;
   g_lastFlowBar=0;
   g_flowDay=day;
   g_orReady=false;
   g_orbLongDone=false;
   g_orbShortDone=false;
   g_sess.valid=false;
   g_vwap=0.0;
  }

// average total volume of recent flow bars, excluding the newest one
double FlowAvgVolume()
  {
   int last=g_flowCount-2;              // exclude signal bar
   if(last<0) return 0.0;
   int cnt=0; double sum=0.0;
   for(int i=last;i>=0 && cnt<InpFlowAvgBars;i--)
     {
      if(!g_flow[i].valid) continue;
      sum+=g_flow[i].totalVol;
      cnt++;
     }
   return (cnt>0)?sum/cnt:0.0;
  }

double FlowAvgAbsDelta()
  {
   int last=g_flowCount-2;
   if(last<0) return 0.0;
   int cnt=0; double sum=0.0;
   for(int i=last;i>=0 && cnt<InpFlowAvgBars;i--)
     {
      if(!g_flow[i].valid) continue;
      sum+=MathAbs(g_flow[i].delta);
      cnt++;
     }
   return (cnt>0)?sum/cnt:0.0;
  }

// collect flow for all closed bars since collection start
void UpdateFlow()
  {
   datetime day=g_flowDay;
   datetime cs=CollectStart(day);
   datetime closed=iTime(_Symbol,PERIOD_M1,1);
   if(closed==0 || closed<cs) return;

   int startShift=iBarShift(_Symbol,PERIOD_M1,cs,false);
   if(startShift<0) return;
   if(startShift>2000) startShift=2000;  // safety cap

   for(int s=startShift;s>=1;s--)
     {
      datetime bt=iTime(_Symbol,PERIOD_M1,s);
      if(bt<cs) continue;
      if(bt<=g_lastFlowBar) continue;
      if(DayStart(bt)!=day) continue;
      BarFlow bf;
      ComputeBarFlow(bt,bf);   // appended even if invalid to keep sequence
      AppendFlow(bf);
      g_lastFlowBar=bt;
     }

   if(!g_flagsSeen && !g_flagsWarned && g_flowCount>=InpMinFlowBars)
     {
      g_flagsWarned=true;
      Print("FV-EA: no aggressor tick flags on ",_Symbol,
            " - using tick-rule delta approximation (forex/CFD mode). ",
            "Consider lowering InpImbMinVolume.");
     }
  }

//+------------------------------------------------------------------+
//| Daily statistics from trade history                              |
//+------------------------------------------------------------------+
void UpdateDailyStats()
  {
   g_tradesToday=0;
   g_dailyPnL=0.0;
   g_consecLosses=0;

   datetime ds=DayStart(TimeCurrent());
   if(!HistorySelect(ds,TimeCurrent()+86400)) return;

   long   posIds[];
   double posPnl[];
   int    np=0;

   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
     {
      ulong dt=HistoryDealGetTicket(i);
      if(dt==0) continue;
      if((long)HistoryDealGetInteger(dt,DEAL_MAGIC)!=InpMagic) continue;
      if(HistoryDealGetString(dt,DEAL_SYMBOL)!=_Symbol) continue;

      ENUM_DEAL_ENTRY de=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt,DEAL_ENTRY);
      if(de==DEAL_ENTRY_IN)
        {
         g_tradesToday++;
         continue;
        }
      if(de==DEAL_ENTRY_OUT || de==DEAL_ENTRY_OUT_BY || de==DEAL_ENTRY_INOUT)
        {
         double pnl=HistoryDealGetDouble(dt,DEAL_PROFIT)
                   +HistoryDealGetDouble(dt,DEAL_COMMISSION)
                   +HistoryDealGetDouble(dt,DEAL_SWAP);
         long pid=(long)HistoryDealGetInteger(dt,DEAL_POSITION_ID);
         int k=-1;
         for(int j=0;j<np;j++)
            if(posIds[j]==pid) { k=j; break; }
         if(k<0)
           {
            ArrayResize(posIds,np+1);
            ArrayResize(posPnl,np+1);
            posIds[np]=pid; posPnl[np]=0.0;
            k=np; np++;
           }
         posPnl[k]+=pnl;
         g_dailyPnL+=pnl;
        }
     }

   for(int j=np-1;j>=0;j--)
     {
      if(posPnl[j]<0.0) g_consecLosses++;
      else break;
     }
  }

//+------------------------------------------------------------------+
//| Position helpers                                                 |
//+------------------------------------------------------------------+
bool SelectOurPosition(ulong &ticket)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      ticket=tk;
      return true;
     }
   return false;
  }

void TryModifySL(ulong ticket, double newSL)
  {
   if(!PositionSelectByTicket(ticket)) return;
   double curSL=PositionGetDouble(POSITION_SL);
   double tp   =PositionGetDouble(POSITION_TP);
   long   type =PositionGetInteger(POSITION_TYPE);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double minDist=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   newSL=NormalizeDouble(newSL,_Digits);

   if(type==POSITION_TYPE_BUY)
     {
      if(curSL>0.0 && newSL<=curSL+_Point) return;   // only tighten
      if(bid-newSL<minDist) return;
     }
   else
     {
      if(curSL>0.0 && newSL>=curSL-_Point) return;
      if(newSL-ask<minDist) return;
     }
   g_trade.PositionModify(ticket,newSL,tp);
  }

void ResetTradeBookkeeping()
  {
   g_entryPrice=0.0;
   g_riskDist=0.0;
   g_barsInTrade=0;
   g_partialDone=false;
   g_beDone=false;
  }

//+------------------------------------------------------------------+
//| Position sizing                                                  |
//+------------------------------------------------------------------+
double CalcLots(int dir, double price, double slDist)
  {
   if(slDist<=0.0) return 0.0;
   double riskMoney=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercent/100.0;

   // preferred: exact loss for 1 lot via the server's own profit calc
   // (immune to inconsistent tick-value specs on some symbols)
   double lossPerLot=0.0;
   double sl=(dir>0)?price-slDist:price+slDist;
   ENUM_ORDER_TYPE ot=(dir>0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double profit=0.0;
   if(OrderCalcProfit(ot,_Symbol,1.0,price,sl,profit) && profit<0.0)
      lossPerLot=-profit;
   if(lossPerLot<=0.0)
     {
      double ts =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      double tv =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
      if(ts<=0.0 || tv<=0.0) return 0.0;
      lossPerLot=slDist/ts*tv;
     }
   if(lossPerLot<=0.0) return 0.0;
   double lots=NormalizeVolume(riskMoney/lossPerLot);
   if(lots<=0.0) return 0.0;

   // margin check - halve until it fits
   double freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   for(int guard=0;guard<20 && lots>0.0;guard++)
     {
      double margin=0.0;
      if(!OrderCalcMargin(ot,_Symbol,lots,price,margin)) return 0.0;
      if(margin<freeMargin*0.95) break;
      lots=NormalizeVolume(lots*0.5);
     }
   return lots;
  }

//+------------------------------------------------------------------+
//| Trade execution                                                  |
//+------------------------------------------------------------------+
bool OpenTrade(int dir, double sl, double tp, string tag)
  {
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double price=(dir>0)?ask:bid;
   double minDist=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;

   sl=NormalizeDouble(sl,_Digits);
   tp=NormalizeDouble(tp,_Digits);

   if(dir>0)
     {
      if(sl>=price-minDist) return false;
      if(tp>0.0 && tp<=price+minDist) return false;
     }
   else
     {
      if(sl<=price+minDist) return false;
      if(tp>0.0 && tp>=price-minDist) return false;
     }

   double slDist=MathAbs(price-sl);
   double lots=CalcLots(dir,price,slDist);
   if(lots<=0.0)
     {
      Print("FV-EA: lot calculation failed (slDist=",DoubleToString(slDist,_Digits),")");
      return false;
     }

   bool ok=(dir>0)
      ? g_trade.Buy(lots,_Symbol,0.0,sl,tp,tag)
      : g_trade.Sell(lots,_Symbol,0.0,sl,tp,tag);

   uint rc=g_trade.ResultRetcode();
   if(!ok || (rc!=TRADE_RETCODE_DONE && rc!=TRADE_RETCODE_PLACED && rc!=TRADE_RETCODE_DONE_PARTIAL))
     {
      Print("FV-EA: order failed [",tag,"] retcode=",rc," ",g_trade.ResultRetcodeDescription());
      return false;
     }

   double fill=g_trade.ResultPrice();
   if(fill<=0.0) fill=price;
   g_entryPrice=fill;
   g_riskDist=MathAbs(fill-sl);
   g_barsInTrade=0;
   g_partialDone=false;
   g_beDone=false;

   Print("FV-EA: OPEN ",(dir>0?"LONG":"SHORT")," [",tag,"] lots=",DoubleToString(lots,2),
         " @",DoubleToString(fill,_Digits),
         " sl=",DoubleToString(sl,_Digits),
         " tp=",DoubleToString(tp,_Digits),
         " R=",DoubleToString(g_riskDist,_Digits));
   return true;
  }

void CloseOurPosition(string reason)
  {
   ulong ticket=0;
   if(!SelectOurPosition(ticket)) return;
   if(g_trade.PositionClose(ticket))
      Print("FV-EA: position closed (",reason,")");
   ResetTradeBookkeeping();
  }

//+------------------------------------------------------------------+
//| Ongoing position management (every tick)                         |
//+------------------------------------------------------------------+
void ManageOpenPosition()
  {
   ulong ticket=0;
   if(!SelectOurPosition(ticket))
     {
      if(g_riskDist>0.0) ResetTradeBookkeeping();
      return;
     }

   // flatten at session end
   datetime now=TimeCurrent();
   if(InpCloseAtSessEnd && now>=SessionEnd(DayStart(now)))
     {
      CloseOurPosition("session end");
      return;
     }

   long   type =PositionGetInteger(POSITION_TYPE);
   double entry=PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   =PositionGetDouble(POSITION_SL);
   double vol  =PositionGetDouble(POSITION_VOLUME);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double price=(type==POSITION_TYPE_BUY)?bid:ask;

   // restore bookkeeping after restart
   if(g_riskDist<=0.0)
     {
      g_entryPrice=entry;
      double d=(sl>0.0)?MathAbs(entry-sl):0.0;
      g_riskDist=(d>_Point)?d:GetATR();
      if(g_riskDist<=0.0) return;
     }

   double gain=(type==POSITION_TYPE_BUY)?(price-entry):(entry-price);
   double R=gain/g_riskDist;

   // scale out half + break-even at +BreakEvenR
   if(R>=InpBreakEvenR)
     {
      if(InpScaleOutHalf && !g_partialDone)
        {
         double half=NormalizeVolume(vol*0.5);
         double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
         if(half>=vmin && vol-half>=vmin)
           {
            if(g_trade.PositionClosePartial(ticket,half))
               Print("FV-EA: scaled out ",DoubleToString(half,2)," @ +",DoubleToString(R,2),"R");
           }
         g_partialDone=true;
        }
      if(!g_beDone)
        {
         TryModifySL(ticket,entry);
         g_beDone=true;
        }
     }

   // ATR trail after +TrailStartR
   if(R>=InpTrailStartR)
     {
      double atr=GetATR();
      if(atr>0.0)
        {
         double newSL=(type==POSITION_TYPE_BUY)
            ? price-InpTrailATRMult*atr
            : price+InpTrailATRMult*atr;
         TryModifySL(ticket,newSL);
        }
     }
  }

// scratch exit: flow pressure died against us within a few bars of entry
void CheckScratch()
  {
   ulong ticket=0;
   if(!SelectOurPosition(ticket)) return;
   g_barsInTrade++;
   if(g_barsInTrade<InpScratchBars) return;
   if(g_flowCount<1 || !g_flow[g_flowCount-1].valid) return;
   if(g_riskDist<=0.0) return;

   long   type =PositionGetInteger(POSITION_TYPE);
   double entry=PositionGetDouble(POSITION_PRICE_OPEN);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double price=(type==POSITION_TYPE_BUY)?bid:ask;
   double R=((type==POSITION_TYPE_BUY)?(price-entry):(entry-price))/g_riskDist;
   if(R>=0.3) return;   // trade is working - leave it alone

   double d=g_flow[g_flowCount-1].delta;
   double avgAbsD=FlowAvgAbsDelta();
   if(avgAbsD<=0.0) return;

   bool against=(type==POSITION_TYPE_BUY  && d<0.0 && MathAbs(d)>=avgAbsD)
             || (type==POSITION_TYPE_SELL && d>0.0 && d>=avgAbsD);
   if(against)
      CloseOurPosition("scratch: opposing delta, no progress");
  }

//+------------------------------------------------------------------+
//| Entry gating                                                     |
//+------------------------------------------------------------------+
bool CanTrade()
  {
   datetime now=TimeCurrent();
   datetime day=DayStart(now);
   if(now<SessionStart(day)) return false;
   if(now>=SessionEnd(day)-InpNoEntryFinalMin*60) return false;

   ulong ticket=0;
   if(SelectOurPosition(ticket)) return false;

   if(g_flowCount<InpMinFlowBars) return false;
   if(!g_flow[g_flowCount-1].valid) return false;
   if(g_flow[g_flowCount-1].time!=iTime(_Symbol,PERIOD_M1,1)) return false;
   if(!g_prior.valid) return false;

   if(g_tradesToday>=InpMaxTradesPerDay)
     {
      return false;
     }
   if(g_consecLosses>=InpMaxConsecLosses)
     {
      return false;   // Valentini's hard daily stop
     }
   double dayStartBal=AccountInfoDouble(ACCOUNT_BALANCE)-g_dailyPnL;
   if(InpDailyLossPct>0.0 && g_dailyPnL<=-dayStartBal*InpDailyLossPct/100.0)
      return false;
   if(InpDailyProfitPct>0.0 && g_dailyPnL>=dayStartBal*InpDailyProfitPct/100.0)
      return false;

   if(InpMaxSpreadPoints>0)
     {
      double spread=(SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/_Point;
      if(spread>InpMaxSpreadPoints) return false;
     }
   return true;
  }

// minimum stop distance: structural stops must clear market noise
// (spread + microstructure). Below this, spread costs dominate R.
double StopFloorDist(double atr)
  {
   double spread=SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID);
   return MathMax(InpMinStopATR*atr,InpMinStopSpreadMult*spread);
  }

//+------------------------------------------------------------------+
//| Signal evaluation on the just-closed M1 bar                      |
//| returns +1 long / -1 short / 0 none                              |
//+------------------------------------------------------------------+
int EvaluateSignal(double &slOut, double &tpOut, string &tagOut)
  {
   slOut=0.0; tpOut=0.0; tagOut="";

   MqlRates rr[];
   if(CopyRates(_Symbol,PERIOD_M1,1,2,rr)!=2) return 0;
   MqlRates r1=rr[1];   // just-closed bar (rr is ascending: [0]=shift2, [1]=shift1)
   MqlRates r2=rr[0];   // bar before it

   double atr=GetATR();
   if(atr<=0.0) return 0;
   double tol=InpLevelTolATR*atr;
   double buffer=InpStopBufferTicks*TickSizeOf();

   int last=g_flowCount-1;
   BarFlow f=g_flow[last];
   if(!f.valid || f.time!=r1.time) return 0;

   double avgVol =FlowAvgVolume();
   double avgAbsD=FlowAvgAbsDelta();
   if(avgVol<=0.0) return 0;

   double prevDelta=0.0;
   bool   prevOk=false;
   if(last>=1 && g_flow[last-1].valid && g_flow[last-1].time==r1.time-PeriodSeconds(PERIOD_M1))
     {
      prevDelta=g_flow[last-1].delta;
      prevOk=true;
     }

   // ---- aggression building blocks -------------------------------
   double range=r1.high-r1.low;
   bool absorb    =(f.totalVol>=InpAbsVolMult*avgVol) && (range<=InpAbsRangeATR*atr);
   bool absorbBull,absorbBear;
   if(InpAbsDirectional)
     {
      // true absorption: aggressive flow into the level that FAILS to move
      // price - sellers hit bids but close holds up (bullish), and vice versa
      absorbBull=absorb && range>0.0 && f.delta<=0.0 && (r1.close>=r1.low +range*0.5);
      absorbBear=absorb && range>0.0 && f.delta>=0.0 && (r1.close<=r1.high-range*0.5);
     }
   else
     {
      absorbBull=absorb && range>0.0 && (r1.close>=r1.high-range*0.35);
      absorbBear=absorb && range>0.0 && (r1.close<=r1.low +range*0.35);
     }
   bool flipUp =prevOk && prevDelta<=0.0 &&  f.delta>=InpDeltaFlipMult*avgAbsD && f.delta>0.0;
   bool flipDn =prevOk && prevDelta>=0.0 && -f.delta>=InpDeltaFlipMult*avgAbsD && f.delta<0.0;
   bool stackUp=(f.stackedBuyImb >=InpStackedLevels);
   bool stackDn=(f.stackedSellImb>=InpStackedLevels);
   bool aggrUp =flipUp||stackUp||absorbBull;
   bool aggrDn =flipDn||stackDn||absorbBear;

   // effort vs result: heavy one-sided delta that failed to pay - those
   // aggressors are trapped and fuel the reversal (footprint trap signal)
   bool trapShort=InpUseEffortResult && avgAbsD>0.0 && range>0.0
                  &&  f.delta>=avgAbsD && (r1.close<=r1.low +range*0.5);
   bool trapLong =InpUseEffortResult && avgAbsD>0.0 && range>0.0
                  && -f.delta>=avgAbsD && (r1.close>=r1.high-range*0.5);

   // trend entries may demand a genuine volume burst on the trigger bar
   bool burstOk=(InpMinVolBurst<=0.0) || (f.totalVol>=InpMinVolBurst*avgVol);

   // ---- direction building blocks ---------------------------------
   bool cvdUp=false, cvdDn=false;
   if(last>=InpCVDSlopeBars)
     {
      cvdUp=g_cvdHist[last]>g_cvdHist[last-InpCVDSlopeBars];
      cvdDn=g_cvdHist[last]<g_cvdHist[last-InpCVDSlopeBars];
     }
   bool vwapOk=(g_vwap>0.0);

   // CVD divergence at the extreme: price pokes out but cumulative delta
   // fails to confirm - buyers/sellers are running out of fuel
   bool cvdDivShortOk=true, cvdDivLongOk=true;
   if(InpUseCVDDiv && last>InpCVDDivBars)
     {
      double mx=-DBL_MAX, mn=DBL_MAX;
      for(int i=last-InpCVDDivBars;i<last;i++)
        {
         if(g_cvdHist[i]>mx) mx=g_cvdHist[i];
         if(g_cvdHist[i]<mn) mn=g_cvdHist[i];
        }
      cvdDivShortOk=(g_cvdHist[last]<mx);
      cvdDivLongOk =(g_cvdHist[last]>mn);
     }

   //================================================================
   // MODEL A: trend continuation (out of balance, pullback to LVN)
   //================================================================
   if(InpUseTrendModel && vwapOk)
     {
      // --- long: price accepted above prior-day value area
      if(r1.close>g_prior.vah && cvdUp && r1.close>g_vwap && aggrUp && burstOk)
        {
         double lvl=0.0, bestD=DBL_MAX;
         double cand[3];
         cand[0]=NearestLVN(g_sess,r1.low);
         cand[1]=g_vwap;
         cand[2]=g_prior.vah;      // breakout retest
         for(int i=0;i<3;i++)
           {
            if(cand[i]<=0.0) continue;
            double d=MathAbs(r1.low-cand[i]);
            if(d<=tol && d<bestD) { bestD=d; lvl=cand[i]; }
           }
         if(lvl>0.0)
           {
            double entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
            double sl=MathMin(r1.low,lvl)-buffer;
            double dist=entry-sl;
            double fl=StopFloorDist(atr);
            if(dist>0.0 && dist<fl) { dist=fl; sl=entry-dist; }
            if(dist>0.0 && dist<=3.0*atr)
              {
               slOut=sl;
               tpOut=entry+InpFixedRR*dist;
               tagOut="FV-TREND-L";
               return 1;
              }
           }
        }
      // --- short: price accepted below prior-day value area
      if(r1.close<g_prior.val && cvdDn && r1.close<g_vwap && aggrDn && burstOk)
        {
         double lvl=0.0, bestD=DBL_MAX;
         double cand[3];
         cand[0]=NearestLVN(g_sess,r1.high);
         cand[1]=g_vwap;
         cand[2]=g_prior.val;
         for(int i=0;i<3;i++)
           {
            if(cand[i]<=0.0) continue;
            double d=MathAbs(r1.high-cand[i]);
            if(d<=tol && d<bestD) { bestD=d; lvl=cand[i]; }
           }
         if(lvl>0.0)
           {
            double entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
            double sl=MathMax(r1.high,lvl)+buffer;
            double dist=sl-entry;
            double fl=StopFloorDist(atr);
            if(dist>0.0 && dist<fl) { dist=fl; sl=entry+dist; }
            if(dist>0.0 && dist<=3.0*atr)
              {
               slOut=sl;
               tpOut=entry-InpFixedRR*dist;
               tagOut="FV-TREND-S";
               return -1;
              }
           }
        }
     }

   //================================================================
   // MODEL B: mean reversion (failed VA breakout -> back to POC)
   //================================================================
   if(InpUseMeanReversion)
     {
      // --- short: poke above VAH, close back inside - sellers step in
      // or aggressive buyers are trapped above value
      if(r1.high>g_prior.vah && r1.close<g_prior.vah && (aggrDn||trapShort) && cvdDivShortOk)
        {
         double entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
         double sl=r1.high+buffer;
         double dist=sl-entry;
         double fl=StopFloorDist(atr);
         if(dist>0.0 && dist<fl) { dist=fl; sl=entry+dist; }
         if(dist>0.0 && dist<=3.0*atr)
           {
            double tp=PickPOCTarget(-1,entry,dist);
            if(tp>0.0)
              {
               slOut=sl; tpOut=tp; tagOut="FV-MR-S";
               return -1;
              }
           }
        }
      // --- long: poke below VAL, close back inside - buyers step in
      // or aggressive sellers are trapped below value
      if(r1.low<g_prior.val && r1.close>g_prior.val && (aggrUp||trapLong) && cvdDivLongOk)
        {
         double entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double sl=r1.low-buffer;
         double dist=entry-sl;
         double fl=StopFloorDist(atr);
         if(dist>0.0 && dist<fl) { dist=fl; sl=entry-dist; }
         if(dist>0.0 && dist<=3.0*atr)
           {
            double tp=PickPOCTarget(1,entry,dist);
            if(tp>0.0)
              {
               slOut=sl; tpOut=tp; tagOut="FV-MR-L";
               return 1;
              }
           }
        }
     }

   //================================================================
   // MODEL C: opening range breakout (optional)
   //================================================================
   if(InpUseORB && g_orReady)
     {
      bool volOk=(f.totalVol>=InpORBVolMult*avgVol);
      if(!g_orbLongDone && r2.close<=g_orHigh && r1.close>g_orHigh
         && f.delta>0.0 && volOk && cvdUp)
        {
         double entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double sl=r1.low-buffer;
         if(sl>=g_orLow) sl=MathMax(sl,(g_orHigh+g_orLow)*0.5);
         double dist=entry-sl;
         double fl=StopFloorDist(atr);
         if(dist>0.0 && dist<fl) { dist=fl; sl=entry-dist; }
         if(dist>0.0 && dist<=3.0*atr)
           {
            g_orbLongDone=true;
            slOut=sl; tpOut=entry+InpFixedRR*dist; tagOut="FV-ORB-L";
            return 1;
           }
        }
      if(!g_orbShortDone && r2.close>=g_orLow && r1.close<g_orLow
         && f.delta<0.0 && volOk && cvdDn)
        {
         double entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
         double sl=r1.high+buffer;
         if(sl<=g_orHigh) sl=MathMin(sl,(g_orHigh+g_orLow)*0.5);
         double dist=sl-entry;
         double fl=StopFloorDist(atr);
         if(dist>0.0 && dist<fl) { dist=fl; sl=entry+dist; }
         if(dist>0.0 && dist<=3.0*atr)
           {
            g_orbShortDone=true;
            slOut=sl; tpOut=entry-InpFixedRR*dist; tagOut="FV-ORB-S";
            return -1;
           }
        }
     }

   return 0;
  }

// pick nearest POC target (session or prior day) that satisfies MinRR
double PickPOCTarget(int dir, double entry, double slDist)
  {
   double best=0.0, bestDist=DBL_MAX;
   double cand[2];
   cand[0]=g_sess.valid ?g_sess.poc :0.0;
   cand[1]=g_prior.valid?g_prior.poc:0.0;
   for(int i=0;i<2;i++)
     {
      if(cand[i]<=0.0) continue;
      double d=(dir>0)?(cand[i]-entry):(entry-cand[i]);
      if(d<=0.0) continue;                      // wrong side
      if(d/slDist<InpMinRR) continue;           // Valentini: min 2:1
      if(d<bestDist) { bestDist=d; best=cand[i]; }
     }
   if(best>0.0) return best;
   if(InpMRFixedRRFallback)
      return (dir>0)?entry+InpMinRR*slDist:entry-InpMinRR*slDist;
   return 0.0;
  }

//+------------------------------------------------------------------+
//| Opening range calculation                                        |
//+------------------------------------------------------------------+
void UpdateOpeningRange()
  {
   if(g_orReady || !InpUseORB) return;
   datetime day=g_flowDay;
   datetime ss=SessionStart(day);
   datetime orEnd=ss+InpORBMinutes*60;
   if(TimeCurrent()<orEnd) return;

   MqlRates rates[];
   int n=CopyRates(_Symbol,PERIOD_M1,ss,orEnd-1,rates);
   if(n<1) return;
   double hi=-DBL_MAX, lo=DBL_MAX;
   for(int i=0;i<n;i++)
     {
      if(rates[i].high>hi) hi=rates[i].high;
      if(rates[i].low <lo) lo=rates[i].low;
     }
   if(hi>lo)
     {
      g_orHigh=hi; g_orLow=lo; g_orReady=true;
      if(InpVerboseLog)
         Print("FV-EA: opening range ",DoubleToString(lo,_Digits)," - ",DoubleToString(hi,_Digits));
     }
  }

//+------------------------------------------------------------------+
//| Prior-day profile                                                |
//+------------------------------------------------------------------+
void UpdatePriorDayProfile()
  {
   datetime today=DayStart(TimeCurrent());
   if(g_priorBuiltFor==today && g_prior.valid) return;

   datetime d0=iTime(_Symbol,PERIOD_D1,0);
   datetime d1=iTime(_Symbol,PERIOD_D1,1);
   if(d0==0 || d1==0 || d1>=d0) return;

   if(BuildProfileRange(d1,d0-1,g_prior))
     {
      g_priorBuiltFor=today;
      if(InpVerboseLog)
         Print("FV-EA: prior-day profile POC=",DoubleToString(g_prior.poc,_Digits),
               " VAH=",DoubleToString(g_prior.vah,_Digits),
               " VAL=",DoubleToString(g_prior.val,_Digits),
               " LVNs=",g_prior.lvnCount);
     }
  }

//+------------------------------------------------------------------+
//| Chart status line                                                |
//+------------------------------------------------------------------+
void UpdateComment()
  {
   datetime now=TimeCurrent();
   datetime day=DayStart(now);
   bool inSess=(now>=SessionStart(day) && now<SessionEnd(day));
   string state="n/a";
   if(g_prior.valid)
     {
      double c=iClose(_Symbol,PERIOD_M1,1);
      if(c>g_prior.vah)      state="IMBALANCED UP";
      else if(c<g_prior.val) state="IMBALANCED DOWN";
      else                   state="BALANCED (in value)";
     }
   string s="Fabio Valentini Orderflow Scalper\n";
   s+="Session: "+(inSess?"OPEN":"closed")+"  |  Market: "+state+"\n";
   if(g_prior.valid)
      s+="PriorDay  POC "+DoubleToString(g_prior.poc,_Digits)
        +"  VAH "+DoubleToString(g_prior.vah,_Digits)
        +"  VAL "+DoubleToString(g_prior.val,_Digits)+"\n";
   if(g_sess.valid)
      s+="Session   POC "+DoubleToString(g_sess.poc,_Digits)
        +"  VWAP "+DoubleToString(g_vwap,_Digits)
        +"  LVNs "+(string)g_sess.lvnCount+"\n";
   if(g_flowCount>0)
      s+="CVD "+DoubleToString(g_cvd,0)
        +"  lastDelta "+DoubleToString(g_flow[g_flowCount-1].delta,0)
        +"  ("+(g_flagsSeen?"real flags":"tick-rule approx")+")\n";
   s+="Today: trades "+(string)g_tradesToday
     +"  PnL "+DoubleToString(g_dailyPnL,2)
     +"  consecLosses "+(string)g_consecLosses;
   Comment(s);
  }

//+------------------------------------------------------------------+
//| Once-per-M1-bar processing                                       |
//+------------------------------------------------------------------+
void ProcessNewBar()
  {
   datetime now=TimeCurrent();
   datetime today=DayStart(now);

   if(g_flowDay!=today)
      ResetDailyState(today);

   UpdatePriorDayProfile();

   // collect order flow from warm-up onwards
   if(now>=CollectStart(today))
      UpdateFlow();

   // session structures
   datetime ss=SessionStart(today);
   datetime closed=iTime(_Symbol,PERIOD_M1,1);
   if(now>=ss && closed>=ss)
     {
      BuildProfileRange(ss,closed,g_sess);
      g_vwap=CalcSessionVWAP(ss,closed);
      UpdateOpeningRange();
     }

   UpdateDailyStats();

   // manage a running trade on bar close (scratch rule)
   CheckScratch();

   // look for a new entry
   if(CanTrade())
     {
      double sl,tp;
      string tag;
      int dir=EvaluateSignal(sl,tp,tag);
      if(dir!=0)
        {
         if(InpVerboseLog)
            Print("FV-EA: signal ",tag," dir=",dir,
                  " delta=",DoubleToString(g_flow[g_flowCount-1].delta,0),
                  " stackedB=",g_flow[g_flowCount-1].stackedBuyImb,
                  " stackedS=",g_flow[g_flowCount-1].stackedSellImb,
                  " CVD=",DoubleToString(g_cvd,0));
         OpenTrade(dir,sl,tp,tag);
        }
     }

   UpdateComment();
  }

//+------------------------------------------------------------------+
//| Expert event handlers                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_atrHandle=iATR(_Symbol,PERIOD_M1,InpATRPeriod);
   if(g_atrHandle==INVALID_HANDLE)
     {
      Print("FV-EA: failed to create ATR handle");
      return INIT_FAILED;
     }

   if(SessionEnd(0)<=SessionStart(0))
     {
      Print("FV-EA: session end must be after session start");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_prior.valid=false;
   g_sess.valid=false;
   ResetTradeBookkeeping();

   Print("FV-EA: initialized on ",_Symbol,
         ". Session ",InpSessStartHour,":",StringFormat("%02d",InpSessStartMin),
         "-",InpSessEndHour,":",StringFormat("%02d",InpSessEndMin)," server time. ",
         "Risk ",DoubleToString(InpRiskPercent,2),"%/trade, minRR ",DoubleToString(InpMinRR,1),
         ", max ",InpMaxConsecLosses," consecutive losses/day.");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_atrHandle!=INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   Comment("");
  }

void OnTick()
  {
   datetime bt=iTime(_Symbol,PERIOD_M1,0);
   if(bt>0 && bt!=g_lastM1Bar)
     {
      g_lastM1Bar=bt;
      ProcessNewBar();
     }
   ManageOpenPosition();
  }
//+------------------------------------------------------------------+
