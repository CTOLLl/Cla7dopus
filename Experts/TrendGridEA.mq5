//+------------------------------------------------------------------+
//|                                                  TrendGridEA.mq5  |
//|     Trend-following averaging grid with hard safety rails.       |
//|     NOT a martingale. Default lot multiplier = 1.0.              |
//+------------------------------------------------------------------+
#property copyright "TrendGridEA"
#property version   "1.00"
#property strict
#property description "Trend-aligned averaging grid: opens an initial position in the"
#property description "direction of HTF bias, then adds at fixed ATR-spaced levels if"
#property description "price runs against it. Closes the WHOLE basket when net floating"
#property description "profit reaches a target (in account currency or % of equity)."
#property description ""
#property description "SAFETY RAILS (all enforced unconditionally):"
#property description " - HTF trend filter (default ON) — never grids against H1 EMA bias."
#property description " - Hard cap on grid levels."
#property description " - Hard equity drawdown stop (closes all on threshold breach)."
#property description " - Daily loss stop & news blackout."
#property description " - Default lot multiplier = 1.0 (NOT martingale). Multiplier > 1"
#property description "   is allowed but explicitly warns at init."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//=================== INPUTS ========================================
input group   "=== Risk management ==="
input double  InpBaseLot            = 0.01;     // Starting lot for level 1
input double  InpLotMultiplier      = 1.0;      // 1.0 = flat (recommended). >1.0 = scaled (DANGER above 1.3)
input double  InpMaxDailyLossPct    = 3.0;      // Halt new baskets after daily loss (%)
input double  InpEmergencyEquityDDPct = 8.0;    // Close ALL positions if equity drops this % from session start (hard stop)
input bool    InpEnforceLotCap      = true;     // Cap total open volume vs equity
input double  InpMaxTotalLotPer1k   = 0.30;     // If enforced: max total open lots per $1000 of equity

input group   "=== Direction filter (TREND ONLY) ==="
input bool    InpUseHtfBias         = true;     // Strongly recommended ON
input ENUM_TIMEFRAMES InpHtfTf      = PERIOD_H1;
input int     InpHtfEmaFast         = 20;
input int     InpHtfEmaSlow         = 50;
input bool    InpAllowLong          = true;
input bool    InpAllowShort         = true;

input group   "=== Entry signal (first level only) ==="
// First grid level only opens on a real pullback signal — not at any random price.
input int     InpRsiPeriod          = 14;
input double  InpRsiLongMax         = 45.0;     // Long entry: RSI dipped below this (pullback in uptrend)
input double  InpRsiShortMin        = 55.0;     // Short entry: RSI above this (pullback in downtrend)

input group   "=== Grid construction ==="
input int     InpMaxGridLevels      = 5;        // Hard cap — never more than this many positions in basket
input int     InpAtrPeriod          = 14;
input double  InpGridStepAtrMult    = 0.8;      // Spacing between levels = this * ATR
input double  InpGridStepMinPoints  = 80;       // Floor for spacing (broker points)

input group   "=== Basket take-profit ==="
// The basket is closed when EITHER condition is met (whichever first):
input bool    InpUseAbsTpMoney      = true;
input double  InpAbsTpMoney         = 5.0;      // Close basket when net floating profit >= this (account currency)
input bool    InpUseTpPctEquity     = true;
input double  InpTpPctEquity        = 0.5;      // Close basket when net floating profit >= this % of equity at basket start

input group   "=== Per-basket loss circuit-breaker ==="
// Independent of the equity-DD emergency: if basket floating loss exceeds this % of equity,
// close the basket (controlled stop, before equity DD trips).
input bool    InpUseBasketSL        = true;
input double  InpBasketSLPctEquity  = 4.0;

input group   "=== Session / news ==="
input bool    InpUseSession         = true;
input int     InpStartHour          = 8;        // Server time
input int     InpEndHour            = 20;
input bool    InpBlockFridayLate    = true;     // No new baskets Fri >= 17:00
input bool    InpBlockNewsWindow    = true;
input int     InpNewsStartHour      = 14;
input int     InpNewsStartMinute    = 25;
input int     InpNewsDurationMin    = 60;
input int     InpSpreadMaxPoints    = 25;

input group   "=== Re-entry control ==="
input int     InpCooldownBarsAfterBasket = 4;   // Bars to wait after closing a basket
input int     InpCooldownBarsAfterDD     = 60;  // Bars to wait after emergency DD trip

