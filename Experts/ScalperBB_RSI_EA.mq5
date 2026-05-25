//+------------------------------------------------------------------+
//|                                         ScalperBB_RSI_EA.mq5     |
//|         High-frequency mean-reversion scalper (Bollinger + RSI)  |
//+------------------------------------------------------------------+
#property copyright "ScalperBB_RSI_EA"
#property version   "1.00"
#property strict
#property description "Mean-reversion scalper. Bollinger Bands deviation entry"
#property description "with RSI confirmation, ATR-based stop and middle-band /"
#property description "RR-based exit. Designed for M5-M15 on low-spread pairs."
#property description "Generates many trades per week. NOT a get-rich scheme."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- inputs: risk
input group   "=== Risk management ==="
input double  InpRiskPercent       = 0.5;      // Risk per trade (% of equity)
input double  InpMaxDailyLossPct   = 3.0;      // Daily loss cap (%) -> stop trading
input int     InpMaxOpenPositions  = 2;        // Max simultaneous EA positions
input int     InpMaxTradesPerDay   = 30;       // Hard cap on daily trade count
input double  InpMinLot            = 0.0;      // Min lot override (0 = broker default)

//--- inputs: Bollinger / RSI
input group   "=== Entry signal ==="
input int     InpBBPeriod          = 20;       // Bollinger period
input double  InpBBDeviation       = 2.0;      // Bollinger std-dev multiplier
input int     InpRsiPeriod         = 14;       // RSI period
input double  InpRsiBuyLevel       = 30.0;     // Buy when RSI <= this on signal bar
input double  InpRsiSellLevel      = 70.0;     // Sell when RSI >= this on signal bar
input bool    InpRequireBandPierce = true;     // Require bar low/high to pierce the band

//--- inputs: exit / SL-TP
input group   "=== Exit ==="
input int     InpAtrPeriod         = 14;       // ATR period
input double  InpAtrStopMult       = 1.5;      // SL distance = ATR * this
input bool    InpExitAtMiddleBand  = true;     // Take profit at BB middle (else fixed RR)
input double  InpRRTarget          = 1.0;      // TP = SL * this (used if not BB-middle)
input int     InpMaxBarsInTrade    = 20;       // Force close after N bars (0 = disabled)

//--- inputs: trend filter (optional, off by default => more trades)
input group   "=== Optional trend filter (HTF) ==="
input bool    InpUseTrendFilter    = false;    // Only trade in direction of higher-TF EMA
input ENUM_TIMEFRAMES InpTrendTf   = PERIOD_H1; // Higher timeframe
input int     InpTrendEmaPeriod    = 50;       // EMA period on higher TF

//--- inputs: session filter
input group   "=== Session filter (server time) ==="
input bool    InpUseSessionFilter  = true;     // Restrict trading hours
input int     InpStartHour         = 7;        // Trade from hour (server time)
input int     InpEndHour           = 20;       // Trade until hour
input bool    InpBlockFridayLate   = true;     // No new trades Fri after 18:00

//--- inputs: execution
input group   "=== Execution ==="
input ulong   InpMagic             = 770043;   // Magic number
input int     InpSlippagePoints    = 20;       // Max slippage (points)
input bool    InpAllowLong         = true;
input bool    InpAllowShort        = true;
input bool    InpOneTradePerBar    = true;     // No re-entry on same bar

//--- globals
CTrade        trade;
CPositionInfo pos;
CSymbolInfo   sym;

int           hBB    = INVALID_HANDLE;
int           hRsi   = INVALID_HANDLE;
int           hAtr   = INVALID_HANDLE;
int           hTrend = INVALID_HANDLE; // higher-tf EMA

datetime      lastSignalBar = 0;
datetime      dayStartTime  = 0;
double        dayStartEquity = 0.0;
int           dayTradeCount  = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.SetAsyncMode(false);

   if(!sym.Name(_Symbol)) return INIT_FAILED;
   sym.RefreshRates();

   hBB    = iBands(_Symbol, _Period, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   hRsi   = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   hAtr   = iATR(_Symbol, _Period, InpAtrPeriod);
   if(InpUseTrendFilter)
      hTrend = iMA(_Symbol, InpTrendTf, InpTrendEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(hBB == INVALID_HANDLE || hRsi == INVALID_HANDLE || hAtr == INVALID_HANDLE)
     {
      Print("Indicator init failed");
      return INIT_FAILED;
     }
   if(InpUseTrendFilter && hTrend == INVALID_HANDLE)
     {
      Print("Trend filter indicator init failed");
      return INIT_FAILED;
     }

   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   dayStartTime   = TodayMidnight();
   dayTradeCount  = 0;
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hBB    != INVALID_HANDLE) IndicatorRelease(hBB);
   if(hRsi   != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hAtr   != INVALID_HANDLE) IndicatorRelease(hAtr);
   if(hTrend != INVALID_HANDLE) IndicatorRelease(hTrend);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!sym.RefreshRates()) return;
   RolloverDay();

   // Time-based exit applies every tick
   if(InpMaxBarsInTrade > 0) CloseStaleTrades();

   if(IsNewBar())
     {
      if(!DailyLossExceeded() && dayTradeCount < InpMaxTradesPerDay &&
         CountOpenPositions() < InpMaxOpenPositions &&
         WithinSession())
        {
         EvaluateAndTrade();
        }
     }
  }

//+------------------------------------------------------------------+
//| Day / session helpers                                            |
//+------------------------------------------------------------------+
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

bool DailyLossExceeded()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(dayStartEquity <= 0.0) return false;
   double lossPct = (dayStartEquity - eq) / dayStartEquity * 100.0;
   return (lossPct >= InpMaxDailyLossPct);
  }

