//+------------------------------------------------------------------+
//|                                        SimpleGrid_Forex_EA.mq5   |
//|        Dual-direction grid EA for Forex pairs.                   |
//|        No entry logic — just opens both sides on start and adds  |
//|        martingale levels on adverse moves. Risk-management:      |
//|        basket SL, daily DD halt, spread filter, pip auto-scale,  |
//|        Friday flat-close, BE trail and cooldown.                 |
//+------------------------------------------------------------------+
#property copyright   "Tembo Algotrading"
#property version     "1.10"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>

// --- Grid mechanics ---
input long   InpMagic         = 20260605;   // Magic number
input double InpLot            = 0.01;      // First lot
input double InpLotMult        = 1.5;       // Lot multiplier per level
input double InpStepPips       = 25.0;      // Grid step in PIPS (auto-scaled to points)
input int    InpMaxLevels      = 8;         // Max levels per direction
input double InpTpMoney        = 3.0;       // Basket take profit (account currency)
input int    InpSlippagePts    = 20;        // Slippage (points)

// --- Risk management ---
input double InpBasketSlPct    = 6.0;       // Basket SL as % of equity (0 = disabled)
input double InpDailyDDPct     = 4.0;       // Daily DD halt % (0 = disabled)
input double InpMaxSpreadPips  = 3.0;       // Skip opens if spread > this (pips, 0 = ignore)
input int    InpCooldownSec    = 10;        // Min seconds between adds per side
input bool   InpUseBeTrail     = true;      // Use breakeven trail
input double InpBeArmFraction  = 0.5;       // Arm BE after profit >= TP * this
input double InpBeLockFraction = 0.25;      // On pullback, close when profit <= TP * this

// --- Time filter ---
input bool   InpFlatOnFriday   = true;      // Close all and stop on Friday after hour
input int    InpFridayCloseHr  = 21;        // Hour (server) to flatten on Friday

CTrade        Trade;
CPositionInfo Pos;
CSymbolInfo   Sym;

double   g_pipSize          = 0.0;     // 10*point for 5/3-digit, point for 4/2-digit
double   g_equityDayStart   = 0.0;
datetime g_dayStartTime     = 0;
bool     g_haltedDaily      = false;
datetime g_lastAddBuy       = 0;
datetime g_lastAddSell      = 0;
bool     g_beArmedBuy       = false;
bool     g_beArmedSell      = false;
double   g_basketTpBuy      = 0.0;
double   g_basketTpSell     = 0.0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!Sym.Name(_Symbol)) return INIT_FAILED;
   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints((ulong)InpSlippagePts);
   Trade.SetTypeFillingBySymbol(_Symbol);

   // Pip size: on 5-digit / 3-digit (JPY) brokers, 1 pip = 10 points.
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pipSize = ((digits == 3) || (digits == 5)) ? (10.0 * Sym.Point()) : Sym.Point();

   g_equityDayStart = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStartTime   = 0;
   g_haltedDaily    = false;
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void Scan(ENUM_POSITION_TYPE dir, int &cnt, double &profit,
          double &bestPrice, double &worstPrice)
  {
   cnt = 0; profit = 0.0;
   bestPrice = 0.0;
   worstPrice = (dir == POSITION_TYPE_BUY) ? DBL_MAX : 0.0;

   for(int i = PositionsTotal()-1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      if(Pos.Magic()  != InpMagic) continue;
      if(Pos.PositionType() != dir) continue;

      cnt++;
      profit += Pos.Profit() + Pos.Swap() + Pos.Commission();
      double p = Pos.PriceOpen();

      if(dir == POSITION_TYPE_BUY)
        {
         if(p > bestPrice)  bestPrice  = p;
         if(p < worstPrice) worstPrice = p;
        }
      else
        {
         if(p > worstPrice) worstPrice = p;
         if(bestPrice == 0.0 || p < bestPrice) bestPrice = p;
        }
     }
   if(dir == POSITION_TYPE_BUY && worstPrice == DBL_MAX) worstPrice = 0.0;
  }

//+------------------------------------------------------------------+
void CloseDirection(ENUM_POSITION_TYPE dir)
  {
   for(int i = PositionsTotal()-1; i >= 0; --i)
     {
      if(!Pos.SelectByIndex(i)) continue;
      if(Pos.Symbol() != _Symbol) continue;
      if(Pos.Magic()  != InpMagic) continue;
      if(Pos.PositionType() != dir) continue;
      Trade.PositionClose(Pos.Ticket(), (ulong)InpSlippagePts);
     }
   if(dir == POSITION_TYPE_BUY)  { g_beArmedBuy  = false; g_basketTpBuy  = 0.0; }
   else                          { g_beArmedSell = false; g_basketTpSell = 0.0; }
  }

void CloseAll()
  {
   CloseDirection(POSITION_TYPE_BUY);
   CloseDirection(POSITION_TYPE_SELL);
  }

//+------------------------------------------------------------------+
double NextLot(int currentLevels)
  {
   double lot = InpLot * MathPow(MathMax(1.0, InpLotMult), currentLevels);
   double step = Sym.LotsStep();
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   if(lot < Sym.LotsMin()) lot = Sym.LotsMin();
   if(lot > Sym.LotsMax()) lot = Sym.LotsMax();
   return NormalizeDouble(lot, 2);
  }

double SpreadPips()
  {
   if(g_pipSize <= 0) return 0;
   return (Sym.Ask() - Sym.Bid()) / g_pipSize;
  }

