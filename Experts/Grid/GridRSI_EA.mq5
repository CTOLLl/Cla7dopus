//+------------------------------------------------------------------+
//|                                                  GridRSI_EA.mq5  |
//|                          Grid Expert Advisor with RSI filter and |
//|                          comprehensive risk management for MT5   |
//+------------------------------------------------------------------+
#property copyright   "Tembo Algotrading"
#property link        ""
#property version     "1.00"
#property description "Safe, scalable grid EA with RSI entry filter,"
#property description "ATR-adaptive step, basket TP, equity stop and"
#property description "hard risk limits. Trades a single symbol."
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>
#include <Trade/AccountInfo.mqh>

//---------------------------------- Inputs ----------------------------------
enum ENUM_DIR_MODE
  {
   DIR_BOTH = 0,   // Trade both directions
   DIR_LONG = 1,   // Long only
   DIR_SHORT= 2    // Short only
  };

enum ENUM_STEP_MODE
  {
   STEP_FIXED = 0, // Fixed step in points
   STEP_ATR   = 1  // ATR-based step
  };

// --- General ---
input group "=== General ==="
input long              InpMagic            = 20260525;     // Magic number
input string            InpComment          = "GridRSI";    // Order comment
input ENUM_DIR_MODE     InpDirectionMode    = DIR_BOTH;     // Direction mode

// --- Entry filter (RSI) ---
input group "=== RSI filter ==="
input ENUM_TIMEFRAMES   InpRsiTF            = PERIOD_M15;   // RSI timeframe
input int               InpRsiPeriod        = 14;           // RSI period
input double            InpRsiOversold      = 30.0;         // RSI oversold (buy)
input double            InpRsiOverbought    = 70.0;         // RSI overbought (sell)
input bool              InpUseRsiFilter     = true;         // Use RSI filter for first entry

// --- Grid ---
input group "=== Grid ==="
input ENUM_STEP_MODE    InpStepMode         = STEP_ATR;     // Step mode
input int               InpFixedStepPoints  = 250;          // Fixed step (points) if STEP_FIXED
input ENUM_TIMEFRAMES   InpAtrTF            = PERIOD_M15;   // ATR timeframe
input int               InpAtrPeriod        = 14;           // ATR period
input double            InpAtrStepMult      = 1.0;          // ATR step multiplier
input int               InpMaxGridLevels    = 8;            // Max grid levels per direction
input double            InpLotMultiplier    = 1.4;          // Lot martingale multiplier (>=1.0)
input double            InpFirstLot         = 0.01;         // First lot (if not auto-risk)
input bool              InpAutoLotByRisk    = true;         // Compute first lot from risk %
input double            InpRiskPerBasketPct = 1.5;          // Max % equity loss if basket goes the worst case

// --- Basket exits ---
input group "=== Basket exits ==="
input double            InpBasketTpMoney    = 0.0;          // Basket TP in account money (0 = use pct)
input double            InpBasketTpPct      = 0.6;          // Basket TP as % of equity (if money = 0)
input double            InpBasketSlPct      = 5.0;          // Basket SL as % of equity (hard stop)
input bool              InpUseTrailingBE    = true;         // Move basket SL to BE once TP/2 reached
input double            InpBreakevenPct     = 0.30;         // Lock-in profit % of equity at BE

// --- Risk & filters ---
input group "=== Risk & filters ==="
input double            InpMaxSpreadPoints  = 50;           // Max spread (points)
input double            InpMaxLotCap        = 5.0;          // Hard cap on a single order lot
input double            InpMaxTotalLots     = 50.0;         // Hard cap on aggregate open lots
input double            InpDailyDDLimitPct  = 4.0;          // Daily DD limit % (then halt)
input double            InpMaxEquityDDPct   = 20.0;         // Absolute equity DD % from peak (halt)
input bool              InpTradeFridayClose = false;        // Allow trading near Friday close
input int               InpStartHour        = 0;            // Trading start hour (server)
input int               InpEndHour          = 24;           // Trading end hour (server) [0..24]
input int               InpSlippagePoints   = 20;           // Allowed slippage (points)

//---------------------------------- Globals ----------------------------------
CTrade         Trade;
CPositionInfo  Pos;
CSymbolInfo    Sym;
CAccountInfo   Acc;

