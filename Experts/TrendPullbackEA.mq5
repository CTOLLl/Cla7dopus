//+------------------------------------------------------------------+
//|                                            TrendPullbackEA.mq5   |
//|                              Trend-following pullback EA (MQL5)  |
//+------------------------------------------------------------------+
#property copyright "TrendPullbackEA"
#property version   "1.00"
#property strict
#property description "Trend-following pullback EA. EMA200/ADX trend filter,"
#property description "EMA50 pullback entry confirmed by RSI cross, ATR-based"
#property description "stops and targets, R-multiple trailing. Risk-per-trade"
#property description "position sizing. Designed for H1+ on liquid instruments"
#property description "(XAUUSD, US30, NAS100, EURUSD, GBPUSD)."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- inputs: risk & money management
input group   "=== Risk management ==="
input double  InpRiskPercent       = 1.0;      // Risk per trade (% of equity)
input double  InpMaxDailyLossPct   = 4.0;      // Stop trading after daily loss (%)
input int     InpMaxOpenPositions  = 1;        // Max simultaneous positions for this EA
input double  InpMinLot            = 0.0;      // Min lot override (0 = broker default)

//--- inputs: strategy
input group   "=== Strategy ==="
input int     InpEmaTrendPeriod    = 200;      // Trend EMA period
input int     InpEmaPullbackPeriod = 50;       // Pullback EMA period
input int     InpAdxPeriod         = 14;       // ADX period
input double  InpAdxThreshold      = 20.0;     // Min ADX to consider trend valid
input int     InpRsiPeriod         = 14;       // RSI period
input double  InpRsiLongLevel      = 40.0;     // RSI cross-up level for long
input double  InpRsiShortLevel     = 60.0;     // RSI cross-down level for short
input int     InpAtrPeriod         = 14;       // ATR period
input double  InpAtrStopMult       = 1.5;      // Stop = ATR * this
input double  InpAtrTargetMult     = 3.0;      // Target = ATR * this (RR 1:2)
input double  InpPullbackAtrMax    = 1.5;      // Max distance price-EMA50 in ATR to call it "pullback"

//--- inputs: trailing
input group   "=== Trailing ==="
input bool    InpUseTrailing       = true;     // Enable trailing after 1R profit
input double  InpTrailStartR       = 1.0;      // Start trailing after this R-multiple
input double  InpTrailAtrMult      = 1.5;      // Trailing distance in ATR

//--- inputs: execution
input group   "=== Execution ==="
input ulong   InpMagic             = 770042;   // Magic number
input int     InpSlippagePoints    = 20;       // Max slippage (points)
input bool    InpAllowLong         = true;     // Allow long trades
input bool    InpAllowShort        = true;     // Allow short trades
input bool    InpTradeOnNewBarOnly = true;     // Only evaluate on a new bar

//--- globals
CTrade        trade;
CPositionInfo pos;
CSymbolInfo   sym;

int           hEmaTrend    = INVALID_HANDLE;
int           hEmaPullback = INVALID_HANDLE;
int           hAdx         = INVALID_HANDLE;
int           hRsi         = INVALID_HANDLE;
int           hAtr         = INVALID_HANDLE;

datetime      lastBarTime  = 0;
double        dayStartEquity = 0.0;
datetime      dayStartTime   = 0;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.SetAsyncMode(false);

   if(!sym.Name(_Symbol))
     {
      Print("Failed to bind symbol");
      return INIT_FAILED;
     }
   sym.RefreshRates();

   hEmaTrend    = iMA(_Symbol, _Period, InpEmaTrendPeriod,    0, MODE_EMA, PRICE_CLOSE);
   hEmaPullback = iMA(_Symbol, _Period, InpEmaPullbackPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hAdx         = iADX(_Symbol, _Period, InpAdxPeriod);
   hRsi         = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   hAtr         = iATR(_Symbol, _Period, InpAtrPeriod);

   if(hEmaTrend == INVALID_HANDLE || hEmaPullback == INVALID_HANDLE ||
      hAdx == INVALID_HANDLE || hRsi == INVALID_HANDLE || hAtr == INVALID_HANDLE)
     {
      Print("Indicator init failed");
      return INIT_FAILED;
     }

   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   dayStartTime   = TodayMidnight();

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hEmaTrend    != INVALID_HANDLE) IndicatorRelease(hEmaTrend);
   if(hEmaPullback != INVALID_HANDLE) IndicatorRelease(hEmaPullback);
   if(hAdx         != INVALID_HANDLE) IndicatorRelease(hAdx);
   if(hRsi         != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hAtr         != INVALID_HANDLE) IndicatorRelease(hAtr);
  }

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!sym.RefreshRates()) return;

   RolloverDailyEquity();

   // Manage trailing on every tick (cheap)
   if(InpUseTrailing) ManageTrailing();

   // Evaluate entries only on new bar (or every tick if user opts out)
   if(InpTradeOnNewBarOnly && !IsNewBar()) return;

   if(DailyLossExceeded())
     {
      // no new trades today
      return;
     }

   if(CountOpenPositions() >= InpMaxOpenPositions) return;

   EvaluateAndTrade();
  }

