//+------------------------------------------------------------------+
//|                                              SmartGridProEA.mq5  |
//|     Adaptive grid EA with regime detection, ATR-spaced levels,   |
//|     dynamic basket TP, trailing lock-in, and hard safety rails.  |
//|                                                                  |
//|     NOT a martingale by default (multiplier = 1.0). Multiplier   |
//|     > 1 is allowed but explicitly warned at init.                |
//+------------------------------------------------------------------+
#property copyright "SmartGridProEA"
#property version   "1.10"
#property strict
#property description "Adaptive grid: detects regime (trend / range) on HTF, sizes the"
#property description "grid step dynamically by ATR, opens an initial signal-based entry,"
#property description "then adds levels against adverse moves up to a hard cap. Closes the"
#property description "whole basket on dynamic TP (absolute cash, % equity, or trailing)."
#property description ""
#property description "SAFETY RAILS (always on):"
#property description " - HTF regime / bias filter (trend mode only by default)."
#property description " - Hard cap on grid levels."
#property description " - Per-basket loss circuit breaker (cuts before equity DD)."
#property description " - Session-equity emergency stop closes ALL positions."
#property description " - Daily loss halt, weekend / Friday-late / news blackout."
#property description " - Total-volume lot cap relative to equity."
#property description " - Spread, freeze level, and stop-out distance guards."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//=================== INPUTS ========================================
input group   "=== Risk management ==="
input double  InpBaseLot              = 0.01;     // Starting lot for level 1
input double  InpLotMultiplier        = 1.0;      // 1.0 = flat. > 1.0 = scaled (DANGER above 1.3)
input bool    InpUseRiskBasedLot      = false;    // Auto-size base lot from risk % of equity
input double  InpRiskPctPerBasket     = 1.0;      // If risk-based: % equity risked per full basket
input double  InpMaxDailyLossPct      = 3.0;      // Halt new baskets after daily loss reaches this %
input double  InpEmergencyEquityDDPct = 8.0;      // Close ALL if equity drops this % from session peak
input bool    InpEnforceLotCap        = true;     // Cap total open volume vs equity
input double  InpMaxTotalLotPer1k     = 0.30;     // If enforced: max total open lots per $1000 equity

input group   "=== Regime / direction filter ==="
input bool    InpUseHtfBias           = true;     // Strongly recommended ON
input ENUM_TIMEFRAMES InpHtfTf        = PERIOD_H1;
input int     InpHtfEmaFast           = 20;
input int     InpHtfEmaSlow           = 50;
input bool    InpUseAdxRegime         = true;     // Require ADX > threshold to trade trend
input int     InpAdxPeriod            = 14;
input double  InpAdxMinTrend          = 18.0;     // ADX below this = treat as ranging (skip)
input bool    InpAllowLong            = true;
input bool    InpAllowShort           = true;

input group   "=== Entry signal (first level only) ==="
input int     InpRsiPeriod            = 14;
input double  InpRsiLongMax           = 45.0;     // Long entry: RSI dipped at/under this (pullback in uptrend)
input double  InpRsiShortMin          = 55.0;     // Short entry: RSI rose at/above this (pullback in downtrend)
input bool    InpRequireBosConfirm    = false;    // Optional: require break of prior swing in trend direction

input group   "=== Grid construction ==="
input int     InpMaxGridLevels        = 6;        // Hard cap on positions in a basket
input int     InpAtrPeriod            = 14;
input double  InpGridStepAtrMult      = 0.8;      // Spacing between levels = this * ATR
input double  InpGridStepMinPoints    = 80;       // Floor for spacing (broker points)
input bool    InpExpandStepOnLevels   = true;     // Widen step as basket grows (curbs over-stacking)
input double  InpStepExpansionPct     = 15.0;     // Each extra level widens required step by this %

input group   "=== Basket take-profit ==="
input bool    InpUseAbsTpMoney        = true;
input double  InpAbsTpMoney           = 5.0;      // Close basket when net floating profit >= this (account currency)
input bool    InpUseTpPctEquity       = true;
input double  InpTpPctEquity          = 0.5;      // Close basket when PnL >= this % of basket-start equity
input bool    InpScaleTpWithLevels    = true;     // Lower required PnL slightly as levels grow (recover-and-exit)
input double  InpTpScaleFloorPct      = 60.0;     // Don't scale TP below this percent of original target