int            g_hRsi      = INVALID_HANDLE;
int            g_hAtr      = INVALID_HANDLE;

double         g_equityPeak       = 0.0;
double         g_dayStartEquity   = 0.0;
datetime       g_dayStartTime     = 0;
bool           g_haltedByRisk     = false;

// Per-direction state
struct GridState
  {
   double  lastEntryPrice;   // last filled price for this direction
   int     levels;           // number of opened levels in this direction
   double  basketStartEquity;// equity when basket opened (for BE logic)
   bool    beArmed;          // breakeven armed
  };
GridState g_long, g_short;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double step = Sym.LotsStep();
   double minLot = Sym.LotsMin();
   double maxLot = Sym.LotsMax();
   if(step <= 0.0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   if(InpMaxLotCap > 0 && lot > InpMaxLotCap) lot = InpMaxLotCap;
   return NormalizeDouble(lot, 2);
  }

double PointsToPrice(double points)
  {
   return points * Sym.Point();
  }

double SpreadPoints()
  {
   return (Sym.Ask() - Sym.Bid()) / Sym.Point();
  }

bool IsWithinTradingHours()
  {
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   if(t.hour < InpStartHour || t.hour >= InpEndHour) return false;
   if(!InpTradeFridayClose && t.day_of_week == 5 && t.hour >= 21) return false;
   return true;
  }

void ResetGridState(GridState &gs)
  {
   gs.lastEntryPrice    = 0.0;
   gs.levels            = 0;
   gs.basketStartEquity = 0.0;
   gs.beArmed           = false;
  }

//+------------------------------------------------------------------+
//| Aggregate open positions for this EA                             |
//+------------------------------------------------------------------+
void ScanPositions(int &longCnt, int &shortCnt,
                   double &longLots, double &shortLots,
                   double &longHighPrice, double &longLowPrice,
                   double &shortHighPrice, double &shortLowPrice,
                   double &floatingPL)
  {
   longCnt=0; shortCnt=0;
   longLots=0; shortLots=0;
   longHighPrice=0; longLowPrice=DBL_MAX;
   shortHighPrice=0; shortLowPrice=DBL_MAX;
   floatingPL=0;

   for(int i = PositionsTotal()-1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      if(Pos.Magic()  != InpMagic) continue;

      double price = Pos.PriceOpen();
      double vol   = Pos.Volume();
      double pl    = Pos.Profit() + Pos.Swap() + Pos.Commission();
      floatingPL += pl;

      if(Pos.PositionType() == POSITION_TYPE_BUY)
        {
         longCnt++; longLots += vol;
         if(price > longHighPrice) longHighPrice = price;
         if(price < longLowPrice)  longLowPrice  = price;
        }
      else
        {
         shortCnt++; shortLots += vol;
         if(price > shortHighPrice) shortHighPrice = price;
         if(price < shortLowPrice)  shortLowPrice  = price;
        }
     }
   if(longLowPrice  == DBL_MAX) longLowPrice  = 0;
   if(shortLowPrice == DBL_MAX) shortLowPrice = 0;
  }

//+------------------------------------------------------------------+
//| Compute current grid step in price units                         |
//+------------------------------------------------------------------+
double CurrentStepPrice()
  {
   if(InpStepMode == STEP_FIXED)
      return PointsToPrice(InpFixedStepPoints);

   double atr[1];
   if(CopyBuffer(g_hAtr, 0, 0, 1, atr) != 1)
      return PointsToPrice(InpFixedStepPoints);
   double step = atr[0] * InpAtrStepMult;
   double minStep = PointsToPrice(MathMax(10, Sym.StopsLevel() * 2));
   if(step < minStep) step = minStep;
   return step;
  }