//+------------------------------------------------------------------+
//| Helpers: new bar / day rollover                                  |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = (datetime)iTime(_Symbol, _Period, 0);
   if(t == lastBarTime) return false;
   lastBarTime = t;
   return true;
  }

datetime TodayMidnight()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
  }

void RolloverDailyEquity()
  {
   datetime today = TodayMidnight();
   if(today != dayStartTime)
     {
      dayStartTime   = today;
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
     }
  }

bool DailyLossExceeded()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(dayStartEquity <= 0.0) return false;
   double lossPct = (dayStartEquity - eq) / dayStartEquity * 100.0;
   return (lossPct >= InpMaxDailyLossPct);
  }

//+------------------------------------------------------------------+
//| Position counting / lookup                                       |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int n = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol) continue;
      if(pos.Magic()  != InpMagic) continue;
      n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
//| Indicator reads                                                  |
//+------------------------------------------------------------------+
bool GetIndicators(double &emaTrend, double &emaPullback,
                   double &adx, double &rsiCurr, double &rsiPrev,
                   double &atr, double &closeCurr, double &closePrev)
  {
   double bufTrend[2], bufPull[2], bufAdx[2], bufRsi[3], bufAtr[2];
   if(CopyBuffer(hEmaTrend,    0, 0, 2, bufTrend) != 2) return false;
   if(CopyBuffer(hEmaPullback, 0, 0, 2, bufPull)  != 2) return false;
   if(CopyBuffer(hAdx,         0, 0, 2, bufAdx)   != 2) return false; // main ADX line
   if(CopyBuffer(hRsi,         0, 0, 3, bufRsi)   != 3) return false;
   if(CopyBuffer(hAtr,         0, 0, 2, bufAtr)   != 2) return false;

   // Use last closed bar (index 1) for evaluation
   emaTrend    = bufTrend[1];
   emaPullback = bufPull[1];
   adx         = bufAdx[1];
   rsiCurr     = bufRsi[1];
   rsiPrev     = bufRsi[2];
   atr         = bufAtr[1];

   closeCurr = iClose(_Symbol, _Period, 1);
   closePrev = iClose(_Symbol, _Period, 2);
   return (atr > 0.0);
  }

//+------------------------------------------------------------------+
//| Position sizing — risk % of equity, normalized to broker steps   |
//+------------------------------------------------------------------+
double CalcLotByRisk(double stopDistancePrice)
  {
   if(stopDistancePrice <= 0.0) return 0.0;

   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney   = equity * (InpRiskPercent / 100.0);

   double tickValue   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0) return 0.0;

   // Loss per 1.0 lot at the given stop distance
   double lossPerLot  = (stopDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0.0) return 0.0;

   double lot = riskMoney / lossPerLot;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(InpMinLot > 0.0) minLot = MathMax(minLot, InpMinLot);

   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(minLot, MathMin(maxLot, lot));

   // Final guard: if computed lot is below broker min, do not trade.
   if(lot < minLot - 1e-9) return 0.0;
   return NormalizeDouble(lot, 2);
  }

