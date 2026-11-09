//+------------------------------------------------------------------+
//| Fibonacci BOS Fast v2.00 - derived from 523 - MDC v1.12           |
//| Visual indicator only. Does NOT place/manage orders.             |
//| Research defaults, NOT optimized or proven profitable.           |
//| Closed-bar pivots/BOS; newest ZigZag leg can change.              |
//| Live alerts use observed Bid/Ask quotes AFTER signal creation.    |
//| Historical levels are drawings only, not backtested outcomes.    |
//| Reattach/history rebuild resets monitoring; wait for a new BOS.   |
//+------------------------------------------------------------------+
#property copyright "523 - MDC"
#property version   "2.00"




//+------------------------------------------------------------------+
//| ENUMS                                                            |
//+------------------------------------------------------------------+
enum ENUM_TXTSIZE
  {
   TS_TINY   = 0,  // Tiny
   TS_SMALL  = 1,  // Small
   TS_NORMAL = 2,  // Normal
   TS_LARGE  = 3   // Large
  };

enum ENUM_LSTYLE
  {
   LS_SOLID  = 0,  // Solid
   LS_DASHED = 1,  // Dashed
   LS_DOTTED = 2   // Dotted
  };

enum ENUM_PTSRC
  {
   PT_AUTO   = 0,  // Auto (symbol tick size)
   PT_CUSTOM = 1   // Custom
  };

enum ENUM_STOP_MODE
  {
   STOP_STRUCTURE_ATR = 0, // Beyond swing + ATR buffer
   STOP_ZONE_FIXED    = 1  // Legacy fixed buffer beyond entry zone
  };

enum ENUM_SETUP_STATE
  {
   SETUP_WAITING = 0,
   SETUP_TOUCHED,
   SETUP_STOPPED,
   SETUP_COMPLETE,
   SETUP_EXPIRED,
   SETUP_INVALIDATED,
   SETUP_SUPERSEDED,
   SETUP_HISTORY,
   SETUP_UNKNOWN
  };

enum ENUM_PANELCORNER
  {
   PC_TOPLEFT  = 0,  // Top Left
   PC_TOPRIGHT = 1,  // Top Right
   PC_BOTLEFT  = 2,  // Bottom Left
   PC_BOTRIGHT = 3   // Bottom Right
  };

//+------------------------------------------------------------------+
//| 1 - ZIGZAG SETTINGS                                              |
//+------------------------------------------------------------------+
input group "1 - ZigZag Settings"
input int     InpDepth        = 4;                   // Pivot confirmation bars on EACH side
input int     InpDeviation    = 5;                   // Minimum deviation (tick/custom units)
input int     InpBackstep     = 2;                   // Backstep (bars)
input bool    InpShowZZ       = true;                // Draw ZigZag line
input int     InpZZSegments   = 30;                  // Max ZigZag segments
input color   InpZZColor      = clrGray;             // ZigZag colour
input bool    InpZZLiveLeg    = false;               // Draw live (repainting) leg

//+------------------------------------------------------------------+
//| 2 - FIBONACCI LEVELS                                             |
//+------------------------------------------------------------------+
input group "2 - Fibonacci Levels"
input double  InpZ1Hi         =  1.200;              // Zone 1 - Upper
input double  InpZ1Mid        =  1.150;              // Zone 1 - Midpoint
input double  InpZ1Lo         =  1.100;              // Zone 1 - Lower
input double  InpEnHi         =  0.786;              // Entry - Upper lvl
input double  InpEnMid        =  0.702;              // Entry midpoint reference (not an order)
input double  InpEnLo         =  0.618;              // Entry - Lower lvl
input double  InpTP1          =  0.382;              // TP 1
input double  InpTP2          =  0.000;              // TP 2
input double  InpTP3          = -0.272;              // TP 3

//+------------------------------------------------------------------+
//| 3 - RISK MANAGEMENT                                              |
//+------------------------------------------------------------------+
input group "3 - Risk Management"
input int         InpSLPoints = 300;                 // Legacy zone SL buffer (tick/custom units)
input ENUM_PTSRC  InpPtMode   = PT_AUTO;             // Point size source
input double      InpPtCustom = 0.01;                // Custom point size


input group "3a - Faster signals / quality filters (research defaults)"
input int            InpATRPeriod       = 14;       // Wilder ATR, completed bars only
input double         InpMinSwingATR     = 0.50;     // Opposite swing separation in ATR (0=off)
input double         InpBOSBufferATR    = 0.10;     // Close beyond broken level by this ATR
input double         InpMinImpulseATR  = 1.50;     // Minimum anchor range in ATR (0=off)
input ENUM_STOP_MODE InpStopMode       = STOP_STRUCTURE_ATR;
input double         InpSLBufferATR    = 0.20;     // Buffer beyond structural swing
input double         InpMinRR2         = 1.00;     // Gross TP2 R/R from worst zone edge (0=off)
input double         InpMaxSpreadATR   = 0.10;     // Block new touches if spread > ATR fraction (0=off)
input int            InpSetupMaxBars   = 12;       // Eligible bars after BOS; expire untouched setup

//+------------------------------------------------------------------+
//| 4 - VISUAL SETTINGS                                              |
//+------------------------------------------------------------------+
input group "4 - Visual Settings"
input bool         InpShowFib      = false;          // Show Fibonacci levels
input bool         InpShowZone1    = false;           // Show Zone 1 (1.1-1.2)
input bool         InpShowEntryBox = true;           // Show Entry Box
input bool         InpShowTP       = true;           // Show TP levels
input bool         InpShowSL       = true;          // Show SL
input bool         InpShowSwingLab = true;           // Show Swing labels
input bool         InpShowPriceLab = true;           // Show Price labels
input bool         InpShowHistory  = false;          // Show Historical Setups
input int          InpMaxHistory   = 5;              // Maximum Historical Setups
input int          InpRightExt     = 25;             // Extend right (bars)
input int          InpPricePrec    = -1;             // Price decimals (-1 = symbol digits)
input int          InpBoxTransp    = 85;             // Entry Box transparency
input bool         InpBoxBorder    = true;           // Entry Box border
input int          InpBoxBorderW   = 2;              // Entry Box border width
input bool         InpBoxText      = true;           // Entry Box text
input ENUM_TXTSIZE InpBoxTextSize  = TS_NORMAL;      // Entry Box text size
input int          InpTPWidth      = 2;              // TP line width
input ENUM_LSTYLE  InpTPStyle      = LS_SOLID;       // TP line style
input bool         InpTPLabShow    = true;           // TP labels
input ENUM_TXTSIZE InpTPLabSize    = TS_SMALL;       // TP / SL label size
input ENUM_TXTSIZE InpFibLabSize   = TS_TINY;        // Fib label size
input color        InpColBull      = C'38,166,154';  // Bullish zone colour
input color        InpColBear      = C'239,83,80';   // Bearish zone colour
input color        InpColZone1     = C'255,215,0';   // Zone 1 colour
input color        InpColTP        = C'0,188,212';   // TP colour
input color        InpColSL        = C'242,54,69';   // SL colour
input color        InpColFib       = C'178,181,190'; // Fibonacci colour
input color        InpColSwing     = C'120,123,134'; // Swing label colour
input color        InpColTxt       = clrWhite;       // Label text colour

//+------------------------------------------------------------------+
//| 5 - ALERTS                                                       |
//+------------------------------------------------------------------+
input group "5 - Alerts"
input bool   InpAlertBullSetup = true;   // Alert - New Bullish Setup
input bool   InpAlertBearSetup = true;   // Alert - New Bearish Setup
input bool   InpAlertBullZone  = true;   // Alert - Bullish Entry Zone
input bool   InpAlertBearZone  = true;   // Alert - Bearish Entry Zone
input bool   InpAlertTP1       = true;   // Alert - TP 1 reached
input bool   InpAlertTP2       = true;   // Alert - TP 2 reached
input bool   InpAlertTP3       = true;   // Alert - TP 3 reached
input bool   InpAlertSL        = true;   // Alert - SL reached

input group "6 - Notification Methods"
input bool   InpUsePopup       = true;             // Enable Popup Alerts
input bool   InpUsePush        = false;            // Enable Push Notifications
input bool   InpUseSound       = true;             // Enable Sound Alerts
input string InpSoundFile      = "alert.wav";      // Sound file
input bool   InpUseEmail       = false;            // Enable Email Alerts

//+------------------------------------------------------------------+
//| 7 - TRIAL / LICENSE                                               |
//+------------------------------------------------------------------+
input group "7 - TRIAL / LICENSE"
input bool     InpEnableExpiry   = true;                    // Enable Expiration
input datetime InpExpiryDate     = D'2026.12.31 23:59';     // Expiration Date
input bool     InpShowExpiryWarn = true;                    // Show Expiration Warning
input int      InpWarnDays       = 7;                       // Warning Days Before Expiry
input bool     InpWarnAlert      = false;                   // Alert on Warning Threshold (popup/push/sound)

//+------------------------------------------------------------------+
//| 8 - INFORMATION PANEL                                            |
//+------------------------------------------------------------------+
input group "8 - Information Panel"
input bool             InpShowPanel   = true;         // Show Panel
input ENUM_PANELCORNER InpPanelPos    = PC_TOPLEFT;    // Panel Position
input int               InpPanelWidth  = 310;           // Panel Width
input int               InpPanelHeight = 0;             // Panel Height (0 = auto)
input int               InpPanelX      = 10;            // Panel X Offset
input int               InpPanelY      = 20;            // Panel Y Offset
input color              InpPanelBg     = C'20,20,24';   // Panel Background colour
input int                InpPanelTransp = 15;            // Panel Background transparency (0-100)
input color              InpPanelBorder = C'90,90,100';  // Panel Border colour
input color              InpPanelTitleC = clrWhite;      // Panel Title colour
input color              InpPanelHeadC  = C'0,188,212';  // Panel Section-header colour
input color              InpPanelTxtC   = C'220,220,225';// Panel Text colour
input color              InpPanelDimC   = C'140,140,148';// Panel Dim/placeholder colour
input color              InpPanelBullC  = C'38,166,154'; // Panel Bullish colour
input color              InpPanelBearC  = C'239,83,80';  // Panel Bearish colour
input color              InpPanelWarnC  = C'255,193,7';  // Panel Warning colour
input color              InpPanelExpC   = C'242,54,69';  // Panel Expired colour

