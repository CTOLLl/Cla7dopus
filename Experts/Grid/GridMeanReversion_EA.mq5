//+------------------------------------------------------------------+
//|                                       GridMeanReversion_EA.mq5   |
//|        Mean-reversion grid Expert Advisor with adaptive spacing, |
//|        regime filter and worst-case-driven position sizing.      |
//+------------------------------------------------------------------+
#property copyright   "Tembo Algotrading"
#property link        ""
#property version     "1.00"
#property description "Mean-reversion grid EA: Bollinger + z-score entry,"
#property description "ADX regime filter, ATR-adaptive step,"
#property description "worst-case lot sizing, basket TP/SL, equity halt."
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>
#include <Trade/AccountInfo.mqh>

//---------------------------------- Enums -----------------------------------
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

enum ENUM_SIZING_MODE
  {
   SIZING_FIXED         = 0, // Fixed first lot
   SIZING_RISK_WORSTCASE = 1 // Auto: worst-case basket loss = RiskPct
  };

//---------------------------------- Inputs ----------------------------------
input group "=== General ==="
input long              InpMagic            = 20260601;     // Magic number
input string            InpComment          = "GridMR";     // Order comment
input ENUM_DIR_MODE     InpDirectionMode    = DIR_BOTH;     // Direction mode

input group "=== Mean-reversion signal ==="
input ENUM_TIMEFRAMES   InpSignalTF         = PERIOD_M15;   // Signal timeframe
input int               InpBBPeriod         = 20;           // Bollinger period
input double            InpBBDeviations     = 2.0;          // Bollinger deviations
input double            InpZScoreEntry      = 2.0;          // Min |z-score| from mid-band to enter
input int               InpRsiPeriod        = 14;           // RSI period (confirmation)
input double            InpRsiOversold      = 30.0;         // RSI oversold (buy)
input double            InpRsiOverbought    = 70.0;         // RSI overbought (sell)
input bool              InpUseRsiConfirm    = true;         // Require RSI confirmation
input int               InpAdxPeriod        = 14;           // ADX period (regime filter)
input double            InpAdxMaxForEntry   = 28.0;         // Skip first entry if ADX above
input bool              InpUseAdxFilter     = true;         // Use ADX regime filter

input group "=== Grid ==="
input ENUM_STEP_MODE    InpStepMode         = STEP_ATR;     // Step mode
input int               InpFixedStepPoints  = 300;          // Fixed step (points)
input ENUM_TIMEFRAMES   InpAtrTF            = PERIOD_M15;   // ATR timeframe
input int               InpAtrPeriod        = 14;           // ATR period
input double            InpAtrStepMult      = 1.2;          // ATR step multiplier
input double            InpStepGrowth       = 1.10;         // Step grows by this factor per level
input int               InpMaxGridLevels    = 7;            // Max grid levels per direction
input double            InpLotMultiplier    = 1.35;         // Lot multiplier per level (>=1.0)
input ENUM_SIZING_MODE  InpSizingMode       = SIZING_RISK_WORSTCASE; // First-lot sizing mode
input double            InpFirstLot         = 0.01;         // First lot if SIZING_FIXED
input double            InpRiskPerBasketPct = 1.5;          // Worst-case basket loss as % of equity

input group "=== Basket exits ==="
input double            InpBasketTpMoney    = 0.0;          // Basket TP money (0 = use pct)
input double            InpBasketTpPct      = 0.6;          // Basket TP as % of equity
input double            InpBasketSlPct      = 5.0;          // Hard basket SL as % of equity
input bool              InpUseTrailingBE    = true;         // Arm breakeven after TP/2
input double            InpBreakevenPct     = 0.25;         // Lock-in profit % of equity at BE
input bool              InpClosePartialOnTP = false;        // Close worst-priced position on partial TP
input double            InpPartialTpPct     = 0.45;         // Partial TP threshold (% of basket TP)