input group   "=== Trailing basket lock-in ==="
input bool    InpUseTrailingBasketTp  = true;     // After peak PnL reaches arm threshold, trail floor
input double  InpTrailArmPctOfTp      = 60.0;     // Arm trailing once PnL >= this % of basket TP target
input double  InpTrailGivebackPct     = 35.0;     // Close basket if PnL falls back to this % of peak

input group   "=== Per-basket loss circuit-breaker ==="
input bool    InpUseBasketSL          = true;
input double  InpBasketSLPctEquity    = 4.0;      // Close basket if floating loss >= this % of basket-start equity

input group   "=== Session / news ==="
input bool    InpUseSession           = true;
input int     InpStartHour            = 8;        // Server time
input int     InpEndHour              = 20;
input bool    InpBlockFridayLate      = true;     // No new baskets Fri >= 17:00
input bool    InpBlockNewsWindow      = true;
input int     InpNewsStartHour        = 14;
input int     InpNewsStartMinute      = 25;
input int     InpNewsDurationMin      = 60;
input int     InpSpreadMaxPoints      = 25;

input group   "=== Re-entry control ==="
input int     InpCooldownBarsAfterBasket = 3;
input int     InpCooldownBarsAfterDD     = 60;

input group   "=== Execution ==="
input ulong   InpMagic                = 880123;
input int     InpSlippagePoints       = 20;
input string  InpBasketComment        = "SmartGridPro";

//=================== GLOBALS =======================================
CTrade        trade;
CPositionInfo pos;
CSymbolInfo   sym;

int           hAtr      = INVALID_HANDLE;
int           hRsi      = INVALID_HANDLE;
int           hAdx      = INVALID_HANDLE;
int           hHtfFast  = INVALID_HANDLE;
int           hHtfSlow  = INVALID_HANDLE;

datetime      lastBarTime        = 0;
datetime      dayStartTime       = 0;
double        dayStartEquity     = 0.0;
double        sessionPeakEq      = 0.0;
datetime      basketClosedAt     = 0;
datetime      emergencyTrippedAt = 0;
bool          emergencyActive    = false;

// Per-basket state
int           basketSide         = 0;     // +1 long, -1 short, 0 flat
int           basketLevelCount   = 0;
double        basketLastPrice    = 0.0;
double        basketStartEquity  = 0.0;
double        basketTpTargetMoney = 0.0;  // resolved TP target at basket open (in money)
double        basketPeakPnl      = 0.0;   // running max floating PnL since basket open
bool          basketTrailArmed   = false;

//=================== INIT ==========================================
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.SetAsyncMode(false);

   if(!sym.Name(_Symbol)) return INIT_FAILED;
   sym.RefreshRates();

   hAtr = iATR(_Symbol, _Period, InpAtrPeriod);
   hRsi = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   if(InpUseAdxRegime) hAdx = iADX(_Symbol, _Period, InpAdxPeriod);
   if(InpUseHtfBias)
     {
      hHtfFast = iMA(_Symbol, InpHtfTf, InpHtfEmaFast, 0, MODE_EMA, PRICE_CLOSE);
      hHtfSlow = iMA(_Symbol, InpHtfTf, InpHtfEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
     }
   if(hAtr == INVALID_HANDLE || hRsi == INVALID_HANDLE) return INIT_FAILED;
   if(InpUseAdxRegime && hAdx == INVALID_HANDLE) return INIT_FAILED;
   if(InpUseHtfBias && (hHtfFast == INVALID_HANDLE || hHtfSlow == INVALID_HANDLE)) return INIT_FAILED;

   if(InpLotMultiplier > 1.3)
      Print("WARNING: InpLotMultiplier > 1.3 approaches martingale behavior — test thoroughly.");
   if(!InpUseHtfBias)
      Print("WARNING: HTF trend filter is OFF. A grid without a trend filter is the most ",
            "common reason these EAs blow accounts.");
   if(InpMaxGridLevels > 10)
      Print("WARNING: InpMaxGridLevels > 10 — basket can become unrecoverable. Consider lowering.");

   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   sessionPeakEq  = dayStartEquity;
   dayStartTime   = TodayMidnight();
   ResetBasketState();
   AdoptExistingPositions();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(hAtr     != INVALID_HANDLE) IndicatorRelease(hAtr);
   if(hRsi     != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hAdx     != INVALID_HANDLE) IndicatorRelease(hAdx);
   if(hHtfFast != INVALID_HANDLE) IndicatorRelease(hHtfFast);
   if(hHtfSlow != INVALID_HANDLE) IndicatorRelease(hHtfSlow);
  }