input group "8a - Panel Content"
input bool   InpPnlSymbol   = true;   // Show Symbol
input bool   InpPnlTF       = true;   // Show Timeframe
input bool   InpPnlCountdown = true;  // Show Bar Countdown
input int    InpPnlCdWarnSecs = 10;   // Countdown warning colour under N seconds
input bool   InpPnlStatus   = true;   // Show Status
input bool   InpPnlZZ       = true;   // Show ZigZag Settings
input bool   InpPnlStruct   = true;   // Show Current Structure
input bool   InpPnlBOS      = true;   // Show BOS Status
input bool   InpPnlEntry    = true;   // Show Entry Price
input bool   InpPnlTP       = true;   // Show TP Levels
input bool   InpPnlSL       = true;   // Show SL
input bool   InpPnlExpiry   = true;   // Show Expiration
input bool   InpPnlPrice    = true;   // Show Current Price
input bool   InpPnlSpread   = true;   // Show Spread
input bool   InpPnlAlerts   = true;   // Show Alerts status

//+------------------------------------------------------------------+
//| GLOBALS                                                          |
//+------------------------------------------------------------------+
string g_prefix = "";
#define PFX g_prefix

double  g_point      = 0.0;       // resolved point size
int     g_depth      = 4;
int     g_deviation  = 5;
int     g_backstep   = 2;
int     g_maxHist    = 5;
int     g_prec       = 2;
int     g_rightExt   = 25;

// --- ZigZag state machine (mirrors Pine lastP/lastB/lastD/prevP/prevB) ---
double  g_lastP = 0.0;
int     g_lastB = -1;
int     g_lastD = 0;            // +1 = swing high, -1 = swing low
double  g_prevP = 0.0;
int     g_prevB = -1;
bool    g_hasPrev = false;

bool    g_bullUsed = false;
bool    g_bearUsed = false;

int     g_processed = 0;        // index of next bar to process
int     g_setupId   = 0;
bool    g_alertsOn  = false;    // suppressed during the initial history pass
bool    g_rebuilding = false;
double  g_tickSize = 0.0;
double  g_atr = 0.0;
int     g_atrCount = 0;
datetime g_firstBarTime = 0;
datetime g_lastClosedTime = 0;
string  g_filterNote = "Waiting for confirmed BOS";

string  g_zzNames[];            // ZigZag polyline object names (committed legs)

// --- ZigZag rendering state (v1.12) -------------------------------------
// The newest leg is PROVISIONAL: its right endpoint keeps moving while
// same-direction pivots extend it, so it lives in one reused object and is
// only committed to a permanent, index-named object once the chain advances.
// Written only by the ZZ* draw helpers - no signal code reads any of these.
double  g_zzProvAP   = 0.0;     // provisional leg - left anchor price
int     g_zzProvAB   = -1;      // provisional leg - left anchor bar
double  g_zzProvBP   = 0.0;     // provisional leg - right endpoint price
int     g_zzProvBB   = -1;      // provisional leg - right endpoint bar
bool    g_zzHasProv  = false;   // a provisional leg is currently drawn
bool    g_zzHasLive  = false;   // the live-leg object currently exists

// --- Trial / expiration state ---
bool    g_warnAlerted = false;  // one-shot flag so the warning alert doesn't spam

//+------------------------------------------------------------------+
//| SETUP OBJECT                                                     |
//+------------------------------------------------------------------+
class CSetup
  {
public:
   int      id;
   int      dir;
   double   a0, a1;
   int      leftBar;
   int      extBar;
   int      createBar;
   double   enA, enB, enMid;
   double   boxTop, boxBot;
   double   tp1, tp2, tp3, sl;
   bool     active, inZone, touched;
   bool     t1, t2, t3, slHit;
   ENUM_SETUP_STATE state;
   double   atrAtSetup, observedEntry, rr2;
   datetime eligibleTime;
   bool     spreadBlocked;
   string   objs[];

            CSetup(void)
     {
      id=0; dir=0; a0=0.0; a1=0.0; leftBar=0; extBar=0; createBar=0;
      enA=0.0; enB=0.0; enMid=0.0; boxTop=0.0; boxBot=0.0;
      tp1=0.0; tp2=0.0; tp3=0.0; sl=0.0;
      active=true; inZone=false; touched=false;
      t1=false; t2=false; t3=false; slHit=false;
      state=SETUP_WAITING; atrAtSetup=0.0; observedEntry=0.0; rr2=0.0;
      eligibleTime=0; spreadBlocked=false;
      ArrayResize(objs,0);
     }

   void     AddObj(const string nm)
     {
      int n=ArraySize(objs);
      ArrayResize(objs,n+1);
      objs[n]=nm;
     }

   void     Kill(void)
     {
      for(int i=0; i<ArraySize(objs); i++)
         ObjectDelete(0,objs[i]);
      ArrayResize(objs,0);
     }
  };

CSetup *g_setups[];

//+------------------------------------------------------------------+
//| SMALL HELPERS                                                    |
//+------------------------------------------------------------------+
int TxtSize(const ENUM_TXTSIZE s)
  {
   switch(s)
     {
      case TS_TINY:   return 7;
      case TS_SMALL:  return 8;
      case TS_LARGE:  return 12;
      default:        return 10;
     }
  }

ENUM_LINE_STYLE LStyle(const ENUM_LSTYLE s)
  {
   switch(s)
     {
      case LS_DASHED: return STYLE_DASH;
      case LS_DOTTED: return STYLE_DOT;
      default:        return STYLE_SOLID;
     }
  }

string FmtPx(const double v)
  {
   return DoubleToString(v,g_prec);
  }

// MT5 chart objects have no alpha channel: emulate Pine transparency by
// blending the colour towards the current chart background colour.
color Blend(const color c,const int transp)
  {
   int t = (int)MathMax(0,MathMin(100,transp));
   color bg = (color)ChartGetInteger(0,CHART_COLOR_BACKGROUND);
   double a = 1.0 - t/100.0;
   int c0=(int)(c&0xFF),      c1=(int)((c>>8)&0xFF),  c2=(int)((c>>16)&0xFF);
   int b0=(int)(bg&0xFF),     b1=(int)((bg>>8)&0xFF), b2=(int)((bg>>16)&0xFF);
   int r0=(int)(c0*a + b0*(1.0-a));
   int r1=(int)(c1*a + b1*(1.0-a));
   int r2=(int)(c2*a + b2*(1.0-a));
   return (color)((r2<<16)|(r1<<8)|r0);
  }

// Fibonacci price for level L given anchors a0 (level 0) and a1 (level 1)
double FibPrice(const double a0,const double a1,const double L)
  {
   return a0 + L*(a1-a0);
  }

// Round prices to the broker's tradable tick grid. Fib levels use nearest;
// stops round outward so rounding never tightens the intended stop.
double SnapPrice(const double value,const int outward=0)
  {
   double units=value/g_tickSize;
   double ticks=(outward<0 ? MathFloor(units+1e-9) :
                 (outward>0 ? MathCeil(units-1e-9) : MathRound(units)));
   return NormalizeDouble(ticks*g_tickSize,_Digits);
  }

// Wilder ATR seeded by the arithmetic mean of the first N true ranges.
void UpdateATRValue(const double hi,const double lo,const double prevClose,const bool first)
  {
   double tr=hi-lo;
   if(!first)
      tr=MathMax(tr,MathMax(MathAbs(hi-prevClose),MathAbs(lo-prevClose)));
   if(g_atrCount<InpATRPeriod)
     {
      g_atr+=tr;
      g_atrCount++;
      if(g_atrCount==InpATRPeriod) g_atr/=InpATRPeriod;
     }
   else
      g_atr=(g_atr*(InpATRPeriod-1)+tr)/InpATRPeriod;
  }

bool ATRReady(void) { return (g_atrCount>=InpATRPeriod && g_atr>0.0); }

double SwingThreshold(void)
  {
   return MathMax(g_deviation*g_point,ATRReady() ? InpMinSwingATR*g_atr : 0.0);
  }

bool ConfigureLevels(CSetup *s)
  {
   if(!ATRReady()) return false;
   double span=MathAbs(s.a0-s.a1);
   if(span<InpMinImpulseATR*g_atr) return false;
   s.enA=SnapPrice(FibPrice(s.a0,s.a1,InpEnHi));
   s.enB=SnapPrice(FibPrice(s.a0,s.a1,InpEnLo));
   s.enMid=SnapPrice(FibPrice(s.a0,s.a1,InpEnMid));
   s.boxTop=MathMax(s.enA,s.enB);
   s.boxBot=MathMin(s.enA,s.enB);
   s.tp1=SnapPrice(FibPrice(s.a0,s.a1,InpTP1));
   s.tp2=SnapPrice(FibPrice(s.a0,s.a1,InpTP2));
   s.tp3=SnapPrice(FibPrice(s.a0,s.a1,InpTP3));
   s.atrAtSetup=g_atr;
   double buffer=(InpStopMode==STOP_STRUCTURE_ATR ?
                  MathMax(2.0*g_tickSize,InpSLBufferATR*g_atr) : InpSLPoints*g_point);
   double base=(InpStopMode==STOP_STRUCTURE_ATR ? s.a1 :
                (s.dir==1 ? s.boxBot : s.boxTop));
   s.sl=SnapPrice(base-s.dir*buffer,-s.dir);
   double worst=(s.dir==1 ? s.boxTop : s.boxBot);
   double risk=s.dir*(worst-s.sl);
   double reward=s.dir*(s.tp2-worst);
   // Reject collapsed tick-rounded levels and incorrectly ordered input levels.
   if(s.boxTop<=s.boxBot || risk<=0.0 || reward<=0.0 ||
      s.dir*(s.tp1-worst)<=0.0 || s.dir*(s.tp2-s.tp1)<=0.0 ||
      s.dir*(s.tp3-s.tp2)<=0.0) return false;
   s.rr2=reward/risk;
   return (s.rr2>=InpMinRR2);
  }

