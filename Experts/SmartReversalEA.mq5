//+------------------------------------------------------------------+
//|                                          SmartReversalEA.mq5     |
//|     Liquidity-sweep reversal EA with HTF bias and smart exits    |
//+------------------------------------------------------------------+
#property copyright "SmartReversalEA"
#property version   "1.10"
#property strict
#property description "Trades liquidity sweeps / false breaks of recent swing"
#property description "highs/lows, optionally aligned with higher-timeframe bias."
#property description "Smart exits: partial close at 1R, BE move, ATR trailing."
#property description "Filters: spread, daily ATR regime, session, news blackout,"
#property description "cooldown after consecutive losses (anti-revenge)."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\DealInfo.mqh>

//=================== INPUTS ========================================
input group   "=== Risk management ==="
input double  InpRiskPercent       = 0.75;     // Risk per trade (% of equity)
input double  InpMaxDailyLossPct   = 3.0;      // Halt trading after daily loss (%)
input int     InpMaxOpenPositions  = 1;        // Max simultaneous positions
input int     InpMaxTradesPerDay   = 6;        // Hard cap (smart != spam)
input double  InpMinLot            = 0.0;      // Min lot override (0 = broker default)

input group   "=== Liquidity sweep signal ==="
input int     InpSwingLookback     = 20;       // Bars used to define recent swing H/L
input double  InpSweepMinAtr       = 0.15;     // Wick must exceed swing by >= this * ATR
input double  InpSweepMaxAtr       = 1.50;     // ...but not more than this * ATR (avoid genuine breakouts)
input bool    InpRequireCloseInside = true;    // Bar must close back inside the prior range
input bool    InpRequireOppositeMomentum = true; // RSI must reject (not be at extreme in sweep direction)
input int     InpRsiPeriod         = 14;
input double  InpRsiBuyMax         = 45.0;     // For a bullish sweep (long), RSI should NOT be already overbought
input double  InpRsiSellMin        = 55.0;     // For a bearish sweep (short), RSI should NOT be already oversold

input group   "=== HTF bias filter (confluence) ==="
input bool    InpUseHtfBias        = true;
input ENUM_TIMEFRAMES InpHtfTf     = PERIOD_H1;
input int     InpHtfEmaFast        = 20;
input int     InpHtfEmaSlow        = 50;
input bool    InpAllowCounterTrend = true;     // If true, allow reversal even against HTF (when sweep is very strong)
input double  InpCounterTrendMinAtr = 0.60;    // For counter-trend, sweep must exceed swing by >= this * ATR

input group   "=== Regime filters ==="
input int     InpAtrPeriod         = 14;
input double  InpDailyAtrMinMult   = 0.50;     // Skip if today's ATR < (this * 20d avg)
input double  InpDailyAtrMaxMult   = 2.50;     // Skip if today's ATR > (this * 20d avg)
input int     InpSpreadMaxPoints   = 25;       // Skip trade if current spread > X points

input group   "=== Session / news ==="
input bool    InpUseSession        = true;
input int     InpStartHour         = 7;        // Inclusive (server time)
input int     InpEndHour           = 19;       // Exclusive
input bool    InpBlockFridayLate   = true;     // No new trades Fri >= 18:00
input bool    InpBlockNewsWindow   = true;     // Daily news blackout
input int     InpNewsStartHour     = 14;       // Server time
input int     InpNewsStartMinute   = 25;
input int     InpNewsDurationMin   = 60;       // Minutes after start

input group   "=== Exit / trade management ==="
input double  InpAtrStopMult       = 1.2;      // SL = ATR * this (placed beyond the sweep wick)
input double  InpTpRMultiple       = 2.5;      // TP for runner = R * this
input bool    InpPartialAt1R       = true;     // Close half at 1R, move SL to BE
input double  InpPartialFraction   = 0.5;      // Fraction to close (0.5 = half)
input double  InpBEOffsetPts       = 5;        // Move SL to entry + this many points (covers commission)
input bool    InpTrailRemainder    = true;     // Trail remainder by ATR after partial close
input double  InpTrailAtrMult      = 1.0;

input group   "=== Anti-revenge cooldown ==="
input int     InpConsecLossPause   = 3;        // After this many consecutive EA losses, pause
input int     InpPauseBars         = 16;       // Pause length, in chart bars

