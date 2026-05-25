//+------------------------------------------------------------------+
//|                                       SessionVwapScalperEA.mq5    |
//|     Structural intraday scalper: session-anchored VWAP pullback   |
//|     aligned with higher-timeframe bias. Conservative by design.   |
//+------------------------------------------------------------------+
#property copyright "SessionVwapScalperEA"
#property version   "1.00"
#property strict
#property description "Trades pullbacks to a session-anchored VWAP in the direction of"
#property description "a higher-timeframe EMA bias. Confirms with a bar rejection off VWAP."
#property description "Tight intraday risk: 0.2% per trade, hard 1.5% daily stop, max 5 trades."
#property description "Designed for the London-NY overlap on liquid majors (EURUSD, USDJPY,"
#property description "GBPUSD) on M5. NOT a high-frequency tick scalper."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\DealInfo.mqh>

//=================== INPUTS ========================================
input group   "=== Risk management ==="
input double  InpRiskPercent       = 0.2;      // Risk per trade (% of equity) — intentionally small
input double  InpMaxDailyLossPct   = 1.5;      // Halt trading after daily loss (%)
input int     InpMaxOpenPositions  = 1;        // Max simultaneous positions
input int     InpMaxTradesPerDay   = 5;        // Hard daily cap
input double  InpMinLot            = 0.0;      // Min lot override (0 = broker default)

input group   "=== Session anchoring (VWAP reset) ==="
// VWAP is rebuilt from this hour every day. Default = London open server time.
// On most MT5 brokers (GMT+2/+3) London opens ~10:00 server; tune to your broker.
input int     InpSessionStartHour  = 10;
input int     InpSessionStartMin   = 0;
input int     InpTradeStartHour    = 12;       // Don't trade before this (let VWAP develop)
input int     InpTradeEndHour      = 18;       // Stop opening new after this (NY pm fade)
input bool    InpBlockFridayLate   = true;     // No new trades Fri >= 17:00
input bool    InpBlockNewsWindow   = true;     // Daily news blackout
input int     InpNewsStartHour     = 14;       // Server time (default ~ NY 08:30)
input int     InpNewsStartMinute   = 25;
input int     InpNewsDurationMin   = 60;

input group   "=== HTF bias filter ==="
input bool    InpUseHtfBias        = true;
input ENUM_TIMEFRAMES InpHtfTf     = PERIOD_H1;
input int     InpHtfEmaFast        = 20;
input int     InpHtfEmaSlow        = 50;
// If true, also require HTF close to be on the bias side of the fast EMA.
input bool    InpRequireHtfClose   = true;

input group   "=== Entry signal (VWAP pullback + rejection) ==="
input double  InpVwapTouchTolAtr   = 0.10;     // Bar must touch within this * ATR of VWAP
input double  InpRejectionMinAtr   = 0.25;     // Wick on VWAP side must be >= this * ATR
input double  InpBodyMaxAtr        = 1.20;     // Skip if signal bar body > this * ATR (chasing)
input int     InpRsiPeriod         = 14;
input bool    InpUseRsiFilter      = true;
input double  InpRsiLongMin        = 35.0;     // For longs: RSI > this (not oversold continuation)
input double  InpRsiLongMax        = 65.0;     // For longs: RSI < this (not overbought already)
input double  InpRsiShortMin       = 35.0;
input double  InpRsiShortMax       = 65.0;

input group   "=== Regime filters ==="
input int     InpAtrPeriod         = 14;
input double  InpDailyAtrMinMult   = 0.60;     // Skip if today's ATR < this * 20d avg (dead)
input double  InpDailyAtrMaxMult   = 2.00;     // Skip if today's ATR > this * 20d avg (chaos)
input int     InpSpreadMaxPoints   = 15;       // Strict for a scalper

input group   "=== Exit / trade management ==="
input double  InpAtrStopMult       = 1.0;      // SL = signal-bar extreme +/- this * ATR
input double  InpTpRMultiple       = 1.5;      // TP for runner = R * this
input bool    InpPartialAt1R       = true;     // Close half at 1R, move SL to BE
input double  InpPartialFraction   = 0.5;
input double  InpBEOffsetPts       = 5;        // BE offset in points (covers commission)
input bool    InpTrailRemainder    = true;
input double  InpTrailAtrMult      = 0.8;
input int     InpMaxBarsInTrade    = 24;       // Time-stop: close if still open after N bars

input group   "=== Anti-revenge cooldown ==="
input int     InpConsecLossPause   = 2;        // After this many losses in a row, pause
input int     InpPauseBars         = 12;       // Pause length, in chart bars

input group   "=== Execution ==="
input ulong   InpMagic             = 770055;
input int     InpSlippagePoints    = 10;
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
// Track entry-bar time per open ticket (for the bar time-stop)
struct EntryRec { ulong ticket; datetime barTime; };
EntryRec      entryRecs[];

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
   ArrayResize(entryRecs, 0);
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
         consecLosses = 0;
         PrintFormat("[VwapScalper] Cooldown until %s", TimeToString(pauseUntilBar));
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
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.hour < InpTradeStartHour || dt.hour >= InpTradeEndHour) return false;
   if(InpBlockFridayLate && dt.day_of_week == 5 && dt.hour >= 17) return false;
   // Saturday/Sunday safety (some brokers feed weekend ticks)
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

