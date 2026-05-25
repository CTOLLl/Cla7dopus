//+------------------------------------------------------------------+
//|                                              SimpleGrid_EA.mq5   |
//|        Simplest dual-direction grid EA: opens Buy and Sell       |
//|        baskets, adds martingale levels by fixed step,            |
//|        closes each basket on money take-profit.                  |
//+------------------------------------------------------------------+
#property copyright   "Tembo Algotrading"
#property version     "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>

input long   InpMagic       = 20260602;   // Magic number
input double InpLot          = 0.01;      // First lot
input double InpLotMult      = 1.5;       // Lot multiplier per level
input int    InpStepPoints   = 300;       // Grid step (points)
input int    InpMaxLevels    = 8;         // Max levels per direction
input double InpTpMoney      = 5.0;       // Take profit per basket (account currency)
input int    InpSlippage     = 20;        // Slippage (points)

CTrade        Trade;
CPositionInfo Pos;
CSymbolInfo   Sym;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!Sym.Name(_Symbol)) return INIT_FAILED;
   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints((ulong)InpSlippage);
   Trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
// Aggregate this EA's positions for a given direction
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
         if(p > bestPrice)  bestPrice  = p;     // highest buy entry
         if(p < worstPrice) worstPrice = p;     // lowest  buy entry
        }
      else
        {
         if(p > worstPrice) worstPrice = p;     // highest sell entry
         if(bestPrice == 0.0 || p < bestPrice) bestPrice = p; // lowest sell entry
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
      Trade.PositionClose(Pos.Ticket(), (ulong)InpSlippage);
     }
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

//+------------------------------------------------------------------+
void ManageSide(ENUM_POSITION_TYPE dir)
  {
   int    cnt = 0;
   double profit = 0.0, bestPrice = 0.0, worstPrice = 0.0;
   Scan(dir, cnt, profit, bestPrice, worstPrice);

   // Take profit by money
   if(cnt > 0 && profit >= InpTpMoney)
     {
      CloseDirection(dir);
      return;
     }

   if(cnt >= InpMaxLevels) return;

   double stepPrice = InpStepPoints * Sym.Point();
   Sym.RefreshRates();

   if(cnt == 0)
     {
      // First entry — open immediately
      double lot = NextLot(0);
      if(dir == POSITION_TYPE_BUY)
         Trade.Buy(lot, _Symbol, Sym.Ask(), 0, 0, "SimpleGrid");
      else
         Trade.Sell(lot, _Symbol, Sym.Bid(), 0, 0, "SimpleGrid");
      return;
     }

   // Add next level when price moves further AGAINST the basket
   bool addNow = false;
   if(dir == POSITION_TYPE_BUY)
      addNow = (Sym.Ask() <= worstPrice - stepPrice);
   else
      addNow = (Sym.Bid() >= worstPrice + stepPrice);

   if(addNow)
     {
      double lot = NextLot(cnt);
      if(dir == POSITION_TYPE_BUY)
         Trade.Buy(lot, _Symbol, Sym.Ask(), 0, 0, "SimpleGrid");
      else
         Trade.Sell(lot, _Symbol, Sym.Bid(), 0, 0, "SimpleGrid");
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!Sym.RefreshRates()) return;
   ManageSide(POSITION_TYPE_BUY);
   ManageSide(POSITION_TYPE_SELL);
  }
//+------------------------------------------------------------------+