//+------------------------------------------------------------------+
//| Entry evaluation                                                 |
//+------------------------------------------------------------------+
void EvaluateAndTrade()
  {
   double emaT, emaP, adx, rsiC, rsiP, atr, cC, cP;
   if(!GetIndicators(emaT, emaP, adx, rsiC, rsiP, atr, cC, cP)) return;
   if(adx < InpAdxThreshold) return;

   bool trendUp   = (cC > emaT);
   bool trendDown = (cC < emaT);

   // Pullback proximity to EMA50 (in ATRs)
   double distAtr = MathAbs(cC - emaP) / atr;
   bool nearPullbackEma = (distAtr <= InpPullbackAtrMax);

   // RSI cross signals (on last closed bar)
   bool rsiCrossUp   = (rsiP <  InpRsiLongLevel  && rsiC >= InpRsiLongLevel);
   bool rsiCrossDown = (rsiP >  InpRsiShortLevel && rsiC <= InpRsiShortLevel);

   if(InpAllowLong && trendUp && nearPullbackEma && rsiCrossUp)
     {
      OpenLong(atr);
      return;
     }
   if(InpAllowShort && trendDown && nearPullbackEma && rsiCrossDown)
     {
      OpenShort(atr);
      return;
     }
  }

//+------------------------------------------------------------------+
//| Order placement                                                  |
//+------------------------------------------------------------------+
void OpenLong(double atr)
  {
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double stopDp = InpAtrStopMult   * atr;
   double tpDp   = InpAtrTargetMult * atr;
   double sl     = NormalizeDouble(ask - stopDp, _Digits);
   double tp     = NormalizeDouble(ask + tpDp,   _Digits);

   double lot = CalcLotByRisk(stopDp);
   if(lot <= 0.0)
     {
      Print("[", _Symbol, "] Skip LONG: computed lot below broker min (deposit too small for ", InpRiskPercent, "% risk).");
      return;
     }
   if(!RespectsStopLevel(sl, tp, ask, true)) return;

   if(!trade.Buy(lot, _Symbol, ask, sl, tp, "TrendPullback L"))
      Print("Buy failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
  }

void OpenShort(double atr)
  {
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stopDp = InpAtrStopMult   * atr;
   double tpDp   = InpAtrTargetMult * atr;
   double sl     = NormalizeDouble(bid + stopDp, _Digits);
   double tp     = NormalizeDouble(bid - tpDp,   _Digits);

   double lot = CalcLotByRisk(stopDp);
   if(lot <= 0.0)
     {
      Print("[", _Symbol, "] Skip SHORT: computed lot below broker min.");
      return;
     }
   if(!RespectsStopLevel(sl, tp, bid, false)) return;

   if(!trade.Sell(lot, _Symbol, bid, sl, tp, "TrendPullback S"))
      Print("Sell failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
  }

bool RespectsStopLevel(double sl, double tp, double price, bool isLong)
  {
   long stopsLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist     = stopsLevelPts * point;
   if(minDist <= 0.0) return true;

   double slDist = MathAbs(price - sl);
   double tpDist = MathAbs(price - tp);
   if(slDist < minDist || tpDist < minDist)
     {
      Print("Skip: SL/TP too close to price (broker stops level). minDist=", minDist);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Trailing stop: starts after 1R profit, trails at InpTrailAtrMult |
//+------------------------------------------------------------------+
void ManageTrailing()
  {
   double atrBuf[1];
   if(CopyBuffer(hAtr, 0, 0, 1, atrBuf) != 1) return;
   double atr = atrBuf[0];
   if(atr <= 0.0) return;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol() != _Symbol) continue;
      if(pos.Magic()  != InpMagic) continue;

      double entry  = pos.PriceOpen();
      double sl     = pos.StopLoss();
      double tp     = pos.TakeProfit();
      long   type   = pos.PositionType();
      double risk   = InpAtrStopMult * atr; // approx initial R
      double trail  = InpTrailAtrMult * atr;

      if(type == POSITION_TYPE_BUY)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit = bid - entry;
         if(profit >= InpTrailStartR * risk)
           {
            double newSl = NormalizeDouble(bid - trail, _Digits);
            if(newSl > sl + (_Point * 2))
               trade.PositionModify(pos.Ticket(), newSl, tp);
           }
        }
      else if(type == POSITION_TYPE_SELL)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit = entry - ask;
         if(profit >= InpTrailStartR * risk)
           {
            double newSl = NormalizeDouble(ask + trail, _Digits);
            if(sl == 0.0 || newSl < sl - (_Point * 2))
               trade.PositionModify(pos.Ticket(), newSl, tp);
           }
        }
     }
  }
//+------------------------------------------------------------------+