//+------------------------------------------------------------------+
//| Compute first lot by risk: worst-case loss = riskPct of equity   |
//+------------------------------------------------------------------+
double ComputeFirstLot()
  {
   if(!InpAutoLotByRisk) return NormalizeLot(InpFirstLot);

   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxLossUSD = equity * InpRiskPerBasketPct / 100.0;
   double step       = CurrentStepPrice();
   if(step <= 0) return NormalizeLot(InpFirstLot);

   // Worst-case (price runs against full grid): summed loss for geometric lots
   // sum_{k=0..N-1} lot0 * m^k * (loss per unit price at level k)
   // Approximate per-level loss as step * tickValue / tickSize * (k+1) (distance from entry).
   double tickValue = Sym.TickValue();
   double tickSize  = Sym.TickSize();
   if(tickSize <= 0) return NormalizeLot(InpFirstLot);
   double lossPerLotPerStep = step / tickSize * tickValue;

   int    N = InpMaxGridLevels;
   double m = MathMax(1.0, InpLotMultiplier);

   double worst = 0.0;
   for(int k=0; k<N; ++k)
     {
      double lotK   = MathPow(m, k);              // relative to lot0
      double distSteps = (double)(N - k);         // remaining distance until last level
      worst += lotK * distSteps * lossPerLotPerStep;
     }
   if(worst <= 0) return NormalizeLot(InpFirstLot);

   double lot0 = maxLossUSD / worst;
   return NormalizeLot(MathMax(lot0, Sym.LotsMin()));
  }

//+------------------------------------------------------------------+
//| RSI / signal helpers                                             |
//+------------------------------------------------------------------+
bool RsiBuySignal()
  {
   if(!InpUseRsiFilter) return true;
   double v[1];
   if(CopyBuffer(g_hRsi, 0, 1, 1, v) != 1) return false;
   return v[0] <= InpRsiOversold;
  }

bool RsiSellSignal()
  {
   if(!InpUseRsiFilter) return true;
   double v[1];
   if(CopyBuffer(g_hRsi, 0, 1, 1, v) != 1) return false;
   return v[0] >= InpRsiOverbought;
  }

//+------------------------------------------------------------------+
//| Place a market order with proper checks                          |
//+------------------------------------------------------------------+
bool OpenMarket(ENUM_POSITION_TYPE dir, double lot)
  {
   Sym.RefreshRates();
   if(SpreadPoints() > InpMaxSpreadPoints)
     {
      PrintFormat("Skip open: spread %.1f > limit %.1f", SpreadPoints(), InpMaxSpreadPoints);
      return false;
     }

   double price = (dir == POSITION_TYPE_BUY) ? Sym.Ask() : Sym.Bid();
   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   Trade.SetTypeFillingBySymbol(_Symbol);

   bool ok;
   if(dir == POSITION_TYPE_BUY)
      ok = Trade.Buy(lot, _Symbol, price, 0.0, 0.0, InpComment);
   else
      ok = Trade.Sell(lot, _Symbol, price, 0.0, 0.0, InpComment);

   if(!ok)
      PrintFormat("OrderSend failed: ret=%d %s", Trade.ResultRetcode(), Trade.ResultRetcodeDescription());
   return ok;
  }

//+------------------------------------------------------------------+
//| Close all positions in a direction                               |
//+------------------------------------------------------------------+
void CloseDirection(ENUM_POSITION_TYPE dir)
  {
   for(int i = PositionsTotal()-1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      if(Pos.Magic()  != InpMagic) continue;
      if(Pos.PositionType() != dir) continue;
      Trade.PositionClose(Pos.Ticket(), (ulong)InpSlippagePoints);
     }
  }

void CloseAll()
  {
   CloseDirection(POSITION_TYPE_BUY);
   CloseDirection(POSITION_TYPE_SELL);
   ResetGridState(g_long);
   ResetGridState(g_short);
  }

//+------------------------------------------------------------------+
//| Risk gate: equity DD, daily DD, halt                             |
//+------------------------------------------------------------------+
void UpdateRiskMetrics()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_equityPeak) g_equityPeak = equity;

   // Daily snapshot
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   datetime day0 = StringToTime(StringFormat("%04d.%02d.%02d 00:00", t.year, t.mon, t.day));
   if(g_dayStartTime != day0)
     {
      g_dayStartTime   = day0;
      g_dayStartEquity = equity;
     }

   if(g_equityPeak > 0)
     {
      double ddPct = (g_equityPeak - equity) / g_equityPeak * 100.0;
      if(ddPct >= InpMaxEquityDDPct)
        {
         if(!g_haltedByRisk)
            PrintFormat("HALT: equity DD %.2f%% >= limit %.2f%%", ddPct, InpMaxEquityDDPct);
         g_haltedByRisk = true;
        }
     }

   if(g_dayStartEquity > 0)
     {
      double ddDay = (g_dayStartEquity - equity) / g_dayStartEquity * 100.0;
      if(ddDay >= InpDailyDDLimitPct)
        {
         if(!g_haltedByRisk)
            PrintFormat("HALT: daily DD %.2f%% >= limit %.2f%%", ddDay, InpDailyDDLimitPct);
         g_haltedByRisk = true;
        }
     }
  }