string SetupStateText(CSetup *s)
  {
   if(s==NULL) return "WAITING FOR BOS";
   switch(s.state)
     {
      case SETUP_WAITING:     return s.spreadBlocked ? "WAIT - SPREAD TOO WIDE" : "WAITING FOR ZONE";
      case SETUP_TOUCHED:     return "ZONE TOUCHED (quote)";
      case SETUP_STOPPED:     return "STOP REACHED - CLOSED";
      case SETUP_COMPLETE:    return "TP3 REACHED - CLOSED";
      case SETUP_EXPIRED:     return "EXPIRED - NO TOUCH";
      case SETUP_INVALIDATED: return "INVALIDATED BEFORE TOUCH";
      case SETUP_SUPERSEDED:  return "REPLACED BY NEW SETUP";
      case SETUP_HISTORY:     return "HISTORY - WAIT NEW BOS";
      default:               return "DATA GAP - UNRESOLVED";
     }
  }

void FinishSetup(CSetup *s,const ENUM_SETUP_STATE state)
  {
   s.state=state;
   s.active=false;
  }

string TfString(void)
  {
   string s = EnumToString((ENUM_TIMEFRAMES)_Period);   // e.g. PERIOD_M5
   int p = StringFind(s,"_");
   if(p>=0)
      return StringSubstr(s,p+1);
   return s;
  }

datetime RightTime(const datetime &time[],const int rates_total)
  {
   int last = rates_total-1;
   if(last<0)
      return (datetime)TimeCurrent();
   return (datetime)(time[last] + (long)g_rightExt*PeriodSeconds(_Period));
  }

datetime BarTime(const datetime &time[],const int rates_total,const int idx)
  {
   int i = (int)MathMax(0,MathMin(rates_total-1,idx));
   return time[i];
  }

//+------------------------------------------------------------------+
//| OBJECT CREATION                                                  |
//+------------------------------------------------------------------+
void MkLine(CSetup *s,const string nm,const datetime t1,const double p1,
            const datetime t2,const double p2,const color c,const int w,
            const ENUM_LINE_STYLE st)
  {
   if(ObjectFind(0,nm)<0)
      ObjectCreate(0,nm,OBJ_TREND,0,t1,p1,t2,p2);
   ObjectSetInteger(0,nm,OBJPROP_TIME,0,t1);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,0,p1);
   ObjectSetInteger(0,nm,OBJPROP_TIME,1,t2);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,1,p2);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,c);
   ObjectSetInteger(0,nm,OBJPROP_WIDTH,w);
   ObjectSetInteger(0,nm,OBJPROP_STYLE,st);
   ObjectSetInteger(0,nm,OBJPROP_RAY_LEFT,false);
   ObjectSetInteger(0,nm,OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,nm,OBJPROP_BACK,false);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,nm,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
   if(s!=NULL)
      s.AddObj(nm);
  }

void MkText(CSetup *s,const string nm,const datetime t,const double p,
            const string txt,const color c,const int fsize,
            const ENUM_ANCHOR_POINT anchor)
  {
   if(ObjectFind(0,nm)<0)
      ObjectCreate(0,nm,OBJ_TEXT,0,t,p);
   ObjectSetInteger(0,nm,OBJPROP_TIME,0,t);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,0,p);
   ObjectSetString (0,nm,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,c);
   ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,fsize);
   ObjectSetString (0,nm,OBJPROP_FONT,"Arial");
   ObjectSetInteger(0,nm,OBJPROP_ANCHOR,anchor);
   ObjectSetInteger(0,nm,OBJPROP_BACK,false);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,nm,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
   if(s!=NULL)
      s.AddObj(nm);
  }

void MkRect(CSetup *s,const string nm,const datetime t1,const double p1,
            const datetime t2,const double p2,const color c,
            const bool fill,const int width)
  {
   if(ObjectFind(0,nm)<0)
      ObjectCreate(0,nm,OBJ_RECTANGLE,0,t1,p1,t2,p2);
   ObjectSetInteger(0,nm,OBJPROP_TIME,0,t1);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,0,p1);
   ObjectSetInteger(0,nm,OBJPROP_TIME,1,t2);
   ObjectSetDouble (0,nm,OBJPROP_PRICE,1,p2);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,c);
   ObjectSetInteger(0,nm,OBJPROP_FILL,fill);
   ObjectSetInteger(0,nm,OBJPROP_WIDTH,width);
   ObjectSetInteger(0,nm,OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,nm,OBJPROP_BACK,fill);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,nm,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
   if(s!=NULL)
      s.AddObj(nm);
  }

//+------------------------------------------------------------------+
//| SETUP ARRAY MANAGEMENT                                           |
//+------------------------------------------------------------------+
void PushSetup(CSetup *s)
  {
   int n=ArraySize(g_setups);
   ArrayResize(g_setups,n+1);
   g_setups[n]=s;
  }

void RemoveSetupAt(const int idx)
  {
   int n=ArraySize(g_setups);
   if(idx<0 || idx>=n)
      return;
   if(CheckPointer(g_setups[idx])!=POINTER_INVALID)
     {
      g_setups[idx].Kill();
      delete g_setups[idx];
     }
   for(int i=idx; i<n-1; i++)
      g_setups[i]=g_setups[i+1];
   ArrayResize(g_setups,n-1);
  }

void ClearAllSetups(void)
  {
   for(int i=ArraySize(g_setups)-1; i>=0; i--)
      RemoveSetupAt(i);
   ArrayResize(g_setups,0);
  }

void ClearZigZag(void)
  {
   for(int i=0; i<ArraySize(g_zzNames); i++)
      ObjectDelete(0,g_zzNames[i]);
   ArrayResize(g_zzNames,0);
   //--- the two single-instance legs are not in g_zzNames, so delete them here
   ObjectDelete(0,PFX+"zz_prov");
   ObjectDelete(0,PFX+"zz_live");
   g_zzProvAP=0.0; g_zzProvAB=-1;
   g_zzProvBP=0.0; g_zzProvBB=-1;
   g_zzHasProv=false;
   g_zzHasLive=false;
  }

//+------------------------------------------------------------------+
//| ZIGZAG RENDERING (v1.12)                                         |
//|                                                                  |
//| Visual layer only. These helpers read the ZigZag state machine   |
//| but never write to it, so no setup, entry zone, TP or SL can be  |
//| affected by anything in this section.                            |
//+------------------------------------------------------------------+

// The provisional leg has become final (the chain advanced past it): copy it
// into a permanent object named after its two bar indices and let the
// existing InpZZSegments FIFO own it from here on.
void ZZCommitProvisional(const datetime &time[],const int rates_total)
  {
   if(!g_zzHasProv)
      return;

   string nm = PFX + "zz_" + IntegerToString(g_zzProvAB) + "_" + IntegerToString(g_zzProvBB);
   MkLine(NULL,nm,BarTime(time,rates_total,g_zzProvAB),g_zzProvAP,
          BarTime(time,rates_total,g_zzProvBB),g_zzProvBP,InpZZColor,1,STYLE_SOLID);

   int k=ArraySize(g_zzNames);
   ArrayResize(g_zzNames,k+1);
   g_zzNames[k]=nm;
   while(ArraySize(g_zzNames)>InpZZSegments)
     {
      ObjectDelete(0,g_zzNames[0]);
      int m=ArraySize(g_zzNames);
      for(int i=0; i<m-1; i++)
         g_zzNames[i]=g_zzNames[i+1];
      ArrayResize(g_zzNames,m-1);
     }

   g_zzHasProv=false;
  }

// Point the single provisional object at the current newest leg,
// prev swing -> last swing. Called on every confirmed pivot that touches the
// chain, so an extension moves this endpoint in place instead of stranding it.
void ZZUpdateProvisional(const datetime &time[],const int rates_total)
  {
   g_zzProvAB=g_prevB;  g_zzProvAP=g_prevP;
   g_zzProvBB=g_lastB;  g_zzProvBP=g_lastP;
   g_zzHasProv=true;

   MkLine(NULL,PFX+"zz_prov",BarTime(time,rates_total,g_zzProvAB),g_zzProvAP,
          BarTime(time,rates_total,g_zzProvBB),g_zzProvBP,InpZZColor,1,STYLE_SOLID);
  }

void ZZHideLive(void)
  {
   if(g_zzHasLive)
      ObjectSetInteger(0,PFX+"zz_live",OBJPROP_TIMEFRAMES,OBJ_NO_PERIODS);
  }

// Optional dashed leg from the last confirmed swing to the running extreme of
// the developing move, including the forming bar. REPAINTS by design - it is
// off unless the user asks for it.
void ZZUpdateLiveLeg(const datetime &time[],const int rates_total,
                     const double &high[],const double &low[])
  {
   if(!InpShowZZ || !InpZZLiveLeg || g_lastD==0 || g_lastB<0)
     {
      ZZHideLive();
      return;
     }

   int cur = rates_total-1;
   if(cur<=g_lastB)
     {
      ZZHideLive();
      return;
     }

   // window [g_lastB, cur] inclusive; HighestHigh/LowestLow scan back from cur
   int    len = cur-g_lastB+1;
   double xv  = 0.0;
   int    xb  = cur;
   if(g_lastD==-1)
      HighestHigh(high,cur,len,xv,xb);   // last swing was a LOW  -> leg is UP
   else
      LowestLow(low,cur,len,xv,xb);      // last swing was a HIGH -> leg is DOWN

   //--- degenerate: the extreme is still the swing itself, there is no leg yet
   if(xb==g_lastB)
     {
      ZZHideLive();
      return;
     }

   //--- same deviation filter the state machine applies before advancing, so a
   //--- one-tick wiggle cannot spawn a line.
   //--- NOTE: deliberately NOT backstep-filtered. This leg can therefore show a
   //--- move that the chain would later refuse to confirm. That is intended:
   //--- it is a preview of the developing move, not a prediction that the swing
   //--- will be confirmed.
   if(MathAbs(xv-g_lastP) < SwingThreshold())
     {
      ZZHideLive();
      return;
     }

   //--- one object, updated in place - never recreated per tick
   MkLine(NULL,PFX+"zz_live",BarTime(time,rates_total,g_lastB),g_lastP,
          BarTime(time,rates_total,xb),xv,Blend(InpZZColor,45),1,STYLE_DASH);
   ObjectSetInteger(0,PFX+"zz_live",OBJPROP_TIMEFRAMES,OBJ_ALL_PERIODS);
   g_zzHasLive=true;
  }