input group "=== Risk & filters ==="
input double            InpMaxSpreadPoints  = 50;           // Max spread (points)
input double            InpMaxLotCap        = 5.0;          // Hard cap on single order lot
input double            InpMaxTotalLots     = 50.0;         // Hard cap on aggregate open lots
input double            InpDailyDDLimitPct  = 4.0;          // Daily DD limit % (halt)
input double            InpMaxEquityDDPct   = 20.0;         // Equity DD % from peak (halt)
input double            InpMarginUsageMaxPct= 50.0;         // Max used-margin / equity %
input bool              InpTradeFridayClose = false;        // Allow trading near Friday close
input int               InpStartHour        = 0;            // Trading start hour (server)
input int               InpEndHour          = 24;           // Trading end hour (server) [0..24]
input int               InpSlippagePoints   = 20;           // Allowed slippage (points)
input int               InpCooldownSeconds  = 30;           // Cooldown between grid adds (sec)

//---------------------------------- Globals ---------------------------------
CTrade         Trade;
CPositionInfo  Pos;
CSymbolInfo    Sym;
CAccountInfo   Acc;

int            g_hBB     = INVALID_HANDLE;
int            g_hRsi    = INVALID_HANDLE;
int            g_hAdx    = INVALID_HANDLE;
int            g_hAtr    = INVALID_HANDLE;

double         g_equityPeak       = 0.0;
double         g_dayStartEquity   = 0.0;
datetime       g_dayStartTime     = 0;
bool           g_haltedByRisk     = false;
datetime       g_lastAddTimeLong  = 0;
datetime       g_lastAddTimeShort = 0;

struct GridState
  {
   double  lastEntryPrice;     // last filled price for this direction
   int     levels;             // number of opened levels in this direction
   double  basketStartEquity;  // equity when basket opened
   bool    beArmed;            // breakeven armed
   bool    partialDone;        // partial TP already executed for this basket
   double  firstLot;           // first lot used in this basket (locked at open)
  };
GridState g_long, g_short;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double step   = Sym.LotsStep();
   double minLot = Sym.LotsMin();
   double maxLot = Sym.LotsMax();
   if(step <= 0.0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   if(InpMaxLotCap > 0 && lot > InpMaxLotCap) lot = InpMaxLotCap;
   int digits = (step >= 0.1) ? 1 : 2;
   return NormalizeDouble(lot, digits);
  }

double PointsToPrice(double points) { return points * Sym.Point(); }

double SpreadPoints()
  {
   return (Sym.Ask() - Sym.Bid()) / Sym.Point();
  }

bool IsWithinTradingHours()
  {
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   if(t.hour < InpStartHour || t.hour >= InpEndHour) return false;
   if(!InpTradeFridayClose && t.day_of_week == 5 && t.hour >= 21) return false;
   if(t.day_of_week == 0 || t.day_of_week == 6) return false; // weekend safety
   return true;
  }

