//+------------------------------------------------------------------+
//|                                              TrendGrid_EA.mq5    |
//|        Trend-following grid (pyramid) EA.                        |
//|        - Detects trend by EMA fast/slow cross on signal TF.      |
//|        - Opens position in trend direction.                      |
//|        - Pyramids: adds lots when price moves WITH the trend.    |
//|        - On trend flip: closes everything, opens opposite trade. |
//+------------------------------------------------------------------+
#property copyright   "Tembo Algotrading"
#property version     "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>

enum ENUM_TREND
  {
   TREND_NONE = 0,
   TREND_UP   = 1,
   TREND_DOWN = -1
  };

// --- Trend detection ---
input ENUM_TIMEFRAMES InpSignalTF      = PERIOD_M30;   // Signal timeframe
input int             InpEmaFastPeriod = 21;           // Fast EMA period
input int             InpEmaSlowPeriod = 55;           // Slow EMA period
input bool            InpRequireSlope  = true;         // Also require slow EMA slope to confirm trend

// --- Grid (pyramiding) ---
input long            InpMagic         = 20260606;    // Magic number
input double          InpFirstLot      = 0.05;        // First entry lot
input double          InpAddLot        = 0.05;        // Each pyramid add lot (fixed)
input bool            InpUseAddMult    = false;       // If true, add = first * mult^level
input double          InpAddMult       = 0.8;         // Decreasing multiplier for adds (<=1 recommended)
input double          InpStepPips      = 20.0;        // Pyramid step (pips). Auto-scaled by digits.
input int             InpMaxLevels     = 5;           // Max positions per trend leg
input int             InpSlippagePts   = 20;          // Slippage (points)

// --- Exits & risk ---
input bool            InpCloseOnFlip   = true;        // Close basket when trend flips
input double          InpTpPips        = 0;           // Optional TP in pips from avg price (0 = off)
input double          InpSlPips        = 0;           // Optional SL in pips from worst price (0 = off)
input double          InpTrailStartPips= 30.0;        // Start trailing after this profit (pips, 0=off)
input double          InpTrailStepPips = 15.0;        // Trail by this many pips
input double          InpBasketSlPct   = 5.0;         // Hard basket SL as % of equity (0 = off)
input bool            InpFlipOnceFlat  = true;        // After flip, only re-enter once flat
input int             InpCooldownSec   = 5;           // Cooldown between pyramid adds (sec)

CTrade        Trade;
CPositionInfo Pos;
CSymbolInfo   Sym;

int       g_hEmaFast    = INVALID_HANDLE;
int       g_hEmaSlow    = INVALID_HANDLE;
double    g_pipSize     = 0.0;
ENUM_TREND g_lastTrend  = TREND_NONE;
datetime  g_lastBar     = 0;
datetime  g_lastAddTime = 0;
double    g_trailLevel  = 0.0;     // current trailing stop (price)
bool      g_trailArmed  = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!Sym.Name(_Symbol)) return INIT_FAILED;
   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints((ulong)InpSlippagePts);
   Trade.SetTypeFillingBySymbol(_Symbol);

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pipSize = ((digits == 3) || (digits == 5)) ? (10.0 * Sym.Point()) : Sym.Point();

   g_hEmaFast = iMA(_Symbol, InpSignalTF, InpEmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaSlow = iMA(_Symbol, InpSignalTF, InpEmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hEmaFast == INVALID_HANDLE || g_hEmaSlow == INVALID_HANDLE)
     {
      Print("EMA handles invalid");
      return INIT_FAILED;
     }

   g_lastTrend  = TREND_NONE;
   g_lastBar    = 0;
   g_trailArmed = false;
   g_trailLevel = 0.0;
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_hEmaFast != INVALID_HANDLE) IndicatorRelease(g_hEmaFast);
   if(g_hEmaSlow != INVALID_HANDLE) IndicatorRelease(g_hEmaSlow);
  }

//+------------------------------------------------------------------+
// Read finished-bar EMA values (shift=1) and the previous slow EMA (shift=2)
bool ReadTrend(ENUM_TREND &trend)
  {
   double fast[1], slow[2];
   if(CopyBuffer(g_hEmaFast, 0, 1, 1, fast) != 1) return false;
   if(CopyBuffer(g_hEmaSlow, 0, 1, 2, slow) != 2) return false;
   // slow[0] = bar 2, slow[1] = bar 1 in mql series order after CopyBuffer
   double slowNow  = slow[1];
   double slowPrev = slow[0];

   if(fast[0] > slowNow)
     {
      if(!InpRequireSlope || slowNow >= slowPrev) trend = TREND_UP;
      else                                        trend = TREND_NONE;
     }
   else if(fast[0] < slowNow)
     {
      if(!InpRequireSlope || slowNow <= slowPrev) trend = TREND_DOWN;
      else                                        trend = TREND_NONE;
     }
   else
      trend = TREND_NONE;
   return true;
  }