//+------------------------------------------------------------------+
// Daily DD tracker + halt
void UpdateDailyDD()
  {
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   datetime day0 = StringToTime(StringFormat("%04d.%02d.%02d 00:00", t.year, t.mon, t.day));
   if(g_dayStartTime != day0)
     {
      g_dayStartTime    = day0;
      g_equityDayStart  = AccountInfoDouble(ACCOUNT_EQUITY);
      g_haltedDaily     = false;
     }
   if(InpDailyDDPct <= 0) return;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_equityDayStart > 0)
     {
      double dd = (g_equityDayStart - eq) / g_equityDayStart * 100.0;
      if(dd >= InpDailyDDPct && !g_haltedDaily)
        {
         PrintFormat("HALT: daily DD %.2f%% >= %.2f%%", dd, InpDailyDDPct);
         g_haltedDaily = true;
        }
     }
  }

bool IsFridayFlatTime()
  {
   if(!InpFlatOnFriday) return false;
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   return (t.day_of_week == 5 && t.hour >= InpFridayCloseHr);
  }

//+------------------------------------------------------------------+
// Basket SL by floating loss vs equity %
bool BasketSlHit(double profit)
  {
   if(InpBasketSlPct <= 0) return false;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double sl = eq * InpBasketSlPct / 100.0;
   return (profit <= -sl);
  }

//+------------------------------------------------------------------+
// BE trail per side. Arm at profit >= TP * arm, close on pullback to TP * lock.
bool BreakevenExit(ENUM_POSITION_TYPE dir, double profit)
  {
   if(!InpUseBeTrail) return false;
   if(InpTpMoney <= 0) return false;
   double armLvl  = InpTpMoney * InpBeArmFraction;
   double lockLvl = InpTpMoney * InpBeLockFraction;

   if(dir == POSITION_TYPE_BUY)
     {
      if(!g_beArmedBuy && profit >= armLvl) g_beArmedBuy = true;
      if(g_beArmedBuy && profit > 0 && profit <= lockLvl) return true;
     }
   else
     {
      if(!g_beArmedSell && profit >= armLvl) g_beArmedSell = true;
      if(g_beArmedSell && profit > 0 && profit <= lockLvl) return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
void ManageSide(ENUM_POSITION_TYPE dir)
  {
   int    cnt = 0;
   double profit = 0.0, bestPrice = 0.0, worstPrice = 0.0;
   Scan(dir, cnt, profit, bestPrice, worstPrice);

   if(cnt == 0)
     {
      // reset per-direction BE state when no positions
      if(dir == POSITION_TYPE_BUY)  { g_beArmedBuy  = false; }
      else                          { g_beArmedSell = false; }
     }

   // --- Exits (always run, even when halted) ---
   if(cnt > 0)
     {
      if(profit >= InpTpMoney) { CloseDirection(dir); return; }
      if(BasketSlHit(profit))
        {
         PrintFormat("Basket SL hit (%s): profit=%.2f", EnumToString(dir), profit);
         CloseDirection(dir);
         return;
        }
      if(BreakevenExit(dir, profit))
        {
         PrintFormat("BE lock (%s): profit=%.2f", EnumToString(dir), profit);
         CloseDirection(dir);
         return;
        }
     }

   // --- Halts that prevent new entries ---
   if(g_haltedDaily) return;
   if(IsFridayFlatTime())
     {
      if(cnt > 0) CloseDirection(dir);
      return;
     }
   if(cnt >= InpMaxLevels) return;

   // Spread filter
   if(InpMaxSpreadPips > 0 && SpreadPips() > InpMaxSpreadPips) return;

   double stepPrice = InpStepPips * g_pipSize;
   if(stepPrice <= 0) return;

   Sym.RefreshRates();

   if(cnt == 0)
     {
      double lot = NextLot(0);
      bool ok;
      if(dir == POSITION_TYPE_BUY)
         ok = Trade.Buy(lot, _Symbol, Sym.Ask(), 0, 0, "SimpleGridForex");
      else
         ok = Trade.Sell(lot, _Symbol, Sym.Bid(), 0, 0, "SimpleGridForex");
      if(ok)
        {
         if(dir == POSITION_TYPE_BUY)  g_lastAddBuy  = TimeCurrent();
         else                          g_lastAddSell = TimeCurrent();
        }
      return;
     }

   // Cooldown for adds
   datetime lastAdd = (dir == POSITION_TYPE_BUY) ? g_lastAddBuy : g_lastAddSell;
   if((int)(TimeCurrent() - lastAdd) < InpCooldownSec) return;

   bool addNow = false;
   if(dir == POSITION_TYPE_BUY)
      addNow = (Sym.Ask() <= worstPrice - stepPrice);
   else
      addNow = (Sym.Bid() >= worstPrice + stepPrice);

   if(addNow)
     {
      double lot = NextLot(cnt);
      bool ok;
      if(dir == POSITION_TYPE_BUY)
         ok = Trade.Buy(lot, _Symbol, Sym.Ask(), 0, 0, "SimpleGridForex");
      else
         ok = Trade.Sell(lot, _Symbol, Sym.Bid(), 0, 0, "SimpleGridForex");
      if(ok)
        {
         if(dir == POSITION_TYPE_BUY)  g_lastAddBuy  = TimeCurrent();
         else                          g_lastAddSell = TimeCurrent();
        }
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!Sym.RefreshRates()) return;
   UpdateDailyDD();

   // If halt is in effect — flatten and stop. Exit logic above still ran in ManageSide previously,
   // but on halt we proactively close everything.
   if(g_haltedDaily) { CloseAll(); return; }

   ManageSide(POSITION_TYPE_BUY);
   ManageSide(POSITION_TYPE_SELL);
  }
//+------------------------------------------------------------------+