void ResetAll(void)
  {
   ClearAllSetups();
   ClearZigZag();
   ObjectsDeleteAll(0,PFX);
   g_lastP=0.0; g_lastB=-1; g_lastD=0;
   g_prevP=0.0; g_prevB=-1; g_hasPrev=false;
   g_bullUsed=false; g_bearUsed=false;
   g_processed=0;
   g_setupId=0;
   g_atr=0.0; g_atrCount=0;
   g_firstBarTime=0; g_lastClosedTime=0;
   g_filterNote="Waiting for confirmed BOS";
   g_alertsOn=false;
   CreatePanel();   // recreate panel objects since ObjectsDeleteAll wiped them (same PFX prefix)
  }

//+------------------------------------------------------------------+
//| ============ TRIAL / EXPIRATION SYSTEM (ADDED) ================ |
//| Central, single source of truth for the licence state so every  |
//| signal / alert path can be gated through the same check.        |
//+------------------------------------------------------------------+

// Uses TimeCurrent() (MT5 server/platform time) rather than the local PC
// clock, and the comparison is against a fixed calendar input, so changing
// the chart timeframe or reloading the indicator cannot reset or bypass it.
bool IsExpired(void)
  {
   if(!InpEnableExpiry)
      return false;
   return (TimeCurrent() >= InpExpiryDate);
  }

bool IsInWarningWindow(void)
  {
   if(!InpEnableExpiry || !InpShowExpiryWarn)
      return false;
   if(IsExpired())
      return false;
   long secsLeft = (long)(InpExpiryDate - TimeCurrent());
   long warnSecs = (long)InpWarnDays*86400;
   return (secsLeft>=0 && secsLeft<=warnSecs);
  }

// Whole days remaining, rounded up (e.g. 30h left -> "2 days")
int DaysToExpiry(void)
  {
   long secsLeft = (long)(InpExpiryDate - TimeCurrent());
   if(secsLeft<0)
      secsLeft=0;
   int days = (int)(secsLeft/86400);
   if(secsLeft%86400 > 0)
      days++;
   return days;
  }

string ExpiryDateString(void)
  {
   MqlDateTime dt;
   TimeToStruct(InpExpiryDate,dt);
   static string months[12] = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"};
   string mon = (dt.mon>=1 && dt.mon<=12) ? months[dt.mon-1] : "";
   return StringFormat("%02d %s %04d",dt.day,mon,dt.year);
  }

// One-shot (non-spamming) alert when the warning window is first entered.
void CheckExpiryWarningAlert(void)
  {
   if(!InpWarnAlert)
      return;
   if(IsInWarningWindow())
     {
      if(!g_warnAlerted)
        {
         g_warnAlerted=true;
         Notify_Raw("TRIAL EXPIRING SOON\nExpires: "+ExpiryDateString()+" ("+IntegerToString(DaysToExpiry())+" day(s) left)");
        }
     }
   else
      g_warnAlerted=false;
  }

//+------------------------------------------------------------------+
//| NOTIFICATIONS                                                    |
//+------------------------------------------------------------------+
// Low-level sender used both by the normal trading alerts and by the
// (optional) expiry-warning alert. Does NOT itself check IsExpired(),
// since the warning alert must still fire while the trial is active.
void Notify_Raw(const string body)
  {
   string head = _Symbol + " " + TfString();
   string msg  = head + "\n" + body;

   if(InpUsePopup)
      Alert(msg);
   if(InpUsePush)
      SendNotification(msg);
   if(InpUseSound && StringLen(InpSoundFile)>0)
      PlaySound(InpSoundFile);
   if(InpUseEmail)
      SendMail(head + " - Fibonacci BOS Setup", msg);
   Print("[FBS] ",StringSubstr(msg,0,400));
  }

void Notify(const string body)
  {
   if(!g_alertsOn || g_rebuilding)
      return;
   // Central expiry gate: once the trial has expired, no trading alert of
   // any kind (setup / zone / TP / SL) is allowed to fire, from any path.
   if(IsExpired())
      return;
   Notify_Raw(body);
  }

void NotifySetup(CSetup *s)
  {
   if(s==NULL)
      return;
   if(s.dir==1 && !InpAlertBullSetup)
      return;
   if(s.dir==-1 && !InpAlertBearSetup)
      return;
   string body = (s.dir==1 ? "BULLISH" : "BEARISH") + " Fibonacci Setup v2 (visual only)\n"
                 + "Entry: " + FmtPx(s.boxBot) + " - " + FmtPx(s.boxTop) + "\n"
                 + "TP1: " + FmtPx(s.tp1) + "\n"
                 + "TP2: " + FmtPx(s.tp2) + "\n"
                 + "TP3: " + FmtPx(s.tp3) + "\n"
                 + "SL: "  + FmtPx(s.sl) + "\n"
                 + "TP2 gross R/R (worst edge): " + DoubleToString(s.rr2,2) + "\n"
                 + "Wait for a subsequent executable quote in the zone.";
   Notify(body);
  }

void OriginalNotifyZone(CSetup *s)
  {
   if(s==NULL)
      return;
   if(s.dir==1 && !InpAlertBullZone)
      return;
   if(s.dir==-1 && !InpAlertBearZone)
      return;
   string body = (s.dir==1 ? "BULLISH" : "BEARISH") + " ENTRY ZONE OBSERVED (not an order)\n"
                 + "Zone: " + FmtPx(s.boxBot) + " - " + FmtPx(s.boxTop) + "\n"
                 + "Observed quote: " + FmtPx(s.observedEntry);
   Notify(body);
  }

void OriginalNotifyLevel(const string tag,const double price,const bool enabled)
  {
   if(!enabled)
      return;
   Notify(tag + " OBSERVED AFTER ZONE TOUCH\nLevel: " + FmtPx(price));
  }

//+------------------------------------------------------------------+
//| PIVOTS - replication of ta.pivothigh / ta.pivotlow               |
//| A pivot at bar p needs `depth` bars on BOTH sides and is only    |
//| confirmed once bar p+depth has closed.                           |
//+------------------------------------------------------------------+
bool IsPivotHigh(const double &high[],const int p,const int depth,const int rates_total)
  {
   if(p-depth<0 || p+depth>rates_total-1)
      return false;
   double v=high[p];
   for(int i=p-depth; i<=p+depth; i++)
     {
      if(i==p)
         continue;
      if(high[i]>=v)
         return false;
     }
   return true;
  }

bool IsPivotLow(const double &low[],const int p,const int depth,const int rates_total)
  {
   if(p-depth<0 || p+depth>rates_total-1)
      return false;
   double v=low[p];
   for(int i=p-depth; i<=p+depth; i++)
     {
      if(i==p)
         continue;
      if(low[i]<=v)
         return false;
     }
   return true;
  }

// Highest high (and its bar) over the last `len` bars ending at bar b.
// Ties keep the MOST RECENT bar - identical to the Pine f_hh() loop.
void HighestHigh(const double &high[],const int b,const int len,double &val,int &idx)
  {
   val=high[b];
   idx=b;
   for(int i=1; i<len; i++)
     {
      int j=b-i;
      if(j<0)
         break;
      if(high[j]>val)
        {
         val=high[j];
         idx=j;
        }
     }
  }

void LowestLow(const double &low[],const int b,const int len,double &val,int &idx)
  {
   val=low[b];
   idx=b;
   for(int i=1; i<len; i++)
     {
      int j=b-i;
      if(j<0)
         break;
      if(low[j]<val)
        {
         val=low[j];
         idx=j;
        }
     }
  }

//+------------------------------------------------------------------+
//| BUILD ALL OBJECTS FOR A SETUP                                    |
//+------------------------------------------------------------------+
void BuildFibLine(CSetup *s,const string tag,const double lvl,const color c,
                  const int w,const ENUM_LSTYLE st,const datetime tLeft,
                  const datetime tRight)
  {
   double p = FibPrice(s.a0,s.a1,lvl);
   string nm = PFX + IntegerToString(s.id) + "_fib_" + tag;
   MkLine(s,nm,tLeft,p,tRight,p,c,w,LStyle(st));
   if(InpShowPriceLab)
      MkText(s,nm+"_lab",tRight,p,FmtPx(p),c,TxtSize(InpFibLabSize),ANCHOR_LEFT);
  }

void BuildLevelLine(CSetup *s,const string tag,const double p,const color c,
                    const int w,const ENUM_LSTYLE st,const bool lab,
                    const datetime tLeft,const datetime tRight)
  {
   string nm = PFX + IntegerToString(s.id) + "_lvl_" + tag;
   MkLine(s,nm,tLeft,p,tRight,p,c,w,LStyle(st));
   if(lab)
      MkText(s,nm+"_lab",tRight,p,FmtPx(p),c,TxtSize(InpTPLabSize),ANCHOR_LEFT);
  }