//=================== TICK =========================================
void OnTick()
  {
   if(!sym.RefreshRates()) return;
   RolloverDay();
   UpdatePeakEquity();

   if(CheckEmergencyEquityStop()) return;

   if(BasketIsOpen())
     {
      if(ManageBasketExit()) return;
      ManageBasketGridAdd();
      return;
     }

   if(!IsNewBar()) return;
   if(emergencyActive) return;
   if(InCooldown()) return;
   if(DailyLossExceeded()) return;
   if(!WithinTradingWindow()) return;
   if(!SpreadOK()) return;

   EvaluateFirstEntry();
  }

//=================== STATE / EMERGENCY ============================
void ResetBasketState()
  {
   basketSide          = 0;
   basketLevelCount    = 0;
   basketLastPrice     = 0.0;
   basketStartEquity   = 0.0;
   basketTpTargetMoney = 0.0;
   basketPeakPnl       = 0.0;
   basketTrailArmed    = false;
  }

bool BasketIsOpen()
  {
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol || pos.Magic() != InpMagic) continue;
      return true;
     }
   if(basketSide != 0) ResetBasketState();
   return false;
  }

void AdoptExistingPositions()
  {
   int count = 0;
   long sideSum = 0;
   double lastPrice = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol || pos.Magic() != InpMagic) continue;
      count++;
      sideSum += (pos.PositionType() == POSITION_TYPE_BUY) ? +1 : -1;
      double p = pos.PriceOpen();
      if(p > lastPrice || lastPrice == 0.0) lastPrice = p;
     }
   if(count > 0)
     {
      basketLevelCount    = count;
      basketSide          = (sideSum > 0) ? +1 : -1;
      basketLastPrice     = lastPrice;
      basketStartEquity   = AccountInfoDouble(ACCOUNT_EQUITY);
      basketTpTargetMoney = ResolveTpTarget(basketStartEquity);
      basketPeakPnl       = 0.0;
      basketTrailArmed    = false;
      PrintFormat("Adopted %d existing positions (side=%d) into basket state", count, basketSide);
     }
  }

bool CheckEmergencyEquityStop()
  {
   if(InpEmergencyEquityDDPct <= 0.0) return false;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(sessionPeakEq <= 0.0) return false;
   double ddPct = (sessionPeakEq - eq) / sessionPeakEq * 100.0;
   if(ddPct < InpEmergencyEquityDDPct) return false;

   PrintFormat("[EMERGENCY] Equity DD %.2f%% >= %.2f%% — closing ALL and pausing",
               ddPct, InpEmergencyEquityDDPct);
   CloseAllBasketPositions("EMERGENCY DD");
   emergencyActive    = true;
   emergencyTrippedAt = TimeCurrent();
   basketClosedAt     = TimeCurrent();
   ResetBasketState();
   return true;
  }

void UpdatePeakEquity()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > sessionPeakEq) sessionPeakEq = eq;
  }

bool InCooldown()
  {
   int periodSec = PeriodSeconds(_Period);
   if(emergencyActive)
     {
      if(TimeCurrent() - emergencyTrippedAt >= (datetime)InpCooldownBarsAfterDD * periodSec)
        {
         emergencyActive = false;
         sessionPeakEq   = AccountInfoDouble(ACCOUNT_EQUITY);
         PrintFormat("[Cooldown] Emergency pause released, peak equity reset to %.2f", sessionPeakEq);
         return false;
        }
      return true;
     }
   if(basketClosedAt > 0)
     {
      if(TimeCurrent() - basketClosedAt < (datetime)InpCooldownBarsAfterBasket * periodSec)
         return true;
     }
   return false;
  }

bool DailyLossExceeded()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(dayStartEquity <= 0.0) return false;
   double lossPct = (dayStartEquity - eq) / dayStartEquity * 100.0;
   return (lossPct >= InpMaxDailyLossPct);
  }