//+------------------------------------------------------------------+
void Scan(int &buyCnt, int &sellCnt,
          double &buyLots, double &sellLots,
          double &buyAvg,  double &sellAvg,
          double &buyHigh, double &buyLow,
          double &sellHigh, double &sellLow,
          double &floatingPL)
  {
   buyCnt=0; sellCnt=0;
   buyLots=0; sellLots=0;
   double buyNotional=0, sellNotional=0;
   buyHigh=0; buyLow=DBL_MAX;
   sellHigh=0; sellLow=DBL_MAX;
   floatingPL=0;

   for(int i = PositionsTotal()-1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      if(Pos.Magic()  != InpMagic) continue;

      double price = Pos.PriceOpen();
      double vol   = Pos.Volume();
      floatingPL  += Pos.Profit() + Pos.Swap() + Pos.Commission();

      if(Pos.PositionType() == POSITION_TYPE_BUY)
        {
         buyCnt++; buyLots += vol; buyNotional += vol * price;
         if(price > buyHigh) buyHigh = price;
         if(price < buyLow)  buyLow  = price;
        }
      else
        {
         sellCnt++; sellLots += vol; sellNotional += vol * price;
         if(price > sellHigh) sellHigh = price;
         if(price < sellLow)  sellLow  = price;
        }
     }
   if(buyLow  == DBL_MAX) buyLow  = 0;
   if(sellLow == DBL_MAX) sellLow = 0;
   buyAvg  = (buyLots  > 0) ? buyNotional  / buyLots  : 0;
   sellAvg = (sellLots > 0) ? sellNotional / sellLots : 0;
  }

//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double step = Sym.LotsStep();
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   if(lot < Sym.LotsMin()) lot = Sym.LotsMin();
   if(lot > Sym.LotsMax()) lot = Sym.LotsMax();
   return NormalizeDouble(lot, 2);
  }

double AddLotForLevel(int level)
  {
   if(level == 0) return NormalizeLot(InpFirstLot);
   if(InpUseAddMult)
      return NormalizeLot(InpFirstLot * MathPow(MathMax(0.1, InpAddMult), level));
   return NormalizeLot(InpAddLot);
  }

//+------------------------------------------------------------------+
void CloseAll()
  {
   for(int i = PositionsTotal()-1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      if(Pos.Magic()  != InpMagic) continue;
      Trade.PositionClose(Pos.Ticket(), (ulong)InpSlippagePts);
     }
   g_trailArmed = false;
   g_trailLevel = 0.0;
  }