void BuildSetup(CSetup *s,const datetime &time[],const int rates_total)
  {
   datetime tLeft  = BarTime(time,rates_total,s.createBar+1);
   datetime tRight = RightTime(time,rates_total);
   color    zcol   = (s.dir==1 ? InpColBull : InpColBear);
   bool     isBull = (s.dir==1);
   string   base   = PFX + IntegerToString(s.id);

   MkText(s,base+"_available",tLeft,isBull?s.boxTop:s.boxBot,
          "BOS confirmed",zcol,TxtSize(TS_SMALL),isBull?ANCHOR_LOWER:ANCHOR_UPPER);

   //--- Fibonacci structure lines -------------------------------------
   if(InpShowFib)
     {
      BuildFibLine(s,"1",  1.0,      InpColFib,1,LS_SOLID, tLeft,tRight);
      BuildFibLine(s,"0",  0.0,      InpColFib,1,LS_SOLID, tLeft,tRight);
      BuildFibLine(s,"eH", InpEnHi,  InpColFib,1,LS_DOTTED,tLeft,tRight);
      BuildFibLine(s,"eM", InpEnMid, InpColFib,1,LS_DASHED,tLeft,tRight);
      BuildFibLine(s,"eL", InpEnLo,  InpColFib,1,LS_DOTTED,tLeft,tRight);
      if(InpShowZone1)
        {
         BuildFibLine(s,"z1H",InpZ1Hi, InpColZone1,1,LS_DOTTED,tLeft,tRight);
         BuildFibLine(s,"z1M",InpZ1Mid,InpColZone1,1,LS_DASHED,tLeft,tRight);
         BuildFibLine(s,"z1L",InpZ1Lo, InpColZone1,1,LS_DOTTED,tLeft,tRight);
        }
     }

   //--- Zone 1 box -----------------------------------------------------
   if(InpShowZone1)
     {
      double z1a = FibPrice(s.a0,s.a1,InpZ1Hi);
      double z1b = FibPrice(s.a0,s.a1,InpZ1Lo);
      double zTop = MathMax(z1a,z1b);
      double zBot = MathMin(z1a,z1b);
      MkRect(s,base+"_z1fill",tLeft,zTop,tRight,zBot,
             Blend(InpColZone1,(int)MathMin(InpBoxTransp+8,100)),true,1);
      if(InpBoxBorder)
         MkRect(s,base+"_z1edge",tLeft,zTop,tRight,zBot,InpColZone1,false,1);
      if(InpBoxText)
         MkText(s,base+"_z1txt",tLeft,(zTop+zBot)/2.0,
                FmtPx(zTop)+" - "+FmtPx(zBot),InpColZone1,
                TxtSize(InpFibLabSize),ANCHOR_LEFT);
     }

   //--- Entry Box ------------------------------------------------------
   if(InpShowEntryBox)
     {
      MkRect(s,base+"_enfill",tLeft,s.boxTop,tRight,s.boxBot,
             Blend(zcol,InpBoxTransp),true,1);
      if(InpBoxBorder)
         MkRect(s,base+"_enedge",tLeft,s.boxTop,tRight,s.boxBot,zcol,false,
                (int)MathMax(1,InpBoxBorderW));
      if(InpBoxText)
        {
         datetime tMid = (datetime)(tLeft + (tRight-tLeft)/2);
         MkText(s,base+"_entxt",tMid,(s.boxTop+s.boxBot)/2.0,
                FmtPx(s.boxTop)+" - "+FmtPx(s.boxBot),zcol,
                TxtSize(InpBoxTextSize),ANCHOR_CENTER);
        }
     }

   //--- TP levels ------------------------------------------------------
   if(InpShowTP)
     {
      BuildLevelLine(s,"tp1",s.tp1,InpColTP,InpTPWidth,InpTPStyle,InpTPLabShow,tLeft,tRight);
      BuildLevelLine(s,"tp2",s.tp2,InpColTP,InpTPWidth,InpTPStyle,InpTPLabShow,tLeft,tRight);
      BuildLevelLine(s,"tp3",s.tp3,InpColTP,InpTPWidth,InpTPStyle,InpTPLabShow,tLeft,tRight);
     }

   //--- Stop Loss ------------------------------------------------------
   if(InpShowSL)
      BuildLevelLine(s,"sl",s.sl,InpColSL,InpTPWidth,LS_SOLID,InpTPLabShow,tLeft,tRight);

   //--- Swing anchor labels -------------------------------------------
   if(InpShowSwingLab)
     {
      string nA1 = isBull ? "Swing Low (1)"  : "Swing High (1)";
      string nA0 = isBull ? "Swing High (0)" : "Swing Low (0)";
      datetime tA0 = BarTime(time,rates_total,s.extBar);
      datetime tA1 = BarTime(time,rates_total,s.leftBar);
      MkText(s,base+"_sw1",tA1,s.a1,nA1+"  "+FmtPx(s.a1),InpColSwing,
             TxtSize(InpFibLabSize),isBull ? ANCHOR_UPPER : ANCHOR_LOWER);
      MkText(s,base+"_sw0",tA0,s.a0,nA0+"  "+FmtPx(s.a0),InpColSwing,
             TxtSize(InpFibLabSize),isBull ? ANCHOR_LOWER : ANCHOR_UPPER);
     }
  }

//+------------------------------------------------------------------+
//| EXTEND THE ACTIVE SETUP TO THE RIGHT                             |
//+------------------------------------------------------------------+
void ExtendActive(const datetime &time[],const int rates_total)
  {
   int n=ArraySize(g_setups);
   if(n<=0)
      return;
   CSetup *s=g_setups[n-1];
   if(CheckPointer(s)==POINTER_INVALID || !s.active)
      return;

   datetime tRight = RightTime(time,rates_total);
   datetime tLeft  = BarTime(time,rates_total,s.createBar+1);

   for(int i=0; i<ArraySize(s.objs); i++)
     {
      string nm=s.objs[i];
      if(ObjectFind(0,nm)<0)
         continue;
      ENUM_OBJECT tp=(ENUM_OBJECT)ObjectGetInteger(0,nm,OBJPROP_TYPE);
      if(tp==OBJ_TREND || tp==OBJ_RECTANGLE)
         ObjectSetInteger(0,nm,OBJPROP_TIME,1,tRight);
      else
         if(tp==OBJ_TEXT)
           {
            if(StringFind(nm,"_lab")>=0)
               ObjectSetInteger(0,nm,OBJPROP_TIME,0,tRight);
            else
               if(StringFind(nm,"_entxt")>=0)
                  ObjectSetInteger(0,nm,OBJPROP_TIME,0,(datetime)(tLeft+(tRight-tLeft)/2));
           }
     }
  }

//+------------------------------------------------------------------+
//| QUOTE MONITOR - observed milestones, not fills or trade results.  |
//| Never reuse full candle extrema for live entry/exit chronology.   |
//+------------------------------------------------------------------+
void TrackQuote(CSetup *s,const int bar,const datetime quoteTime,
                const double bid,const double ask)
  {
   if(s==NULL || !s.active || s.state==SETUP_HISTORY ||
      bar<=s.createBar || quoteTime<s.eligibleTime ||
      bid<=0.0 || ask<bid || !MathIsValidNumber(bid) || !MathIsValidNumber(ask)) return;

   if(!s.touched && bar-s.createBar>InpSetupMaxBars)
     {
      FinishSetup(s,SETUP_EXPIRED);
      return;
     }

   double exitQuote=(s.dir==1 ? bid : ask);
   bool stop=(s.dir==1 ? exitQuote<=s.sl : exitQuote>=s.sl);
   if(stop)
     {
      if(s.touched)
        {
         s.slHit=true;
         FinishSetup(s,SETUP_STOPPED);
         NotifyLevel("SL",s.sl,InpAlertSL);
        }
      else
         FinishSetup(s,SETUP_INVALIDATED);
      return; // terminal: no subsequent TP notification for this setup
     }

   if(!s.touched)
     {
      s.spreadBlocked=(InpMaxSpreadATR>0.0 && ask-bid>InpMaxSpreadATR*s.atrAtSetup);
      if(s.spreadBlocked) return;
      double entryQuote=(s.dir==1 ? ask : bid);
      bool inside=(entryQuote>=s.boxBot && entryQuote<=s.boxTop);
      if(inside)
        {
         s.touched=true;
         s.inZone=true;
         s.state=SETUP_TOUCHED;
         s.observedEntry=entryQuote;
         NotifyZone(s);
        }
      return; // no target on the entry observation
     }

   if(!s.t1 && (s.dir==1 ? exitQuote>=s.tp1 : exitQuote<=s.tp1))
     { s.t1=true; NotifyLevel("TP1",s.tp1,InpAlertTP1); }
   if(!s.t2 && (s.dir==1 ? exitQuote>=s.tp2 : exitQuote<=s.tp2))
     { s.t2=true; NotifyLevel("TP2",s.tp2,InpAlertTP2); }
   if(!s.t3 && (s.dir==1 ? exitQuote>=s.tp3 : exitQuote<=s.tp3))
     {
      s.t3=true;
      FinishSetup(s,SETUP_COMPLETE);
      NotifyLevel("TP3",s.tp3,InpAlertTP3);
     }
  }

void TrackLive(const int bar)
  {
   if(IsExpired() || ArraySize(g_setups)==0) return;
   CSetup *s=g_setups[ArraySize(g_setups)-1];
   if(CheckPointer(s)==POINTER_INVALID) return;
   MqlTick tick={};
   if(SymbolInfoTick(_Symbol,tick))
      TrackQuote(s,bar,tick.time,tick.bid,tick.ask);
  }