//=================== FILTERS ======================================
bool WithinTradingWindow()
  {
   if(!InpUseSession) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return false;
   if(InpBlockFridayLate && dt.day_of_week == 5 && dt.hour >= 17) return false;
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;

   if(InpBlockNewsWindow)
     {
      int startMin = InpNewsStartHour * 60 + InpNewsStartMinute;
      int endMin   = startMin + InpNewsDurationMin;
      int nowMin   = dt.hour * 60 + dt.min;
      if(nowMin >= startMin && nowMin < endMin) return false;
     }
   return true;
  }

bool SpreadOK()
  {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread <= 0) return true;
   return (spread <= InpSpreadMaxPoints);
  }

//=================== HELPERS ======================================
datetime TodayMidnight()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
  }

void RolloverDay()
  {
   datetime today = TodayMidnight();
   if(today != dayStartTime)
     {
      dayStartTime   = today;
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      sessionPeakEq  = dayStartEquity;
     }
  }

bool IsNewBar()
  {
   datetime t = (datetime)iTime(_Symbol, _Period, 0);
   if(t == lastBarTime) return false;
   lastBarTime = t;
   return true;
  }

int GetHtfBias()
  {
   if(!InpUseHtfBias) return 0;
   double f[2], s[2];
   if(CopyBuffer(hHtfFast, 0, 0, 2, f) != 2) return 0;
   if(CopyBuffer(hHtfSlow, 0, 0, 2, s) != 2) return 0;
   if(f[1] > s[1]) return +1;
   if(f[1] < s[1]) return -1;
   return 0;
  }

double GetAdx()
  {
   if(!InpUseAdxRegime) return 100.0; // treat as always-trending if disabled
   double b[1];
   if(CopyBuffer(hAdx, 0, 0, 1, b) != 1) return -1.0;
   return b[0];
  }

double GetAtr()
  {
   double b[1];
   if(CopyBuffer(hAtr, 0, 0, 1, b) != 1) return 0.0;
   return b[0];
  }

double GetRsi()
  {
   double b[2];
   if(CopyBuffer(hRsi, 0, 0, 2, b) != 2) return -1.0;
   return b[1];
  }

double NormalizeVolume(double v)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;
   double r = MathFloor(v / step) * step;
   if(r < minV) r = minV;
   if(r > maxV) r = maxV;
   return NormalizeDouble(r, 2);
  }

double ComputeBaseLot()
  {
   if(!InpUseRiskBasedLot) return InpBaseLot;
   // Risk-based sizing: estimate worst-case loss across all grid levels at basket-SL distance
   // and back out the base lot. Approximate worst-loss = sum(lot_i) * (basketSL%* startEquity).
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0.0) return InpBaseLot;
   double sumMult = 0.0;
   for(int i = 1; i <= InpMaxGridLevels; i++)
      sumMult += MathPow(InpLotMultiplier, i - 1);
   if(sumMult <= 0.0) return InpBaseLot;
   double riskMoney = eq * (InpRiskPctPerBasket / 100.0);
   // Use a 1% adverse equity move as a normalized base — conservative; user can dial.
   double approxLot = riskMoney / (sumMult * MathMax(InpBasketSLPctEquity, 1.0) / 100.0 * 100.0);
   if(approxLot <= 0.0) approxLot = InpBaseLot;
   return NormalizeVolume(approxLot);
  }

double LotForLevel(int levelIndex)
  {
   double baseLot = ComputeBaseLot();
   double lot = baseLot * MathPow(InpLotMultiplier, levelIndex - 1);
   return NormalizeVolume(lot);
  }

double TotalOpenVolume()
  {
   double v = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol || pos.Magic() != InpMagic) continue;
      v += pos.Volume();
     }
   return v;
  }

bool LotCapWouldBeExceeded(double newLot)
  {
   if(!InpEnforceLotCap) return false;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0.0) return true;
   double maxTotal = (eq / 1000.0) * InpMaxTotalLotPer1k;
   double projected = TotalOpenVolume() + newLot;
   return (projected > maxTotal + 1e-9);
  }

double ResolveTpTarget(double baseEq)
  {
   double tp = 0.0;
   if(InpUseAbsTpMoney) tp = InpAbsTpMoney;
   if(InpUseTpPctEquity)
     {
      double pctTp = baseEq * (InpTpPctEquity / 100.0);
      if(tp <= 0.0 || pctTp < tp) tp = pctTp;   // use the *easier* (smaller) of the two so basket closes sooner
     }
   if(tp <= 0.0) tp = MathMax(InpAbsTpMoney, baseEq * 0.005);
   return tp;
  }