bool RegimeOK()
  {
   double atrD[21];
   if(CopyBuffer(hAtrDaily, 0, 0, 21, atrD) != 21) return true;
   double today = atrD[1];
   double sum = 0.0;
   for(int i = 1; i <= 20; i++) sum += atrD[i];
   double avg = sum / 20.0;
   if(avg <= 0.0) return true;
   double ratio = today / avg;
   if(ratio < InpDailyAtrMinMult) return false;
   if(ratio > InpDailyAtrMaxMult) return false;
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

datetime TodaySessionStart()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = InpSessionStartHour;
   dt.min  = InpSessionStartMin;
   dt.sec  = 0;
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

//=================== SESSION-ANCHORED VWAP ========================
// Typical price weighted by tick volume, computed from session start
// up to and including the last closed bar (index 1). Returns 0 on failure.
double ComputeSessionVwap()
  {
   datetime anchor = TodaySessionStart();
   if(anchor >= TimeCurrent()) return 0.0;

   int startBar = iBarShift(_Symbol, _Period, anchor, false);
   if(startBar < 1) return 0.0; // need at least one closed bar past anchor

   // We use bars [1..startBar] (inclusive), i.e. all closed bars since session start.
   int count = startBar; // number of closed bars
   if(count < 1) return 0.0;

   double highs[], lows[], closes[];
   long   vols[];
   if(CopyHigh (_Symbol, _Period, 1, count, highs)  != count) return 0.0;
   if(CopyLow  (_Symbol, _Period, 1, count, lows)   != count) return 0.0;
   if(CopyClose(_Symbol, _Period, 1, count, closes) != count) return 0.0;
   if(CopyTickVolume(_Symbol, _Period, 1, count, vols) != count) return 0.0;

   double pv = 0.0, vv = 0.0;
   for(int i = 0; i < count; i++)
     {
      double tp = (highs[i] + lows[i] + closes[i]) / 3.0;
      double v  = (double)vols[i];
      if(v <= 0.0) v = 1.0; // guard against brokers reporting zero volume
      pv += tp * v;
      vv += v;
     }
   if(vv <= 0.0) return 0.0;
   return pv / vv;
  }

//=================== SIGNAL =======================================
// Long setup:
//   1. HTF bias is up (fast EMA > slow EMA, optionally close > fast EMA).
//   2. Signal bar (index 1) traded down to VWAP (low within tol*ATR below VWAP).
//   3. Signal bar closed back above VWAP (rejection).
//   4. Lower wick of signal bar >= reject*ATR (real rejection, not a doji drift).
//   5. Signal bar body not absurdly large (we don't want to buy a runaway candle).
//   6. RSI within sane band (no extreme).
// Short setup is symmetric.
void EvaluateSignal()
  {
   double atrBuf[2];
   if(CopyBuffer(hAtr, 0, 0, 2, atrBuf) != 2) return;
   double atr = atrBuf[1];
   if(atr <= 0.0) return;

   double vwap = ComputeSessionVwap();
   if(vwap <= 0.0) return;

   double h1 = iHigh (_Symbol, _Period, 1);
   double l1 = iLow  (_Symbol, _Period, 1);
   double o1 = iOpen (_Symbol, _Period, 1);
   double c1 = iClose(_Symbol, _Period, 1);

   double bodyHi = MathMax(o1, c1);
   double bodyLo = MathMin(o1, c1);
   double body   = bodyHi - bodyLo;
   if(body > InpBodyMaxAtr * atr) return;

   double tol     = InpVwapTouchTolAtr * atr;
   double rejMin  = InpRejectionMinAtr * atr;

   bool touchedFromAbove = (l1 <= vwap + tol);             // bar dipped to/near VWAP
   bool closedAbove      = (c1 > vwap);                    // closed back above
   double lowerWick      = bodyLo - l1;                    // wick beneath the body
   bool longRejection    = touchedFromAbove && closedAbove && (lowerWick >= rejMin);

   bool touchedFromBelow = (h1 >= vwap - tol);
   bool closedBelow      = (c1 < vwap);
   double upperWick      = h1 - bodyHi;
   bool shortRejection   = touchedFromBelow && closedBelow && (upperWick >= rejMin);

   // RSI gate
   if(InpUseRsiFilter)
     {
      double rsiBuf[2];
      if(CopyBuffer(hRsi, 0, 0, 2, rsiBuf) != 2) return;
      double rsi = rsiBuf[1];
      if(longRejection  && (rsi < InpRsiLongMin  || rsi > InpRsiLongMax))  longRejection  = false;
      if(shortRejection && (rsi < InpRsiShortMin || rsi > InpRsiShortMax)) shortRejection = false;
     }

   // HTF bias
   int bias = 0;
   if(InpUseHtfBias)
     {
      double f[2], s[2];
      if(CopyBuffer(hHtfFast, 0, 0, 2, f) != 2) return;
      if(CopyBuffer(hHtfSlow, 0, 0, 2, s) != 2) return;
      if(f[1] > s[1]) bias = +1;
      else if(f[1] < s[1]) bias = -1;

      if(InpRequireHtfClose)
        {
         double htfClose = iClose(_Symbol, InpHtfTf, 1);
         if(bias == +1 && htfClose <= f[1]) bias = 0;
         if(bias == -1 && htfClose >= f[1]) bias = 0;
        }
     }
   else
     {
      bias = 0; // neutral allows both
     }

   if(InpAllowLong && longRejection && (bias >= 0 || !InpUseHtfBias))
     {
      if(InpUseHtfBias && bias != +1) return;
      OpenLong(atr, l1);
      return;
     }
   if(InpAllowShort && shortRejection && (bias <= 0 || !InpUseHtfBias))
     {
      if(InpUseHtfBias && bias != -1) return;
      OpenShort(atr, h1);
      return;
     }
  }

//=================== ORDER PLACEMENT ==============================
void OpenLong(double atr, double signalLow)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl  = NormalizeDouble(signalLow - InpAtrStopMult * atr, _Digits);
   double R   = ask - sl;
   if(R <= 0.0) return;
   double tp  = NormalizeDouble(ask + R * InpTpRMultiple, _Digits);

   double lot = CalcLotByRisk(R);
   if(lot <= 0.0)
     {
      PrintFormat("[%s] LONG skipped: lot below broker min (risk %.2f%%)", _Symbol, InpRiskPercent);
      return;
     }
   if(!RespectsStopLevel(sl, tp, ask)) return;

   if(trade.Buy(lot, _Symbol, ask, sl, tp, "VWAP L"))
     {
      dayTradeCount++;
      RecordEntry(trade.ResultDeal(), (datetime)iTime(_Symbol, _Period, 0));
     }
   else
      PrintFormat("Buy failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

void OpenShort(double atr, double signalHigh)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl  = NormalizeDouble(signalHigh + InpAtrStopMult * atr, _Digits);
   double R   = sl - bid;
   if(R <= 0.0) return;
   double tp  = NormalizeDouble(bid - R * InpTpRMultiple, _Digits);

   double lot = CalcLotByRisk(R);
   if(lot <= 0.0)
     {
      PrintFormat("[%s] SHORT skipped: lot below broker min", _Symbol);
      return;
     }
   if(!RespectsStopLevel(sl, tp, bid)) return;

   if(trade.Sell(lot, _Symbol, bid, sl, tp, "VWAP S"))
     {
      dayTradeCount++;
      RecordEntry(trade.ResultDeal(), (datetime)iTime(_Symbol, _Period, 0));
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

void RecordEntry(ulong dealTicket, datetime barTime)
  {
   // Find the position ticket spawned by this deal
   if(!HistoryDealSelect(dealTicket)) return;
   ulong posId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   if(posId == 0) return;
   int sz = ArraySize(entryRecs);
   ArrayResize(entryRecs, sz + 1);
   entryRecs[sz].ticket  = posId;
   entryRecs[sz].barTime = barTime;
  }

datetime EntryBarTime(ulong ticket)
  {
   for(int i = 0; i < ArraySize(entryRecs); i++)
      if(entryRecs[i].ticket == ticket) return entryRecs[i].barTime;
   return 0;
  }

void PruneTrackers()
  {
   int sz = ArraySize(partialDoneTickets);
   for(int i = sz - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(partialDoneTickets[i]))
        {
         for(int j = i; j < sz - 1; j++) partialDoneTickets[j] = partialDoneTickets[j+1];
         ArrayResize(partialDoneTickets, --sz);
        }
     }
   int sz2 = ArraySize(entryRecs);
   for(int i = sz2 - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(entryRecs[i].ticket))
        {
         for(int j = i; j < sz2 - 1; j++) entryRecs[j] = entryRecs[j+1];
         ArrayResize(entryRecs, --sz2);
        }
     }
  }

void ManageOpenTrades()
  {
   PruneTrackers();

   double atrBuf[1];
   if(CopyBuffer(hAtr, 0, 0, 1, atrBuf) != 1) return;
   double atr = atrBuf[0];
   if(atr <= 0.0) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double trailDist = InpTrailAtrMult * atr;
   int periodSec = PeriodSeconds(_Period);

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
      bool   didPartial = PartialAlreadyApplied(ticket);

      double R = (sl > 0.0) ? MathAbs(entry - sl) : 0.0;
      if(R <= 0.0) continue;

      // Time-stop: close if held past N bars
      datetime entryBar = EntryBarTime(ticket);
      if(InpMaxBarsInTrade > 0 && entryBar > 0)
        {
         long elapsed = (TimeCurrent() - entryBar) / periodSec;
         if(elapsed >= InpMaxBarsInTrade)
           {
            trade.PositionClose(ticket);
            continue;
           }
        }

      if(type == POSITION_TYPE_BUY)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit = bid - entry;

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
               double newSl = NormalizeDouble(entry + InpBEOffsetPts * point, _Digits);
               if(newSl > sl + point) trade.PositionModify(ticket, newSl, tp);
               MarkPartialApplied(ticket);
              }
           }

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