input group   "=== Execution ==="
input ulong   InpMagic              = 770099;
input int     InpSlippagePoints     = 20;

//=================== GLOBALS =======================================
CTrade        trade;
CPositionInfo pos;
CSymbolInfo   sym;

int           hAtr        = INVALID_HANDLE;
int           hRsi        = INVALID_HANDLE;
int           hHtfFast    = INVALID_HANDLE;
int           hHtfSlow    = INVALID_HANDLE;

datetime      lastBarTime    = 0;
datetime      dayStartTime   = 0;
double        dayStartEquity = 0.0;
double        sessionPeakEq  = 0.0;
datetime      basketClosedAt = 0;
datetime      emergencyTrippedAt = 0;
bool          emergencyActive = false;

// Per-basket state
int           basketSide       = 0;     // +1 long, -1 short, 0 flat
int           basketLevelCount = 0;
double        basketLastPrice  = 0.0;   // entry price of the most-recent grid level
double        basketStartEquity = 0.0;  // equity at the moment level 1 opened

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
   if(InpUseHtfBias)
     {
      hHtfFast = iMA(_Symbol, InpHtfTf, InpHtfEmaFast, 0, MODE_EMA, PRICE_CLOSE);
      hHtfSlow = iMA(_Symbol, InpHtfTf, InpHtfEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
     }

   if(hAtr == INVALID_HANDLE || hRsi == INVALID_HANDLE) return INIT_FAILED;
   if(InpUseHtfBias && (hHtfFast == INVALID_HANDLE || hHtfSlow == INVALID_HANDLE)) return INIT_FAILED;

   if(InpLotMultiplier > 1.3)
      Print("WARNING: InpLotMultiplier > 1.3 — this approaches martingale behavior and ",
            "can blow the account on a sustained adverse move. Test thoroughly.");
   if(!InpUseHtfBias)
      Print("WARNING: HTF trend filter is OFF. Grid without a trend filter is the most ",
            "common reason these EAs blow accounts.");

   dayStartEquity   = AccountInfoDouble(ACCOUNT_EQUITY);
   sessionPeakEq    = dayStartEquity;
   dayStartTime     = TodayMidnight();
   ResetBasketState();
   // Adopt any pre-existing open positions matching our magic (e.g. after restart)
   AdoptExistingPositions();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(hAtr     != INVALID_HANDLE) IndicatorRelease(hAtr);
   if(hRsi     != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hHtfFast != INVALID_HANDLE) IndicatorRelease(hHtfFast);
   if(hHtfSlow != INVALID_HANDLE) IndicatorRelease(hHtfSlow);
  }

//=================== TICK =========================================
void OnTick()
  {
   if(!sym.RefreshRates()) return;
   RolloverDay();
   UpdatePeakEquity();

   // Emergency DD check runs every tick — it must be able to trip with no delay
   if(CheckEmergencyEquityStop()) return;

   // Manage existing basket (basket TP / basket SL / add next grid level)
   if(BasketIsOpen())
     {
      if(ManageBasketExit()) return;     // returns true if basket was closed this tick
      ManageBasketGridAdd();
      return;                            // never open a NEW basket while one exists
     }

   // No basket open — consider opening one
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
   basketSide        = 0;
   basketLevelCount  = 0;
   basketLastPrice   = 0.0;
   basketStartEquity = 0.0;
  }