input group   "=== Execution ==="
input ulong   InpMagic             = 770044;
input int     InpSlippagePoints    = 20;
input bool    InpAllowLong         = true;
input bool    InpAllowShort        = true;

//=================== GLOBALS =======================================
CTrade        trade;
CPositionInfo pos;
CSymbolInfo   sym;
CDealInfo     deal;

int           hAtr        = INVALID_HANDLE;
int           hAtrDaily   = INVALID_HANDLE;
int           hRsi        = INVALID_HANDLE;
int           hHtfFast    = INVALID_HANDLE;
int           hHtfSlow    = INVALID_HANDLE;

datetime      lastBarTime    = 0;
datetime      dayStartTime   = 0;
double        dayStartEquity = 0.0;
int           dayTradeCount  = 0;
int           consecLosses   = 0;
datetime      pauseUntilBar  = 0;

// Track which open tickets already had their partial-close + BE applied
ulong         partialDoneTickets[];

//=================== INIT ==========================================
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.SetAsyncMode(false);

   if(!sym.Name(_Symbol)) return INIT_FAILED;
   sym.RefreshRates();

   hAtr      = iATR(_Symbol, _Period,    InpAtrPeriod);
   hAtrDaily = iATR(_Symbol, PERIOD_D1,  InpAtrPeriod);
   hRsi      = iRSI(_Symbol, _Period,    InpRsiPeriod, PRICE_CLOSE);
   if(InpUseHtfBias)
     {
      hHtfFast = iMA(_Symbol, InpHtfTf, InpHtfEmaFast, 0, MODE_EMA, PRICE_CLOSE);
      hHtfSlow = iMA(_Symbol, InpHtfTf, InpHtfEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
     }

   if(hAtr == INVALID_HANDLE || hAtrDaily == INVALID_HANDLE || hRsi == INVALID_HANDLE)
     {
      Print("Core indicator init failed");
      return INIT_FAILED;
     }
   if(InpUseHtfBias && (hHtfFast == INVALID_HANDLE || hHtfSlow == INVALID_HANDLE))
     {
      Print("HTF EMA init failed");
      return INIT_FAILED;
     }

   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   dayStartTime   = TodayMidnight();
   dayTradeCount  = 0;
   ArrayResize(partialDoneTickets, 0);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(hAtr      != INVALID_HANDLE) IndicatorRelease(hAtr);
   if(hAtrDaily != INVALID_HANDLE) IndicatorRelease(hAtrDaily);
   if(hRsi      != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hHtfFast  != INVALID_HANDLE) IndicatorRelease(hHtfFast);
   if(hHtfSlow  != INVALID_HANDLE) IndicatorRelease(hHtfSlow);
  }

//=================== TICK =========================================
void OnTick()
  {
   if(!sym.RefreshRates()) return;
   RolloverDay();

   // Manage open trades on every tick
   ManageOpenTrades();

   if(!IsNewBar()) return;

   if(IsPaused()) return;
   if(DailyLossExceeded()) return;
   if(dayTradeCount >= InpMaxTradesPerDay) return;
   if(CountOpenPositions() >= InpMaxOpenPositions) return;
   if(!WithinTradingWindow()) return;
   if(!RegimeOK()) return;
   if(!SpreadOK()) return;

   EvaluateSignal();
  }

//=================== TRADE EVENT (track losses for cooldown) =======
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   deal.Ticket(trans.deal);
   if(deal.Magic() != InpMagic) return;
   if(deal.Symbol() != _Symbol) return;
   if(deal.Entry() != DEAL_ENTRY_OUT && deal.Entry() != DEAL_ENTRY_INOUT) return;

   double profit = deal.Profit() + deal.Swap() + deal.Commission();
   if(profit < 0.0)
     {
      consecLosses++;
      if(consecLosses >= InpConsecLossPause)
        {
         pauseUntilBar = TimeCurrent() + (datetime)(InpPauseBars * PeriodSeconds(_Period));
         consecLosses = 0; // reset after enacting pause
         PrintFormat("[SmartReversal] Cooldown engaged until %s", TimeToString(pauseUntilBar));
        }
     }
   else if(profit > 0.0)
     {
      consecLosses = 0;
     }
  }