//+------------------------------------------------------------------+
//| PROCESS ONE CLOSED BAR - confirmed pivots and filtered BOS       |
//+------------------------------------------------------------------+
void ProcessBar(const int b,const int rates_total,const datetime &time[],
                const double &high[],const double &low[],const double &close[])
  {
   UpdateATRValue(high[b],low[b],b>0?close[b-1]:close[b],b==0);
   bool newLowSwing  = false;
   bool newHighSwing = false;
   bool chainAdvance = false;

   int p = b - g_depth;   // candidate pivot bar confirmed on bar b

   //================= LOW PIVOT =====================================
   if(p>=0 && IsPivotLow(low,p,g_depth,rates_total))
     {
      double pv = low[p];
      if(g_lastD==0)
        {
         g_lastP=pv; g_lastB=p; g_lastD=-1;
         newLowSwing=true;
        }
      else
         if(g_lastD==-1)
           {
            if(pv<g_lastP)
              {
               g_lastP=pv; g_lastB=p;
               newLowSwing=true;
              }
           }
         else
           {
            if(MathAbs(g_lastP-pv)>=SwingThreshold() && (p-g_lastB)>=g_backstep)
              {
               g_prevP=g_lastP; g_prevB=g_lastB; g_hasPrev=true;
               g_lastP=pv; g_lastB=p; g_lastD=-1;
               newLowSwing=true;
               chainAdvance=true;
              }
           }
     }

   //================= HIGH PIVOT ====================================
   if(p>=0 && IsPivotHigh(high,p,g_depth,rates_total))
     {
      double pv = high[p];
      if(g_lastD==0)
        {
         g_lastP=pv; g_lastB=p; g_lastD=1;
         newHighSwing=true;
        }
      else
         if(g_lastD==1)
           {
            if(pv>g_lastP)
              {
               g_lastP=pv; g_lastB=p;
               newHighSwing=true;
              }
           }
         else
           {
            if(MathAbs(pv-g_lastP)>=SwingThreshold() && (p-g_lastB)>=g_backstep)
              {
               g_prevP=g_lastP; g_prevB=g_lastB; g_hasPrev=true;
               g_lastP=pv; g_lastB=p; g_lastD=1;
               newHighSwing=true;
               chainAdvance=true;
              }
           }
     }

   //================= ZIGZAG POLYLINE ===============================
   // Fires on EXTENSIONS (newLow/HighSwing) as well as flips, which is what
   // keeps the polyline continuous: the newest leg is re-pointed in place
   // rather than left behind at a superseded extreme.
   //
   // Ordering note: commit-then-update is safe because at most ONE
   // chainAdvance can occur per bar. On a bar that is both a pivot high and a
   // pivot low, the LOW block runs first and every path through it sets
   // g_lastB = p; the HIGH block's advance guard then tests
   // (p - g_lastB) >= g_backstep, i.e. 0 >= g_backstep, which is always false
   // because OnInit clamps g_backstep = MathMax(1,InpBackstep). If that clamp
   // ever allowed 0, a second advance could fire here and one leg would go
   // uncommitted.
   if(InpShowZZ && g_hasPrev && (chainAdvance || newLowSwing || newHighSwing))
     {
      if(chainAdvance)
         ZZCommitProvisional(time,rates_total);   // the leg just finalised
      ZZUpdateProvisional(time,rates_total);      // re-point the newest leg
     }

   //================= BOS DETECTION =================================
   if(newLowSwing)
      g_bullUsed=false;
   if(newHighSwing)
      g_bearUsed=false;

   // First qualifying close for this confirmed swing. May recognise a break
   // after the initial crossing if the pivot became known later.
   double bosBuffer=ATRReady()?InpBOSBufferATR*g_atr:0.0;
   bool bullBOS = (ATRReady() && g_lastD==-1 && g_hasPrev && !g_bullUsed &&
                   b>g_lastB && close[b]>g_prevP+bosBuffer);
   bool bearBOS = (ATRReady() && g_lastD== 1 && g_hasPrev && !g_bearUsed &&
                   b>g_lastB && close[b]<g_prevP-bosBuffer);

   //================= SETUP CONSTRUCTION ============================
   if(bullBOS || bearBOS)
     {
      // ---- ADDED: trial gate ---------------------------------------
      // If the trial has expired, the break-of-structure is still
      // detected (so the ZigZag/BOS state machine keeps behaving
      // exactly as before), but no NEW setup / entry zone / TP / SL is
      // built and no alert is fired. Consume the used-flag exactly as
      // the un-gated branch below would, so the state machine can't get
      // stuck re-evaluating the same BOS every bar.
      if(IsExpired())
        {
         if(bullBOS) g_bullUsed=true;
         else        g_bearUsed=true;
        }
      else
        {
      int span = (int)MathMin(MathMax(b-g_lastB+1,1),5000);
      double a0=0.0, a1=0.0;
      int    extB=b;

      if(bullBOS)
        {
         double hv=0.0; int hb=b;
         HighestHigh(high,b,span,hv,hb);
         a0   = hv;        // level 0.0 = breakout Swing High
         a1   = g_lastP;   // level 1.0 = confirmed Swing Low
         extB = hb;
         g_bullUsed=true;
        }
      else
        {
         double lv=0.0; int lb=b;
         LowestLow(low,b,span,lv,lb);
         a0   = lv;        // level 0.0 = breakout Swing Low
         a1   = g_lastP;   // level 1.0 = confirmed Swing High
         extB = lb;
         g_bearUsed=true;
        }

      if(a0!=a1)
        {
         CSetup *s = new CSetup();
         s.id        = ++g_setupId;
         s.dir       = bullBOS ? 1 : -1;
         s.a0        = a0;
         s.a1        = a1;
         s.extBar    = extB;
         s.createBar = b;
         s.leftBar   = (int)MathMin(g_lastB,extB);
         s.eligibleTime=BarTime(time,rates_total,b+1);
         if(!ConfigureLevels(s))
           {
            g_filterNote="BOS rejected: range / R:R / tick grid";
            delete s;
            return;
           }
         g_filterNote="BOS accepted (closed bar)";
         if(g_rebuilding) FinishSetup(s,SETUP_HISTORY);

         // freeze / retire the previous setup
         int n=ArraySize(g_setups);
         if(n>0 && CheckPointer(g_setups[n-1])!=POINTER_INVALID)
           {
            if(g_setups[n-1].active)
               FinishSetup(g_setups[n-1],SETUP_SUPERSEDED);
           }

         if(!InpShowHistory)
            ClearAllSetups();
         else
            while(ArraySize(g_setups)>=g_maxHist)
               RemoveSetupAt(0);

         BuildSetup(s,time,rates_total);
         PushSetup(s);
         NotifySetup(s);
        }
        } // end IsExpired() else branch
     }

   // No OHLC-based trade outcomes. Signal did not exist before this close.
   // Live monitoring starts from the next available Bid/Ask observation.
  }

//+------------------------------------------------------------------+
//| =============== BAR-CLOSE COUNTDOWN (ADDED) =================== |
//| How long the forming candle still has to run.  Display only -    |
//| no signal, alert or ZigZag logic reads any of this.              |
//+------------------------------------------------------------------+

// Seconds until the current bar closes, -1 if it cannot be worked out.
// TimeTradeServer() runs off the local clock, so the countdown keeps moving
// through a dead session or a weekend; TimeCurrent() only moves on ticks.
int BarSecondsLeft(void)
  {
   int      per = PeriodSeconds(PERIOD_CURRENT);
   datetime t0  = iTime(_Symbol,PERIOD_CURRENT,0);
   if(per<=0 || t0==0)
      return(-1);

   datetime now = TimeTradeServer();
   if(now==0) now = TimeCurrent();
   if(now==0) return(-1);

   long left = (long)t0 + (long)per - (long)now;
   if(left<0)          left = 0;
   if(left>(long)per)  left = per;
   return((int)left);
  }

string CdClock(const int s)
  {
   if(s<0)
      return("--:--");
   int h = s/3600, m = (s%3600)/60, sec = s%60;
   if(h>0)
      return(StringFormat("%d:%02d:%02d",h,m,sec));
   return(StringFormat("%02d:%02d",m,sec));
  }

//+------------------------------------------------------------------+
//| =============== INFORMATION PANEL (ADDED) ====================== |
//+------------------------------------------------------------------+
#define PNL_PFX      (g_prefix+"PNL_")
#define PNL_MAXROWS  40
#define PNL_LINEH    15
#define PNL_PADTOP   22   // room for the title row
#define PNL_PADBOT   8

int ENUM_CORNER_OF(void)
  {
   switch(InpPanelPos)
     {
      case PC_TOPRIGHT: return (int)CORNER_RIGHT_UPPER;
      case PC_BOTLEFT:  return (int)CORNER_LEFT_LOWER;
      case PC_BOTRIGHT: return (int)CORNER_RIGHT_LOWER;
      default:          return (int)CORNER_LEFT_UPPER;
     }
  }

bool PanelIsTop(void)   { return (InpPanelPos==PC_TOPLEFT || InpPanelPos==PC_TOPRIGHT); }

void PnlLabel(const string nm,const ENUM_OBJECT otype)
  {
   if(ObjectFind(0,nm)>=0)
      return;
   ObjectCreate(0,nm,otype,0,0,0);
   ObjectSetInteger(0,nm,OBJPROP_CORNER,ENUM_CORNER_OF());
   ObjectSetInteger(0,nm,OBJPROP_BACK,false);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,nm,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,nm,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,nm,OBJPROP_ZORDER,1000);
  }

// Create every panel object ONCE. Text/position/visibility are updated
// in-place afterwards (see UpdatePanel) - nothing is recreated per tick.
void CreatePanel(void)
  {
   if(!InpShowPanel)
      return;

   PnlLabel(PNL_PFX+"bg",OBJ_RECTANGLE_LABEL);
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_BGCOLOR,Blend(InpPanelBg,InpPanelTransp));
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_COLOR,InpPanelBorder);
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_WIDTH,1);

   PnlLabel(PNL_PFX+"title",OBJ_LABEL);
   ObjectSetString (0,PNL_PFX+"title",OBJPROP_FONT,"Arial Bold");
   ObjectSetInteger(0,PNL_PFX+"title",OBJPROP_FONTSIZE,10);
   ObjectSetString (0,PNL_PFX+"title",OBJPROP_TEXT,"FIB BOS FAST v2 | VISUAL ONLY");
   ObjectSetInteger(0,PNL_PFX+"title",OBJPROP_COLOR,InpPanelTitleC);

   for(int i=0; i<PNL_MAXROWS; i++)
     {
      string nm = PNL_PFX+"row"+IntegerToString(i);
      PnlLabel(nm,OBJ_LABEL);
      ObjectSetString (0,nm,OBJPROP_FONT,"Arial");
      ObjectSetInteger(0,nm,OBJPROP_FONTSIZE,8);
      ObjectSetString (0,nm,OBJPROP_TEXT,"");
     }

   // Prominent full-width banner shown only while the trial is expired.
   PnlLabel(PNL_PFX+"banner",OBJ_LABEL);
   ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_CORNER,(long)CORNER_LEFT_UPPER);
   ObjectSetString (0,PNL_PFX+"banner",OBJPROP_FONT,"Arial Bold");
   ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_FONTSIZE,14);
   ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_ANCHOR,ANCHOR_CENTER);
   ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_COLOR,InpPanelExpC);
   ObjectSetString (0,PNL_PFX+"banner",OBJPROP_TEXT,"");
  }

// Adds one row to the local buffers used by UpdatePanel().
void PnlAddRow(string &txt[],color &col[],int &n,const string t,const color c)
  {
   if(n>=PNL_MAXROWS)
      return;
   txt[n]=t;
   col[n]=c;
   n++;
  }