void ResetGridState(GridState &gs)
  {
   gs.lastEntryPrice    = 0.0;
   gs.levels            = 0;
   gs.basketStartEquity = 0.0;
   gs.beArmed           = false;
   gs.partialDone       = false;
   gs.firstLot          = 0.0;
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
//| Grid step (price units), supports per-level growth               |
//+------------------------------------------------------------------+
double BaseStepPrice()
  {
   if(InpStepMode == STEP_FIXED)
      return PointsToPrice(InpFixedStepPoints);

   double atr[1];
   if(CopyBuffer(g_hAtr, 0, 0, 1, atr) != 1)
      return PointsToPrice(InpFixedStepPoints);
   double step = atr[0] * InpAtrStepMult;
   long stops = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStep = PointsToPrice(MathMax(10, (double)stops * 2.0));
   if(step < minStep) step = minStep;
   return step;
  }

double LevelStepPrice(int currentLevels)
  {
   double s = BaseStepPrice();
   double g = MathMax(1.0, InpStepGrowth);
   return s * MathPow(g, MathMax(0, currentLevels - 1));
  }

//+------------------------------------------------------------------+
//| First-lot sizing: worst-case basket loss bounded by RiskPct      |
//+------------------------------------------------------------------+
double ComputeFirstLot()
  {
   if(InpSizingMode == SIZING_FIXED)
      return NormalizeLot(InpFirstLot);

   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxLossUSD = equity * InpRiskPerBasketPct / 100.0;
   double base       = BaseStepPrice();
   if(base <= 0) return NormalizeLot(InpFirstLot);

   double tickValue = Sym.TickValue();
   double tickSize  = Sym.TickSize();
   if(tickSize <= 0 || tickValue <= 0) return NormalizeLot(InpFirstLot);

   int    N = InpMaxGridLevels;
   double m = MathMax(1.0, InpLotMultiplier);
   double g = MathMax(1.0, InpStepGrowth);

   // Worst case: price runs full grid against us, all levels filled.
   // Build absolute distance to each entry level k from current price (level 0):
   //   d_k = base * (g^0 + g^1 + ... + g^(k-1))   (k>=1, d_0 = 0)
   // Final adverse price = entry of last level + base * g^(N-1) (assume 1 more step worst-case),
   // approximated by treating the "stop" point as right after the N-th level fills.
   double cumDist[64];
   if(N > 64) N = 64;
   cumDist[0] = 0.0;
   for(int k=1; k<N; ++k)
      cumDist[k] = cumDist[k-1] + base * MathPow(g, k-1);
   double finalAdverse = cumDist[N-1] + base * MathPow(g, MathMax(0, N-1));

   // Sum loss for each level: lots(k) * (finalAdverse - cumDist[k]) / tickSize * tickValue
   double worstPerLot0 = 0.0;
   for(int k=0; k<N; ++k)
     {
      double lotRel = MathPow(m, k);                  // relative to lot0
      double dist   = finalAdverse - cumDist[k];      // price distance still to go after fill
      if(dist < 0) dist = 0;
      worstPerLot0 += lotRel * (dist / tickSize) * tickValue;
     }
   if(worstPerLot0 <= 0) return NormalizeLot(InpFirstLot);

   double lot0 = maxLossUSD / worstPerLot0;
   double normalized = NormalizeLot(MathMax(lot0, Sym.LotsMin()));
   return normalized;
  }

//+------------------------------------------------------------------+
//| Indicator reads                                                  |
//+------------------------------------------------------------------+
bool ReadBB(double &mid, double &upper, double &lower)
  {
   double bMid[1], bUp[1], bLo[1];
   if(CopyBuffer(g_hBB, 0, 1, 1, bMid)  != 1) return false;
   if(CopyBuffer(g_hBB, 1, 1, 1, bUp)   != 1) return false;
   if(CopyBuffer(g_hBB, 2, 1, 1, bLo)   != 1) return false;
   mid = bMid[0]; upper = bUp[0]; lower = bLo[0];
   return true;
  }

bool ReadRsi(double &rsi)
  {
   double v[1];
   if(CopyBuffer(g_hRsi, 0, 1, 1, v) != 1) return false;
   rsi = v[0];
   return true;
  }

bool ReadAdx(double &adx)
  {
   double v[1];
   if(CopyBuffer(g_hAdx, 0, 1, 1, v) != 1) return false;
   adx = v[0];
   return true;
  }

//+------------------------------------------------------------------+
//| Mean-reversion signals                                           |
//+------------------------------------------------------------------+
// Buy: price has plunged below lower BB with sufficient z-score and RSI oversold,
// while ADX shows market is ranging (not in strong trend).
bool MRSignalBuy()
  {
   double mid, up, lo, rsi=0, adx=0;
   if(!ReadBB(mid, up, lo)) return false;

   double close = iClose(_Symbol, InpSignalTF, 1);
   double bandHalf = (up - mid);
   if(bandHalf <= 0) return false;
   double z = (mid - close) / (bandHalf / InpBBDeviations); // positive when below mid
   if(close > lo) return false;       // require touch/break of lower band
   if(z < InpZScoreEntry) return false;

   if(InpUseRsiConfirm)
     {
      if(!ReadRsi(rsi)) return false;
      if(rsi > InpRsiOversold) return false;
     }
   if(InpUseAdxFilter)
     {
      if(!ReadAdx(adx)) return false;
      if(adx > InpAdxMaxForEntry) return false;
     }
   return true;
  }

bool MRSignalSell()
  {
   double mid, up, lo, rsi=0, adx=0;
   if(!ReadBB(mid, up, lo)) return false;

   double close = iClose(_Symbol, InpSignalTF, 1);
   double bandHalf = (up - mid);
   if(bandHalf <= 0) return false;
   double z = (close - mid) / (bandHalf / InpBBDeviations);
   if(close < up) return false;       // require touch/break of upper band
   if(z < InpZScoreEntry) return false;

   if(InpUseRsiConfirm)
     {
      if(!ReadRsi(rsi)) return false;
      if(rsi < InpRsiOverbought) return false;
     }
   if(InpUseAdxFilter)
     {
      if(!ReadAdx(adx)) return false;
      if(adx > InpAdxMaxForEntry) return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Order placement                                                  |
//+------------------------------------------------------------------+
bool OpenMarket(ENUM_POSITION_TYPE dir, double lot)
  {
   Sym.RefreshRates();
   if(SpreadPoints() > InpMaxSpreadPoints)
     {
      PrintFormat("Skip open: spread %.1f > limit %.1f", SpreadPoints(), InpMaxSpreadPoints);
      return false;
     }

   // Margin guard
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double usedMargin = AccountInfoDouble(ACCOUNT_MARGIN);
   if(equity > 0 && (usedMargin / equity * 100.0) >= InpMarginUsageMaxPct)
     {
      PrintFormat("Skip open: margin usage %.1f%% >= cap %.1f%%",
                  usedMargin / equity * 100.0, InpMarginUsageMaxPct);
      return false;
     }
   double price = (dir == POSITION_TYPE_BUY) ? Sym.Ask() : Sym.Bid();
   double marginReq = 0.0;
   ENUM_ORDER_TYPE otype = (dir == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcMargin(otype, _Symbol, lot, price, marginReq))
     {
      if(marginReq > freeMargin * 0.95)
        {
         PrintFormat("Skip open: required margin %.2f > 95%% of free %.2f", marginReq, freeMargin);
         return false;
        }
     }

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

// Close the single worst-priced (largest loss) position in a direction
void CloseWorstInDirection(ENUM_POSITION_TYPE dir)
  {
   ulong worstTicket = 0;
   double worstPL = DBL_MAX;
   for(int i = PositionsTotal()-1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      if(Pos.Magic()  != InpMagic) continue;
      if(Pos.PositionType() != dir) continue;
      double pl = Pos.Profit() + Pos.Swap() + Pos.Commission();
      if(pl < worstPL) { worstPL = pl; worstTicket = Pos.Ticket(); }
     }
   if(worstTicket != 0)
      Trade.PositionClose(worstTicket, (ulong)InpSlippagePoints);
  }

//+------------------------------------------------------------------+
//| Risk gate                                                        |
//+------------------------------------------------------------------+
void UpdateRiskMetrics()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_equityPeak) g_equityPeak = equity;

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
            PrintFormat("HALT: equity DD %.2f%% >= %.2f%%", ddPct, InpMaxEquityDDPct);
         g_haltedByRisk = true;
        }
     }

   if(g_dayStartEquity > 0)
     {
      double ddDay = (g_dayStartEquity - equity) / g_dayStartEquity * 100.0;
      if(ddDay >= InpDailyDDLimitPct)
        {
         if(!g_haltedByRisk)
            PrintFormat("HALT: daily DD %.2f%% >= %.2f%%", ddDay, InpDailyDDLimitPct);
         g_haltedByRisk = true;
        }
     }
  }