//=================== FILTERS ======================================
bool IsPaused()
  {
   if(pauseUntilBar == 0) return false;
   if(TimeCurrent() >= pauseUntilBar) { pauseUntilBar = 0; return false; }
   return true;
  }

bool DailyLossExceeded()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(dayStartEquity <= 0.0) return false;
   double lossPct = (dayStartEquity - eq) / dayStartEquity * 100.0;
   return (lossPct >= InpMaxDailyLossPct);
  }

bool WithinTradingWindow()
  {
   if(!InpUseSession) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return false;
   if(InpBlockFridayLate && dt.day_of_week == 5 && dt.hour >= 18) return false;

   if(InpBlockNewsWindow)
     {
      int startMin = InpNewsStartHour * 60 + InpNewsStartMinute;
      int endMin   = startMin + InpNewsDurationMin;
      int nowMin   = dt.hour * 60 + dt.min;
      if(nowMin >= startMin && nowMin < endMin) return false;
     }
   return true;
  }

bool RegimeOK()
  {
   double atrD[21];
   if(CopyBuffer(hAtrDaily, 0, 0, 21, atrD) != 21) return true; // not enough history -> don't block
   double today = atrD[1];
   double sum = 0.0;
   for(int i = 1; i <= 20; i++) sum += atrD[i];
   double avg = sum / 20.0;
   if(avg <= 0.0) return true;
   double ratio = today / avg;
   if(ratio < InpDailyAtrMinMult) return false; // dead market
   if(ratio > InpDailyAtrMaxMult) return false; // chaos / news day
   return true;
  }

bool SpreadOK()
  {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread <= 0) return true;
   if(spread > InpSpreadMaxPoints) return false;
   return true;
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
      dayTradeCount  = 0;
     }
  }

bool IsNewBar()
  {
   datetime t = (datetime)iTime(_Symbol, _Period, 0);
   if(t == lastBarTime) return false;
   lastBarTime = t;
   return true;
  }

int CountOpenPositions()
  {
   int n = 0, total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol || pos.Magic() != InpMagic) continue;
      n++;
     }
   return n;
  }

//=================== POSITION SIZING ==============================
double CalcLotByRisk(double stopDistancePrice)
  {
   if(stopDistancePrice <= 0.0) return 0.0;
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (InpRiskPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0) return 0.0;

   double lossPerLot = (stopDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0.0) return 0.0;
   double lot = riskMoney / lossPerLot;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(InpMinLot > 0.0) minLot = MathMax(minLot, InpMinLot);

   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   if(lot < minLot - 1e-9) return 0.0;
   return NormalizeDouble(lot, 2);
  }