//+------------------------------------------------------------------+
//| Direction management: open first entry / add grid level          |
//+------------------------------------------------------------------+
void ManageDirection(ENUM_POSITION_TYPE dir,
                     int cnt, double lots,
                     double highPrice, double lowPrice,
                     GridState &gs)
  {
   if(g_haltedByRisk) return;

   // Aggregate lot cap
   double totalLotsHard = lots; // existing per-side
   if(totalLotsHard >= InpMaxTotalLots) return;

   if(cnt == 0)
     {
      // First entry — needs RSI signal & direction permission
      if(dir == POSITION_TYPE_BUY)
        {
         if(InpDirectionMode == DIR_SHORT) return;
         if(!RsiBuySignal()) return;
        }
      else
        {
         if(InpDirectionMode == DIR_LONG) return;
         if(!RsiSellSignal()) return;
        }

      double lot = ComputeFirstLot();
      if(OpenMarket(dir, lot))
        {
         Sym.RefreshRates();
         gs.lastEntryPrice    = (dir == POSITION_TYPE_BUY) ? Sym.Ask() : Sym.Bid();
         gs.levels            = 1;
         gs.basketStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         gs.beArmed           = false;
        }
      return;
     }

   // Already in a basket — check whether to add a grid level
   if(cnt >= InpMaxGridLevels) return;

   double step = CurrentStepPrice();
   if(step <= 0) return;

   Sym.RefreshRates();
   double refPrice;
   bool   triggers;
   if(dir == POSITION_TYPE_BUY)
     {
      // Add when price moves DOWN by step from the worst (lowest) entry
      refPrice = (lowPrice > 0 ? lowPrice : gs.lastEntryPrice);
      triggers = (Sym.Ask() <= refPrice - step);
     }
   else
     {
      // Add when price moves UP by step from the worst (highest) entry
      refPrice = (highPrice > 0 ? highPrice : gs.lastEntryPrice);
      triggers = (Sym.Bid() >= refPrice + step);
     }
   if(!triggers) return;

   double nextLot = ComputeFirstLot() * MathPow(MathMax(1.0, InpLotMultiplier), cnt);
   nextLot = NormalizeLot(nextLot);

   if(lots + nextLot > InpMaxTotalLots) return;

   if(OpenMarket(dir, nextLot))
     {
      Sym.RefreshRates();
      gs.lastEntryPrice = (dir == POSITION_TYPE_BUY) ? Sym.Ask() : Sym.Bid();
      gs.levels         = cnt + 1;
     }
  }