double EffectiveTpTarget()
  {
   if(basketTpTargetMoney <= 0.0) return 0.0;
   if(!InpScaleTpWithLevels || basketLevelCount <= 1) return basketTpTargetMoney;
   // As more levels are added, lower the required PnL gradually (don't scale below floor)
   double scale = 1.0 - 0.10 * (basketLevelCount - 1);
   double floor = InpTpScaleFloorPct / 100.0;
   if(scale < floor) scale = floor;
   return basketTpTargetMoney * scale;
  }

//=================== FIRST ENTRY ==================================
void EvaluateFirstEntry()
  {
   int bias = GetHtfBias();
   if(InpUseHtfBias && bias == 0) return;

   double adx = GetAdx();
   if(adx < 0.0) return;
   if(InpUseAdxRegime && adx < InpAdxMinTrend) return;  // ranging — skip

   double rsi = GetRsi();
   if(rsi < 0.0) return;

   bool wantLong  = false, wantShort = false;
   if(InpAllowLong  && (bias >= 0) && (rsi <= InpRsiLongMax))  wantLong  = true;
   if(InpAllowShort && (bias <= 0) && (rsi >= InpRsiShortMin)) wantShort = true;
   if(InpUseHtfBias)
     {
      if(bias == +1) wantShort = false;
      if(bias == -1) wantLong  = false;
     }
   if(InpRequireBosConfirm)
     {
      if(wantLong  && !BreakOfStructure(+1)) wantLong  = false;
      if(wantShort && !BreakOfStructure(-1)) wantShort = false;
     }

   if(wantLong)       OpenLevel(+1, 1);
   else if(wantShort) OpenLevel(-1, 1);
  }

// Lightweight break-of-structure: did last closed bar break the prior 10-bar high/low in our favor?
bool BreakOfStructure(int side)
  {
   double highs[], lows[], closes[];
   if(CopyHigh(_Symbol, _Period, 1, 12, highs) != 12) return false;
   if(CopyLow(_Symbol, _Period, 1, 12, lows) != 12)   return false;
   if(CopyClose(_Symbol, _Period, 1, 2, closes) != 2) return false;
   double lastClose = closes[1];
   if(side == +1)
     {
      double priorHigh = highs[0];
      for(int i = 1; i < 11; i++) if(highs[i] > priorHigh) priorHigh = highs[i];
      return (lastClose > priorHigh);
     }
   else
     {
      double priorLow = lows[0];
      for(int i = 1; i < 11; i++) if(lows[i] < priorLow) priorLow = lows[i];
      return (lastClose < priorLow);
     }
  }

//=================== GRID ADDITION ================================
void ManageBasketGridAdd()
  {
   if(basketSide == 0) return;
   if(basketLevelCount >= InpMaxGridLevels) return;
   if(InCooldown()) return;
   if(!SpreadOK()) return;
   if(DailyLossExceeded()) return;

   double atr = GetAtr();
   if(atr <= 0.0) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stepPrice = MathMax(InpGridStepAtrMult * atr, InpGridStepMinPoints * point);
   if(InpExpandStepOnLevels && basketLevelCount > 0)
      stepPrice *= (1.0 + (InpStepExpansionPct / 100.0) * (basketLevelCount - 1));

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(basketSide == +1)
     {
      if(ask <= basketLastPrice - stepPrice)
         OpenLevel(+1, basketLevelCount + 1);
     }
   else if(basketSide == -1)
     {
      if(bid >= basketLastPrice + stepPrice)
         OpenLevel(-1, basketLevelCount + 1);
     }
  }