//=================== SIGNAL =======================================
// Liquidity sweep on the last closed bar (index 1):
//   bullish sweep (long setup): low[1]  < min(low[2..N+1])  by >= ATR*MinFactor
//                               and close[1] > that min     (closed back inside)
//   bearish sweep (short setup): symmetric on high.
void EvaluateSignal()
  {
   double atrBuf[2];
   if(CopyBuffer(hAtr, 0, 0, 2, atrBuf) != 2) return;
   double atr = atrBuf[1];
   if(atr <= 0.0) return;

   int n = InpSwingLookback;
   if(n < 5) n = 5;

   double highPrev[]; double lowPrev[];
   if(CopyHigh(_Symbol, _Period, 2, n, highPrev) != n) return;
   if(CopyLow (_Symbol, _Period, 2, n, lowPrev)  != n) return;

   double swingHigh = highPrev[ArrayMaximum(highPrev, 0, n)];
   double swingLow  = lowPrev[ArrayMinimum(lowPrev,   0, n)];

   double h1 = iHigh(_Symbol, _Period, 1);
   double l1 = iLow (_Symbol, _Period, 1);
   double c1 = iClose(_Symbol, _Period, 1);

   double minSweep = InpSweepMinAtr * atr;
   double maxSweep = InpSweepMaxAtr * atr;

   bool bullSweep = (swingLow - l1 >= minSweep) &&
                    (swingLow - l1 <= maxSweep) &&
                    (!InpRequireCloseInside || c1 > swingLow);

   bool bearSweep = (h1 - swingHigh >= minSweep) &&
                    (h1 - swingHigh <= maxSweep) &&
                    (!InpRequireCloseInside || c1 < swingHigh);

   // RSI momentum filter (we want a reversal, so RSI shouldn't already be in the continuation extreme)
   if(InpRequireOppositeMomentum)
     {
      double rsiBuf[2];
      if(CopyBuffer(hRsi, 0, 0, 2, rsiBuf) != 2) return;
      double rsi = rsiBuf[1];
      if(bullSweep && rsi > InpRsiBuyMax)  bullSweep = false;
      if(bearSweep && rsi < InpRsiSellMin) bearSweep = false;
     }

   // HTF bias
   int htfBias = 0; // +1 up, -1 down, 0 neutral
   if(InpUseHtfBias)
     {
      double f[2], s[2];
      if(CopyBuffer(hHtfFast, 0, 0, 2, f) == 2 &&
         CopyBuffer(hHtfSlow, 0, 0, 2, s) == 2)
        {
         if(f[1] > s[1]) htfBias = +1;
         else if(f[1] < s[1]) htfBias = -1;
        }
     }

   if(InpAllowLong && bullSweep)
     {
      bool counterTrend = (htfBias == -1);
      if(InpUseHtfBias && counterTrend)
        {
         if(!InpAllowCounterTrend) return;
         // counter-trend requires a stronger sweep
         if(swingLow - l1 < InpCounterTrendMinAtr * atr) return;
        }
      OpenLong(atr, swingLow, l1);
      return;
     }
   if(InpAllowShort && bearSweep)
     {
      bool counterTrend = (htfBias == +1);
      if(InpUseHtfBias && counterTrend)
        {
         if(!InpAllowCounterTrend) return;
         if(h1 - swingHigh < InpCounterTrendMinAtr * atr) return;
        }
      OpenShort(atr, swingHigh, h1);
      return;
     }
  }