//+------------------------------------------------------------------+
//| Basket exit logic                                                |
//+------------------------------------------------------------------+
void ManageBasketExits()
  {
   int    longCnt=0, shortCnt=0;
   double longLots=0, shortLots=0;
   double lH=0,lL=0,sH=0,sL=0;
   double floating=0;
   ScanPositions(longCnt, shortCnt, longLots, shortLots, lH, lL, sH, sL, floating);

   if(longCnt == 0 && shortCnt == 0)
     {
      ResetGridState(g_long);
      ResetGridState(g_short);
      return;
     }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double tpMoney = InpBasketTpMoney;
   if(tpMoney <= 0.0)
      tpMoney = equity * InpBasketTpPct / 100.0;

   double slMoney = equity * InpBasketSlPct / 100.0;

   // Hard SL — close all
   if(floating <= -slMoney && slMoney > 0)
     {
      PrintFormat("Basket hard SL hit: floating=%.2f limit=%.2f", floating, -slMoney);
      CloseAll();
      return;
     }

   // Take profit
   if(floating >= tpMoney && tpMoney > 0)
     {
      PrintFormat("Basket TP hit: floating=%.2f target=%.2f", floating, tpMoney);
      CloseAll();
      return;
     }

   // Breakeven trail: once we cross TP/2, arm BE — close when profit >= BE % of equity
   if(InpUseTrailingBE)
     {
      double beHalf = tpMoney * 0.5;
      double beLock = equity * InpBreakevenPct / 100.0;

      bool anyBasket = (longCnt + shortCnt) > 0;
      if(anyBasket)
        {
         if(!g_long.beArmed && !g_short.beArmed && floating >= beHalf)
           {
            g_long.beArmed  = (longCnt  > 0);
            g_short.beArmed = (shortCnt > 0);
           }
         if((g_long.beArmed || g_short.beArmed) && floating <= beLock && floating > 0)
           {
            PrintFormat("Basket BE lock: floating=%.2f lock=%.2f", floating, beLock);
            CloseAll();
            return;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| OnInit / OnDeinit / OnTick                                       |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!Sym.Name(_Symbol))
     {
      Print("Symbol init failed");
      return INIT_FAILED;
     }
   Sym.RefreshRates();

   g_hRsi = iRSI(_Symbol, InpRsiTF, InpRsiPeriod, PRICE_CLOSE);
   if(g_hRsi == INVALID_HANDLE) { Print("RSI handle invalid"); return INIT_FAILED; }

   g_hAtr = iATR(_Symbol, InpAtrTF, InpAtrPeriod);
   if(g_hAtr == INVALID_HANDLE) { Print("ATR handle invalid"); return INIT_FAILED; }

   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetMarginMode();
   Trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   Trade.SetAsyncMode(false);

   g_equityPeak     = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStartEquity = g_equityPeak;
   g_dayStartTime   = 0;
   g_haltedByRisk   = false;
   ResetGridState(g_long);
   ResetGridState(g_short);

   if(InpLotMultiplier < 1.0)
      Print("WARNING: lot multiplier < 1.0 disables martingale");
   if(InpMaxGridLevels < 1)
     { Print("InpMaxGridLevels must be >= 1"); return INIT_PARAMETERS_INCORRECT; }

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_hRsi != INVALID_HANDLE) IndicatorRelease(g_hRsi);
   if(g_hAtr != INVALID_HANDLE) IndicatorRelease(g_hAtr);
  }

void OnTick()
  {
   if(!Sym.RefreshRates()) return;
   UpdateRiskMetrics();

   // Always allow basket exits to run, even when halted (we want to flatten quickly)
   ManageBasketExits();

   if(g_haltedByRisk)
     {
      // After hard halt, flatten and don't reopen
      CloseAll();
      return;
     }

   if(!IsWithinTradingHours()) return;
   if(SpreadPoints() > InpMaxSpreadPoints) return;

   int    longCnt=0, shortCnt=0;
   double longLots=0, shortLots=0;
   double lH=0,lL=0,sH=0,sL=0;
   double floating=0;
   ScanPositions(longCnt, shortCnt, longLots, shortLots, lH, lL, sH, sL, floating);

   // Avoid opening on every tick — gate adds to once-per-bar of working TF
   static datetime lastBar = 0;
   datetime curBar = iTime(_Symbol, InpAtrTF, 0);
   bool newBar = (curBar != lastBar);
   if(newBar) lastBar = curBar;

   // First entries: only on new bar (avoids overtrading on noise)
   if(longCnt == 0 && newBar)
      ManageDirection(POSITION_TYPE_BUY,  longCnt,  longLots,  lH, lL, g_long);
   if(shortCnt == 0 && newBar)
      ManageDirection(POSITION_TYPE_SELL, shortCnt, shortLots, sH, sL, g_short);

   // Grid additions: on every tick (price-based trigger), but cooldown by per-tick checks already applied
   if(longCnt > 0)
      ManageDirection(POSITION_TYPE_BUY,  longCnt,  longLots,  lH, lL, g_long);
   if(shortCnt > 0)
      ManageDirection(POSITION_TYPE_SELL, shortCnt, shortLots, sH, sL, g_short);
  }
//+------------------------------------------------------------------+