//+------------------------------------------------------------------+
//| Direction management: first entry & grid adds                    |
//+------------------------------------------------------------------+
void ManageDirection(ENUM_POSITION_TYPE dir,
                     int cnt, double lots,
                     double highPrice, double lowPrice,
                     GridState &gs)
  {
   if(g_haltedByRisk) return;
   if(lots >= InpMaxTotalLots) return;

   if(cnt == 0)
     {
      if(dir == POSITION_TYPE_BUY)
        {
         if(InpDirectionMode == DIR_SHORT) return;
         if(!MRSignalBuy()) return;
        }
      else
        {
         if(InpDirectionMode == DIR_LONG) return;
         if(!MRSignalSell()) return;
        }

      double lot = ComputeFirstLot();
      if(OpenMarket(dir, lot))
        {
         Sym.RefreshRates();
         gs.lastEntryPrice    = (dir == POSITION_TYPE_BUY) ? Sym.Ask() : Sym.Bid();
         gs.levels            = 1;
         gs.basketStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         gs.beArmed           = false;
         gs.partialDone       = false;
         gs.firstLot          = lot;
         if(dir == POSITION_TYPE_BUY) g_lastAddTimeLong  = TimeCurrent();
         else                         g_lastAddTimeShort = TimeCurrent();
        }
      return;
     }

   if(cnt >= InpMaxGridLevels) return;

   // Cooldown between consecutive adds
   datetime now = TimeCurrent();
   datetime lastAdd = (dir == POSITION_TYPE_BUY) ? g_lastAddTimeLong : g_lastAddTimeShort;
   if((int)(now - lastAdd) < InpCooldownSeconds) return;

   double step = LevelStepPrice(cnt);
   if(step <= 0) return;

   Sym.RefreshRates();
   double refPrice;
   bool   triggers;
   if(dir == POSITION_TYPE_BUY)
     {
      refPrice = (lowPrice > 0 ? lowPrice : gs.lastEntryPrice);
      triggers = (Sym.Ask() <= refPrice - step);
     }
   else
     {
      refPrice = (highPrice > 0 ? highPrice : gs.lastEntryPrice);
      triggers = (Sym.Bid() >= refPrice + step);
     }
   if(!triggers) return;

   double baseFirstLot = (gs.firstLot > 0.0) ? gs.firstLot : ComputeFirstLot();
   double nextLot      = NormalizeLot(baseFirstLot * MathPow(MathMax(1.0, InpLotMultiplier), cnt));
   if(lots + nextLot > InpMaxTotalLots) return;

   if(OpenMarket(dir, nextLot))
     {
      Sym.RefreshRates();
      gs.lastEntryPrice = (dir == POSITION_TYPE_BUY) ? Sym.Ask() : Sym.Bid();
      gs.levels         = cnt + 1;
      if(dir == POSITION_TYPE_BUY) g_lastAddTimeLong  = now;
      else                         g_lastAddTimeShort = now;
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
   double tpMoney = (InpBasketTpMoney > 0.0) ? InpBasketTpMoney
                                             : equity * InpBasketTpPct / 100.0;
   double slMoney = equity * InpBasketSlPct / 100.0;

   if(slMoney > 0 && floating <= -slMoney)
     {
      PrintFormat("Basket hard SL: floating=%.2f limit=%.2f", floating, -slMoney);
      CloseAll();
      return;
     }

   if(tpMoney > 0 && floating >= tpMoney)
     {
      PrintFormat("Basket TP: floating=%.2f target=%.2f", floating, tpMoney);
      CloseAll();
      return;
     }

   // Partial close (worst loser) at a softer profit threshold — helps unwind grid safely.
   if(InpClosePartialOnTP && tpMoney > 0)
     {
      double partialTarget = tpMoney * InpPartialTpPct;
      if(longCnt >= 2 && !g_long.partialDone && floating >= partialTarget)
        {
         CloseWorstInDirection(POSITION_TYPE_BUY);
         g_long.partialDone = true;
        }
      if(shortCnt >= 2 && !g_short.partialDone && floating >= partialTarget)
        {
         CloseWorstInDirection(POSITION_TYPE_SELL);
         g_short.partialDone = true;
        }
     }

   // Breakeven trail: arm after TP/2 profit, lock-in at BreakevenPct.
   if(InpUseTrailingBE && tpMoney > 0)
     {
      double beHalf = tpMoney * 0.5;
      double beLock = equity * InpBreakevenPct / 100.0;

      if(!g_long.beArmed && !g_short.beArmed && floating >= beHalf)
        {
         g_long.beArmed  = (longCnt  > 0);
         g_short.beArmed = (shortCnt > 0);
        }
      if((g_long.beArmed || g_short.beArmed) && floating > 0 && floating <= beLock)
        {
         PrintFormat("Basket BE lock: floating=%.2f lock=%.2f", floating, beLock);
         CloseAll();
         return;
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

   g_hBB  = iBands(_Symbol, InpSignalTF, InpBBPeriod, 0, InpBBDeviations, PRICE_CLOSE);
   if(g_hBB == INVALID_HANDLE) { Print("BB handle invalid"); return INIT_FAILED; }
   g_hRsi = iRSI(_Symbol, InpSignalTF, InpRsiPeriod, PRICE_CLOSE);
   if(g_hRsi == INVALID_HANDLE) { Print("RSI handle invalid"); return INIT_FAILED; }
   g_hAdx = iADX(_Symbol, InpSignalTF, InpAdxPeriod);
   if(g_hAdx == INVALID_HANDLE) { Print("ADX handle invalid"); return INIT_FAILED; }
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
      Print("WARNING: lot multiplier < 1.0 disables martingale recovery");
   if(InpMaxGridLevels < 1)
     { Print("InpMaxGridLevels must be >= 1"); return INIT_PARAMETERS_INCORRECT; }
   if(InpRiskPerBasketPct <= 0.0 && InpSizingMode == SIZING_RISK_WORSTCASE)
     { Print("InpRiskPerBasketPct must be > 0 in risk-sizing mode"); return INIT_PARAMETERS_INCORRECT; }

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_hBB  != INVALID_HANDLE) IndicatorRelease(g_hBB);
   if(g_hRsi != INVALID_HANDLE) IndicatorRelease(g_hRsi);
   if(g_hAdx != INVALID_HANDLE) IndicatorRelease(g_hAdx);
   if(g_hAtr != INVALID_HANDLE) IndicatorRelease(g_hAtr);
  }

void OnTick()
  {
   if(!Sym.RefreshRates()) return;
   UpdateRiskMetrics();

   // Always run exits, even when halted — flatten as fast as possible.
   ManageBasketExits();

   if(g_haltedByRisk)
     {
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

   // First entries only on a new signal-TF bar to avoid intra-bar overtrading.
   static datetime lastBar = 0;
   datetime curBar = iTime(_Symbol, InpSignalTF, 0);
   bool newBar = (curBar != lastBar);
   if(newBar) lastBar = curBar;

   if(longCnt == 0 && newBar)
      ManageDirection(POSITION_TYPE_BUY,  longCnt,  longLots,  lH, lL, g_long);
   if(shortCnt == 0 && newBar)
      ManageDirection(POSITION_TYPE_SELL, shortCnt, shortLots, sH, sL, g_short);

   // Grid adds: price-triggered each tick, but cooldown-gated inside ManageDirection.
   if(longCnt > 0)
      ManageDirection(POSITION_TYPE_BUY,  longCnt,  longLots,  lH, lL, g_long);
   if(shortCnt > 0)
      ManageDirection(POSITION_TYPE_SELL, shortCnt, shortLots, sH, sL, g_short);
  }
//+------------------------------------------------------------------+