//=================== ORDER PLACEMENT ==============================
void OpenLong(double atr, double swingLow, double sweepLow)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   // SL goes just BELOW the sweep wick by ATR*stopMult (room for noise)
   double slBase = MathMin(sweepLow, swingLow);
   double sl = NormalizeDouble(slBase - InpAtrStopMult * atr, _Digits);
   double R  = ask - sl;
   if(R <= 0.0) return;
   double tp = NormalizeDouble(ask + R * InpTpRMultiple, _Digits);

   double lot = CalcLotByRisk(R);
   if(lot <= 0.0)
     {
      PrintFormat("[%s] LONG skipped: computed lot below broker min (risk %.2f%%)", _Symbol, InpRiskPercent);
      return;
     }
   if(!RespectsStopLevel(sl, tp, ask)) return;

   if(trade.Buy(lot, _Symbol, ask, sl, tp, "Sweep L"))
     {
      dayTradeCount++;
     }
   else
      PrintFormat("Buy failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

void OpenShort(double atr, double swingHigh, double sweepHigh)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slBase = MathMax(sweepHigh, swingHigh);
   double sl = NormalizeDouble(slBase + InpAtrStopMult * atr, _Digits);
   double R  = sl - bid;
   if(R <= 0.0) return;
   double tp = NormalizeDouble(bid - R * InpTpRMultiple, _Digits);

   double lot = CalcLotByRisk(R);
   if(lot <= 0.0)
     {
      PrintFormat("[%s] SHORT skipped: computed lot below broker min", _Symbol);
      return;
     }
   if(!RespectsStopLevel(sl, tp, bid)) return;

   if(trade.Sell(lot, _Symbol, bid, sl, tp, "Sweep S"))
     {
      dayTradeCount++;
     }
   else
      PrintFormat("Sell failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

bool RespectsStopLevel(double sl, double tp, double price)
  {
   long stopsLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist = stopsLevelPts * point;
   if(minDist <= 0.0) return true;
   if(MathAbs(price - sl) < minDist || MathAbs(price - tp) < minDist)
     {
      Print("Skip: SL/TP inside broker stops level");
      return false;
     }
   return true;
  }

//=================== TRADE MANAGEMENT =============================
bool PartialAlreadyApplied(ulong ticket)
  {
   for(int i = 0; i < ArraySize(partialDoneTickets); i++)
      if(partialDoneTickets[i] == ticket) return true;
   return false;
  }

void MarkPartialApplied(ulong ticket)
  {
   int sz = ArraySize(partialDoneTickets);
   ArrayResize(partialDoneTickets, sz + 1);
   partialDoneTickets[sz] = ticket;
  }

void PrunePartialTickets()
  {
   // Remove tickets that are no longer open
   int sz = ArraySize(partialDoneTickets);
   for(int i = sz - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(partialDoneTickets[i]))
        {
         for(int j = i; j < sz - 1; j++) partialDoneTickets[j] = partialDoneTickets[j+1];
         ArrayResize(partialDoneTickets, --sz);
        }
     }
  }

void ManageOpenTrades()
  {
   PrunePartialTickets();

   double atrBuf[1];
   if(CopyBuffer(hAtr, 0, 0, 1, atrBuf) != 1) return;
   double atr = atrBuf[0];
   if(atr <= 0.0) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double trailDist = InpTrailAtrMult * atr;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol || pos.Magic() != InpMagic) continue;

      ulong ticket = pos.Ticket();
      double entry = pos.PriceOpen();
      double sl    = pos.StopLoss();
      double tp    = pos.TakeProfit();
      double vol   = pos.Volume();
      long   type  = pos.PositionType();
      bool didPartial = PartialAlreadyApplied(ticket);

      double R = (sl > 0.0) ? MathAbs(entry - sl) : 0.0;
      if(R <= 0.0) continue;

      if(type == POSITION_TYPE_BUY)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit = bid - entry;

         // Partial close at 1R + move SL to BE+offset
         if(InpPartialAt1R && !didPartial && profit >= R)
           {
            double closeVol = NormalizeVolume(vol * InpPartialFraction);
            if(closeVol > 0.0 && closeVol < vol - 1e-9)
              {
               if(trade.PositionClosePartial(ticket, closeVol))
                 {
                  double newSl = NormalizeDouble(entry + InpBEOffsetPts * point, _Digits);
                  if(newSl > sl + point) trade.PositionModify(ticket, newSl, tp);
                  MarkPartialApplied(ticket);
                 }
              }
            else if(closeVol >= vol - 1e-9)
              {
               // Volume too small to split — just move SL to BE
               double newSl = NormalizeDouble(entry + InpBEOffsetPts * point, _Digits);
               if(newSl > sl + point) trade.PositionModify(ticket, newSl, tp);
               MarkPartialApplied(ticket);
              }
           }

         // Trailing remainder
         if(InpTrailRemainder && didPartial && profit > R)
           {
            double newSl = NormalizeDouble(bid - trailDist, _Digits);
            if(newSl > sl + point) trade.PositionModify(ticket, newSl, tp);
           }
        }
      else if(type == POSITION_TYPE_SELL)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit = entry - ask;

         if(InpPartialAt1R && !didPartial && profit >= R)
           {
            double closeVol = NormalizeVolume(vol * InpPartialFraction);
            if(closeVol > 0.0 && closeVol < vol - 1e-9)
              {
               if(trade.PositionClosePartial(ticket, closeVol))
                 {
                  double newSl = NormalizeDouble(entry - InpBEOffsetPts * point, _Digits);
                  if(sl == 0.0 || newSl < sl - point) trade.PositionModify(ticket, newSl, tp);
                  MarkPartialApplied(ticket);
                 }
              }
            else if(closeVol >= vol - 1e-9)
              {
               double newSl = NormalizeDouble(entry - InpBEOffsetPts * point, _Digits);
               if(sl == 0.0 || newSl < sl - point) trade.PositionModify(ticket, newSl, tp);
               MarkPartialApplied(ticket);
              }
           }

         if(InpTrailRemainder && didPartial && profit > R)
           {
            double newSl = NormalizeDouble(ask + trailDist, _Digits);
            if(sl == 0.0 || newSl < sl - point) trade.PositionModify(ticket, newSl, tp);
           }
        }
     }
  }

double NormalizeVolume(double v)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(step <= 0.0) return v;
   double r = MathFloor(v / step) * step;
   if(r < minV) return 0.0;
   return NormalizeDouble(r, 2);
  }
//+------------------------------------------------------------------+