bool WithinSession()
  {
   if(!InpUseSessionFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return false;
   if(InpBlockFridayLate && dt.day_of_week == 5 && dt.hour >= 18) return false;
   return true;
  }

bool IsNewBar()
  {
   datetime t = (datetime)iTime(_Symbol, _Period, 0);
   static datetime prev = 0;
   if(t == prev) return false;
   prev = t;
   return true;
  }

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Time-based exit (force-close trades held too long)               |
//+------------------------------------------------------------------+
void CloseStaleTrades()
  {
   int barSecs = PeriodSeconds(_Period);
   datetime now = TimeCurrent();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol || pos.Magic() != InpMagic) continue;
      datetime opened = (datetime)pos.Time();
      if(opened == 0) continue;
      int bars = (int)((now - opened) / barSecs);
      if(bars >= InpMaxBarsInTrade)
         trade.PositionClose(pos.Ticket());
     }
  }

//+------------------------------------------------------------------+
//| Position sizing                                                  |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Indicator reads (signal bar = last closed = index 1)             |
//+------------------------------------------------------------------+
bool ReadSignals(double &bbUpper, double &bbLower, double &bbMiddle,
                 double &rsi, double &atr,
                 double &high1, double &low1, double &close1)
  {
   double upB[2], loB[2], miB[2], rB[2], aB[2];
   if(CopyBuffer(hBB, 1, 0, 2, upB) != 2) return false;  // UPPER_BAND
   if(CopyBuffer(hBB, 2, 0, 2, loB) != 2) return false;  // LOWER_BAND
   if(CopyBuffer(hBB, 0, 0, 2, miB) != 2) return false;  // MAIN (middle)
   if(CopyBuffer(hRsi, 0, 0, 2, rB) != 2) return false;
   if(CopyBuffer(hAtr, 0, 0, 2, aB) != 2) return false;

   bbUpper = upB[1]; bbLower = loB[1]; bbMiddle = miB[1];
   rsi     = rB[1];
   atr     = aB[1];
   high1   = iHigh(_Symbol, _Period, 1);
   low1    = iLow(_Symbol, _Period, 1);
   close1  = iClose(_Symbol, _Period, 1);
   return (atr > 0.0);
  }

int TrendDirection()
  {
   if(!InpUseTrendFilter) return 0; // any
   double buf[2];
   if(CopyBuffer(hTrend, 0, 0, 2, buf) != 2) return 0;
   double ema = buf[1];
   double price = iClose(_Symbol, InpTrendTf, 1);
   if(price > ema) return +1;
   if(price < ema) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
void EvaluateAndTrade()
  {
   if(InpOneTradePerBar)
     {
      datetime barT = (datetime)iTime(_Symbol, _Period, 0);
      if(barT == lastSignalBar) return;
     }

   double up, lo, mi, rsi, atr, h1, l1, c1;
   if(!ReadSignals(up, lo, mi, rsi, atr, h1, l1, c1)) return;

   int dir = TrendDirection();

   bool longSig  = false, shortSig = false;
   if(InpAllowLong && (dir >= 0))
     {
      bool pierce = !InpRequireBandPierce || (l1 <= lo);
      longSig = pierce && (c1 < mi) && (rsi <= InpRsiBuyLevel);
     }
   if(InpAllowShort && (dir <= 0))
     {
      bool pierce = !InpRequireBandPierce || (h1 >= up);
      shortSig = pierce && (c1 > mi) && (rsi >= InpRsiSellLevel);
     }

   if(longSig)
     {
      OpenLong(atr, mi);
      lastSignalBar = (datetime)iTime(_Symbol, _Period, 0);
     }
   else if(shortSig)
     {
      OpenShort(atr, mi);
      lastSignalBar = (datetime)iTime(_Symbol, _Period, 0);
     }
  }

//+------------------------------------------------------------------+
void OpenLong(double atr, double bbMiddle)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double stopDp = InpAtrStopMult * atr;
   double sl = NormalizeDouble(ask - stopDp, _Digits);
   double tp;
   if(InpExitAtMiddleBand && bbMiddle > ask)
      tp = NormalizeDouble(bbMiddle, _Digits);
   else
      tp = NormalizeDouble(ask + stopDp * InpRRTarget, _Digits);

   double lot = CalcLotByRisk(stopDp);
   if(lot <= 0.0)
     {
      Print("[", _Symbol, "] LONG skipped: lot below broker min for ", InpRiskPercent, "% risk");
      return;
     }
   if(!RespectsStopLevel(sl, tp, ask)) return;

   if(trade.Buy(lot, _Symbol, ask, sl, tp, "BB-RSI L"))
      dayTradeCount++;
   else
      Print("Buy failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
  }

void OpenShort(double atr, double bbMiddle)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stopDp = InpAtrStopMult * atr;
   double sl = NormalizeDouble(bid + stopDp, _Digits);
   double tp;
   if(InpExitAtMiddleBand && bbMiddle < bid)
      tp = NormalizeDouble(bbMiddle, _Digits);
   else
      tp = NormalizeDouble(bid - stopDp * InpRRTarget, _Digits);

   double lot = CalcLotByRisk(stopDp);
   if(lot <= 0.0)
     {
      Print("[", _Symbol, "] SHORT skipped: lot below broker min");
      return;
     }
   if(!RespectsStopLevel(sl, tp, bid)) return;

   if(trade.Sell(lot, _Symbol, bid, sl, tp, "BB-RSI S"))
      dayTradeCount++;
   else
      Print("Sell failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
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
//+------------------------------------------------------------------+