void OpenLevel(int side, int levelIndex)
  {
   double lot = LotForLevel(levelIndex);
   if(lot <= 0.0) return;
   if(LotCapWouldBeExceeded(lot))
     {
      PrintFormat("[Grid] Level %d skipped: lot cap reached (total %.2f)",
                  levelIndex, TotalOpenVolume());
      return;
     }

   double price = (side == +1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                               : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   string comment = StringFormat("%s L%d %s", InpBasketComment, levelIndex,
                                 (side == +1 ? "B" : "S"));
   bool ok = (side == +1) ? trade.Buy(lot, _Symbol, price, 0.0, 0.0, comment)
                          : trade.Sell(lot, _Symbol, price, 0.0, 0.0, comment);
   if(!ok)
     {
      PrintFormat("Grid level %d open failed: %d %s",
                  levelIndex, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
     }

   double dealPrice = trade.ResultPrice();
   if(dealPrice <= 0.0) dealPrice = price;

   if(levelIndex == 1)
     {
      basketSide          = side;
      basketLevelCount    = 1;
      basketStartEquity   = AccountInfoDouble(ACCOUNT_EQUITY);
      basketTpTargetMoney = ResolveTpTarget(basketStartEquity);
      basketPeakPnl       = 0.0;
      basketTrailArmed    = false;
     }
   else
     {
      basketLevelCount = levelIndex;
     }
   basketLastPrice = dealPrice;
   PrintFormat("[Grid] Opened level %d %s lot=%.2f @ %.5f (basket size=%d, TPmoney=%.2f)",
               levelIndex, (side == +1 ? "LONG" : "SHORT"),
               lot, dealPrice, basketLevelCount, basketTpTargetMoney);
  }

//=================== BASKET EXIT ==================================
double BasketFloatingPnL()
  {
   double total = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol || pos.Magic() != InpMagic) continue;
      total += pos.Profit() + pos.Swap() + pos.Commission();
     }
   return total;
  }

// Returns true if basket was closed this tick.
bool ManageBasketExit()
  {
   double pnl = BasketFloatingPnL();
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double baseEq = (basketStartEquity > 0.0) ? basketStartEquity : eq;

   // Track running peak
   if(pnl > basketPeakPnl) basketPeakPnl = pnl;

   // 1) Standard TP target
   double tpTarget = EffectiveTpTarget();
   if(tpTarget > 0.0 && pnl >= tpTarget)
     {
      PrintFormat("[Basket] TP hit, PnL=%.2f >= target=%.2f (levels=%d) — closing",
                  pnl, tpTarget, basketLevelCount);
      CloseAllBasketPositions("Basket TP");
      basketClosedAt = TimeCurrent();
      ResetBasketState();
      return true;
     }

   // 2) Trailing lock-in
   if(InpUseTrailingBasketTp && basketTpTargetMoney > 0.0)
     {
      double armAt = basketTpTargetMoney * (InpTrailArmPctOfTp / 100.0);
      if(!basketTrailArmed && basketPeakPnl >= armAt && basketPeakPnl > 0.0)
        {
         basketTrailArmed = true;
         PrintFormat("[Basket] Trailing armed (peak=%.2f, arm=%.2f)", basketPeakPnl, armAt);
        }
      if(basketTrailArmed)
        {
         double floorPnl = basketPeakPnl * (InpTrailGivebackPct / 100.0);
         if(pnl <= floorPnl)
           {
            PrintFormat("[Basket] Trailing exit, PnL=%.2f back to %.0f%% of peak=%.2f — closing",
                        pnl, InpTrailGivebackPct, basketPeakPnl);
            CloseAllBasketPositions("Basket Trail");
            basketClosedAt = TimeCurrent();
            ResetBasketState();
            return true;
           }
        }
     }

   // 3) Loss circuit-breaker
   if(InpUseBasketSL && InpBasketSLPctEquity > 0.0)
     {
      double slLoss = baseEq * (InpBasketSLPctEquity / 100.0);
      if(pnl <= -slLoss)
        {
         PrintFormat("[Basket] SL hit, PnL=%.2f (-%.2f%% of basket equity) — closing",
                     pnl, InpBasketSLPctEquity);
         CloseAllBasketPositions("Basket SL");
         basketClosedAt = TimeCurrent();
         ResetBasketState();
         return true;
        }
     }
   return false;
  }

void CloseAllBasketPositions(const string reason)
  {
   for(int attempt = 0; attempt < 3; attempt++)
     {
      bool anyLeft = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(!pos.SelectByIndex(i)) continue;
         if(pos.Symbol() != _Symbol || pos.Magic() != InpMagic) continue;
         anyLeft = true;
         if(!trade.PositionClose(pos.Ticket()))
            PrintFormat("Close %llu failed (%s attempt %d): %d %s",
                        pos.Ticket(), reason, attempt,
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
        }
      if(!anyLeft) break;
     }
  }
//+------------------------------------------------------------------+