void UpdatePanel(void)
  {
   if(!InpShowPanel)
     {
      // panel toggled off - make sure any previously drawn panel is hidden
      if(ObjectFind(0,PNL_PFX+"bg")>=0)
         ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_TIMEFRAMES,OBJ_NO_PERIODS);
      return;
     }
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_TIMEFRAMES,OBJ_ALL_PERIODS);

   bool expired = IsExpired();
   bool warn    = IsInWarningWindow();

   //--- build the row text/colour lists ------------------------------
   string txt[]; color col[];
   ArrayResize(txt,PNL_MAXROWS);
   ArrayResize(col,PNL_MAXROWS);
   int n=0;

   if(InpPnlSymbol || InpPnlTF || InpPnlCountdown)
     {
      PnlAddRow(txt,col,n,"MARKET",InpPanelHeadC);
      if(InpPnlSymbol) PnlAddRow(txt,col,n,"Symbol   "+_Symbol,InpPanelTxtC);
      if(InpPnlTF)      PnlAddRow(txt,col,n,"TF       "+TfString(),InpPanelTxtC);
      if(InpPnlCountdown)
        {
         int cdLeft = BarSecondsLeft();
         PnlAddRow(txt,col,n,"Close in "+CdClock(cdLeft),
                   (cdLeft>=0 && cdLeft<=InpPnlCdWarnSecs) ? InpPanelWarnC : InpPanelTxtC);
        }
     }
   if(InpPnlPrice || InpPnlSpread)
     {
      double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      long   spr = SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
      if(InpPnlPrice)  PnlAddRow(txt,col,n,"Price    "+FmtPx(bid),InpPanelTxtC);
      if(InpPnlSpread) PnlAddRow(txt,col,n,"Spread   "+IntegerToString((int)spr)+" pts",InpPanelTxtC);
     }
   if(InpPnlZZ)
     {
      PnlAddRow(txt,col,n,"ZIGZAG",InpPanelHeadC);
      PnlAddRow(txt,col,n,"Depth    "+IntegerToString(g_depth),InpPanelTxtC);
      PnlAddRow(txt,col,n,"Deviation "+IntegerToString(g_deviation),InpPanelTxtC);
      PnlAddRow(txt,col,n,"Backstep "+IntegerToString(g_backstep),InpPanelTxtC);
     }

   if(InpPnlStruct || InpPnlBOS || InpPnlEntry || InpPnlTP || InpPnlSL)
     {
      PnlAddRow(txt,col,n,"SIGNAL",InpPanelHeadC);

      int cnt=ArraySize(g_setups);
      CSetup *s = (cnt>0) ? g_setups[cnt-1] : NULL;
      bool have = (s!=NULL && CheckPointer(s)!=POINTER_INVALID);

      if(InpPnlStruct)
        {
         string stxt = have ? (s.dir==1 ? "BULLISH" : "BEARISH") : "-";
         color  scol = have ? (s.dir==1 ? InpPanelBullC : InpPanelBearC) : InpPanelDimC;
         PnlAddRow(txt,col,n,"Setup    "+stxt,scol);
        }
      if(InpPnlBOS)
        {
         PnlAddRow(txt,col,n,"State    "+SetupStateText(s),have?InpPanelTxtC:InpPanelDimC);
         PnlAddRow(txt,col,n,"ATR      "+(ATRReady()?FmtPx(g_atr):"warming up"),InpPanelDimC);
         PnlAddRow(txt,col,n,"TP2 R/R  "+(have?DoubleToString(s.rr2,2)+" gross (worst edge)":"-"),InpPanelDimC);
         PnlAddRow(txt,col,n,g_filterNote,InpPanelDimC);
        }
      if(InpPnlEntry)
         PnlAddRow(txt,col,n,"Entry    "+(have?(FmtPx(s.boxBot)+" - "+FmtPx(s.boxTop)):"-"),have?InpPanelTxtC:InpPanelDimC);
      if(InpPnlTP)
        {
         PnlAddRow(txt,col,n,"TP1      "+(have?FmtPx(s.tp1):"-"),have?InpPanelTxtC:InpPanelDimC);
         PnlAddRow(txt,col,n,"TP2      "+(have?FmtPx(s.tp2):"-"),have?InpPanelTxtC:InpPanelDimC);
         PnlAddRow(txt,col,n,"TP3      "+(have?FmtPx(s.tp3):"-"),have?InpPanelTxtC:InpPanelDimC);
        }
      if(InpPnlSL)
         PnlAddRow(txt,col,n,"SL       "+(have?FmtPx(s.sl):"-"),have?InpPanelTxtC:InpPanelDimC);
     }

   if(InpPnlAlerts)
     {
      bool anyAlerts = (InpAlertBullSetup||InpAlertBearSetup||InpAlertBullZone||InpAlertBearZone||
                         InpAlertTP1||InpAlertTP2||InpAlertTP3||InpAlertSL);
      PnlAddRow(txt,col,n,"Alerts   "+(expired?"OFF (expired)":(anyAlerts?"ON":"OFF")),
                expired?InpPanelExpC:InpPanelTxtC);
     }

   if(InpPnlStatus || InpPnlExpiry)
     {
      PnlAddRow(txt,col,n,"LICENSE",InpPanelHeadC);
      if(InpPnlStatus)
        {
         string stat = !InpEnableExpiry ? "ACTIVE" : (expired ? "TRIAL EXPIRED" : (warn ? "TRIAL" : "TRIAL"));
         color  scol = !InpEnableExpiry ? InpPanelBullC : (expired ? InpPanelExpC : (warn ? InpPanelWarnC : InpPanelTxtC));
         PnlAddRow(txt,col,n,"Status   "+stat,scol);
        }
      if(InpPnlExpiry && InpEnableExpiry)
        {
         if(expired)
            PnlAddRow(txt,col,n,"Expired  "+ExpiryDateString(),InpPanelExpC);
         else
            if(warn)
               PnlAddRow(txt,col,n,"Expires in "+IntegerToString(DaysToExpiry())+" day(s)",InpPanelWarnC);
            else
               PnlAddRow(txt,col,n,"Expires  "+ExpiryDateString(),InpPanelTxtC);
        }
     }

   //--- geometry -------------------------------------------------------
   int   W = InpPanelWidth;
   int   H = (InpPanelHeight>0) ? InpPanelHeight : (PNL_PADTOP + n*PNL_LINEH + PNL_PADBOT);
   bool  top = PanelIsTop();

   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_XDISTANCE,InpPanelX);
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_YDISTANCE,InpPanelY);
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_XSIZE,W);
   ObjectSetInteger(0,PNL_PFX+"bg",OBJPROP_YSIZE,H);

   ObjectSetInteger(0,PNL_PFX+"title",OBJPROP_XDISTANCE,InpPanelX+8);
   ObjectSetInteger(0,PNL_PFX+"title",OBJPROP_YDISTANCE, top ? InpPanelY+6 : InpPanelY+H-PNL_LINEH-4);
   ObjectSetInteger(0,PNL_PFX+"title",OBJPROP_TIMEFRAMES,OBJ_ALL_PERIODS);

   for(int i=0; i<PNL_MAXROWS; i++)
     {
      string nm = PNL_PFX+"row"+IntegerToString(i);
      if(i<n)
        {
         int y = top ? (InpPanelY + PNL_PADTOP + i*PNL_LINEH)
                     : (InpPanelY + H - PNL_PADTOP - (i+1)*PNL_LINEH + 4);
         ObjectSetInteger(0,nm,OBJPROP_XDISTANCE,InpPanelX+8);
         ObjectSetInteger(0,nm,OBJPROP_YDISTANCE,y);
         ObjectSetString (0,nm,OBJPROP_TEXT,txt[i]);
         ObjectSetInteger(0,nm,OBJPROP_COLOR,col[i]);
         ObjectSetInteger(0,nm,OBJPROP_TIMEFRAMES,OBJ_ALL_PERIODS);
        }
      else
        {
         ObjectSetString(0,nm,OBJPROP_TEXT,"");
         ObjectSetInteger(0,nm,OBJPROP_TIMEFRAMES,OBJ_NO_PERIODS);
        }
     }

   //--- expired banner ---------------------------------------------
   if(InpEnableExpiry && expired)
     {
      long chartW = ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
      ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_XDISTANCE,(int)(chartW/2));
      ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_YDISTANCE,30);
      ObjectSetString (0,PNL_PFX+"banner",OBJPROP_TEXT,"!!! TRIAL EXPIRED !!!");
      ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_TIMEFRAMES,OBJ_ALL_PERIODS);
     }
   else
     {
      ObjectSetString(0,PNL_PFX+"banner",OBJPROP_TEXT,"");
      ObjectSetInteger(0,PNL_PFX+"banner",OBJPROP_TIMEFRAMES,OBJ_NO_PERIODS);
     }
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
bool ValidInputs(void)
  {
   if(InpDepth<1 || InpDepth>1000 || InpBackstep<1 || InpBackstep>1000 ||
      InpDeviation<0 || InpZZSegments<1 || InpZZSegments>1000 ||
      InpATRPeriod<2 || InpATRPeriod>1000 || InpSLPoints<=0 || InpSetupMaxBars<1 ||
      InpPricePrec<-1 || InpPricePrec>8) return false;
   if(!MathIsValidNumber(InpMinSwingATR) || !MathIsValidNumber(InpBOSBufferATR) ||
      !MathIsValidNumber(InpMinImpulseATR) || !MathIsValidNumber(InpSLBufferATR) ||
      !MathIsValidNumber(InpMinRR2) || !MathIsValidNumber(InpMaxSpreadATR) ||
      !MathIsValidNumber(InpPtCustom) || InpPtCustom<=0.0 ||
      InpMinSwingATR<0.0 || InpBOSBufferATR<0.0 || InpMinImpulseATR<0.0 ||
      InpSLBufferATR<0.0 || InpMinRR2<0.0 || InpMaxSpreadATR<0.0) return false;
   if(!MathIsValidNumber(InpEnHi) || !MathIsValidNumber(InpEnMid) || !MathIsValidNumber(InpEnLo) ||
      !MathIsValidNumber(InpTP1) || !MathIsValidNumber(InpTP2) || !MathIsValidNumber(InpTP3) ||
      !MathIsValidNumber(InpZ1Hi) || !MathIsValidNumber(InpZ1Mid) || !MathIsValidNumber(InpZ1Lo)) return false;
   return (InpEnHi<1.0 && InpEnHi>InpEnMid && InpEnMid>InpEnLo && InpEnLo>0.0 &&
           InpTP1<InpEnLo && InpTP1>=0.0 && InpTP2<InpTP1 && InpTP3<InpTP2 &&
           InpZ1Lo>1.0 && InpZ1Lo<InpZ1Mid && InpZ1Mid<InpZ1Hi);
  }