//+------------------------------------------------------------------+
bool OpenMarket(ENUM_POSITION_TYPE dir, double lot)
  {
   Sym.RefreshRates();
   double price = (dir == POSITION_TYPE_BUY) ? Sym.Ask() : Sym.Bid();
   bool ok;
   if(dir == POSITION_TYPE_BUY)
      ok = Trade.Buy(lot, _Symbol, price, 0.0, 0.0, "TrendGrid");
   else
      ok = Trade.Sell(lot, _Symbol, price, 0.0, 0.0, "TrendGrid");
   if(!ok)
      PrintFormat("OrderSend failed: ret=%d %s",
                  Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
   return ok;
  }

//+------------------------------------------------------------------+
// Trailing in pips from best-favorable price seen on the basket.
// Stores g_trailLevel as a PRICE. If price crosses it back, close all.
void UpdateTrailingForLong(double avg, int cnt, double floatingPL)
  {
   if(InpTrailStartPips <= 0 || cnt == 0) return;
   double startProfit = InpTrailStartPips * g_pipSize;
   double curBid      = Sym.Bid();
   double profitInPriceUnits = curBid - avg;
   if(!g_trailArmed)
     {
      if(profitInPriceUnits >= startProfit)
        {
         g_trailArmed = true;
         g_trailLevel = curBid - InpTrailStepPips * g_pipSize;
        }
      return;
     }
   double newTrail = curBid - InpTrailStepPips * g_pipSize;
   if(newTrail > g_trailLevel) g_trailLevel = newTrail;
   if(curBid <= g_trailLevel)
     {
      PrintFormat("Trail hit (long): bid=%.5f trail=%.5f PL=%.2f", curBid, g_trailLevel, floatingPL);
      CloseAll();
     }
  }

void UpdateTrailingForShort(double avg, int cnt, double floatingPL)
  {
   if(InpTrailStartPips <= 0 || cnt == 0) return;
   double startProfit = InpTrailStartPips * g_pipSize;
   double curAsk      = Sym.Ask();
   double profitInPriceUnits = avg - curAsk;
   if(!g_trailArmed)
     {
      if(profitInPriceUnits >= startProfit)
        {
         g_trailArmed = true;
         g_trailLevel = curAsk + InpTrailStepPips * g_pipSize;
        }
      return;
     }
   double newTrail = curAsk + InpTrailStepPips * g_pipSize;
   if(newTrail < g_trailLevel) g_trailLevel = newTrail;
   if(curAsk >= g_trailLevel)
     {
      PrintFormat("Trail hit (short): ask=%.5f trail=%.5f PL=%.2f", curAsk, g_trailLevel, floatingPL);
      CloseAll();
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!Sym.RefreshRates()) return;

   // 1) Read current trend (only update on new finished bar of signal TF)
   datetime curBar = iTime(_Symbol, InpSignalTF, 0);
   bool newBar = (curBar != g_lastBar);
   if(newBar) g_lastBar = curBar;

   ENUM_TREND trend = g_lastTrend;
   if(newBar)
     {
      ENUM_TREND t;
      if(!ReadTrend(t)) return;
      trend = t;
     }

   // 2) Scan positions
   int    buyCnt=0, sellCnt=0;
   double buyLots=0, sellLots=0;
   double buyAvg=0, sellAvg=0;
   double buyHigh=0, buyLow=0, sellHigh=0, sellLow=0;
   double floating=0;
   Scan(buyCnt, sellCnt, buyLots, sellLots, buyAvg, sellAvg,
        buyHigh, buyLow, sellHigh, sellLow, floating);
   int    totalCnt = buyCnt + sellCnt;
   double curEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   // 3) Hard basket SL — always runs
   if(InpBasketSlPct > 0 && totalCnt > 0)
     {
      double slMoney = curEquity * InpBasketSlPct / 100.0;
      if(floating <= -slMoney)
        {
         PrintFormat("Basket SL hit: PL=%.2f limit=%.2f", floating, -slMoney);
         CloseAll();
         g_lastTrend = TREND_NONE;  // require new bar to re-enter
         return;
        }
     }

   // 4) Trailing stop on the active leg
   if(buyCnt > 0)  UpdateTrailingForLong (buyAvg,  buyCnt,  floating);
   if(sellCnt > 0) UpdateTrailingForShort(sellAvg, sellCnt, floating);

   // 5) Optional TP / SL in pips from avg/worst price
   if(InpTpPips > 0)
     {
      double tp = InpTpPips * g_pipSize;
      if(buyCnt > 0 && (Sym.Bid() - buyAvg) >= tp)
        {
         PrintFormat("Pip TP hit (long): bid=%.5f avg=%.5f", Sym.Bid(), buyAvg);
         CloseAll(); return;
        }
      if(sellCnt > 0 && (sellAvg - Sym.Ask()) >= tp)
        {
         PrintFormat("Pip TP hit (short): ask=%.5f avg=%.5f", Sym.Ask(), sellAvg);
         CloseAll(); return;
        }
     }
   if(InpSlPips > 0)
     {
      double sl = InpSlPips * g_pipSize;
      if(buyCnt > 0 && (buyLow > 0) && (buyLow - Sym.Bid()) >= sl)
        {
         PrintFormat("Pip SL hit (long): bid=%.5f worst=%.5f", Sym.Bid(), buyLow);
         CloseAll(); return;
        }
      if(sellCnt > 0 && (sellHigh > 0) && (Sym.Ask() - sellHigh) >= sl)
        {
         PrintFormat("Pip SL hit (short): ask=%.5f worst=%.5f", Sym.Ask(), sellHigh);
         CloseAll(); return;
        }
     }

   // 6) Trend flip handler
   if(InpCloseOnFlip && newBar && g_lastTrend != TREND_NONE && trend != TREND_NONE
      && trend != g_lastTrend)
     {
      PrintFormat("Trend flip: %d -> %d, closing basket", g_lastTrend, trend);
      CloseAll();
     }
   if(newBar) g_lastTrend = trend;

   // 7) Entry / pyramid
   if(trend == TREND_NONE) return;

   bool flatNow = (buyCnt == 0 && sellCnt == 0);
   ENUM_POSITION_TYPE dir = (trend == TREND_UP) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   // Avoid opposite leg when not flat (we always trade single direction at a time)
   if((dir == POSITION_TYPE_BUY  && sellCnt > 0) ||
      (dir == POSITION_TYPE_SELL && buyCnt  > 0))
     {
      if(InpFlipOnceFlat) return; // wait until current basket is closed
      CloseAll();                 // otherwise force flat then re-enter next tick
      return;
     }

   int    cnt   = (dir == POSITION_TYPE_BUY) ? buyCnt  : sellCnt;
   double best  = (dir == POSITION_TYPE_BUY) ? buyHigh : sellLow;

   if(cnt == 0)
     {
      if(OpenMarket(dir, AddLotForLevel(0)))
        {
         g_lastAddTime = TimeCurrent();
         g_trailArmed  = false;
         g_trailLevel  = 0.0;
        }
      return;
     }

   if(cnt >= InpMaxLevels) return;
   if((int)(TimeCurrent() - g_lastAddTime) < InpCooldownSec) return;

   double stepPrice = InpStepPips * g_pipSize;
   if(stepPrice <= 0) return;

   bool addNow = false;
   if(dir == POSITION_TYPE_BUY)
      addNow = (Sym.Ask() >= best + stepPrice); // price moved WITH trend by step
   else
      addNow = (Sym.Bid() <= best - stepPrice);

   if(addNow)
     {
      if(OpenMarket(dir, AddLotForLevel(cnt)))
         g_lastAddTime = TimeCurrent();
     }
  }
//+------------------------------------------------------------------+