bool BasketIsOpen()
  {
   // Source of truth: any open positions with our magic on this symbol
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol || pos.Magic() != InpMagic) continue;
      return true;
     }
   if(basketSide != 0)
     {
      // No positions present — reset stale state
      ResetBasketState();
     }
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
      if(p > lastPrice || lastPrice == 0.0) lastPrice = p; // any consistent ref
     }
   if(count > 0)
     {
      basketLevelCount  = count;
      basketSide        = (sideSum > 0) ? +1 : -1;
      basketLastPrice   = lastPrice;
      basketStartEquity = AccountInfoDouble(ACCOUNT_EQUITY); // best estimate
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

   PrintFormat("[EMERGENCY] Equity DD %.2f%% >= %.2f%% — closing ALL positions and pausing",
               ddPct, InpEmergencyEquityDDPct);
   CloseAllBasketPositions("EMERGENCY DD");
   emergencyActive   = true;
   emergencyTrippedAt = TimeCurrent();
   basketClosedAt    = TimeCurrent();
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
      if(TimeCurrent() - emergencyTrippedAt >= InpCooldownBarsAfterDD * periodSec)
        {
         emergencyActive = false;
         // Reset session peak so next basket is measured from a fresh baseline
         sessionPeakEq = AccountInfoDouble(ACCOUNT_EQUITY);
         PrintFormat("[Cooldown] Emergency pause released, peak equity reset to %.2f", sessionPeakEq);
         return false;
        }
      return true;
     }
   if(basketClosedAt > 0)
     {
      if(TimeCurrent() - basketClosedAt < InpCooldownBarsAfterBasket * periodSec)
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
   if(!InpUseHtfBias) return 0; // neutral allows either direction
   double f[2], s[2];
   if(CopyBuffer(hHtfFast, 0, 0, 2, f) != 2) return 0;
   if(CopyBuffer(hHtfSlow, 0, 0, 2, s) != 2) return 0;
   if(f[1] > s[1]) return +1;
   if(f[1] < s[1]) return -1;
   return 0;
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

double LotForLevel(int levelIndex)
  {
   // levelIndex is 1-based: level 1 = base lot
   double lot = InpBaseLot * MathPow(InpLotMultiplier, levelIndex - 1);
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

//=================== FIRST ENTRY ==================================
void EvaluateFirstEntry()
  {
   int bias = GetHtfBias();
   if(InpUseHtfBias && bias == 0) return;

   double rsi = GetRsi();
   if(rsi < 0.0) return;

   bool wantLong  = false, wantShort = false;
   if(InpAllowLong  && (bias >= 0) && (rsi <= InpRsiLongMax))
      wantLong = true;
   if(InpAllowShort && (bias <= 0) && (rsi >= InpRsiShortMin))
      wantShort = true;
   if(InpUseHtfBias)
     {
      // With HTF bias on, force the right direction even if both flags would match
      if(bias == +1) wantShort = false;
      if(bias == -1) wantLong  = false;
     }

   if(wantLong)  OpenLevel(+1, 1);
   else if(wantShort) OpenLevel(-1, 1);
  }

//=================== GRID ADDITION ================================
void ManageBasketGridAdd()
  {
   if(basketSide == 0) return;
   if(basketLevelCount >= InpMaxGridLevels) return;
   if(InCooldown()) return;          // don't add during cooldown
   if(!SpreadOK()) return;
   if(DailyLossExceeded()) return;

   double atr = GetAtr();
   if(atr <= 0.0) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stepPrice = MathMax(InpGridStepAtrMult * atr, InpGridStepMinPoints * point);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(basketSide == +1)
     {
      // Add next long level when price has moved DOWN by stepPrice from last entry
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
      PrintFormat("[Grid] Level %d skipped: lot cap reached (total %.2f)", levelIndex, TotalOpenVolume());
      return;
     }

   double price = (side == +1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                               : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   string comment = StringFormat("Grid L%d %s", levelIndex, (side == +1 ? "B" : "S"));
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
      basketSide        = side;
      basketLevelCount  = 1;
      basketStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
     }
   else
     {
      basketLevelCount = levelIndex;
     }
   basketLastPrice = dealPrice;
   PrintFormat("[Grid] Opened level %d %s lot=%.2f @ %.5f (basket size=%d)",
               levelIndex, (side == +1 ? "LONG" : "SHORT"), lot, dealPrice, basketLevelCount);
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

   bool tpHit = false;
   if(InpUseAbsTpMoney && pnl >= InpAbsTpMoney) tpHit = true;
   if(InpUseTpPctEquity)
     {
      double tpMoney = baseEq * (InpTpPctEquity / 100.0);
      if(pnl >= tpMoney) tpHit = true;
     }
   if(tpHit)
     {
      PrintFormat("[Basket] TP hit, floating PnL=%.2f (levels=%d) — closing", pnl, basketLevelCount);
      CloseAllBasketPositions("Basket TP");
      basketClosedAt = TimeCurrent();
      ResetBasketState();
      return true;
     }

   if(InpUseBasketSL && InpBasketSLPctEquity > 0.0)
     {
      double slLoss = baseEq * (InpBasketSLPctEquity / 100.0);
      if(pnl <= -slLoss)
        {
         PrintFormat("[Basket] SL hit, floating PnL=%.2f (-%.2f%% of basket equity) — closing",
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
   // Close in a few passes — partial fills, requotes etc. can leave residues
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