int IndicatorInit(void)
  {
   g_prefix="FBS2_"+IntegerToString(ChartID())+"_"+IntegerToString((long)GetMicrosecondCount())+"_";
   if(!ValidInputs())
     {
      Print("[FBS v2] Invalid settings: check Fibonacci ordering, positive distances and ranges.");
      return INIT_PARAMETERS_INCORRECT;
     }
   IndicatorSetString(INDICATOR_SHORTNAME,"523 - MDC | Fibonacci BOS Fast v2 (visual)");

   g_depth     = (int)MathMax(1,InpDepth);
   g_deviation = (int)MathMax(0,InpDeviation);
   g_backstep  = (int)MathMax(1,InpBackstep);
   g_maxHist   = (int)MathMax(1,MathMin(20,InpMaxHistory));
   g_prec      = (InpPricePrec<0 ? _Digits : InpPricePrec);
   g_rightExt  = (int)MathMax(0,MathMin(200,InpRightExt));

   g_tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(g_tickSize<=0.0) g_tickSize=_Point;
   if(g_tickSize<=0.0) return INIT_FAILED;
   if(InpPtMode==PT_CUSTOM)
      g_point = MathMax(0.00001,InpPtCustom);
   else
     {
      g_point = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      if(g_point<=0.0)
         g_point = _Point;
      if(g_point<=0.0)
         g_point = 0.01;
     }

   ArrayResize(g_setups,0);
   ArrayResize(g_zzNames,0);
   g_warnAlerted = false;
   ResetAll();               // also creates the panel objects
   UpdatePanel();

   //--- the panel otherwise only refreshes on ticks, and the countdown has to
   //--- keep moving in a quiet session or at the weekend
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void IndicatorDeinit(const int reason)
  {
   EventKillTimer();
   ClearAllSetups();
   ClearZigZag();
   if(StringLen(g_prefix)>0) ObjectsDeleteAll(0,PFX); // only this instance
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| OnTimer - once a second, refresh the panel only.  UpdatePanel()  |
//| just rewrites the text of labels that already exist, so this is  |
//| cheap and touches no ZigZag, setup or alert logic.               |
//+------------------------------------------------------------------+
void IndicatorTimer(void)
  {
   UpdatePanel();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| OnCalculate                                                      |
//+------------------------------------------------------------------+
int IndicatorCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   ArraySetAsSeries(time,false);
   ArraySetAsSeries(open,false);
   ArraySetAsSeries(high,false);
   ArraySetAsSeries(low,false);
   ArraySetAsSeries(close,false);

   int minBars = 2*g_depth + 2;
   if(rates_total < minBars)
      return(0);

   // Rebuild on changed/shifted history. Never infer historical fills.
   int lastClosed=rates_total-2;
   bool reset=(prev_calculated==0 || prev_calculated>rates_total ||
               (g_firstBarTime!=0 && g_firstBarTime!=time[0]));
   if(!reset && g_processed>0 &&
      (g_processed-1>lastClosed || time[g_processed-1]!=g_lastClosedTime)) reset=true;
   if(reset) ResetAll();
   g_firstBarTime=time[0];

   // If complete bars were missed, existing quote chronology is unresolved.
   if(!reset && lastClosed-g_processed>0 && ArraySize(g_setups)>0)
     {
      CSetup *old=g_setups[ArraySize(g_setups)-1];
      if(CheckPointer(old)!=POINTER_INVALID && old.active) FinishSetup(old,SETUP_UNKNOWN);
     }

   for(int b=g_processed; b<=lastClosed; b++)
     {
      g_rebuilding=(reset || b<lastClosed);
      g_alertsOn=!g_rebuilding;
      ProcessBar(b,rates_total,time,high,low,close);
     }
   g_processed=lastClosed+1;
   g_lastClosedTime=time[lastClosed];
   g_rebuilding=false;
   g_alertsOn=true;

   // Real-time monitor sees ONLY the current quote, never the bar's old high/low.
   int cur=rates_total-1;
   TrackLive(cur);
   ExtendActive(time,rates_total);
   ZZUpdateLiveLeg(time,rates_total,high,low);

   //--- trial / panel bookkeeping (ADDED) -----------------------------
   CheckExpiryWarningAlert();
   UpdatePanel();

   ChartRedraw();
   return(rates_total);
  }
//+------------------------------------------------------------------+
// TEST HARNESS: these wrappers replace only notification side effects.
int check_count=0,fail_count=0,zone_count=0,level_count=0;
void NotifyZone(CSetup *s) { zone_count++; Print("CHECK_EVENT ZONE ",s.observedEntry); }
void NotifyLevel(const string tag,const double price,const bool enabled)
  { if(enabled) {level_count++;Print("CHECK_EVENT ",tag," ",price);} }
void Check(const bool ok,const string label)
  { check_count++; if(!ok)fail_count++; Print(ok?"PASS ":"FAIL ",label); }
bool Near(const double a,const double b) {return MathAbs(a-b)<0.000001;}
CSetup *Fixture(const int d=1)
  {
   CSetup *s=new CSetup();
   s.dir=d;s.a0=(d==1?4140:4100);s.a1=(d==1?4100:4140);
   s.createBar=0;s.eligibleTime=D'2026.01.01';
   g_atr=10;g_atrCount=14;
   ConfigureLevels(s);return s;
  }
int OnInit()
  {
   if(!MQLInfoInteger(MQL_TESTER))
     { Print("TESTER ONLY: refused to run on an account chart.");return INIT_FAILED; }
   if(IndicatorInit()!=INIT_SUCCEEDED)return INIT_FAILED;
   g_alertsOn=true;g_rebuilding=false;
   datetime tm=D'2026.01.01 01:00';
   CSetup *s=Fixture();
   Check(Near(s.boxBot,4108.56)&&Near(s.boxTop,4115.28),"bullish tick-rounded Fibonacci zone");
   Check(Near(s.tp1,4124.72)&&Near(s.tp2,4140)&&Near(s.tp3,4150.88),"ordered target prices");
   Check(Near(s.sl,4098),"outward structural stop");
   TrackQuote(s,0,tm,4114,4114.2);
   Check(!s.touched,"no touch in BOS candle");
   TrackQuote(s,1,D'2025.12.31',4114,4114.2);
   Check(!s.touched,"no quote before signal eligibility");
   TrackQuote(s,1,tm,4141,4141.2);
   Check(!s.t1&&!s.t2&&!s.t3&&level_count==0,"no target before entry");
   TrackQuote(s,1,tm,4114.8,4115.5);
   Check(!s.touched,"buy entry requires Ask in zone");
   TrackQuote(s,1,tm,4114,4114.2);
   Check(s.touched&&Near(s.observedEntry,4114.2)&&zone_count==1,"buy quote touch and single notification");
   Check(!s.t1&&level_count==0,"no target on entry observation");
   TrackQuote(s,1,tm,4125,4125.2);
   Check(s.t1&&!s.t2&&!s.t3&&level_count==1,"TP1 observed after entry");
   TrackQuote(s,1,tm,4097,4097.2);
   Check(s.slHit&&s.state==SETUP_STOPPED&&!s.active,"terminal stop state");
   int count=level_count;TrackQuote(s,1,tm,4160,4160.2);
   Check(level_count==count&&!s.t2&&!s.t3,"no targets after stop");delete s;
   s=Fixture();TrackQuote(s,1,tm,4097,4097.2);
   Check(s.state==SETUP_INVALIDATED&&!s.touched&&!s.slHit,"pre-entry invalidation is not a loss");delete s;
   s=Fixture();TrackQuote(s,13,tm,4114,4114.2);
   Check(s.state==SETUP_EXPIRED&&!s.touched,"expiry at first quote of thirteenth eligible bar");delete s;
   s=Fixture();TrackQuote(s,1,tm,4113,4115);
   Check(s.spreadBlocked&&!s.touched,"wide spread blocks entry");delete s;
   s=Fixture();TrackQuote(s,1,tm,4120,4120.2);TrackQuote(s,1,tm,4105,4105.2);
   Check(!s.touched,"gap over zone is not an assumed fill");delete s;
   s=Fixture();FinishSetup(s,SETUP_HISTORY);TrackQuote(s,1,tm,4114,4114.2);
   Check(!s.touched&&s.state==SETUP_HISTORY,"historical setup cannot reactivate");delete s;
   s=Fixture(-1);
   Check(Near(s.boxBot,4124.72)&&Near(s.boxTop,4131.44)&&Near(s.sl,4142),"bearish levels and stop symmetry");
   TrackQuote(s,1,tm,4126,4126.2);
   Check(s.touched&&Near(s.observedEntry,4126),"sell entry uses Bid");
   TrackQuote(s,1,tm,4099.9,4100.1);
   Check(s.t1&&!s.t2,"sell TP2 waits for Ask");
   TrackQuote(s,1,tm,4099.8,4100);
   Check(s.t2&&!s.t3,"sell TP2 at executable Ask");
   TrackQuote(s,1,tm,4088.8,4089);
   Check(s.t3&&!s.active&&s.state==SETUP_COMPLETE,"terminal TP3 state");
   count=level_count;TrackQuote(s,1,tm,4143,4143.2);
   Check(level_count==count&&!s.slHit,"no stop after terminal completion");delete s;
   Print("NATIVE_CHECK_RESULT checks=",check_count," failures=",fail_count);
   return INIT_SUCCEEDED;
  }
void OnTick() { ExpertRemove(); }
void OnDeinit(const int reason) { IndicatorDeinit(reason); }
